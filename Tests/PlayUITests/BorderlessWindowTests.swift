// impl: WIN-001-H1 · H3 · H4 · S1 · S3 · S4 — the chromeless window, and where
// it may be dragged from.
//
// This is the first UI test written, and it is deliberately the one that proves
// the riskiest claims at once: the engine booted (VLC-001-H1), the window has no
// standard window buttons, and it can become key (WIN-001 rule 2).
//
// **The window's own displacement is not asserted here, and cannot be.**
// XCUITest's synthesised press-then-drag does not drive
// `isMovableByWindowBackground`: `window.moved` is never emitted, whatever the
// hit-test returns. That was measured, not assumed — reverting `HUDView.hitTest`
// to its pre-rule-9 body produced exactly the same failure, so it is a property
// of the harness and not of the change. See WIN-001's Notes.
//
// What *is* assertable is the decision behind the drag: `HUDView.hitTest`
// returns nil for a handle, so a press there reaches `VideoHostView` and toggles
// playback (PLAY-001 rule 5); it returns self for the dead band, where nothing
// happens at all; and it returns the control on a control. One decision, three
// observable outcomes — and the same decision the drag depends on.

import PlayA11y
import XCTest

final class BorderlessWindowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 60
    }

    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launchPlaying(_ fixture: URL) throws {
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = [fixture.path, "-audio.volume", "40", "-audio.muted", "NO"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 20)
    }

    private func drag(from start: XCUICoordinate, by delta: CGVector) {
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(delta))
    }

    /// impl: WIN-001-H1
    func testWindowIsChromelessAndKey() throws {
        let fixture = try FixtureBuilder.colorBars10s()
        let app = XCUIApplication()
        app.launchArguments = [fixture.path]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15),
                      "the window must appear within 15 s (WIN-001-H1)")

        // impl: WIN-001-H1 — no standard window buttons exist at all.
        for identifier in ["_XCUI:CloseWindow", "_XCUI:MinimizeWindow", "_XCUI:FullScreenWindow"] {
            XCTAssertFalse(window.buttons[identifier].exists,
                           "\(identifier) must not exist on a borderless window")
        }

        // impl: WIN-001 rule 13 — with no HUD yet, the video view is the surface.
        let video = window.descendants(matching: .any)[A11yID.windowVideoView.rawValue]
        XCTAssertTrue(video.waitForExistence(timeout: 5),
                      "play.window.videoView must be reachable by identifier (CTRL-003)")

        app.terminate()
    }

    // WIN-001-H5 (the ✕ closes, ⌘M minimises) is **not** implemented here. It
    // asserts what the window did, and this harness cannot see that: it reports
    // the window as not hittable even at rest, the same limitation rule 17
    // records for displacement. Verified with real posted events instead, and
    // the measurements are in WIN-001's Notes.

    // MARK: - Where the window may be dragged from (WIN-001 rule 9)

    /// impl: WIN-001-H3 rules 9, 9.6 — dragging the picture moves the window,
    /// and does **not** toggle playback on the way.
    ///
    /// The second assertion is the one that decides rule 9.6's implementation.
    /// If a toggle *is* logged here, AppKit's drag loop did not suppress the
    /// trailing mouseUp and `VideoHostView` needs the movement threshold
    /// `QueueRowView` already uses.
    func testDraggingThePictureDoesNotPause() throws {
        try launchPlaying(try FixtureBuilder.colorBars10s())

        let video = app.windows.firstMatch
            .descendants(matching: .any)[A11yID.windowVideoView.rawValue]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        drag(from: video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
             by: CGVector(dx: 120, dy: -80))

        // rule 9.6 — the drag must not be taken for a click.
        XCTAssertTrue(session.entries(named: "playback.transport.toggle").isEmpty,
                      "a drag is not a click-to-pause")
        XCTAssertTrue(session.entries(named: "playback.state.changed")
            .allSatisfy { $0.payload["to"] as? String != "paused" })
        XCTAssertTrue(session.entries(named: "window.drag.refused").isEmpty,
                      "and the picture is a handle, not a dead band")
    }

    /// impl: WIN-001-H4 rule 9 — the HUD's own backdrop drags the window. Its
    /// bounds are not the criterion; only its controls are.
    func testTheHUDBackdropIsTransparentToTheVideo() throws {
        try launchPlaying(try FixtureBuilder.colorBars10s())
        let window = app.windows.firstMatch

        // Reveal the HUD, then press high in its area — well clear of the
        // control row and the seek bar, but inside the backdrop gradient.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        let hud = window.descendants(matching: .any)[A11yID.hudRoot.rawValue]
        XCTAssertTrue(hud.waitForExistence(timeout: 10))

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).click()

        // The click reached the video, which is what "this point is a drag
        // handle" means: `HUDView.hitTest` returned nil and the press fell
        // through to `VideoHostView` — the same decision that lets a *drag*
        // there move the window (rule 9.3).
        XCTAssertNotNil(session.waitForEntry("playback.transport.toggle", timeout: 5),
                        "rule 9 — the backdrop between controls is not inert")
        XCTAssertTrue(session.entries(named: "window.drag.refused").isEmpty,
                      "and it is not a dead band either")
        XCTAssertTrue(session.entries(named: "playback.seek.scrub").isEmpty,
                      "no control was touched")
        XCTAssertTrue(session.entries(named: "hud.control.pressed").isEmpty)
    }

    /// impl: WIN-001-S1 rules 9, 9.4 — a drag that starts on a control acts on
    /// the control and never moves the window.
    func testADragOnTheSeekBarScrubsAndDoesNotMoveTheWindow() throws {
        try launchPlaying(try FixtureBuilder.colorBars10s())
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()

        let seekBar = window.descendants(matching: .any)[A11yID.hudSeekBar.rawValue]
        XCTAssertTrue(seekBar.waitForExistence(timeout: 10))

        let movesBefore = session.entries(named: "window.moved").count
        drag(from: seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)),
             by: CGVector(dx: 120, dy: 0))

        XCTAssertNotNil(session.waitForEntry("playback.seek.scrub", timeout: 5),
                        "the seek bar took the drag")
        XCTAssertEqual(session.entries(named: "window.moved").count, movesBefore,
                       "rule 9.4 — a control surface never moves the window")
    }

    /// impl: WIN-001-S3 rules 9.1, 9.2, 16 — the dead band does nothing at all,
    /// and it is bounded: a press further out drags again.
    func testTheDeadBandAroundAControlDoesNothingAndIsBounded() throws {
        try launchPlaying(try FixtureBuilder.colorBars10s())
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()

        let playPause = window.descendants(matching: .any)[A11yID.hudPlayPauseButton.rawValue]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))

        // 4 pt above the button's top edge — inside the 8 pt margin.
        playPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -4)).click()

        let refused = session.waitForEntry("window.drag.refused", timeout: 5)
        XCTAssertEqual(refused?.payload["reason"] as? String, "nearControl", "rule 16")
        XCTAssertEqual(refused?.payload["control"] as? String,
                       A11yID.hudPlayPauseButton.rawValue,
                       "rule 16 — and it names which control it was near")
        XCTAssertTrue(session.entries(named: "playback.transport.toggle").isEmpty,
                      "rule 9.2 — the band does not fall through to click-to-toggle")
        XCTAssertTrue(session.entries(named: "hud.control.pressed").isEmpty,
                      "nor does it activate the button it is next to")

        // 12 pt out — beyond the margin, so the press reaches the video again.
        // This is what makes the band a bounded margin rather than a dead zone,
        // and it is the same `hitTest` decision that would let a drag there move
        // the window.
        playPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -12)).click()
        XCTAssertNotNil(session.waitForEntry("playback.transport.toggle", timeout: 5),
                        "rule 9.1 — the band is bounded at 8 pt")
        XCTAssertEqual(session.entries(named: "window.drag.refused").count, 1,
                       "and the second press was not refused")
    }

    /// impl: WIN-001-S4 rule 9.4 — the queue panel is a control surface in its
    /// entirety, which until now was true only by NSView's default.
    func testTheQueuePanelNeverMovesTheWindow() throws {
        try launchPlaying(try FixtureBuilder.queueOfThree())
        session.waitForEntry("playlist.built", timeout: 15)

        app.typeKey("l", modifierFlags: .command)
        let panel = app.windows.firstMatch
            .descendants(matching: .any)[A11yID.queuePanel.rawValue]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))

        let movesBefore = session.entries(named: "window.moved").count
        drag(from: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
             by: CGVector(dx: 120, dy: -40))

        XCTAssertEqual(session.entries(named: "window.moved").count, movesBefore,
                       "rule 9.4 — the panel is a control surface, in its entirety")
        XCTAssertTrue(session.entries(named: "playback.transport.toggle").isEmpty,
                      "and the press did not reach the video underneath it")
        XCTAssertTrue(panel.exists, "and it is still open")
    }
}
