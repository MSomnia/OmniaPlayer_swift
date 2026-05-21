import Foundation

public struct Artist: Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public let platform: String
    public var name: String
    public var imageURL: String

    public init(id: String, platform: String, name: String, imageURL: String) {
        self.id = id
        self.platform = platform
        self.name = name
        self.imageURL = imageURL
    }
}
