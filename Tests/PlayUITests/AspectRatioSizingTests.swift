// impl: WIN-003-H4 · H5 · S1 — the window is the shape of the film.
//
// Two things are asserted for every scenario, deliberately: the log entry that
// records the decision, **and** the window element's own frame. WIN-001-H5's
// lesson was that three separate defects logged perfectly while doing nothing;
// a `window.sizedToVideo` line proves a ratio was computed, not that anything on
// screen took it.

import PlayA11y
import XCTest

final class AspectRatioSizingTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 60
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launchPlaying(_ fixture: URL) throws {
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = [fixture.path, "-audio.muted", "YES"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 20)
    }

    /// The window frame as the accessibility layer reports it — the same numbers
    /// a person would measure on screen, and not a value this app supplied.
    private func windowRatio(file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.height, 0, "the window must have a height", file: file, line: line)
        return frame.width / frame.height
    }

    // MARK: - WIN-003-H4

    /// impl: WIN-003-H4 rules 1, 2, 5, 6, 12, 13 — a 16:9 file, square pixels.
    func testTheWindowTakesTheVideosRatioAndLocksIt() throws {
        try launchPlaying(try FixtureBuilder.colorBars10s())

        guard let sized = session.waitForEntry("window.sizedToVideo", timeout: 15) else { return }
        let payload = sized.payload

        XCTAssertEqual(payload["videoW"] as? Int, 640)
        XCTAssertEqual(payload["videoH"] as? Int, 360)
        // Square pixels read back as n:n — and as **0:0** on a container that
        // declares no `pasp` at all, which is what an MP4 written without one
        // does. Both mean "1", and `VideoGeometry` treats them alike; measured,
        // not assumed (session-20260814T074153Z, seq 26).
        XCTAssertEqual(payload["sarNum"] as? Int, payload["sarDen"] as? Int,
                       "square pixels: the SAR reads back as n:n")

        let dar = payload["dar"] as? Double ?? 0
        XCTAssertEqual(dar, 16.0 / 9, accuracy: 0.01, "rule 2")

        let contentW = payload["contentW"] as? Int ?? 0
        let contentH = payload["contentH"] as? Int ?? 1
        XCTAssertEqual(Double(contentW) / Double(contentH), 16.0 / 9, accuracy: 0.01, "rule 6")

        // impl: WIN-003 rule 13 — 16:9 is the one ratio whose minimum is
        // unchanged, and that is worth pinning: it is what WIN-001-S2 asserts.
        XCTAssertEqual(payload["minW"] as? Int, 320)
        XCTAssertEqual(payload["minH"] as? Int, 180)

        XCTAssertFalse(payload["suspended"] as? Bool ?? true, "no fullscreen was involved")
        XCTAssertTrue(session.entries(named: "window.aspectRatio.suspended").isEmpty)
        XCTAssertTrue(session.entries(named: "window.aspectRatio.unavailable").isEmpty)

        // The window itself, not the log.
        XCTAssertEqual(windowRatio(), 16.0 / 9, accuracy: 0.02,
                       "the window on screen must be the shape the log claims")
    }

    // MARK: - WIN-003-S1 (sad path)

    /// impl: WIN-003-S1 rule 2 — 720 x 576 storage, 16:9 display. A player that
    /// ignores the SAR locks the window to 1.25 and squashes the picture, and
    /// the only difference visible from the outside is this ratio.
    func testAnamorphicMediaIsNotSquashed() throws {
        try launchPlaying(try FixtureBuilder.anamorphic576p())

        guard let sized = session.waitForEntry("window.sizedToVideo", timeout: 15) else { return }
        let payload = sized.payload

        XCTAssertEqual(payload["videoW"] as? Int, 720, "the storage width, unchanged")
        XCTAssertEqual(payload["videoH"] as? Int, 576)

        let dar = payload["dar"] as? Double ?? 0
        XCTAssertEqual(dar, 16.0 / 9, accuracy: 0.02, "rule 2: the display ratio")
        XCTAssertNotEqual(dar, 720.0 / 576, accuracy: 0.1, "and emphatically not 1.25")

        XCTAssertEqual(windowRatio(), 16.0 / 9, accuracy: 0.03,
                       "a 5:4 window here is the squashed picture WIN-003-S1 forbids")
    }

    // MARK: - WIN-003-H5

    /// impl: WIN-003-H5 rules 14, 15 — fullscreen must be allowed to fill the
    /// display, and the lock must come back on the way out.
    func testFullscreenSuspendsTheLockAndExitingRestoresIt() throws {
        try launchPlaying(try FixtureBuilder.colorBars10s())
        session.waitForEntry("window.sizedToVideo", timeout: 15)

        app.typeKey("f", modifierFlags: [])
        guard let suspended = session.waitForEntry("window.aspectRatio.suspended", timeout: 5)
        else { return }
        XCTAssertEqual(suspended.payload["reason"] as? String, "fullscreen")

        // The window must cover its screen. A lock left in place makes AppKit
        // choose the largest rectangle *of that ratio*, which on any display
        // that is not 16:9 leaves the desktop showing along two edges.
        guard let screen = NSScreen.main?.frame else {
            return XCTFail("no screen to go fullscreen on")
        }
        let deadline = Date().addingTimeInterval(10)
        var frame = app.windows.firstMatch.frame
        while Date() < deadline,
              abs(frame.width - screen.width) > 2 || abs(frame.height - screen.height) > 2 {
            usleep(200_000)
            frame = app.windows.firstMatch.frame
        }
        XCTAssertEqual(frame.width, screen.width, accuracy: 2, "fullscreen must fill the width")
        XCTAssertEqual(frame.height, screen.height, accuracy: 2, "and the height (rule 14)")

        app.typeKey(.escape, modifierFlags: [])
        guard let restored = session.waitForEntry("window.aspectRatio.restored", timeout: 10)
        else { return }
        XCTAssertEqual(restored.payload["dar"] as? Double ?? 0, 16.0 / 9, accuracy: 0.01)
        XCTAssertEqual(windowRatio(), 16.0 / 9, accuracy: 0.02,
                       "the ratio is back on the window, not only in the log")
    }
}
