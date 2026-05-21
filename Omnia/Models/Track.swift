import Foundation

public struct Track: Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public let platform: String
    public var title: String
    public var artist: String
    public var artists: [String]
    public var album: String
    public var albumCoverURL: String
    public var durationMs: Int
    public var isExplicit: Bool
    public var streamURL: String?
    public var playlistItemId: String?

    public init(
        id: String,
        platform: String,
        title: String,
        artist: String,
        artists: [String],
        album: String,
        albumCoverURL: String,
        durationMs: Int,
        isExplicit: Bool = false,
        streamURL: String? = nil,
        playlistItemId: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.title = title
        self.artist = artist
        self.artists = artists
        self.album = album
        self.albumCoverURL = albumCoverURL
        self.durationMs = durationMs
        self.isExplicit = isExplicit
        self.streamURL = streamURL
        self.playlistItemId = playlistItemId
    }
}
