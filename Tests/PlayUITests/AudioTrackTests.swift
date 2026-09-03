// impl: TRACK-003-H1 · TRACK-003-S1 · TRACK-003-S3 — audio track selection.

import PlayA11y
import XCTest

final class AudioTrackTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launch(with fixture: URL) throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = [fixture.path, "-audio.volume", "60", "-audio.muted", "NO"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 20)
    }

    private var confirmedAudioTrack: Int {
        session.entries(named: "tracks.audio.selected").last?.payload["trackId"] as? Int ?? -1
    }

    /// impl: TRACK-003-H1 rules 1-2, 6 — both tracks are listed with their
    /// language names resolved, and a default is chosen without any input.
    func testDualAudioIsListedWithLanguageNames() throws {
        try launch(with: try FixtureBuilder.dualAudio10s())

        let list = session.waitForEntry("tracks.audio.listChanged", timeout: 10)
        XCTAssertEqual(list?.payload["count"] as? Int, 2)
        XCTAssertEqual(list?.payload["names"] as? [String], ["English", "French"],
                       "rule 2 — `eng`/`fra` are resolved to names a person can read")

        let chosen = session.waitForEntry(
            "tracks.audio.selected", where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(chosen?.payload["applied"] as? Bool, true,
                       "rule 5 — confirmed by reading libvlc back")
        // rule 6 — audio never defaults to silence, unlike subtitles.
        XCTAssertNotEqual(chosen?.payload["trackId"] as? Int, -1)
    }

    /// impl: TRACK-003 rules 7-8 — `A` moves to the other track without
    /// disturbing playback.
    func testAKeyCyclesAudioTracksWithoutStoppingPlayback() throws {
        try launch(with: try FixtureBuilder.dualAudio10s())
        session.waitForEntry("tracks.audio.listChanged", timeout: 10)
        let before = confirmedAudioTrack

        app.typeKey("a", modifierFlags: [])
        let cycled = session.waitForEntry("tracks.audio.cycled", timeout: 5)
        XCTAssertNotNil(cycled)
        XCTAssertEqual(cycled?.payload["count"] as? Int, 2,
                       "rule 7 — the ring holds the real tracks, and skips Off")

        let after = session.waitForEntry(
            "tracks.audio.selected", where: { $0["source"] as? String == "cycle" }, timeout: 5)
        XCTAssertNotEqual(after?.payload["trackId"] as? Int, before, "the track actually changed")

        // rule 8 — switching mid-playback changes neither position nor status.
        XCTAssertTrue(session.entries(named: "playback.state.changed")
            .allSatisfy { $0.payload["to"] as? String != "paused" })
        XCTAssertNil(session.entries(named: "playback.state.illegal").first)
    }

    /// impl: TRACK-003-S3 — a video-only file offers no audio menu, `A` does
    /// nothing, and the volume control is still there because a later queue item
    /// may well have sound.
    func testVideoOnlyFileHasNoAudioMenuAndRefusesTheCycle() throws {
        try launch(with: try FixtureBuilder.colorBars10s())

        app.typeKey("a", modifierFlags: [])
        let key = session.waitForEntry(
            "input.key", where: { $0["action"] as? String == "cycleAudioTrack" }, timeout: 5)
        XCTAssertEqual(key?.payload["accepted"] as? Bool, false)
        XCTAssertTrue(session.entries(named: "tracks.audio.cycled").isEmpty)
        XCTAssertTrue(session.entries(named: "tracks.audio.selected").isEmpty,
                      "no elementary stream means no selection was ever attempted")

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        let volume = window.descendants(matching: .any)[A11yID.hudVolumeSlider.rawValue]
        XCTAssertTrue(volume.waitForExistence(timeout: 10),
                      "the volume slider stays — video-only media does not disable it")
        let audioButton = window.descendants(matching: .any)[A11yID.hudAudioMenuButton.rawValue]
        XCTAssertFalse(audioButton.exists,
                       "a menu with nothing in it is worse than no menu (rule S3)")
    }
}
