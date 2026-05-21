import Foundation

private let lyricsURL = "https://music.163.com/weapi/song/lyric/v1"

public struct NeteaseLyrics {

    /// Fetch lyrics for a track using the Netease weapi.
    /// Prefers word-level klyric; falls back to line-level LRC.
    public static func fetch(
        trackId: String,
        cookies: [String: String],
        session: URLSession = .shared
    ) async throws -> [LyricLine] {
        let payload = try NeteaseCrypto.weapiEncrypt([
            "id": Int(trackId) ?? 0,
            "lv": 1,
            "kv": 1,
            "csrf_token": cookies["__csrf"] ?? ""
        ])

        var request = URLRequest(url: URL(string: lyricsURL)!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.httpBody = formEncode(payload)

        let (data, _) = try await session.data(for: request)
        guard !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        return parseResponse(json)
    }

    static func parseResponse(_ json: [String: Any]) -> [LyricLine] {
        // Try word-level klyric first
        if let klyricText = (json["klyric"] as? [String: Any])?["lyric"] as? String,
           !klyricText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = parseKlyric(klyricText)
            if !lines.isEmpty { return lines }
        }

        // Fall back to line-level LRC
        let lrcText = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        return LRCParser.parse(lrcText)
    }

    // MARK: - klyric parser
    //
    // Format per line: [startMs,durationMs]<wordOffsetMs,wordDurationMs>text<...>...
    // Example: [12000,5000]<0,500>Hello <500,300>World

    private static func parseKlyric(_ text: String) -> [LyricLine] {
        // Regex patterns
        let linePattern  = #"^\[(\d+),(\d+)\](.*)$"#
        let wordPattern  = #"<(\d+),(\d+)(?:,\d+)?>([^<\[]*)"#

        guard let lineRegex = try? NSRegularExpression(pattern: linePattern),
              let wordRegex = try? NSRegularExpression(pattern: wordPattern)
        else { return [] }

        var result: [LyricLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            guard let lineMatch = lineRegex.firstMatch(in: line, range: fullRange),
                  let startRange = Range(lineMatch.range(at: 1), in: line),
                  let durRange   = Range(lineMatch.range(at: 2), in: line),
                  let bodyRange  = Range(lineMatch.range(at: 3), in: line),
                  let startMs    = Int(line[startRange]),
                  let durationMs = Int(line[durRange])
            else { continue }

            let body = String(line[bodyRange])

            // Parse word-level tokens
            let bodyNS = body as NSString
            let bodyRange2 = NSRange(location: 0, length: bodyNS.length)
            let wordMatches = wordRegex.matches(in: body, range: bodyRange2)

            var words: [LyricWord] = []
            var fullText = ""

            for wm in wordMatches {
                guard let wStartRange = Range(wm.range(at: 1), in: body),
                      let wDurRange   = Range(wm.range(at: 2), in: body),
                      let wTextRange  = Range(wm.range(at: 3), in: body),
                      let wStart = Int(body[wStartRange]),
                      let wDur   = Int(body[wDurRange])
                else { continue }

                let wordText = String(body[wTextRange])
                fullText += wordText
                words.append(LyricWord(
                    startMs: startMs + wStart,
                    endMs:   startMs + wStart + wDur,
                    text:    wordText
                ))
            }

            // If no word tokens found, use the entire body as plain text
            if words.isEmpty { fullText = body.trimmingCharacters(in: .whitespacesAndNewlines) }

            let endMs = startMs + durationMs
            result.append(LyricLine(
                startMs: startMs,
                endMs:   endMs,
                text:    fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                words:   words
            ))
        }

        return result.sorted { $0.startMs < $1.startMs }
    }
}
