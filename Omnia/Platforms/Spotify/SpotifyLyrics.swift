import Foundation

private let lyricsEndpoint = "https://spclient.wg.spotify.com/color-lyrics/v2/track/"

public struct SpotifyLyrics {

    /// Fetch lyrics for a Spotify track.
    /// Returns word-synced lines when available, falls back to line-synced.
    public static func fetch(trackId: String, token: String) async throws -> [LyricLine] {
        guard let url = URL(string: lyricsEndpoint + trackId) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WebPlayer", forHTTPHeaderField: "App-Platform")
        request.setValue("1.2.50.248", forHTTPHeaderField: "Spotify-App-Version")
        request.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return [] }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return parse(json)
    }

    // MARK: - Parse

    private static func parse(_ data: [String: Any]) -> [LyricLine] {
        let lyrics = data["lyrics"] as? [String: Any] ?? [:]
        let linesRaw = lyrics["lines"] as? [[String: Any]] ?? []
        let syncType = lyrics["syncType"] as? String ?? "LINE_SYNCED"
        var result: [LyricLine] = []

        for (i, line) in linesRaw.enumerated() {
            let startMs = Int(line["startTimeMs"] as? String ?? "0") ?? 0
            let endMsRaw = line["endTimeMs"] as? String ?? "0"
            let endMs: Int
            if let rawVal = Int(endMsRaw), rawVal > 0 {
                endMs = rawVal
            } else if i + 1 < linesRaw.count {
                endMs = Int(linesRaw[i + 1]["startTimeMs"] as? String ?? "0") ?? (startMs + 5000)
            } else {
                endMs = startMs + 5000
            }

            let text = line["words"] as? String ?? ""
            let syllables = line["syllables"] as? [[String: Any]] ?? []

            let words: [LyricWord]
            if !syllables.isEmpty && syncType == "WORD_SYNCED" {
                words = syllables.map { s in
                    LyricWord(
                        startMs: Int(s["startTimeMs"] as? String ?? "0") ?? startMs,
                        endMs:   Int(s["endTimeMs"]   as? String ?? "0") ?? endMs,
                        text:    (s["text"] as? String) ?? (s["word"] as? String) ?? ""
                    )
                }
            } else {
                words = []
            }

            result.append(LyricLine(startMs: startMs, endMs: endMs, text: text, words: words))
        }
        return result
    }
}
