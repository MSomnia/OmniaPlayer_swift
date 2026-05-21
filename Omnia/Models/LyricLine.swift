import Foundation

public struct LyricWord: Equatable, Hashable, Codable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public struct LyricLine: Identifiable, Equatable, Hashable, Codable {
    public let id: UUID
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public var words: [LyricWord]

    public init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        text: String,
        words: [LyricWord] = []
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.words = words
    }
}
