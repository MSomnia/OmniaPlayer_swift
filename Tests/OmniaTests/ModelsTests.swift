import XCTest
@testable import Omnia

final class ModelsTests: XCTestCase {
    func testTrackRequiredFieldsAndDefaults() {
        let track = makeTrack()

        XCTAssertEqual(track.id, "123")
        XCTAssertEqual(track.platform, "netease")
        XCTAssertFalse(track.isExplicit)
        XCTAssertNil(track.streamURL)
        XCTAssertNil(track.playlistItemId)
    }

    func testLyricWordFields() {
        let word = LyricWord(startMs: 0, endMs: 500, text: "Hello")

        XCTAssertEqual(word.startMs, 0)
        XCTAssertEqual(word.endMs, 500)
        XCTAssertEqual(word.text, "Hello")
    }

    func testLyricLineDefaultWords() {
        let line = LyricLine(startMs: 0, endMs: 4_000, text: "Hello world")

        XCTAssertEqual(line.startMs, 0)
        XCTAssertEqual(line.endMs, 4_000)
        XCTAssertEqual(line.text, "Hello world")
        XCTAssertEqual(line.words, [])
    }

    func testPlaylistDefaultTracks() {
        let playlist = Playlist(
            id: "p1",
            platform: "spotify",
            name: "My Mix",
            coverURL: "",
            trackCount: 10
        )

        XCTAssertEqual(playlist.tracks, [])
    }

    func testPlayerStateDefaultsIncludeQueueState() {
        let state = PlayerState()

        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.currentTrack)
        XCTAssertEqual(state.positionMs, 0)
        XCTAssertEqual(state.durationMs, 0)
        XCTAssertEqual(state.volume, 70)
        XCTAssertFalse(state.shuffle)
        XCTAssertEqual(state.repeatMode, .none)
        XCTAssertEqual(state.queue, [])
        XCTAssertEqual(state.queueIndex, -1)
    }

    func testArtistAndAlbumFields() {
        let artist = Artist(
            id: "artist-1",
            platform: "netease",
            name: "Artist A",
            imageURL: "https://example.com/pic.jpg"
        )
        let album = Album(
            id: "album-1",
            platform: "spotify",
            name: "Album A",
            artist: artist.name,
            coverURL: "https://example.com/cover.jpg"
        )

        XCTAssertEqual(artist.platform, "netease")
        XCTAssertEqual(album.trackCount, 0)
        XCTAssertEqual(album.year, "")
    }

    func testTrackPlaylistAndLyricLineCodableRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let track = makeTrack()
        let trackData = try encoder.encode(track)
        XCTAssertEqual(try decoder.decode(Track.self, from: trackData), track)

        let playlist = Playlist(
            id: "p1",
            platform: "spotify",
            name: "My Mix",
            coverURL: "",
            trackCount: 1,
            tracks: [track]
        )
        let playlistData = try encoder.encode(playlist)
        XCTAssertEqual(try decoder.decode(Playlist.self, from: playlistData), playlist)

        let lyricLine = LyricLine(
            startMs: 0,
            endMs: 1_000,
            text: "Hello",
            words: [LyricWord(startMs: 0, endMs: 500, text: "Hello")]
        )
        let lyricData = try encoder.encode(lyricLine)
        XCTAssertEqual(try decoder.decode(LyricLine.self, from: lyricData), lyricLine)
    }

    func testPlayerStateCodableRoundTrip() throws {
        let state = PlayerState(
            status: .playing,
            currentTrack: makeTrack(),
            positionMs: 1_234,
            durationMs: 240_000,
            volume: 55,
            shuffle: true,
            repeatMode: .all,
            queue: [makeTrack()],
            queueIndex: 0
        )

        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PlayerState.self, from: data), state)
    }

    private func makeTrack() -> Track {
        Track(
            id: "123",
            platform: "netease",
            title: "Song",
            artist: "Artist",
            artists: ["Artist"],
            album: "Album",
            albumCoverURL: "https://example.com/cover.jpg",
            durationMs: 240_000
        )
    }
}
