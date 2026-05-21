import Foundation
import AVFoundation

// MARK: - LibrespotBackend
//
// Manages Spotify audio playback via the Rust librespot binary.
//
// Architecture:
//   1. A small Python helper uses librespot-python to decrypt the selected track.
//   2. sounddevice plays PCM locally, matching the proven Python implementation.
//   3. The helper reports START/POS/END lines over stdout.
//   4. Omnia sends pause/resume/seek/volume commands over stdin.

@MainActor
public final class LibrespotBackend {

    // MARK: - Callbacks

    public var onPositionChanged: ((Int) -> Void)?   // ms
    public var onEndReached: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onPlaybackStarted: (() -> Void)?

    // MARK: - Configuration

    public var deviceName: String = "Omnia"
    public var bitrate: Int = 320          // 96 | 160 | 320

    // MARK: - Private state

    private let bridge: LibrespotBridge
    private var process: Process?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var commandPipe: Pipe?

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

    public func play(trackId: String, accessToken: String, durationMs: Int = 0) async throws {
        stop()
        framesPlayed = 0
        isPaused = false
        playbackStartedAt = nil
        playbackBaseMs = 0
        playbackDurationMs = durationMs
        didReachEnd = false
        didStartPlayback = false
        maxReportedPositionMs = 0
        guard let python = findSpotifyHelperPython() else {
            throw LibrespotBackendError.pythonNotFound
        }
        guard let helper = Bundle.module.path(forResource: "spotify_playback_helper", ofType: "py")
                ?? Bundle.main.path(forResource: "spotify_playback_helper", ofType: "py") else {
            throw LibrespotBackendError.helperNotFound
        }

        let errPipe = Pipe()
        let outPipe = Pipe()
        let inPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [
            helper,
            trackId,
            accessToken,
            String(Int(volume * 100)),
        ]
        proc.environment = ExecutableResolver.environmentWithExpandedPATH()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError  = errPipe
        try proc.run()
        process = proc
        commandPipe = inPipe

        streamTask = Task { [weak self] in
            await self?.readHelperOutput(outPipe: outPipe, errPipe: errPipe)
        }
    }

    public func pause() {
        isPaused = true
        sendCommand("PAUSE")
    }

    public func resume() {
        isPaused = false
        sendCommand("RESUME")
    }

    public func stop() {
        streamTask?.cancel(); streamTask = nil
        positionTask?.cancel(); positionTask = nil
        sendCommand("STOP")
        process?.terminate(); process = nil
        commandPipe = nil
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        framesPlayed = 0
        isPaused = false
        playbackStartedAt = nil
        playbackBaseMs = 0
        playbackDurationMs = 0
        didReachEnd = false
        didStartPlayback = false
        maxReportedPositionMs = 0
    }

    public func seek(to ms: Int) {
        playbackBaseMs = max(0, ms)
        framesPlayed = Int64(Double(ms) / 1000.0 * sampleRate)
        sendCommand("SEEK \(max(0, ms))")
    }

    public func setVolume(_ v: Int) {
        volume = Float(max(0, min(v, 100))) / 100.0
        audioEngine?.mainMixerNode.outputVolume = volume
        sendCommand("VOLUME \(max(0, min(v, 100)))")
    }

    public var positionMs: Int {
        Int(Double(framesPlayed) / sampleRate * 1000)
    }

    public var hasSession: Bool {
        bridge.hasSession()
    }

    private func readHelperOutput(outPipe: Pipe, errPipe: Pipe) async {
        let handle = outPipe.fileHandleForReading
        var buffer = ""
        while !Task.isCancelled {
            guard let proc = process, proc.isRunning else { break }
            let data = handle.availableData
            if data.isEmpty {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            buffer += String(data: data, encoding: .utf8) ?? ""
            let parts = buffer.components(separatedBy: .newlines)
            buffer = parts.last ?? ""
            for line in parts.dropLast() {
                await handleHelperLine(line)
            }
        }
        if !buffer.isEmpty {
            await handleHelperLine(buffer)
        }
        guard !Task.isCancelled, !didReachEnd else { return }
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !err.isEmpty {
            await MainActor.run { [weak self] in self?.onError?(err) }
        }
    }

    private func handleHelperLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let kind = parts[0]
        let payload = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "START":
            playbackDurationMs = Int(payload) ?? playbackDurationMs
            playbackStartedAt = Date()
            didStartPlayback = true
            await MainActor.run { [weak self] in self?.onPlaybackStarted?() }
        case "POS":
            let ms = Int(payload) ?? 0
            maxReportedPositionMs = max(maxReportedPositionMs, ms)
            framesPlayed = Int64(Double(ms) / 1000.0 * sampleRate)
            await MainActor.run { [weak self] in self?.onPositionChanged?(ms) }
        case "END":
            if didStartPlayback && maxReportedPositionMs > 1000 {
                didReachEnd = true
                await MainActor.run { [weak self] in self?.onEndReached?() }
            } else {
                await MainActor.run { [weak self] in
                    self?.onError?("Spotify 未成功输出音频，已阻止自动跳到下一首")
                }
            }
        case "STOPPED":
            didReachEnd = true
        case "ERROR":
            await MainActor.run { [weak self] in self?.onError?(payload) }
        default:
            NSLog("[LibrespotBackend] helper: \(trimmed)")
        }
    }

    private func sendCommand(_ command: String) {
        guard let data = "\(command)\n".data(using: .utf8) else { return }
        try? commandPipe?.fileHandleForWriting.write(contentsOf: data)
    }

    private func findSpotifyHelperPython() -> String? {
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
            if pythonHasSpotifyDependencies(candidate) {
                NSLog("[LibrespotBackend] using Python helper runtime: \(candidate)")
                return candidate
            }
        }
        return nil
    }

    private func pythonHasSpotifyDependencies(_ python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            "-c",
            "import librespot, sounddevice, soundfile, numpy",
        ]
        process.environment = ExecutableResolver.environmentWithExpandedPATH()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
