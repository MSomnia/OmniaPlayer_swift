import Foundation
import AppKit

/// Manages credentials and session lifecycle for the librespot Rust binary.
///
/// The Rust librespot binary handles Spotify audio decryption. This bridge:
/// 1. Stores/checks the credentials.json file librespot reads on startup.
/// 2. Creates a session via the librespot binary using an access token or OAuth.
///
/// Stream playback is handled separately by LibrespotBackend (Audio/).
public actor LibrespotBridge {

    public nonisolated let credentialsPath: String
    private var activeProcess: Process?

    /// - Parameter credentialsPath: Path for librespot's credentials JSON.
    ///   Defaults to `~/Library/Application Support/Omnia/spotify_credentials.json`.
    public init(credentialsPath: String? = nil) {
        if let path = credentialsPath {
            self.credentialsPath = path
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Omnia")
            self.credentialsPath = support
                .appendingPathComponent("spotify_credentials.json")
                .path
        }
    }

    // MARK: - Session status

    /// Returns true if a credentials file exists (session can be restored).
    public nonisolated func hasSession() -> Bool {
        FileManager.default.fileExists(atPath: credentialsPath)
    }

    // MARK: - Create session via access token

    /// Write a credentials stub that tells librespot to authenticate using the
    /// provided Spotify access token on its next launch.
    ///
    /// librespot (Rust) accepts `AUTHENTICATION_SPOTIFY_TOKEN` when started with
    /// `--access-token <token>`. We persist just enough metadata so that
    /// LibrespotBackend can pass the token on the command line.
    public func createSessionWithToken(_ token: String) async throws {
        try ensureCredentialDirectory()
        let payload: [String: String] = [
            "type": "access_token",
            "access_token": token,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: .prettyPrinted)
        try data.write(to: URL(fileURLWithPath: credentialsPath), options: .atomic)
    }

    // MARK: - Create session via OAuth (opens system browser)

    /// Launch librespot with `--oauth` to begin the OAuth flow.
    /// `urlCallback` receives the authorization URL to open in the browser.
    /// Blocks (via async) until librespot writes credentials to disk or times out.
    public func createSessionOAuth(
        urlCallback: @escaping @Sendable (String) -> Void
    ) async throws {
        let librespotBinary = findLibrespotBinary()
        guard let binary = librespotBinary else {
            throw LibrespotError.binaryNotFound
        }
        try ensureCredentialDirectory()

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--name", "Omnia",
            "--credentials-path", credentialsPath,
            "--oauth",
        ]
        process.environment = ExecutableResolver.environmentWithExpandedPATH()
        process.standardOutput = pipe
        process.standardError  = pipe

        try process.run()
        self.activeProcess = process

        // Read stdout/stderr to find the OAuth URL
        let handle = pipe.fileHandleForReading
        let outputQueue = DispatchQueue(label: "librespot.output")
        outputQueue.async {
            var buffer = ""
            while process.isRunning {
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                buffer += chunk
                // librespot prints the URL like: "Please open ... https://accounts.spotify.com/..."
                let lines = buffer.components(separatedBy: .newlines)
                for line in lines {
                    if let range = line.range(of: "https://accounts.spotify.com") {
                        let urlStr = String(line[range.lowerBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if URL(string: urlStr) != nil {
                            urlCallback(urlStr)
                        }
                    }
                }
                buffer = lines.last ?? ""
            }
        }

        // Wait up to 5 minutes for credentials to appear
        let deadline = Date().addingTimeInterval(300)
        while !hasSession() && Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
        }
        process.terminate()
        self.activeProcess = nil
        if !hasSession() {
            throw LibrespotError.oauthTimeout
        }
    }

    // MARK: - Close

    public func close() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    // MARK: - Helpers

    private func ensureCredentialDirectory() throws {
        let dir = (credentialsPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
    }

    /// Search for the librespot binary in common locations.
    public nonisolated func findLibrespotBinary() -> String? {
        ExecutableResolver.findExecutable(
            named: "librespot",
            bundledResource: "librespot",
            extraCandidates: [
                "/opt/homebrew/bin/librespot",
                "/usr/local/bin/librespot",
                (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                    .appendingPathComponent(".cargo/bin/librespot"),
            ]
        )
    }

    /// Load the stored access token if credentials were created via `createSessionWithToken`.
    public func storedAccessToken() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credentialsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              json["type"] == "access_token"
        else { return nil }
        return json["access_token"]
    }
}

// MARK: - Error

public enum LibrespotError: Error {
    case binaryNotFound
    case oauthTimeout
    case sessionFailed(String)
}
