import Foundation
import AVFoundation

#if canImport(VLCKit)
import VLCKit
#endif

// MARK: - VLCBackend
//
// Primary: AVFoundation (AVPlayer). When VLCKit.xcframework is placed at
// Vendor/VLCKit/VLCKit.xcframework and linked, the #if canImport(VLCKit)
// block replaces this implementation automatically.

@MainActor
public final class VLCBackend: NSObject {

    // MARK: Callbacks

    public var onPositionChanged: ((Int) -> Void)?   // ms
    public var onDurationChanged: ((Int) -> Void)?   // ms, fires once on first known duration
    public var onEndReached: (() -> Void)?
    public var onError: ((String) -> Void)?

#if canImport(VLCKit)
    // ── VLCKit implementation ─────────────────────────────────────────────────

    private var vlcPlayer: VLCMediaPlayer?
    private var pollTimer: Timer?
    private var reportedDuration: Int = 0

    public override init() {
        super.init()
        let p = VLCMediaPlayer()
        p.delegate = self
        vlcPlayer = p
    }

    public func play(url: String, httpUA: String? = nil, httpHeaders: [String: String] = [:]) {
        guard let p = vlcPlayer, let u = URL(string: url) else { return }
        reportedDuration = 0
        let media = VLCMedia(url: u)
        if let ua = httpUA { media.addOption(":http-user-agent=\(ua)") }
        if let referer = httpHeaders["Referer"] ?? httpHeaders["referrer"] {
            media.addOption(":http-referrer=\(referer)")
        }
        p.media = media
        p.play()
        startPoll()
    }

    public func pause()              { vlcPlayer?.pause() }
    public func resume()             { vlcPlayer?.play() }
    public func stop()               { stopPoll(); vlcPlayer?.stop() }
    public func seek(to ms: Int)     { vlcPlayer?.time = VLCTime(int: Int32(ms)) }
    public func setVolume(_ v: Int)  { vlcPlayer?.audio.volume = Int32(max(0, min(v, 200))) }

    public var positionMs: Int { Int(vlcPlayer?.time.intValue ?? 0) }
    public var durationMs:  Int { Int(vlcPlayer?.media?.length.intValue ?? 0) }

    private func startPoll() {
        stopPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ms = Int(self.vlcPlayer?.time.intValue ?? 0)
            if ms >= 0 { self.onPositionChanged?(ms) }
            let dur = Int(self.vlcPlayer?.media?.length.intValue ?? 0)
            if dur > 0 && dur != self.reportedDuration {
                self.reportedDuration = dur
                self.onDurationChanged?(dur)
            }
        }
    }
    private func stopPoll() { pollTimer?.invalidate(); pollTimer = nil }

#else
    // ── AVFoundation fallback ─────────────────────────────────────────────────

    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var reportedDuration: Int = 0

    public override init() { super.init() }

    public func play(url: String, httpUA: String? = nil, httpHeaders: [String: String] = [:]) {
        stop()
        reportedDuration = 0
        guard let mediaURL = URL(string: url) else {
            onError?("Invalid URL")
            return
        }

        var headers = httpHeaders
        if let ua = httpUA {
            headers["User-Agent"] = ua
        }
        let assetOptions = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: mediaURL, options: assetOptions)

        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        p.allowsExternalPlayback = false
        avPlayer = p
        p.play()

        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, time.isNumeric else { return }
                self.onPositionChanged?(Int(time.seconds * 1000))
                if let d = self.avPlayer?.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                    let durMs = Int(d.seconds * 1000)
                    if durMs != self.reportedDuration {
                        self.reportedDuration = durMs
                        self.onDurationChanged?(durMs)
                    }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onEndReached?() }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                          .localizedDescription ?? "Playback error"
            Task { @MainActor [weak self] in self?.onError?(msg) }
        }
    }

    public func pause()  { avPlayer?.pause() }
    public func resume() { avPlayer?.play() }

    public func stop() {
        avPlayer?.pause()
        if let obs = timeObserver { avPlayer?.removeTimeObserver(obs); timeObserver = nil }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs); endObserver  = nil }
        if let obs = failObserver { NotificationCenter.default.removeObserver(obs); failObserver = nil }
        avPlayer = nil
        reportedDuration = 0
    }

    public func seek(to ms: Int) {
        avPlayer?.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000),
                       toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func setVolume(_ volume: Int) {
        avPlayer?.volume = Float(max(0, min(volume, 100))) / 100.0
    }

    public var positionMs: Int {
        guard let t = avPlayer?.currentTime(), t.isNumeric else { return 0 }
        return Int(t.seconds * 1000)
    }
    public var durationMs: Int {
        guard let d = avPlayer?.currentItem?.duration, d.isNumeric else { return 0 }
        return Int(d.seconds * 1000)
    }

#endif
}

// MARK: - VLCKit delegate (only when VLCKit is available)

#if canImport(VLCKit)
extension VLCBackend: VLCMediaPlayerDelegate {
    public func mediaPlayerTimeChanged(_ notification: Notification) {}

    public func mediaPlayerStateChanged(_ notification: Notification) {
        switch vlcPlayer?.state {
        case .ended:
            stopPoll()
            onEndReached?()
        case .error:
            stopPoll()
            onError?("VLC playback error")
        default:
            break
        }
    }
}
#endif
