import Foundation

enum PlaylistTrackCountParser {
    static func count(from value: Any?) -> Int? {
        guard let value else { return nil }
        return metadataCount(in: value, parentKey: nil, isTrackContext: false)
            ?? count(fromTexts: collectText(in: value))
    }

    static func count(fromTrackMetadata value: Any?) -> Int? {
        guard let value else { return nil }
        return metadataCount(in: value, parentKey: nil, isTrackContext: true)
            ?? count(fromTexts: collectText(in: value))
    }

    static func count(fromTexts texts: [String]) -> Int? {
        for text in texts {
            if let count = count(fromText: text) {
                return count
            }
        }
        return nil
    }

    private static func metadataCount(in value: Any, parentKey: String?, isTrackContext: Bool) -> Int? {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if isCountKey(key, parentKey: parentKey, isTrackContext: isTrackContext),
                   let count = numericValue(child) {
                    return count
                }
            }

            for (key, child) in dict {
                let lower = key.lowercased()
                let childIsTrackContext = isTrackContext || ["track", "tracks", "song", "songs"].contains(lower)
                if let count = metadataCount(in: child, parentKey: key, isTrackContext: childIsTrackContext) {
                    return count
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let count = metadataCount(in: child, parentKey: parentKey, isTrackContext: isTrackContext) {
                    return count
                }
            }
        }
        return nil
    }

    private static func isCountKey(_ key: String, parentKey: String?, isTrackContext: Bool) -> Bool {
        let lower = key.lowercased()
        let parent = parentKey?.lowercased() ?? ""
        if [
            "trackcount",
            "songcount",
            "totaltrackcount",
            "totalsongcount",
            "numberoftracks",
            "numberofsongs",
        ].contains(lower) {
            return true
        }
        if ["totalcount", "count", "itemcount", "total"].contains(lower) {
            return isTrackContext || ["track", "tracks", "song", "songs"].contains(parent)
        }
        return false
    }

    private static func numericValue(_ value: Any) -> Int? {
        if let intValue = value as? Int, intValue > 0 {
            return intValue
        }
        if let doubleValue = value as? Double, doubleValue > 0 {
            return Int(doubleValue)
        }
        if let stringValue = value as? String {
            let digits = stringValue.filter(\.isNumber)
            if let intValue = Int(digits), intValue > 0 {
                return intValue
            }
        }
        return nil
    }

    private static func count(fromText text: String) -> Int? {
        let patterns: [(String, Int)] = [
            (#"(?i)(\d[\d,.\s]*)\s*(songs?|tracks?)\b"#, 1),
            (#"(?i)\b(?:songs?|tracks?)\s*(\d[\d,.\s]*)"#, 1),
            (#"(\d[\d,，.\s]*)\s*(?:首歌曲|首歌|首|歌曲)"#, 1),
        ]

        for (pattern, captureIndex) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > captureIndex
            else { continue }

            let raw = nsText.substring(with: match.range(at: captureIndex))
            let digits = raw.filter(\.isNumber)
            if let count = Int(digits), count > 0 {
                return count
            }
        }
        return nil
    }

    private static func collectText(in value: Any) -> [String] {
        var result: [String] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let text = dict["text"] as? String {
                    result.append(text)
                }
                if let simpleText = dict["simpleText"] as? String {
                    result.append(simpleText)
                }
                for child in dict.values {
                    walk(child)
                }
            } else if let array = node as? [Any] {
                for child in array {
                    walk(child)
                }
            }
        }
        walk(value)
        return result
    }
}
