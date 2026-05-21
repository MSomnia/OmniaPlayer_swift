import Foundation

public struct Playlist: Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public let platform: String
    public var name: String
    public var coverURL: String
    public var trackCount: Int
    public var tracks: [Track]

    public init(
        id: String,
        platform: String,
        name: String,
        coverURL: String,
        trackCount: Int,
        tracks: [Track] = []
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.tracks = tracks
    }
}
