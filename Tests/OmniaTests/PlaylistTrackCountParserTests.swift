import XCTest
@testable import Omnia

final class PlaylistTrackCountParserTests: XCTestCase {
    func testParsesEnglishSongCounts() {
        XCTAssertEqual(
            PlaylistTrackCountParser.count(fromTexts: ["Playlist", "1,234 songs"]),
            1_234
        )
        XCTAssertEqual(
            PlaylistTrackCountParser.count(fromTexts: ["tracks 42"]),
            42
        )
    }

    func testParsesChineseSongCounts() {
        XCTAssertEqual(
            PlaylistTrackCountParser.count(fromTexts: ["播放列表", "86 首歌曲"]),
            86
        )
        XCTAssertEqual(
            PlaylistTrackCountParser.count(fromTexts: ["12首"]),
            12
        )
    }

    func testParsesNestedSpotifyTrackMetadata() {
        let data: [String: Any] = [
            "tracks": [
                "pagingInfo": [
                    "totalCount": 37
                ]
            ]
        ]

        XCTAssertEqual(PlaylistTrackCountParser.count(fromTrackMetadata: data["tracks"]), 37)
    }

    func testDoesNotTreatTrackingParamsAsTrackCount() {
        let data: [String: Any] = [
            "trackingParams": "CAAQARgBGAIiEwj60046",
            "subtitle": [
                "runs": [
                    ["text": "Playlist"]
                ]
            ]
        ]

        XCTAssertNil(PlaylistTrackCountParser.count(from: data))
    }
}
