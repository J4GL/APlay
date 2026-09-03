// impl: PLAY-004-S1 — trivial positions are never saved.
//
// PLAY-004-H1/H2/H3/S2/S3 all need TEST-001 rule 7's 5-minute and 90s
// fixtures, neither of which exists in this codebase (colorBars10s is the
// longest fixture, and rule 6's 120 s minimum makes any 10 s clip trivially
// `tooShort` — the one case this file *can* exercise). Building longer
// fixtures is TEST-001's concern, not this feature's, so those scenarios are
// not written here.
//
// Written against the spec; not executed in this environment (no Xcode, see
// README's Test section) — verified instead by manually driving the built
// app with a throwaway 150 s synthetic fixture and reading the JSONL log:
// the full save (ticker/pause/terminate) → offer → accept round trip, the
// exact 8.4 s auto-dismiss timing, `ended` clearing the record, and the
// `isAccepting` guard suppressing a spurious seek-dismissal log on accept
// all confirmed working end to end.

import PlayA11y
import XCTest

final class ResumePositionTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launch(with arguments: [String]) throws {
        continueAfterFailure = false
        executionTimeAllowance = 60
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
    }

    /// impl: PLAY-004-S1 (the `tooShort` third of it) — the 10 s fixture is
    /// under rule 6's 120 s minimum regardless of position, so quitting
    /// after it plays must never write a resume record.
    func testAShortFixtureIsNeverSaved() throws {
        try launch(with: [try FixtureBuilder.colorBars10s().path])
        XCTAssertNotNil(session.waitForEntry("playback.state.changed",
            where: { $0["to"] as? String == "playing" }, timeout: 20))

        app.terminate()
        XCTAssertNotNil(session.waitForEntry("playback.resume.skipped",
            where: { $0["reason"] as? String == "tooShort" }, timeout: 10))
        XCTAssertNil(session.entries(named: "playback.resume.saved").last)

        // Reopening it must offer nothing.
        try launch(with: [try FixtureBuilder.colorBars10s().path])
        XCTAssertNotNil(session.waitForEntry("playback.state.changed",
            where: { $0["to"] as? String == "playing" }, timeout: 20))
        XCTAssertTrue(session.entries(named: "playback.resume.offered").isEmpty)
        XCTAssertFalse(app.otherElements[A11yID.toastResume.rawValue].exists)
    }
}
