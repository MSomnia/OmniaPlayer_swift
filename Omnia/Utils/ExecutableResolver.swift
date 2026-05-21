import Foundation

enum ExecutableResolver {
    static func findExecutable(
        named name: String,
        bundledResource: String? = nil,
        extraCandidates: [String] = []
    ) -> String? {
        var candidates: [String] = []

        if let bundledResource,
           let bundled = Bundle.main.path(forResource: bundledResource, ofType: nil) {
            candidates.append(bundled)
        }

        candidates.append(contentsOf: extraCandidates.map(expandTilde))

        for directory in searchPathDirectories() {
            candidates.append((directory as NSString).appendingPathComponent(name))
        }

        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty && seen.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func environmentWithExpandedPATH() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPathDirectories().joined(separator: ":")
        return env
    }

    static func searchPathDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let common = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.nvm/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.pyenv/shims",
            "\(home)/Library/Python/3.12/bin",
            "\(home)/Library/Python/3.11/bin",
            "\(home)/Library/Python/3.10/bin",
            "\(home)/Library/Python/3.9/bin",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin",
            "/Library/Frameworks/Python.framework/Versions/3.9/bin",
        ]
        return uniqued(
            (
                current.split(separator: ":").map(String.init)
                + common
                + childBinDirectories(at: "\(home)/.nvm/versions/node")
                + childBinDirectories(at: "\(home)/.local/share/fnm/node-versions", suffix: "installation/bin")
            ).map(expandTilde)
        )
    }

    private static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func childBinDirectories(at root: String, suffix: String = "bin") -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return children.map { (root as NSString).appendingPathComponent(($0 as NSString).appendingPathComponent(suffix)) }
    }
}
