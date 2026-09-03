// impl: PLAY-001-H1 · PLAY-002 rule 9 · PLAY-003 rule 3 · CTRL-001 rules 4-5 —
// the media controls, asserted through the log and the HUD's own elements.

import PlayA11y
import XCTest

final class TransportTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        executionTimeAllowance = 60

        let fixture = try FixtureBuilder.colorBars10s()
        let launchedAt = Date()
        app = XCUIApplication()
        // Volume and mute persist to UserDefaults (PLAY-003 rule 6), so without
        // pinning them a run inherits whatever the previous run left behind —
        // and at the 125 % ceiling a `+5 %` press correctly changes nothing,
        // which reads as a failure. `-key value` arguments populate
        // NSArgumentDomain, which wins over the persisted domain on read.
        app.launchArguments = [fixture.path, "-audio.volume", "100", "-audio.muted", "NO"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 20)
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// impl: PLAY-001-H1 — Space pauses and resumes, and the button glyph
    /// follows the engine rather than the click.
    func testSpaceTogglesPauseAndResume() throws {
        app.typeKey(" ", modifierFlags: [])
        XCTAssertNotNil(session.waitForEntry(
            "playback.state.changed",
            where: { $0["from"] as? String == "playing" && $0["to"] as? String == "paused" },
            timeout: 5))

        app.typeKey(" ", modifierFlags: [])
        XCTAssertNotNil(session.waitForEntry(
            "playback.state.changed",
            where: { $0["from"] as? String == "paused" && $0["to"] as? String == "playing" },
            timeout: 5))

        // impl: CTRL-002 rule 11 — the press itself is traceable.
        let keys = session.entries(named: "input.key")
            .filter { $0.payload["action"] as? String == "togglePlayPause" }
        XCTAssertGreaterThanOrEqual(keys.count, 2, "each Space press logs input.key")
        XCTAssertTrue(keys.allSatisfy { $0.payload["accepted"] as? Bool == true })
    }

    /// impl: PLAY-002 rule 9 — arrows seek by ∓5 s, ⇧ by ∓60 s, clamped.
    func testArrowKeysSeek() throws {
        app.typeKey(.rightArrow, modifierFlags: [])
        let forward = session.waitForEntry(
            "playback.seek.keyboard", where: { ($0["deltaMs"] as? Int) == 5_000 }, timeout: 5)
        XCTAssertNotNil(forward)

        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertNotNil(session.waitForEntry(
            "playback.seek.keyboard", where: { ($0["deltaMs"] as? Int) == -5_000 }, timeout: 5))

        app.typeKey(.rightArrow, modifierFlags: [.shift])
        let long = session.waitForEntry(
            "playback.seek.keyboard", where: { ($0["deltaMs"] as? Int) == 60_000 }, timeout: 5)

        // impl: PLAY-002 rule 9 — +60 s on a 10 s fixture clamps, never wraps.
        let toMs = long?.payload["toMs"] as? Int ?? -1
        let lengthMs = long?.payload["lengthMs"] as? Int ?? 0
        XCTAssertLessThanOrEqual(toMs, max(0, lengthMs - 100),
                                 "a keyboard nudge past the end clamps to length − 100 ms")
    }

    /// impl: PLAY-003 rules 3-4 — ↑/↓ step by 5 %, M toggles mute and restores
    /// the exact pre-mute level.
    func testVolumeKeysAndMute() throws {
        app.typeKey(.upArrow, modifierFlags: [])
        let up = session.waitForEntry("playback.volume.changed",
                                      where: { $0["source"] as? String == "keyboard" }, timeout: 5)
        let from = up?.payload["fromPercent"] as? Int ?? -1
        let to = up?.payload["toPercent"] as? Int ?? -1
        XCTAssertEqual(to - from, 5, "↑ steps by exactly 5 % (PLAY-003 rule 3)")

        app.typeKey("m", modifierFlags: [])
        XCTAssertNotNil(session.waitForEntry(
            "playback.mute.changed", where: { $0["muted"] as? Bool == true }, timeout: 5))

        app.typeKey("m", modifierFlags: [])
        let unmuted = session.waitForEntry(
            "playback.mute.changed", where: { $0["muted"] as? Bool == false }, timeout: 5)
        XCTAssertEqual(unmuted?.payload["restoredPercent"] as? Int, to,
                       "unmute restores the exact pre-mute level (PLAY-003 rule 4)")
    }

    /// impl: CTRL-001 rules 4-5, 8 — the HUD auto-hides after 2.5 s of playing,
    /// comes back on pointer movement, and its play/pause button is reachable
    /// and traceable.
    ///
    /// The hide half is asserted first on purpose: the HUD is already visible at
    /// launch (the `stateChange` trigger, rule 4, because `opening` is not
    /// `playing`), so hovering straight away proves nothing — `hud.shown` only
    /// fires on a transition.
    func testHUDAutoHidesThenReturnsOnPointerMovement() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        XCTAssertNotNil(session.waitForEntry(
            "hud.shown", where: { $0["trigger"] as? String == "stateChange" }, timeout: 10),
            "the HUD is up while the player is not yet playing (rule 4)")

        // The pointer must be parked away from the HUD's controls before the
        // idle wait: a pointer resting in the bottom bar holds the
        // `pointerInsideHUD` suppression (rule 5) and the HUD correctly never
        // hides. Whatever the previous test left the pointer on is not ours to
        // assume, so this is set explicitly rather than hoped for.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).hover()

        // impl: CTRL-001 rule 5 — 2.5 s idle, and only while playing.
        XCTAssertNotNil(session.waitForEntry(
            "hud.hidden", where: { $0["trigger"] as? String == "idle" }, timeout: 15))

        // A different point, or there is no movement for AppKit to report.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).hover()
        XCTAssertNotNil(session.waitForEntry(
            "hud.shown", where: { $0["trigger"] as? String == "mouseMove" }, timeout: 10))

        let button = window.descendants(matching: .any)[A11yID.hudPlayPauseButton.rawValue]
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "play.hud.playPauseButton must be reachable (CTRL-003)")

        // impl: CTRL-001 rule 8 — the press logs before the action takes effect.
        button.click()
        XCTAssertNotNil(session.waitForEntry(
            "hud.control.pressed",
            where: { $0["element"] as? String == A11yID.hudPlayPauseButton.rawValue },
            timeout: 5))
        XCTAssertNotNil(session.waitForEntry(
            "playback.state.changed", where: { $0["to"] as? String == "paused" }, timeout: 5))
    }

    /// impl: PLAY-002-S4 rule 3 — a seek made while **paused** must hold its new
    /// position. libvlc emits no time event while paused, so a bar driven only
    /// by events snapped straight back: the seek had happened and only the
    /// display disagreed. Invisible while playing, because an event arrives
    /// within ~100 ms and hides it.
    ///
    /// The assertion goes through `→`, whose log reports the position it started
    /// from — the cheapest way to read the state the bar is drawn from.
    func testASeekMadeWhilePausedHoldsItsPosition() throws {
        app.typeKey(" ", modifierFlags: [])
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "paused" }, timeout: 10)

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        let bar = window.descendants(matching: .any)[A11yID.hudSeekBar.rawValue]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))

        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))

        let scrub = session.waitForEntry("playback.seek.scrub",
                                         where: { ($0["final"] as? Bool) == true }, timeout: 10)
        let target = try XCTUnwrap(scrub?.payload["toMs"] as? Int)
        XCTAssertGreaterThan(target, 0)

        app.typeKey(.rightArrow, modifierFlags: [])
        let nudge = session.waitForEntry("playback.seek.keyboard", timeout: 10)
        XCTAssertEqual(nudge?.payload["fromMs"] as? Int, target,
                       "the scrubbed position held; it did not snap back to where it was paused")

        // rule 7 — scrubbing does not resume playback.
        XCTAssertTrue(session.entries(named: "playback.state.changed")
            .filter { $0.seq > (scrub?.seq ?? 0) }
            .allSatisfy { $0.payload["to"] as? String != "playing" })
    }

    // MARK: - PLAY-001-H4 — a different file, loaded while one is running

    /// `setUpWithError` launches the single-file fixture, which has no queue to
    /// advance through. These two cases need one, so they relaunch.
    private func relaunchWithQueue() throws {
        app.terminate()
        let fixture = try FixtureBuilder.queueOfThree()
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = [fixture.path, "-audio.volume", "100", "-audio.muted", "NO"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        session.waitForEntry("playlist.built", timeout: 20)
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 20)
    }

    /// impl: PLAY-001-H4 rule 2 — a **manual** advance happens from `playing`,
    /// not from `ended`. Before the table gained that edge the transition was
    /// refused *and ignored*, so `onMediaChanged` never fired and the per-media
    /// reset was skipped; libvlc's own `stopped` covered it a beat later, which
    /// made a correctness bug look like a timing detail.
    func testManualAdvanceFromPlayingResetsPerMediaState() throws {
        try relaunchWithQueue()
        // Past 4 s, so positionMs is unmistakably non-zero when the advance
        // happens and a reset is something the log can show.
        Thread.sleep(forTimeInterval: 4.5)

        app.typeKey("]", modifierFlags: .command)

        let opening = session.waitForEntry(
            "playback.state.changed",
            where: { $0["from"] as? String == "playing" && $0["to"] as? String == "opening" },
            timeout: 10)
        XCTAssertNotNil(opening, "rule 2 — playing → opening is a legal transition")
        XCTAssertEqual(opening?.payload["positionMs"] as? Int, 0,
                       "the per-media reset ran on *this* transition (LIST-001 rule 9)")

        XCTAssertNotNil(session.waitForEntry("playlist.advanced",
                                             where: { $0["reason"] as? String == "next" },
                                             timeout: 5))
        XCTAssertNotNil(session.waitForEntry("playback.state.changed",
                                             where: { $0["to"] as? String == "playing" },
                                             timeout: 15))
        XCTAssertTrue(session.entries(named: "playback.state.illegal").isEmpty,
                      "no illegal transition anywhere in the run")
    }

    /// impl: PLAY-001-H4 rule 2 — the same from `paused`, which the table also
    /// had no edge for.
    func testManualAdvanceFromPausedResetsPerMediaState() throws {
        try relaunchWithQueue()
        Thread.sleep(forTimeInterval: 4.5)

        app.typeKey(" ", modifierFlags: [])
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "paused" }, timeout: 10)

        app.typeKey("]", modifierFlags: .command)

        let opening = session.waitForEntry(
            "playback.state.changed",
            where: { $0["from"] as? String == "paused" && $0["to"] as? String == "opening" },
            timeout: 10)
        XCTAssertNotNil(opening, "rule 2 — paused → opening is legal too")
        XCTAssertEqual(opening?.payload["positionMs"] as? Int, 0)
        XCTAssertTrue(session.entries(named: "playback.state.illegal").isEmpty)
    }
}
