#!/usr/bin/env python3
"""
Persistent Spotify playback daemon for OmniaPlayer Swift.

argv:  <access_token> <initial_volume_0_to_100>
stdin:
    PLAY <track_id> <duration_ms>   – start/restart streaming track
    PAUSE                           – pause
    RESUME                          – resume
    STOP                            – stop track (daemon stays alive)
    SEEK <ms>                       – seek to position
    VOLUME <0-100>                  – set volume
    QUIT                            – exit
stdout:
    READY                           – session ready, accepting PLAY
    START <duration_ms>             – first PCM block delivered
    POS <ms>                        – position (~250 ms)
    END                             – track ended naturally
    STOPPED                         – stopped by STOP command
    ERROR <message>
"""
from __future__ import annotations

import select
import sys
import threading
import time

import numpy as np
import sounddevice as sd
import soundfile as sf
from librespot.audio.decoders import AudioQuality, VorbisOnlyAudioQuality
from librespot.core import Session
from librespot.metadata import TrackId
from librespot.proto.Authentication_pb2 import AuthenticationType, LoginCredentials

BLOCK_SIZE = 1024
CHUNK_SIZE = 16384
REPORT_MS = 250


def emit(kind: str, payload: str = "") -> None:
    print(f"{kind} {payload}".rstrip(), flush=True)


class StreamingBuffer:
    """
    Thread-safe blocking buffer for progressive OGG/Vorbis decode.

    - write(data): called from the download thread as chunks arrive.
    - read(n): blocks until n bytes are available or EOF/abort.
    - seek(pos, SEEK_END): returns a 64 MiB overestimate before finish() so
      libsndfile can open the OGG container without waiting for the full
      download. After finish(), returns the true size.
    - abort(): causes pending read() calls to return b"" immediately so
      the playback thread can exit when a new PLAY interrupts it.
    """

    _OVERESTIMATE = 64 * 1024 * 1024  # 64 MiB

    def __init__(self) -> None:
        self._buf = bytearray()
        self._pos = 0
        self._eof = False
        self._aborted = False
        self._cond = threading.Condition()

    def write(self, data: bytes) -> None:
        with self._cond:
            self._buf.extend(data)
            self._cond.notify_all()

    def finish(self) -> None:
        with self._cond:
            self._eof = True
            self._cond.notify_all()

    def abort(self) -> None:
        with self._cond:
            self._aborted = True
            self._eof = True
            self._cond.notify_all()

    def read(self, n: int = -1) -> bytes:
        with self._cond:
            if n <= 0:
                while not self._eof:
                    self._cond.wait(0.05)
                data = bytes(self._buf[self._pos :])
                self._pos = len(self._buf)
                return data
            while len(self._buf) - self._pos < n and not self._eof:
                self._cond.wait(0.05)
            if self._aborted and len(self._buf) - self._pos < n:
                return b""
            avail = min(n, len(self._buf) - self._pos)
            data = bytes(self._buf[self._pos : self._pos + avail])
            self._pos += avail
            return data

    def seek(self, pos: int, whence: int = 0) -> int:
        with self._cond:
            if whence == 0:
                self._pos = max(0, pos)
            elif whence == 1:
                self._pos = max(0, self._pos + pos)
            elif whence == 2:
                if not self._eof:
                    # Don't block — return overestimate so libsndfile opens immediately
                    return self._OVERESTIMATE + pos
                self._pos = max(0, len(self._buf) + pos)
            return self._pos

    def tell(self) -> int:
        with self._cond:
            return self._pos

    def seekable(self) -> bool:
        return True

    def readable(self) -> bool:
        return True

    @property
    def name(self) -> str:
        return "<streaming-ogg>"


class SpotifyDaemon:
    def __init__(self, access_token: str, initial_volume: int) -> None:
        self._session: Session | None = None
        self._access_token = access_token
        self._lock = threading.Lock()
        self._volume = max(0.0, min(initial_volume / 100.0, 1.0))
        self._paused = False
        self._stopped_track = False
        self._seek_ms: int | None = None
        self._play_gen = 0
        self._current_buf: StreamingBuffer | None = None
        self._playback_done = threading.Event()
        self._playback_done.set()

    # ------------------------------------------------------------------
    # Session
    # ------------------------------------------------------------------

    def create_session(self) -> None:
        builder = Session.Builder()
        builder.login_credentials = LoginCredentials(
            typ=AuthenticationType.AUTHENTICATION_SPOTIFY_TOKEN,
            auth_data=self._access_token.encode("utf-8"),
        )
        self._session = builder.create()

    # ------------------------------------------------------------------
    # Playback
    # ------------------------------------------------------------------

    def start_track(self, track_id: str, duration_ms: int) -> None:
        # Abort current playback and bump generation counter
        with self._lock:
            if self._current_buf is not None:
                self._current_buf.abort()
            self._stopped_track = False
            self._paused = False
            self._seek_ms = None
            self._play_gen += 1
            my_gen = self._play_gen

        # Wait (briefly) for the previous playback thread to release sounddevice
        self._playback_done.wait(timeout=0.3)
        self._playback_done.clear()

        threading.Thread(
            target=self._stream_and_play,
            args=(track_id, duration_ms, my_gen),
            daemon=True,
        ).start()

    def _stream_and_play(self, track_id: str, duration_ms: int, my_gen: int) -> None:
        assert self._session is not None
        try:
            loaded = self._session.content_feeder().load(
                TrackId.from_uri(f"spotify:track:{track_id}"),
                VorbisOnlyAudioQuality(AudioQuality.HIGH),
                False,
                None,
            )
        except Exception as exc:
            if self._is_current(my_gen):
                emit("ERROR", str(exc))
            self._playback_done.set()
            return

        audio_stream = loaded.input_stream.stream()
        buf = StreamingBuffer()
        with self._lock:
            self._current_buf = buf

        def download() -> None:
            try:
                while True:
                    if buf._aborted:
                        break
                    chunk = audio_stream.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    buf.write(chunk)
            finally:
                buf.finish()

        threading.Thread(target=download, daemon=True).start()

        ended_naturally = False
        try:
            with sf.SoundFile(buf) as sf_file:
                sf_file.seek(0)  # reset after libsndfile's internal header seeks
                samplerate = sf_file.samplerate
                channels = max(sf_file.channels, 1)
                pos_frames = 0
                last_report_ms = -REPORT_MS
                started = False

                with sd.OutputStream(
                    samplerate=samplerate, channels=channels, dtype="float32"
                ) as stream:
                    while True:
                        if not self._is_current(my_gen):
                            return

                        with self._lock:
                            local_paused = self._paused
                            local_seek = self._seek_ms
                            self._seek_ms = None
                            local_volume = self._volume
                            local_stopped = self._stopped_track

                        if local_stopped:
                            emit("STOPPED")
                            return

                        if local_seek is not None:
                            seek_frame = int(local_seek * samplerate / 1000)
                            try:
                                sf_file.seek(seek_frame)
                                pos_frames = seek_frame
                            except Exception:
                                pass

                        if local_paused:
                            time.sleep(0.02)
                            continue

                        block = sf_file.read(BLOCK_SIZE, dtype="float32", always_2d=True)
                        if len(block) == 0:
                            ended_naturally = True
                            break
                        if len(block) < BLOCK_SIZE:
                            block = np.pad(block, ((0, BLOCK_SIZE - len(block)), (0, 0)))

                        stream.write(block * local_volume)

                        if not started:
                            started = True
                            emit("START", str(duration_ms))

                        pos_frames += BLOCK_SIZE
                        pos_ms = int(pos_frames / samplerate * 1000)
                        if pos_ms - last_report_ms >= REPORT_MS:
                            last_report_ms = pos_ms
                            emit("POS", str(pos_ms))

        except Exception as exc:
            if self._is_current(my_gen):
                emit("ERROR", str(exc))
        finally:
            self._playback_done.set()
            with self._lock:
                if self._current_buf is buf:
                    self._current_buf = None

        if self._is_current(my_gen) and ended_naturally:
            emit("END")

    def _is_current(self, gen: int) -> bool:
        with self._lock:
            return self._play_gen == gen

    # ------------------------------------------------------------------
    # Command handler
    # ------------------------------------------------------------------

    def handle_command(self, line: str) -> bool:
        """Returns False when the daemon should exit."""
        parts = line.strip().split(maxsplit=2)
        if not parts:
            return True
        cmd = parts[0].upper()

        if cmd == "PLAY" and len(parts) >= 2:
            track_id = parts[1]
            duration_ms = int(parts[2]) if len(parts) > 2 else 0
            self.start_track(track_id, duration_ms)
        elif cmd == "PAUSE":
            with self._lock:
                self._paused = True
        elif cmd == "RESUME":
            with self._lock:
                self._paused = False
        elif cmd == "STOP":
            with self._lock:
                self._stopped_track = True
                if self._current_buf is not None:
                    self._current_buf.abort()
        elif cmd == "SEEK" and len(parts) > 1:
            try:
                with self._lock:
                    self._seek_ms = max(0, int(float(parts[1])))
            except ValueError:
                pass
        elif cmd == "VOLUME" and len(parts) > 1:
            try:
                with self._lock:
                    self._volume = max(0.0, min(float(parts[1]) / 100.0, 1.0))
            except ValueError:
                pass
        elif cmd == "QUIT":
            return False
        return True


def main() -> int:
    if len(sys.argv) < 3:
        emit("ERROR", "usage: spotify_playback_helper.py <access_token> <volume>")
        return 2

    access_token = sys.argv[1]
    try:
        initial_volume = int(sys.argv[2])
    except ValueError:
        initial_volume = 70

    daemon = SpotifyDaemon(access_token, initial_volume)
    try:
        daemon.create_session()
    except Exception as exc:
        emit("ERROR", f"session: {exc}")
        return 1

    emit("READY")

    while True:
        try:
            readable, _, _ = select.select([sys.stdin], [], [], 0.1)
            if readable:
                line = sys.stdin.readline()
                if not line:
                    break
                if not daemon.handle_command(line):
                    break
        except (KeyboardInterrupt, EOFError):
            break

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
