import Foundation
import AVFoundation

// MARK: - LibrespotBackend
//
// Manages Spotify audio playback via a persistent Python daemon.
//
// Architecture:
//   1. startDaemon(accessToken:volume:) spawns the Python helper once and
//      waits for the READY handshake (librespot session created).
//   2. play(trackId:…) sends PLAY <trackId> <durationMs> to the daemon;
//      the daemon streams OGG audio progressively via sounddevice.
//   3. stop() sends STOP (keeps daemon alive for the next track).
//   4. stopDaemon() sends QUIT + terminates the process (called on app close).

@MainActor
public final class LibrespotBackend {

    // MARK: - Callbacks

    public var onPositionChanged: ((Int) -> Void)?
    public var onEndReached: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onPlaybackStarted: (() -> Void)?

    // MARK: - Configuration

    public var deviceName: String = "Omnia"
    public var bitrate: Int = 320

    // MARK: - Private state — Python env

    private let bridge: LibrespotBridge
    private var helperPython: String?
    private var helperPythonTask: Task<String?, Never>?

    // MARK: - Private state — daemon process (persistent)

    private var daemonProcess: Process?
    private var commandPipe: Pipe?
    private var daemonOutputTask: Task<Void, Never>?
    private var daemonStartTask: Task<Void, Error>?
    private var daemonReadyContinuation: CheckedContinuation<Void, Error>?
    private var isDaemonReady = false

    // MARK: - Private state — current track

    private var sampleRate: Double = 44100
    private var framesPlayed: Int64 = 0
    private var volume: Float = 0.7
    private var isPaused = false
    private var playbackStartedAt: Date?
    private var playbackBaseMs = 0
    private var playbackDurationMs = 0
    private var didReachEnd = false
    private var didStartPlayback = false
    private var maxReportedPositionMs = 0

    public init(bridge: LibrespotBridge) {
        self.bridge = bridge
    }

    // MARK: - Public API

    /// Pre-detect the Python runtime in the background so it's ready when
    /// startDaemon() is called.
    public func warmUpRuntime() {
        guard helperPython == nil, helperPythonTask == nil else { return }
        helperPythonTask = Task.detached {
            Self.findSpotifyHelperPython()
        }
    }

    /// Start the persistent daemon process. Waits for the READY handshake
    /// (librespot session created). Safe to call multiple times — no-ops
    /// if the daemon is already running.
    public func startDaemon(accessToken: String, volume: Int) async {
        let clampedVolume = max(0, min(volume, 100))
        self.volume = Float(clampedVolume) / 100.0

        // If a start is already in progress, wait for it instead of racing.
        if let existing = daemonStartTask {
            _ = try? await existing.value
            setVolume(clampedVolume)
            return
        }
        // Already healthy — nothing to do.
        if isDaemonReady, daemonProcess?.isRunning == true {
            setVolume(clampedVolume)
            return
        }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self._doStartDaemon(accessToken: accessToken, volume: clampedVolume)
        }
        daemonStartTask = task
        _ = try? await task.value
        daemonStartTask = nil
    }

    /// Send a PLAY command to the daemon, starting a new track.
    /// Starts (or restarts) the daemon if it is not running.
    public func play(trackId: String, accessToken: String, durationMs: Int = 0) async throws {
        resetTrackState(durationMs: durationMs)

        if !isDaemonReady || daemonProcess?.isRunning != true {
            try await _doStartDaemon(accessToken: accessToken, volume: Int(volume * 100))
        }

        sendCommand("PLAY \(trackId) \(durationMs)")
    }

    public func pause() {
        isPaused = true
        sendCommand("PAUSE")
    }

    public func resume() {
        isPaused = false
        sendCommand("RESUME")
    }

    /// Stop the current track but keep the daemon alive for the next play.
    public func stop() {
        resetTrackState(durationMs: 0)
        if isDaemonReady, daemonProcess?.isRunning == true {
            sendCommand("STOP")
        }
    }

    /// Fully shut down the daemon (call from AppController.close()).
    public func stopDaemon() {
        daemonOutputTask?.cancel()
        daemonOutputTask = nil
        sendCommand("QUIT")
        daemonProcess?.terminate()
        daemonProcess = nil
        commandPipe = nil
        isDaemonReady = false
        // Unblock any in-progress startDaemon wait.
        daemonReadyContinuation?.resume(throwing: LibrespotBackendError.sessionRequired)
        daemonReadyContinuation = nil
        resetTrackState(durationMs: 0)
    }

    public func seek(to ms: Int) {
        playbackBaseMs = max(0, ms)
        framesPlayed = Int64(Double(ms) / 1000.0 * sampleRate)
        sendCommand("SEEK \(max(0, ms))")
    }

    public func setVolume(_ v: Int) {
        volume = Float(max(0, min(v, 100))) / 100.0
        sendCommand("VOLUME \(max(0, min(v, 100)))")
    }

    public var positionMs: Int {
        Int(Double(framesPlayed) / sampleRate * 1000)
    }

    public var hasSession: Bool {
        bridge.hasSession()
    }

    // MARK: - Daemon lifecycle

    private func _doStartDaemon(accessToken: String, volume: Int) async throws {
        _killDaemonProcess()
        let clampedVolume = max(0, min(volume, 100))
        self.volume = Float(clampedVolume) / 100.0

        guard let python = await resolveHelperPython() else {
            throw LibrespotBackendError.pythonNotFound
        }
        guard let helper = Bundle.module.path(forResource: "spotify_playback_helper", ofType: "py")
                ?? Bundle.main.path(forResource: "spotify_playback_helper", ofType: "py") else {
            throw LibrespotBackendError.helperNotFound
        }

        // librespot-python defaults to os.getcwd() for credentials.json.
        // When launched from Finder the CWD is "/" (not writable), which
        // makes Session.Builder().create() fail. Use Application Support instead.
        let appSupportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omnia")
        try? FileManager.default.createDirectory(
            at: appSupportDir, withIntermediateDirectories: true)

        let outPipe = Pipe()
        let inPipe  = Pipe()
        let errPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [helper, accessToken, String(clampedVolume)]
        proc.currentDirectoryURL = appSupportDir
        proc.environment = ExecutableResolver.environmentWithExpandedPATH()
        proc.standardInput  = inPipe
        proc.standardOutput = outPipe
        proc.standardError  = errPipe
        try proc.run()

        daemonProcess = proc
        commandPipe   = inPipe
        isDaemonReady = false

        daemonOutputTask = Task.detached { [weak self] in
            await self?.readDaemonOutput(outPipe: outPipe, errPipe: errPipe, process: proc)
        }

        // Wait for READY with a 20-second timeout.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            daemonReadyContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let pending = self.daemonReadyContinuation else { return }
                    self.daemonReadyContinuation = nil
                    self.isDaemonReady = false
                    pending.resume(throwing: LibrespotBackendError.sessionRequired)
                }
            }
        }
    }

    private func _killDaemonProcess() {
        daemonOutputTask?.cancel()
        daemonOutputTask = nil
        daemonProcess?.terminate()
        daemonProcess = nil
        commandPipe = nil
        isDaemonReady = false
    }

    // MARK: - Daemon stdout reader

    nonisolated private func readDaemonOutput(outPipe: Pipe, errPipe: Pipe, process: Process) async {
        let handle = outPipe.fileHandleForReading
        var buffer = ""
        while !Task.isCancelled {
            guard process.isRunning else { break }
            let data = handle.availableData
            if data.isEmpty {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            buffer += String(data: data, encoding: .utf8) ?? ""
            let parts = buffer.components(separatedBy: .newlines)
            buffer = parts.last ?? ""
            for line in parts.dropLast() {
                guard await isDaemonProcess(process) else { return }
                await handleHelperLine(line)
            }
        }
        if !buffer.isEmpty {
            guard await isDaemonProcess(process) else { return }
            await handleHelperLine(buffer)
        }
        // Daemon exited — mark it dead so the next play() will restart it.
        await MainActor.run { [weak self] in
            guard let self, self.daemonProcess === process else { return }
            self.isDaemonReady = false
            self.daemonProcess = nil
            self.commandPipe = nil
            if let pending = self.daemonReadyContinuation {
                self.daemonReadyContinuation = nil
                pending.resume(throwing: LibrespotBackendError.sessionRequired)
            }
        }
    }

    private func isDaemonProcess(_ process: Process) -> Bool {
        daemonProcess === process
    }

    private func handleHelperLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let kind    = parts[0]
        let payload = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "READY":
            isDaemonReady = true
            daemonReadyContinuation?.resume()
            daemonReadyContinuation = nil
        case "START":
            if let ms = Int(payload), ms > 0 { playbackDurationMs = ms }
            playbackStartedAt = Date()
            didStartPlayback  = true
            onPlaybackStarted?()
        case "POS":
            let ms = Int(payload) ?? 0
            maxReportedPositionMs = max(maxReportedPositionMs, ms)
            framesPlayed = Int64(Double(ms) / 1000.0 * sampleRate)
            onPositionChanged?(ms)
        case "END":
            guard !didReachEnd else { return }
            if didStartPlayback && maxReportedPositionMs > 1000 {
                didReachEnd = true
                onEndReached?()
            } else {
                onError?("Spotify 未成功输出音频，已阻止自动跳到下一首")
            }
        case "STOPPED":
            didReachEnd = true
        case "ERROR":
            onError?(payload)
        default:
            NSLog("[LibrespotBackend] daemon: \(trimmed)")
        }
    }

    // MARK: - Helpers

    private func sendCommand(_ command: String) {
        guard let data = "\(command)\n".data(using: .utf8) else { return }
        try? commandPipe?.fileHandleForWriting.write(contentsOf: data)
    }

    private func resetTrackState(durationMs: Int) {
        framesPlayed          = 0
        isPaused              = false
        playbackStartedAt     = nil
        playbackBaseMs        = 0
        playbackDurationMs    = durationMs
        didReachEnd           = false
        didStartPlayback      = false
        maxReportedPositionMs = 0
    }

    private func resolveHelperPython() async -> String? {
        if let helperPython { return helperPython }
        let task: Task<String?, Never>
        if let existing = helperPythonTask {
            task = existing
        } else {
            task = Task.detached { Self.findSpotifyHelperPython() }
            helperPythonTask = task
        }
        let python = await task.value
        helperPython = python
        helperPythonTask = nil
        return python
    }

    nonisolated private static func findSpotifyHelperPython() -> String? {
        var candidates: [String] = []
        for dir in ExecutableResolver.searchPathDirectories() {
            candidates.append((dir as NSString).appendingPathComponent("python3"))
        }
        candidates.append("/Library/Frameworks/Python.framework/Versions/3.12/bin/python3")
        candidates.append("/Library/Frameworks/Python.framework/Versions/3.11/bin/python3")
        candidates.append("/opt/homebrew/bin/python3")

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if Self.pythonHasSpotifyDependencies(candidate) {
                NSLog("[LibrespotBackend] using Python helper runtime: \(candidate)")
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func pythonHasSpotifyDependencies(_ python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import librespot, sounddevice, soundfile, numpy"]
        process.environment = ExecutableResolver.environmentWithExpandedPATH()
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - Error

public enum LibrespotBackendError: LocalizedError {
    case binaryNotFound
    case pythonNotFound
    case helperNotFound
    case sessionRequired
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "找不到 librespot 二进制文件。请先安装：brew install librespot 或从 https://github.com/librespot-org/librespot 下载后放到 /usr/local/bin/"
        case .pythonNotFound:
            return "找不到带有 librespot/sounddevice/soundfile/numpy 的 python3，无法启动 Spotify 播放 helper"
        case .helperNotFound:
            return "找不到 Spotify 播放 helper"
        case .sessionRequired:
            return "Spotify 会话未建立，请重新登录"
        case .streamFailed(let msg):
            return "Spotify 播放失败：\(msg)"
        }
    }
}
