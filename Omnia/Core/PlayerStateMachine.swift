import Foundation
import Combine

// MARK: - PlayerStateMachine
//
// Mirrors Python core/player.py (UnifiedPlayer).
// State transitions:
//   IDLE → load() → LOADING → onLoadSuccess() → PLAYING
//   PLAYING → pause() → PAUSED → resume() → PLAYING
//   any → stop() → IDLE
//   LOADING → onLoadError() → ERROR

@MainActor
public final class PlayerStateMachine: ObservableObject {

    @Published public private(set) var state: PlayerState = PlayerState()

    public init() {}

    // MARK: - Track lifecycle

    /// Begin loading a track. Transitions: any → LOADING.
    public func load(_ track: Track) {
        state.currentTrack = track
        state.positionMs   = 0
        state.durationMs   = track.durationMs
        state.status       = .loading
    }

    /// Confirm successful load. Transitions: LOADING → PLAYING.
    public func onLoadSuccess() {
        guard state.status == .loading else { return }
        state.status = .playing
    }

    /// Report a load error. Transitions: LOADING → ERROR.
    public func onLoadError(_ message: String) {
        guard state.status == .loading else { return }
        state.status = .error
    }

    /// Report an error from an already-started backend.
    public func onPlaybackError(_ message: String) {
        state.status = .error
    }

    // MARK: - Playback control

    /// Pause. Transitions: PLAYING → PAUSED.
    public func pause() {
        guard state.status == .playing else { return }
        state.status = .paused
    }

    /// Resume. Transitions: PAUSED → PLAYING.
    public func resume() {
        guard state.status == .paused else { return }
        state.status = .playing
    }

    /// Stop and reset. Transitions: any → IDLE.
    public func stop() {
        state.currentTrack = nil
        state.positionMs   = 0
        state.durationMs   = 0
        state.status       = .idle
    }

    /// Seek to a position (only in PLAYING or PAUSED state).
    public func seek(to ms: Int) {
        guard state.status == .playing || state.status == .paused else { return }
        state.positionMs = max(0, min(ms, state.durationMs))
    }

    // MARK: - Player settings

    public func setVolume(_ volume: Int) {
        state.volume = max(0, min(volume, 100))
    }

    public func setShuffle(_ enabled: Bool) {
        state.shuffle = enabled
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        state.repeatMode = mode
    }

    // MARK: - Backend callbacks

    /// Called by VLCBackend / LibrespotBackend position ticker.
    public func updatePosition(_ ms: Int) {
        state.positionMs = ms
    }

    /// Called once when the backend first reports a real duration.
    public func updateDuration(_ ms: Int) {
        guard ms != state.durationMs else { return }
        state.durationMs = ms
    }
}
