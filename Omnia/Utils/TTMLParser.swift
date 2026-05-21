import Foundation

public final class TTMLParser: NSObject, XMLParserDelegate {
    private var parsedLines: [LyricLine] = []
    private var currentLine: WorkingLine?
    private var currentWord: WorkingWord?
    private var parseFailed = false

    public override init() {
        super.init()
    }

    public static func parse(_ data: Data) -> [LyricLine] {
        let parserDelegate = TTMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), !parserDelegate.parseFailed else {
            return []
        }

        return parserDelegate.parsedLines.sorted { $0.startMs < $1.startMs }
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "p":
            guard let startMs = Self.timeValue(attributeDict["begin"]) else {
                currentLine = nil
                return
            }
            let endMs = Self.endValue(from: attributeDict, fallbackStartMs: startMs)
            currentLine = WorkingLine(startMs: startMs, endMs: endMs)

        case "span":
            guard currentLine != nil else {
                return
            }
            let startMs = Self.timeValue(attributeDict["begin"]) ?? currentLine?.startMs ?? 0
            let endMs = Self.endValue(from: attributeDict, fallbackStartMs: startMs)
            currentWord = WorkingWord(startMs: startMs, endMs: endMs)

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentWord != nil {
            currentWord?.text += string
        } else {
            currentLine?.text += string
        }
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName.lowercased() {
        case "span":
            guard var word = currentWord else {
                return
            }
            word.text = Self.normalizedText(word.text)
            if !word.text.isEmpty {
                currentLine?.words.append(LyricWord(
                    startMs: word.startMs,
                    endMs: word.endMs ?? word.startMs,
                    text: word.text
                ))
            }
            currentWord = nil

        case "p":
            guard let line = currentLine else {
                return
            }

            let lineText = Self.normalizedText(line.text)
            let words = line.words.filter { !$0.text.isEmpty }
            let text = lineText.isEmpty ? words.map(\.text).joined(separator: " ") : lineText
            guard !text.isEmpty || !words.isEmpty else {
                currentLine = nil
                return
            }

            let inferredEnd = words.last?.endMs ?? line.startMs + 5_000
            parsedLines.append(LyricLine(
                startMs: line.startMs,
                endMs: line.endMs ?? inferredEnd,
                text: text,
                words: words
            ))
            currentLine = nil

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parseFailed = true
    }

    private static func endValue(from attributes: [String: String], fallbackStartMs: Int) -> Int? {
        if let end = timeValue(attributes["end"]) {
            return end
        }
        if let duration = timeValue(attributes["dur"]) {
            return fallbackStartMs + duration
        }
        return nil
    }

    private static func timeValue(_ value: String?) -> Int? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("PT"), value.hasSuffix("S") {
            value.removeFirst(2)
            value.removeLast()
            return secondsToMilliseconds(value)
        }

        if value.lowercased().hasSuffix("ms") {
            value.removeLast(2)
            return Int(Double(value) ?? .nan)
        }

        if value.lowercased().hasSuffix("s") {
            value.removeLast()
            return secondsToMilliseconds(value)
        }

        let components = value.split(separator: ":").map(String.init)
        if components.count == 3 {
            guard let hours = Int(components[0]), let minutes = Int(components[1]) else {
                return nil
            }
            return (hours * 3_600_000) + (minutes * 60_000) + (secondsToMilliseconds(components[2]) ?? 0)
        }

        if components.count == 2 {
            guard let minutes = Int(components[0]) else {
                return nil
            }
            return (minutes * 60_000) + (secondsToMilliseconds(components[1]) ?? 0)
        }

        return secondsToMilliseconds(value)
    }

    private static func secondsToMilliseconds(_ value: String) -> Int? {
        guard let seconds = Double(value) else {
            return nil
        }
        return Int((seconds * 1_000).rounded())
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct WorkingLine {
    var startMs: Int
    var endMs: Int?
    var text = ""
    var words: [LyricWord] = []
}

private struct WorkingWord {
    var startMs: Int
    var endMs: Int?
    var text = ""
}
