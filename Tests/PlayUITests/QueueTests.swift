// impl: LIST-001-H1 · H2 · S1 · S2 · S3 — the playback queue and auto-advance.
//
// Every assertion here is a log entry or an element query, because a queue that
// "seems to advance" proves nothing about which item libvlc actually loaded.

import PlayA11y
import XCTest

final class QueueTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// The directory is passed whole, so LIST-001 rule 3's one-level expansion
    /// and MEDIA-001 rule 2's name ordering are part of every scenario below.
    private func launch(with path: String, timeAllowance: TimeInterval = 120) throws {
        continueAfterFailure = false
        executionTimeAllowance = timeAllowance
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = [path, "-audio.volume", "60", "-audio.muted", "YES"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
    }

    private func showHUD() -> XCUIElement {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        return window
    }

    // MARK: - Happy paths

    /// impl: LIST-001-H1 rules 3, 5, 13 — three files play in order with no
    /// intervention, on one media player.
    func testThreeFilesPlayInOrderWithoutIntervention() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)

        let built = session.waitForEntry("playlist.built", timeout: 20)
        XCTAssertEqual(built?.payload["count"] as? Int, 3)

        // rule 5 — two advances for three items, both automatic and in order.
        session.waitForEntry("playlist.advanced",
                             where: { $0["toIndex"] as? Int == 1 && $0["reason"] as? String == "auto" },
                             timeout: 30)
        session.waitForEntry("playlist.advanced",
                             where: { $0["toIndex"] as? Int == 2 && $0["reason"] as? String == "auto" },
                             timeout: 30)
        session.waitForEntry("playlist.exhausted", timeout: 30)
        XCTAssertNotNil(session.entries(named: "playback.state.changed")
            .last(where: { $0.payload["to"] as? String == "ended" }))

        // VLC-002 rule 1 — one player for the whole session, not one per item.
        XCTAssertEqual(session.entries(named: "engine.player.created").count, 1)
        XCTAssertTrue(session.entries(named: "playback.state.illegal").isEmpty,
                      "ended → opening is a legal transition; the queue must not force an illegal one")
    }

    /// impl: LIST-001-H2 rule 6 — ⌘[ goes back inside the first 3 s and
    /// restarts the current item after it.
    func testPreviousGoesBackEarlyAndRestartsLater() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)
        session.waitForEntry("playlist.advanced",
                             where: { $0["toIndex"] as? Int == 1 }, timeout: 30)

        // Item B has just started, so this is inside the 3 s window.
        app.typeKey("[", modifierFlags: .command)
        let back = session.waitForEntry("playlist.advanced",
                                        where: { $0["reason"] as? String == "previous" }, timeout: 10)
        XCTAssertEqual(back?.payload["toIndex"] as? Int, 0)
        XCTAssertTrue(session.entries(named: "playlist.restartedCurrent").isEmpty,
                      "inside 3 s it is a previous, never a restart")

        // Let A run past the threshold, then press again. A bounded sleep, not a
        // poll: `positionMs` only reaches the log on a state change, so there is
        // nothing to poll — the assertion below reads the position out of the
        // entry the press itself produces.
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 15)
        Thread.sleep(forTimeInterval: 3.5)
        app.typeKey("[", modifierFlags: .command)
        let restart = session.waitForEntry("playlist.restartedCurrent", timeout: 10)
        XCTAssertEqual(restart?.payload["index"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(restart?.payload["positionMs"] as? Int ?? 0, 3_000,
                                    "rule 6 — the restart branch is chosen by elapsed time")
        XCTAssertEqual(session.entries(named: "playlist.advanced")
            .filter { $0.payload["reason"] as? String == "previous" }.count, 1,
                       "after 3 s it restarts instead of moving back a second time")
    }

    // MARK: - Sad paths

    /// impl: LIST-001-S1 rule 8 — a zero-byte file in the middle is marked,
    /// skipped, and the queue carries on.
    func testBrokenMiddleItemIsSkippedNotFatal() throws {
        try launch(with: try FixtureBuilder.queueWithBrokenMiddleItem().path)
        session.waitForEntry("playlist.built", where: { $0["count"] as? Int == 3 }, timeout: 20)

        let failed = session.waitForEntry("playlist.itemFailed", timeout: 40)
        XCTAssertEqual(failed?.payload["index"] as? Int, 1)
        XCTAssertNotNil(session.entries(named: "media.open.failed")
            .first(where: { $0.payload["reason"] as? String == "emptyFile" }),
                        "MEDIA-002 rule 6 — a zero-byte file is `emptyFile`, not a decode failure")

        session.waitForEntry("playlist.advanced",
                             where: { $0["toIndex"] as? Int == 2 }, timeout: 20)
        session.waitForEntry("playlist.exhausted", timeout: 30)
        XCTAssertTrue(app.windows.firstMatch.exists, "one broken item never takes the app down")
    }

    /// impl: LIST-001-S2 rules 7, 12 — next at the end is ignored and does not
    /// wrap, and the button says so visually.
    func testNextAtTheEndIsIgnoredAndDoesNotWrap() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)
        session.waitForEntry("playlist.built", timeout: 20)

        let window = showHUD()
        let nextButton = window.descendants(matching: .any)[A11yID.hudNextButton.rawValue]
        let previousButton = window.descendants(matching: .any)[A11yID.hudPreviousButton.rawValue]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 10),
                      "rule 12 — a three-item queue shows the next button")

        // Jump to the last item, then ask for one more. The reason is not
        // asserted here: if auto-advance happens to get there first the queue is
        // still at the end, which is what this scenario is about.
        app.typeKey("]", modifierFlags: .command)
        app.typeKey("]", modifierFlags: .command)
        session.waitForEntry("playlist.advanced",
                             where: { $0["toIndex"] as? Int == 2 }, timeout: 20)

        let advancesBefore = session.entries(named: "playlist.advanced").count
        app.typeKey("]", modifierFlags: .command)
        app.typeKey("]", modifierFlags: .command)
        let ignored = session.entries(named: "playlist.advance.ignored")
            .filter { $0.payload["reason"] as? String == "atEnd" }
        XCTAssertGreaterThanOrEqual(ignored.count, 2, "rule 7 — refused twice, with a reason")
        XCTAssertEqual(session.entries(named: "playlist.advanced").count, advancesBefore,
                       "it did not wrap round to the first item")

        // The UI test requirement: dimmed, measured on the pixels rather than
        // read off an internal flag. The comparison is against the *previous*
        // button in the same capture pass — a mirror-image glyph over the same
        // backdrop — and not against an earlier capture of this button, because
        // the fixture changes colour every second and that would compare
        // backgrounds instead of opacity.
        _ = showHUD()
        let dimmed = Self.peakLuminance(nextButton.screenshot().image)
        let normal = Self.peakLuminance(previousButton.screenshot().image)
        XCTAssertLessThan(dimmed, normal * 0.85,
                          "CTRL-001 rule 3 — unavailable renders at 40 % opacity "
                          + "(next \(dimmed) vs previous \(normal))")
    }

    /// impl: LIST-001-S3 rule 12 — one file means no queue controls at all,
    /// while ⌘] and ⌘[ still report why they did nothing.
    func testSingleItemQueueHidesTheQueueControls() throws {
        try launch(with: try FixtureBuilder.colorBars10s().path, timeAllowance: 90)
        session.waitForEntry("playlist.built", where: { $0["count"] as? Int == 1 }, timeout: 20)

        let window = showHUD()
        XCTAssertTrue(window.descendants(matching: .any)[A11yID.hudPlayPauseButton.rawValue]
            .waitForExistence(timeout: 10), "the HUD is up — the absences below are meaningful")
        for identifier in [A11yID.hudNextButton, .hudPreviousButton, .hudQueueButton] {
            XCTAssertFalse(window.descendants(matching: .any)[identifier.rawValue].exists,
                           "\(identifier.rawValue) must be absent for a one-item queue")
        }

        app.typeKey("]", modifierFlags: .command)
        XCTAssertNotNil(session.waitForEntry("playlist.advance.ignored",
                                             where: { $0["reason"] as? String == "atEnd" },
                                             timeout: 5))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertNotNil(session.waitForEntry("playlist.advance.ignored",
                                             where: { $0["reason"] as? String == "atStart" },
                                             timeout: 5),
                        "within the first 3 s there is nothing before item 0")
    }

    // MARK: - Measurement

    /// Peak luminance of an element capture — the brightest pixel, which on a
    /// HUD button is the glyph itself. The spec asks for opacity to be asserted
    /// on the pixels, because an `isEnabled` flag can be true while the control
    /// renders identically. Peak rather than mean: the mean is dominated by the
    /// backdrop showing through, which moved the two captures only 9 % apart
    /// (0.413 vs 0.455) and made the real 60 % ink difference look marginal.
    private static func peakLuminance(_ image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return 0 }
        var peak = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let luminance = 0.2126 * Double(colour.redComponent)
                    + 0.7152 * Double(colour.greenComponent)
                    + 0.0722 * Double(colour.blueComponent)
                peak = max(peak, luminance)
            }
        }
        return peak
    }
}
