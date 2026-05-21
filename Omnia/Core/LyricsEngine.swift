import Foundation

public struct LyricsEngine {
    public var lines: [LyricLine]

    public init(lines: [LyricLine] = []) {
        self.lines = lines
    }

    public func currentLineIndex(positionMs: Int) -> Int? {
        guard !lines.isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = lines.count

        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if lines[midpoint].startMs <= positionMs {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        let index = lowerBound - 1
        guard index >= 0, lines[index].endMs > positionMs else {
            return nil
        }
        return index
    }

    public func currentWordIndex(lineIndex: Int, positionMs: Int) -> Int? {
        guard lines.indices.contains(lineIndex) else {
            return nil
        }

        let words = lines[lineIndex].words
        guard !words.isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = words.count

        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if words[midpoint].startMs <= positionMs {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        let index = lowerBound - 1
        guard index >= 0, words[index].endMs > positionMs else {
            return nil
        }
        return index
    }

    public func progressInLine(lineIndex: Int, positionMs: Int) -> Double {
        guard lines.indices.contains(lineIndex) else {
            return 0
        }

        let line = lines[lineIndex]
        let duration = max(line.endMs - line.startMs, 1)
        let elapsed = positionMs - line.startMs
        return min(max(Double(elapsed) / Double(duration), 0), 1)
    }

    public func currentPosition(positionMs: Int) -> (lineIndex: Int, wordIndex: Int?)? {
        guard let lineIndex = currentLineIndex(positionMs: positionMs) else {
            return nil
        }
        return (lineIndex, currentWordIndex(lineIndex: lineIndex, positionMs: positionMs))
    }
}
