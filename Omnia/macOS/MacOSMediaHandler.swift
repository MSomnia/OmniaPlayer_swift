import Foundation
import AppKit
import MediaPlayer

// MARK: - MacOSMediaHandler
//
// Mirrors Python core/macos_media.py (MacOSMediaHandler).
// Responsibilities:
//   - MPNowPlayingInfoCenter  → lock-screen / Control Center track info
//   - MPRemoteCommandCenter   → media keys (F7/F8/F9, AirPods, etc.)
//   - StatusItemManager       → menu-bar icon + scrolling title

@MainActor
public final class MacOSMediaHandler {

    public weak var controller: AppController?

    private let nowPlaying  = MPNowPlayingInfoCenter.default()
    private let commands    = MPRemoteCommandCenter.shared()
    private let statusItem  = StatusItemManager()

    private var coverData: Data?
    private var currentTrack: Track?

    public init() {}

    // MARK: - Setup

    public func setup(controller: AppController) {
        self.controller = controller
        registerRemoteCommands()
        setupStatusItem()
    }

    // MARK: - Full update (track change, play/pause, seek)

    public func updateNowPlaying(track: Track?, positionMs: Int, isPlaying: Bool) {
        currentTrack = track
        statusItem.updateTitle(track: track, isPlaying: isPlaying)

        guard let track else {
            nowPlaying.nowPlayingInfo = nil
            nowPlaying.playbackState  = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle:              track.title,
            MPMediaItemPropertyArtist:             track.artist,
            MPMediaItemPropertyAlbumTitle:         track.album,
            MPMediaItemPropertyPlaybackDuration:   Double(track.durationMs) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate:  isPlaying ? 1.0 : 0.0,
        ]

        if let data = coverData, let image = NSImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: CGSize(width: 300, height: 300)
            ) { _ in image }
        }

        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState  = isPlaying ? .playing : .paused
    }

    // MARK: - Lightweight position-only update (every 250ms)

    public func updatePosition(_ ms: Int, isPlaying: Bool) {
        guard currentTrack != nil,
              var info = nowPlaying.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(ms) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState  = isPlaying ? .playing : .paused
    }

    // MARK: - Cover art

    public func setCoverArt(data: Data) {
        coverData = data
        // Re-push the updated artwork if we have a current track
        if let track = currentTrack {
            let isPlaying = nowPlaying.playbackState == .playing
            let elapsed = (nowPlaying.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0) * 1000
            updateNowPlaying(track: track, positionMs: Int(elapsed), isPlaying: isPlaying)
        }
    }

    // MARK: - Status bar

    public func setupStatusItem() {
        statusItem.setup(controller: controller)
    }

    // MARK: - Cleanup

    public func close() {
        nowPlaying.nowPlayingInfo = nil
        nowPlaying.playbackState  = .stopped

        // Deregister all command handlers
        commands.playCommand.removeTarget(nil)
        commands.pauseCommand.removeTarget(nil)
        commands.togglePlayPauseCommand.removeTarget(nil)
        commands.nextTrackCommand.removeTarget(nil)
        commands.previousTrackCommand.removeTarget(nil)
        commands.changePlaybackPositionCommand.removeTarget(nil)

        statusItem.teardown()
    }

    // MARK: - Remote command registration

    private func registerRemoteCommands() {
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.controller?.togglePlayPause() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.controller?.togglePlayPause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.controller?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.controller?.playNext() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.controller?.playPrev() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let seekEvent = event as? MPChangePlaybackPositionCommandEvent {
                let ms = Int(seekEvent.positionTime * 1000)
                Task { @MainActor [weak self] in self?.controller?.seek(to: ms) }
            }
            return .success
        }
    }
}
