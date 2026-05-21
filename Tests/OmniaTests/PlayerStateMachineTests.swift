import XCTest
@testable import Omnia

@MainActor
final class PlayerStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func makeSM() -> PlayerStateMachine { PlayerStateMachine() }

    private func makeTrack(id: String = "t1", duration: Int = 180_000) -> Track {
        Track(id: id, platform: "netease", title: "Song", artist: "Artist",
              artists: ["Artist"], album: "Album", albumCoverURL: "", durationMs: duration)
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        let sm = makeSM()
        XCTAssertEqual(sm.state.status, .idle)
        XCTAssertNil(sm.state.currentTrack)
        XCTAssertEqual(sm.state.positionMs, 0)
        XCTAssertEqual(sm.state.durationMs, 0)
        XCTAssertEqual(sm.state.volume, 70)
        XCTAssertFalse(sm.state.shuffle)
        XCTAssertEqual(sm.state.repeatMode, .none)
    }

    // MARK: - load → LOADING

    func testLoadSetsTrackAndLoading() {
        let sm = makeSM()
        let track = makeTrack()
        sm.load(track)
        XCTAssertEqual(sm.state.status, .loading)
        XCTAssertEqual(sm.state.currentTrack, track)
        XCTAssertEqual(sm.state.durationMs, track.durationMs)
        XCTAssertEqual(sm.state.positionMs, 0)
    }

    func testLoadResetsPosition() {
        let sm = makeSM()
        sm.load(makeTrack(id: "a"))
        sm.onLoadSuccess()
        sm.updatePosition(5000)
        sm.load(makeTrack(id: "b"))
        XCTAssertEqual(sm.state.positionMs, 0)
    }

    // MARK: - LOADING → PLAYING / ERROR

    func testOnLoadSuccessTransitionsToPlaying() {
        let sm = makeSM()
        sm.load(makeTrack())
        sm.onLoadSuccess()
        XCTAssertEqual(sm.state.status, .playing)
    }

    func testOnLoadSuccessIgnoredWhenNotLoading() {
        let sm = makeSM()
        sm.onLoadSuccess()   // from IDLE
        XCTAssertEqual(sm.state.status, .idle)

        sm.load(makeTrack())
        sm.onLoadSuccess()
        sm.onLoadSuccess()   // second call while PLAYING
        XCTAssertEqual(sm.state.status, .playing)
    }

    func testOnLoadErrorTransitionsToError() {
        let sm = makeSM()
        sm.load(makeTrack())
        sm.onLoadError("network failure")
        XCTAssertEqual(sm.state.status, .error)
    }

    func testOnLoadErrorIgnoredWhenNotLoading() {
        let sm = makeSM()
        sm.onLoadError("x")
        XCTAssertEqual(sm.state.status, .idle)
    }

    // MARK: - PLAYING ⇄ PAUSED

    func testPauseFromPlaying() {
        let sm = makeSM()
        sm.load(makeTrack()); sm.onLoadSuccess()
        sm.pause()
        XCTAssertEqual(sm.state.status, .paused)
    }

    func testPauseIgnoredWhenNotPlaying() {
        let sm = makeSM()
        sm.pause()
        XCTAssertEqual(sm.state.status, .idle)
    }

    func testResumeFromPaused() {
        let sm = makeSM()
        sm.load(makeTrack()); sm.onLoadSuccess()
        sm.pause()
        sm.resume()
        XCTAssertEqual(sm.state.status, .playing)
    }

    func testResumeIgnoredWhenNotPaused() {
        let sm = makeSM()
        sm.resume()
        XCTAssertEqual(sm.state.status, .idle)

        sm.load(makeTrack()); sm.onLoadSuccess()
        sm.resume()    // already PLAYING
        XCTAssertEqual(sm.state.status, .playing)
    }

    // MARK: - stop → IDLE

    func testStopFromPlaying() {
        let sm = makeSM()
        sm.load(makeTrack()); sm.onLoadSuccess()
        sm.stop()
        XCTAssertEqual(sm.state.status, .idle)
        XCTAssertNil(sm.state.currentTrack)
        XCTAssertEqual(sm.state.positionMs, 0)
        XCTAssertEqual(sm.state.durationMs, 0)
    }

    func testStopFromPaused() {
        let sm = makeSM()
        sm.load(makeTrack()); sm.onLoadSuccess(); sm.pause()
        sm.stop()
        XCTAssertEqual(sm.state.status, .idle)
    }

    func testStopFromError() {
        let sm = makeSM()
        sm.load(makeTrack()); sm.onLoadError("err")
        sm.stop()
        XCTAssertEqual(sm.state.status, .idle)
    }

    func testStopFromIdle() {
        let sm = makeSM()
        sm.stop()
        XCTAssertEqual(sm.state.status, .idle)
    }

    // MARK: - seek

    func testSeekWhilePlaying() {
        let sm = makeSM()
        sm.load(makeTrack(duration: 200_000)); sm.onLoadSuccess()
        sm.seek(to: 50_000)
        XCTAssertEqual(sm.state.positionMs, 50_000)
        XCTAssertEqual(sm.state.status, .playing)
    }

    func testSeekWhilePaused() {
        let sm = makeSM()
        sm.load(makeTrack(duration: 200_000)); sm.onLoadSuccess(); sm.pause()
        sm.seek(to: 100_000)
        XCTAssertEqual(sm.state.positionMs, 100_000)
        XCTAssertEqual(sm.state.status, .paused)
    }

    func testSeekClampedToZero() {
        let sm = makeSM()
        sm.load(makeTrack(duration: 200_000)); sm.onLoadSuccess()
        sm.seek(to: -1000)
        XCTAssertEqual(sm.state.positionMs, 0)
    }

    func testSeekClampedToDuration() {
        let sm = makeSM()
        sm.load(makeTrack(duration: 200_000)); sm.onLoadSuccess()
        sm.seek(to: 999_999)
        XCTAssertEqual(sm.state.positionMs, 200_000)
    }

    func testSeekIgnoredWhenIdle() {
        let sm = makeSM()
        sm.seek(to: 5000)
        XCTAssertEqual(sm.state.positionMs, 0)
    }

    // MARK: - Settings

    func testSetVolumeClamped() {
        let sm = makeSM()
        sm.setVolume(150)
        XCTAssertEqual(sm.state.volume, 100)
        sm.setVolume(-10)
        XCTAssertEqual(sm.state.volume, 0)
        sm.setVolume(55)
        XCTAssertEqual(sm.state.volume, 55)
    }

    func testSetShuffle() {
        let sm = makeSM()
        sm.setShuffle(true)
        XCTAssertTrue(sm.state.shuffle)
        sm.setShuffle(false)
        XCTAssertFalse(sm.state.shuffle)
    }

    func testSetRepeatMode() {
        let sm = makeSM()
        for mode in RepeatMode.allCases {
            sm.setRepeatMode(mode)
            XCTAssertEqual(sm.state.repeatMode, mode)
        }
    }

    // MARK: - Backend callbacks

    func testUpdatePosition() {
        let sm = makeSM()
        sm.load(makeTrack(duration: 180_000)); sm.onLoadSuccess()
        sm.updatePosition(90_000)
        XCTAssertEqual(sm.state.positionMs, 90_000)
    }

    func testUpdateDuration() {
        let sm = makeSM()
        sm.load(makeTrack(duration: 0))
        sm.updateDuration(240_000)
        XCTAssertEqual(sm.state.durationMs, 240_000)
    }

    func testUpdateDurationNoopWhenUnchanged() {
        let sm = makeSM()
        sm.load(makeTrack(duration: 180_000))
        sm.updateDuration(180_000)
        XCTAssertEqual(sm.state.durationMs, 180_000)
    }
}
