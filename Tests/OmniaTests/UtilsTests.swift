import AppKit
import XCTest
@testable import Omnia

final class UtilsTests: XCTestCase {
    func testLRCParserParsesAndSortsTimedLines() {
        let text = """
        [00:10.50] second line
        [00:01.23] first line
        [00:15.000] final line
        """

        let lines = LRCParser.parse(text)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].startMs, 1_230)
        XCTAssertEqual(lines[0].endMs, 10_500)
        XCTAssertEqual(lines[0].text, "first line")
        XCTAssertEqual(lines[1].startMs, 10_500)
        XCTAssertEqual(lines[1].endMs, 15_000)
        XCTAssertEqual(lines[2].endMs, 20_000)
        XCTAssertEqual(lines[2].words, [])
    }

    func testLRCParserSupportsMultipleTimestampsOnOneLine() {
        let lines = LRCParser.parse("[00:01.00][00:02.00] repeat")

        XCTAssertEqual(lines.map(\.startMs), [1_000, 2_000])
        XCTAssertEqual(lines.map(\.text), ["repeat", "repeat"])
    }

    func testTTMLParserParsesLineAndWordTimings() throws {
        let xml = """
        <tt>
          <body>
            <div>
              <p begin="00:00:10.000" end="00:00:12.000">
                <span begin="00:00:10.000" end="00:00:10.500">Hello</span>
                <span begin="00:00:10.500" end="00:00:11.200">world</span>
              </p>
              <p begin="PT13.25S" dur="1.5s">Plain line</p>
            </div>
          </body>
        </tt>
        """

        let lines = TTMLParser.parse(Data(xml.utf8))

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].startMs, 10_000)
        XCTAssertEqual(lines[0].endMs, 12_000)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].words, [
            LyricWord(startMs: 10_000, endMs: 10_500, text: "Hello"),
            LyricWord(startMs: 10_500, endMs: 11_200, text: "world")
        ])

        XCTAssertEqual(lines[1].startMs, 13_250)
        XCTAssertEqual(lines[1].endMs, 14_750)
        XCTAssertEqual(lines[1].text, "Plain line")
        XCTAssertEqual(lines[1].words, [])
    }

    func testLyricsEngineFindsCurrentLineWordAndProgress() {
        let lines = [
            LyricLine(
                startMs: 1_000,
                endMs: 3_000,
                text: "Hello world",
                words: [
                    LyricWord(startMs: 1_000, endMs: 2_000, text: "Hello"),
                    LyricWord(startMs: 2_000, endMs: 3_000, text: "world")
                ]
            ),
            LyricLine(startMs: 4_000, endMs: 5_000, text: "Next")
        ]
        let engine = LyricsEngine(lines: lines)

        XCTAssertNil(engine.currentLineIndex(positionMs: 500))
        XCTAssertEqual(engine.currentLineIndex(positionMs: 2_250), 0)
        XCTAssertEqual(engine.currentWordIndex(lineIndex: 0, positionMs: 2_250), 1)
        XCTAssertEqual(engine.currentLineIndex(positionMs: 3_000), nil)
        XCTAssertEqual(engine.currentPosition(positionMs: 4_500)?.lineIndex, 1)
        XCTAssertEqual(engine.progressInLine(lineIndex: 0, positionMs: 2_000), 0.5, accuracy: 0.001)
        XCTAssertEqual(engine.progressInLine(lineIndex: 0, positionMs: 500), 0, accuracy: 0.001)
        XCTAssertEqual(engine.progressInLine(lineIndex: 0, positionMs: 4_000), 1, accuracy: 0.001)
    }

    func testDominantColorExtractsAverageRGBFromImageData() async throws {
        let data = try makePNGData(red: 0.2, green: 0.4, blue: 0.6)

        let color = await DominantColor.extract(from: data)

        let rgb = try XCTUnwrap(color)
        XCTAssertEqual(rgb.0, 51, accuracy: 8)
        XCTAssertEqual(rgb.1, 102, accuracy: 8)
        XCTAssertEqual(rgb.2, 153, accuracy: 8)
    }

    private func makePNGData(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "UtilsTests", code: 1)
        }

        let color = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        for x in 0..<2 {
            for y in 0..<2 {
                bitmap.setColor(color, atX: x, y: y)
            }
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "UtilsTests", code: 2)
        }
        return data
    }
}
