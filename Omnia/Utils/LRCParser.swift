import Foundation

public struct LRCParser {
    public init() {}

    public static func parse(_ text: String) -> [LyricLine] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let pattern = #"\[(\d{2,}):(\d{2,3})\.(\d{2,3})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        var parsed: [(startMs: Int, text: String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = regex.matches(in: line, range: nsRange)
            guard !matches.isEmpty else {
                continue
            }

            let lyricStart = matches.last?.range.upperBound ?? 0
            let lyricText = String(line[Range(NSRange(location: lyricStart, length: nsRange.length - lyricStart), in: line)!])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            for match in matches {
                guard
                    let minutesRange = Range(match.range(at: 1), in: line),
                    let secondsRange = Range(match.range(at: 2), in: line),
                    let fractionRange = Range(match.range(at: 3), in: line),
                    let startMs = parseMilliseconds(
                        minutes: String(line[minutesRange]),
                        seconds: String(line[secondsRange]),
                        fraction: String(line[fractionRange])
                    )
                else {
                    continue
                }

                parsed.append((startMs, lyricText))
            }
        }

        let sorted = parsed.sorted { lhs, rhs in
            if lhs.startMs == rhs.startMs {
                return lhs.text < rhs.text
            }
            return lhs.startMs < rhs.startMs
        }

        return sorted.enumerated().map { index, item in
            let endMs = index + 1 < sorted.count ? sorted[index + 1].startMs : item.startMs + 5_000
            return LyricLine(startMs: item.startMs, endMs: endMs, text: item.text)
        }
    }

    private static func parseMilliseconds(minutes: String, seconds: String, fraction: String) -> Int? {
        guard let minutes = Int(minutes), let seconds = Int(seconds) else {
            return nil
        }

        let milliseconds = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3)) ?? 0
        return minutes * 60_000 + seconds * 1_000 + milliseconds
    }
}
