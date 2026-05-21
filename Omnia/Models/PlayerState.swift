import Foundation

public enum PlaybackStatus: String, Equatable, Hashable, Codable {
    case idle
    case loading
    case playing
    case paused
    case error
}

public enum RepeatMode: String, Equatable, Hashable, CaseIterable, Codable {
    case none
    case one
    case all
}

public struct PlayerState: Equatable, Hashable, Codable {
    public var status: PlaybackStatus
    public var currentTrack: Track?
    public var positionMs: Int
    public var durationMs: Int
    public var volume: Int
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    public var queue: [Track]
    public var queueIndex: Int

    public init(
        status: PlaybackStatus = .idle,
        currentTrack: Track? = nil,
        positionMs: Int = 0,
        durationMs: Int = 0,
        volume: Int = 70,
        shuffle: Bool = false,
        repeatMode: RepeatMode = .none,
        queue: [Track] = [],
        queueIndex: Int = -1
    ) {
        self.status = status
        self.currentTrack = currentTrack
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.volume = volume
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.queue = queue
        self.queueIndex = queueIndex
    }
}
