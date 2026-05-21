import XCTest
@testable import Omnia

@MainActor
final class PlayQueueTests: XCTestCase {

    // MARK: - Helpers

    private func makeQueue() -> PlayQueue { PlayQueue() }

    private func track(_ id: String) -> Track {
        Track(id: id, platform: "netease", title: "Song \(id)", artist: "Artist",
              artists: ["Artist"], album: "Album", albumCoverURL: "", durationMs: 180_000)
    }

    private func threeTrackQueue() -> PlayQueue {
        let q = makeQueue()
        q.setTracks([track("a"), track("b"), track("c")])
        return q
    }

    // MARK: - Initial state

    func testEmptyQueueOnInit() {
        let q = makeQueue()
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.currentIndex, -1)
        XCTAssertNil(q.currentTrack)
    }

    // MARK: - setTracks

    func testSetTracksBasic() {
        let q = makeQueue()
        let tracks = [track("a"), track("b")]
        q.setTracks(tracks)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(q.currentTrack?.id, "a")
    }

    func testSetTracksCustomStartIndex() {
        let q = makeQueue()
        q.setTracks([track("a"), track("b"), track("c")], startAt: 1)
        XCTAssertEqual(q.currentIndex, 1)
        XCTAssertEqual(q.currentTrack?.id, "b")
    }

    func testSetTracksEmpty() {
        let q = makeQueue()
        q.setTracks([])
        XCTAssertEqual(q.currentIndex, -1)
        XCTAssertNil(q.currentTrack)
    }

    func testSetTracksReplacesExisting() {
        let q = threeTrackQueue()
        q.setTracks([track("x")])
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.currentTrack?.id, "x")
    }

    // MARK: - add

    func testAddToEmptyQueue() {
        let q = makeQueue()
        q.add(track("a"))
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(q.currentTrack?.id, "a")
    }

    func testAddDoesNotChangeIndexWhenQueueNonEmpty() {
        let q = threeTrackQueue()
        q.add(track("d"))
        XCTAssertEqual(q.count, 4)
        XCTAssertEqual(q.currentIndex, 0)
    }

    // MARK: - next

    func testNextAdvancesIndex() {
        let q = threeTrackQueue()
        let n = q.next()
        XCTAssertEqual(n?.id, "b")
        XCTAssertEqual(q.currentIndex, 1)
    }

    func testNextAtEndRepeatNoneReturnsNil() {
        let q = threeTrackQueue()
        _ = q.next(); _ = q.next()    // now at "c"
        let n = q.next(repeatMode: .none)
        XCTAssertNil(n)
        XCTAssertEqual(q.currentIndex, 2)  // index unchanged
    }

    func testNextAtEndRepeatAllWraps() {
        let q = threeTrackQueue()
        _ = q.next(); _ = q.next()    // now at "c"
        let n = q.next(repeatMode: .all)
        XCTAssertEqual(n?.id, "a")
        XCTAssertEqual(q.currentIndex, 0)
    }

    func testNextRepeatOneReturnsSameTrack() {
        let q = threeTrackQueue()
        let n = q.next(repeatMode: .one)
        XCTAssertEqual(n?.id, "a")
        XCTAssertEqual(q.currentIndex, 0)
    }

    // MARK: - peekNext

    func testPeekNextDoesNotAdvance() {
        let q = threeTrackQueue()
        let p = q.peekNext()
        XCTAssertEqual(p?.id, "b")
        XCTAssertEqual(q.currentIndex, 0)
    }

    func testPeekNextAtEndRepeatNone() {
        let q = threeTrackQueue()
        _ = q.next(); _ = q.next()
        XCTAssertNil(q.peekNext(repeatMode: .none))
    }

    func testPeekNextAtEndRepeatAll() {
        let q = threeTrackQueue()
        _ = q.next(); _ = q.next()
        XCTAssertEqual(q.peekNext(repeatMode: .all)?.id, "a")
    }

    func testPeekNextRepeatOne() {
        let q = threeTrackQueue()
        XCTAssertEqual(q.peekNext(repeatMode: .one)?.id, "a")
    }

    // MARK: - previous

    func testPreviousDecrementsIndex() {
        let q = threeTrackQueue()
        _ = q.next()               // → b
        let p = q.previous()
        XCTAssertEqual(p?.id, "a")
        XCTAssertEqual(q.currentIndex, 0)
    }

    func testPreviousAtStartStaysAtZero() {
        let q = threeTrackQueue()
        let p = q.previous()
        XCTAssertEqual(p?.id, "a")
        XCTAssertEqual(q.currentIndex, 0)
    }

    // MARK: - shuffle / unshuffle

    func testShuffleChangesOrder() {
        let q = makeQueue()
        let many = (0..<20).map { track(String($0)) }
        q.setTracks(many)
        let original = q.tracks.map { $0.id }
        // Shuffle multiple times — at least one should differ
        var shuffled = false
        for _ in 0..<10 {
            q.shuffle()
            if q.tracks.map({ $0.id }) != original { shuffled = true; break }
        }
        XCTAssertTrue(shuffled, "Expected shuffled order to differ from original")
    }

    func testShuffleKeepsCurrentTrack() {
        let q = threeTrackQueue()
        _ = q.next()   // currentTrack = "b"
        q.shuffle()
        XCTAssertEqual(q.currentTrack?.id, "b")
    }

    func testUnshuffleRestoresOrder() {
        let q = threeTrackQueue()
        let original = q.tracks.map { $0.id }
        q.shuffle()
        q.unshuffle()
        XCTAssertEqual(q.tracks.map { $0.id }, original)
    }

    func testUnshuffleNoopWhenNotShuffled() {
        let q = threeTrackQueue()
        let before = q.tracks.map { $0.id }
        q.unshuffle()
        XCTAssertEqual(q.tracks.map { $0.id }, before)
    }

    // MARK: - remove

    func testRemoveBeforeCurrentDecrementsIndex() {
        let q = threeTrackQueue()
        _ = q.next()   // index = 1 (track "b")
        q.remove(at: 0)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(q.currentTrack?.id, "b")
    }

    func testRemoveCurrentClampsIndex() {
        let q = threeTrackQueue()
        _ = q.next(); _ = q.next()   // index = 2 (last, "c")
        q.remove(at: 2)
        XCTAssertEqual(q.currentIndex, 1)  // clamped to new last
    }

    func testRemoveAfterCurrentDoesNotChangeIndex() {
        let q = threeTrackQueue()
        q.remove(at: 2)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(q.count, 2)
    }

    func testRemoveLastTrackResetsIndex() {
        let q = makeQueue()
        q.add(track("a"))
        q.remove(at: 0)
        XCTAssertEqual(q.currentIndex, -1)
        XCTAssertTrue(q.isEmpty)
    }

    // MARK: - move

    func testMoveUpdatesCurrentTrackIndex() {
        let q = threeTrackQueue()
        _ = q.next()   // currentTrack = "b" at index 1
        q.move(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(q.currentTrack?.id, "b")
        XCTAssertEqual(q.tracks[q.currentIndex].id, "b")
    }

    // MARK: - clear

    func testClearResetsAll() {
        let q = threeTrackQueue()
        q.clear()
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.currentIndex, -1)
        XCTAssertNil(q.currentTrack)
    }
}
