import Foundation

private let lrclibSearchURL = "https://lrclib.net/api/search"

public struct YTMusicLyrics {

    /// Fetch order (most useful first):
    /// 1. LRCLIB.net — synced LRC, enables lyric scroll
    /// 2. YTMusic internal — plain text only (no timestamps), shown as static block
    /// 3. Return empty
    public static func fetch(track: Track, client: YTMusicClient) async throws -> [LyricLine] {
        if let lines = try? await fetchFromLRCLIB(track: track), !lines.isEmpty {
            return lines
        }
        if let lines = try? await fetchFromYTMusic(track: track, client: client), !lines.isEmpty {
            return lines
        }
        return []
    }

    // MARK: - LRCLIB

    private static func fetchFromLRCLIB(track: Track) async throws -> [LyricLine] {
        let rawTitle = normalizedSongTitle(track.title)
        let artist   = normalizedArtist(track.artist)
        guard !rawTitle.isEmpty else { return [] }

        // Try the normalized title first, then strip a leading "Artist - " prefix.
        // Many YTMusic video titles use "Artist Name - Song Title" format which
        // doesn't match LRCLIB entries stored under just "Song Title".
        var candidates = [rawTitle]
        for sep in [" - ", " – ", " — "] {
            if let sepRange = rawTitle.range(of: sep) {
                let stripped = String(rawTitle[sepRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty && stripped != rawTitle {
                    candidates.append(stripped)
                    break
                }
            }
        }

        for title in candidates {
            if let lines = try? await queryLRCLIB(title: title, artist: artist), !lines.isEmpty {
                return lines
            }
        }
        return []
    }

    private static func queryLRCLIB(title: String, artist: String) async throws -> [LyricLine] {
        var comps = URLComponents(string: lrclibSearchURL)!
        comps.queryItems = [
            URLQueryItem(name: "track_name",  value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = comps.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        for item in results {
            if let synced = item["syncedLyrics"] as? String, !synced.isEmpty {
                let lines = LRCParser.parse(synced)
                if !lines.isEmpty { return lines }
            }
        }
        for item in results {
            if let plain = item["plainLyrics"] as? String,
               !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [LyricLine(
                    startMs: 0,
                    endMs: Int.max,
                    text: plain.trimmingCharacters(in: .whitespacesAndNewlines),
                    words: []
                )]
            }
        }
        return []
    }

    // MARK: - YTMusic internal lyrics

    private static func fetchFromYTMusic(track: Track, client: YTMusicClient) async throws -> [LyricLine] {
        guard !track.id.isEmpty else { return [] }

        let nextResp = try await client.innertube("next", body: ["videoId": track.id])
        guard let browseId = extractLyricsBrowseId(from: nextResp), !browseId.isEmpty else {
            return []
        }

        let browseResp = try await client.innertube("browse", body: ["browseId": browseId])

        let text = extractLyricsText(from: browseResp)
        guard !text.isEmpty else { return [] }

        return [LyricLine(startMs: 0, endMs: Int.max, text: text, words: [])]
    }

    private static func extractLyricsBrowseId(from nextResp: [String: Any]) -> String? {
        let c = nextResp["contents"] as? [String: Any]
        let single = c?["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any]
        let tabbed = (single?["tabbedRenderer"] as? [String: Any])?["watchNextTabbedResultsRenderer"] as? [String: Any]
        let tabs = tabbed?["tabs"] as? [[String: Any]] ?? []

        for tab in tabs {
            guard let tr = tab["tabRenderer"] as? [String: Any] else { continue }
            let title = (tr["title"] as? String ?? "")
            let accessibility = (((tr["accessibility"] as? [String: Any])?["accessibilityData"] as? [String: Any])?["label"] as? String) ?? ""
            let tabText = [title, accessibility, allText(in: tr)].joined(separator: " ").lowercased()
            if tabText.contains("lyric") || tabText.contains("歌词") {
                if let browseId = firstBrowseId(in: tr) {
                    return browseId
                }
            }
        }
        return firstBrowseId(in: nextResp) { $0.hasPrefix("MPLYt") }
    }

    private static func extractLyricsText(from browseResp: [String: Any]) -> String {
        let candidates = musicDescriptionShelves(in: browseResp)
            .map { textValue($0["description"]) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let text = candidates.max { $0.count < $1.count } ?? ""
        let unavailable = text.lowercased()
        if unavailable.contains("lyrics aren") || unavailable.contains("暂无歌词") {
            return ""
        }
        return text
    }

    // MARK: - Normalizers

    private static func normalizedSongTitle(_ raw: String) -> String {
        raw
            .replacingOccurrences(
                of: #"\s*[\(\[（【].*?(official|audio|video|mv|lyrics?|歌词|动态歌词|完整版|高音质).*?[\)\]）】]"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s*[-–—]\s*(official|audio|video|mv|lyrics?|歌词).*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedArtist(_ raw: String) -> String {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",/&、•"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
    }

    // MARK: - JSON helpers

    private static func musicDescriptionShelves(in value: Any) -> [[String: Any]] {
        if let dict = value as? [String: Any] {
            var result: [[String: Any]] = []
            if let shelf = dict["musicDescriptionShelfRenderer"] as? [String: Any] {
                result.append(shelf)
            }
            for child in dict.values {
                result.append(contentsOf: musicDescriptionShelves(in: child))
            }
            return result
        }
        if let array = value as? [Any] {
            return array.flatMap { musicDescriptionShelves(in: $0) }
        }
        return []
    }

    private static func firstBrowseId(in value: Any, where predicate: (String) -> Bool = { _ in true }) -> String? {
        if let dict = value as? [String: Any] {
            if let endpoint = dict["browseEndpoint"] as? [String: Any],
               let browseId = endpoint["browseId"] as? String,
               predicate(browseId) {
                return browseId
            }
            if let browseId = dict["browseId"] as? String, predicate(browseId) {
                return browseId
            }
            for child in dict.values {
                if let browseId = firstBrowseId(in: child, where: predicate) {
                    return browseId
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let browseId = firstBrowseId(in: child, where: predicate) {
                    return browseId
                }
            }
        }
        return nil
    }

    private static func allText(in value: Any) -> String {
        if let dict = value as? [String: Any] {
            return dict.values.map { allText(in: $0) }.joined(separator: " ")
        }
        if let array = value as? [Any] {
            return array.map { allText(in: $0) }.joined(separator: " ")
        }
        return value as? String ?? ""
    }

    private static func textValue(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let dict = value as? [String: Any] else { return "" }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }
}
