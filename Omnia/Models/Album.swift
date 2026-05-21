import Foundation

public struct Album: Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public let platform: String
    public var name: String
    public var artist: String
    public var coverURL: String
    public var trackCount: Int
    public var year: String

    public init(
        id: String,
        platform: String,
        name: String,
        artist: String,
        coverURL: String,
        trackCount: Int = 0,
        year: String = ""
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.artist = artist
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.year = year
    }
}
