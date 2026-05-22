import AppKit
import Foundation

@MainActor
final class GitHubReleaseUpdateService: ObservableObject {
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/MSomnia/OmniaPlayer_swift/releases/latest")!
    private static let latestReleasePageURL = URL(string: "https://github.com/MSomnia/OmniaPlayer_swift/releases/latest")!

    @Published private(set) var canCheckForUpdates: Bool = true
    @Published private(set) var status: UpdateStatus?

    var currentVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion?.isEmpty == false ? shortVersion : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(short), .some(build)) where short != build:
            return "\(short) (\(build))"
        case let (.some(short), _):
            return short
        case let (_, .some(build)):
            return build
        default:
            return "1.0"
        }
    }

    var updateSourceText: String {
        Self.latestReleasePageURL.absoluteString
    }

    func checkForUpdates() async {
        guard canCheckForUpdates else { return }

        canCheckForUpdates = false
        status = UpdateStatus(isChecking: true)

        do {
            let release = try await fetchLatestRelease()
            let currentVersion = currentShortVersion
            let latestVersion = release.displayVersion
            let isNewer = Self.compareVersions(latestVersion, currentVersion) == .orderedDescending

            status = UpdateStatus(
                available: isNewer,
                remoteShort: latestVersion,
                commitMessages: release.releaseNoteLines,
                releaseURL: release.htmlURL,
                isChecking: false
            )
        } catch {
            status = UpdateStatus(error: error.localizedDescription, isChecking: false)
        }

        canCheckForUpdates = true
    }

    func openLatestReleasePage() {
        let urlString = status?.releaseURL ?? Self.latestReleasePageURL.absoluteString
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private var currentShortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Omnia", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubReleaseUpdateError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        case 404:
            throw GitHubReleaseUpdateError.noRelease
        default:
            throw GitHubReleaseUpdateError.httpStatus(http.statusCode)
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericVersionComponents(lhs)
        let right = numericVersionComponents(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0

            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }

        return .orderedSame
    }

    private static func numericVersionComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "v" || $0 == "V" }
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: String
    let body: String?

    var displayVersion: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    var releaseNoteLines: [String] {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return name.map { [$0] } ?? []
        }

        return body
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
    }
}

private enum GitHubReleaseUpdateError: LocalizedError {
    case invalidResponse
    case noRelease
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回了无法识别的响应。"
        case .noRelease:
            return "GitHub 上还没有可用的 Release。"
        case .httpStatus(let code):
            return "GitHub Release 检查失败（HTTP \(code)）。"
        }
    }
}
