import Foundation

public struct UpdateStatus: Equatable, Hashable, Codable {
    public var available: Bool
    public var remoteShort: String
    public var commitMessages: [String]
    public var error: String?
    public var releaseURL: String?
    public var isChecking: Bool

    public init(
        available: Bool = false,
        remoteShort: String = "",
        commitMessages: [String] = [],
        error: String? = nil,
        releaseURL: String? = nil,
        isChecking: Bool = false
    ) {
        self.available = available
        self.remoteShort = remoteShort
        self.commitMessages = commitMessages
        self.error = error
        self.releaseURL = releaseURL
        self.isChecking = isChecking
    }
}
