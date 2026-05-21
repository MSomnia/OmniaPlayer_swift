#!/usr/bin/env python3
from __future__ import annotations

import io
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

paused = False
stopped = False
seek_pos: int | None = None
volume = 0.7
lock = threading.Lock()


def emit(kind: str, payload: str = "") -> None:
    print(f"{kind} {payload}".rstrip(), flush=True)


def command_loop(total_frames: int, samplerate: int) -> None:
    global paused, stopped, seek_pos, volume
    while not stopped:
        readable, _, _ = select.select([sys.stdin], [], [], 0.05)
        if not readable:
            continue
        line = sys.stdin.readline()
        if not line:
            break
        parts = line.strip().split()
        if not parts:
            continue
        cmd = parts[0].upper()
        with lock:
            if cmd == "PAUSE":
                paused = True
            elif cmd == "RESUME":
                paused = False
            elif cmd == "STOP":
                stopped = True
            elif cmd == "SEEK" and len(parts) > 1:
                ms = max(0, int(float(parts[1])))
                seek_pos = min(int(ms * samplerate / 1000), max(total_frames - 1, 0))
            elif cmd == "VOLUME" and len(parts) > 1:
                volume = max(0.0, min(float(parts[1]) / 100.0, 1.0))


def create_session(access_token: str) -> Session:
    builder = Session.Builder()
    builder.login_credentials = LoginCredentials(
        typ=AuthenticationType.AUTHENTICATION_SPOTIFY_TOKEN,
        auth_data=access_token.encode("utf-8"),
    )
    return builder.create()


def load_track(access_token: str, track_id: str) -> tuple[np.ndarray, int]:
    session = create_session(access_token)
    loaded = session.content_feeder().load(
        TrackId.from_uri(f"spotify:track:{track_id}"),
        VorbisOnlyAudioQuality(AudioQuality.HIGH),
        False,
        None,
    )

    buf = io.BytesIO()
    audio_stream = loaded.input_stream.stream()
    while True:
        chunk = audio_stream.read(CHUNK_SIZE)
        if not chunk:
            break
        buf.write(chunk)
    buf.seek(0)

    with sf.SoundFile(buf) as sound_file:
        samplerate = sound_file.samplerate
        audio_data = sound_file.read(dtype="float32")

    if audio_data.ndim == 1:
        audio_data = audio_data.reshape(-1, 1)
    return audio_data, samplerate


def play(audio_data: np.ndarray, samplerate: int, initial_volume: int) -> None:
    global paused, stopped, seek_pos, volume
    volume = max(0.0, min(initial_volume / 100.0, 1.0))
    total = len(audio_data)
    if total <= 0:
        raise RuntimeError("Spotify track decoded to empty audio")
    channels = audio_data.shape[1] if audio_data.ndim > 1 else 1
    pos = 0
    last_report_ms = -REPORT_MS
    started = False

    threading.Thread(target=command_loop, args=(total, samplerate), daemon=True).start()

    with sd.OutputStream(samplerate=samplerate, channels=channels, dtype="float32") as stream:
        while not stopped:
            with lock:
                local_paused = paused
                local_seek = seek_pos
                seek_pos = None
                local_volume = volume

            if local_seek is not None:
                pos = local_seek
            if local_paused:
                time.sleep(0.02)
                continue

            end = pos + BLOCK_SIZE
            block = audio_data[pos:end]
            if len(block) == 0:
                break
            if len(block) < BLOCK_SIZE:
                block = np.pad(block, ((0, BLOCK_SIZE - len(block)), (0, 0)))
            stream.write(block * local_volume)
            if not started:
                started = True
                emit("START", str(int(total / max(samplerate, 1) * 1000)))
            pos = min(end, total)

            now_ms = int(pos / max(samplerate, 1) * 1000)
            if now_ms - last_report_ms >= REPORT_MS:
                last_report_ms = now_ms
                emit("POS", str(now_ms))

    if stopped:
        emit("STOPPED")
    else:
        emit("END")


def main() -> int:
    if len(sys.argv) < 4:
        emit("ERROR", "usage: spotify_playback_helper.py <track_id> <access_token> <volume>")
        return 2
    track_id = sys.argv[1]
    access_token = sys.argv[2]
    initial_volume = int(sys.argv[3])
    try:
        audio_data, samplerate = load_track(access_token, track_id)
        play(audio_data, samplerate, initial_volume)
        return 0
    except Exception as exc:
        emit("ERROR", str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
