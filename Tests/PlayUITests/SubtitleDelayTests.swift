// impl: TRACK-002-H1 · TRACK-002-H2 · TRACK-002-S1 · TRACK-002-S2 — subtitle
// delay, including the ms→µs conversion that a 1000× error would silently break.

import PlayA11y
import XCTest

final class SubtitleDelayTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launch(with fixture: URL) throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = [fixture.path, "-audio.volume", "60", "-audio.muted", "NO"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 20)
    }

    /// TRACK-001 rule 8's default depends on the machine's language settings, so
    /// no test may assume a track is selected. `S` is pressed until libvlc
    /// confirms one is.
    private func selectAnySubtitleTrack() {
        session.waitForEntry("tracks.subtitle.listChanged",
                             where: { ($0["count"] as? Int ?? 0) >= 2 }, timeout: 10)
        for _ in 0..<3 {
            let selected = session.entries(named: "tracks.subtitle.selected").last?
                .payload["trackId"] as? Int ?? -1
            if selected >= 0 { return }
            app.typeKey("s", modifierFlags: [])
            _ = session.waitForEntry("tracks.subtitle.cycled", timeout: 5)
            usleep(200_000)
        }
        XCTFail("no subtitle track could be selected on the sidecar fixture")
    }

    /// impl: TRACK-002-H1 rules 1, 3-4 — J steps by 100 ms, ⇧J by 1000 ms, and
    /// the readout is one element that updates rather than one per press.
    func testSteppingTheDelayUpdatesValueAndReadout() throws {
        try launch(with: try FixtureBuilder.filmWithSidecars())
        selectAnySubtitleTrack()

        for _ in 0..<4 { app.typeKey("j", modifierFlags: []) }
        app.typeKey("j", modifierFlags: [.shift])

        let final = session.waitForEntry(
            "tracks.delay.changed", where: { ($0["toMs"] as? Int) == 1_400 }, timeout: 10)
        XCTAssertNotNil(final, "4 × 100 ms + 1 × 1000 ms = 1400 ms")
        XCTAssertEqual(final?.payload["stepMs"] as? Int, 1_000)
        XCTAssertEqual(session.entries(named: "tracks.delay.changed").count, 5,
                       "one entry per press, no more")

        let readout = app.windows.firstMatch.descendants(matching: .any)[
            A11yID.overlaySubtitleDelay.rawValue]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        XCTAssertEqual(readout.value as? String, "Subtitle delay +1.4 s",
                       "rule 4 — sign and one decimal are part of the readout")

        // rule 4 — it hides 1.5 s after the last press, and it is *one* element,
        // so it must be gone rather than merely covered by four siblings.
        let vanished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: readout)
        XCTAssertEqual(XCTWaiter().wait(for: [vanished], timeout: 6), .completed)
    }

    /// impl: TRACK-002-H2 rule 1 — ⌥H returns to zero and says so.
    func testOptionHResetsTheDelay() throws {
        try launch(with: try FixtureBuilder.filmWithSidecars())
        selectAnySubtitleTrack()

        app.typeKey("h", modifierFlags: [.shift])
        XCTAssertNotNil(session.waitForEntry(
            "tracks.delay.changed", where: { ($0["toMs"] as? Int) == -1_000 }, timeout: 10))

        app.typeKey("h", modifierFlags: [.option])
        let reset = session.waitForEntry("tracks.delay.reset", timeout: 5)
        XCTAssertEqual(reset?.payload["fromMs"] as? Int, -1_000)

        let readout = app.windows.firstMatch.descendants(matching: .any)[
            A11yID.overlaySubtitleDelay.rawValue]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        XCTAssertEqual(readout.value as? String, "Subtitle delay 0 s")
    }

    /// impl: TRACK-002-S1 rule 2 — the delay clamps at ±60 s and never passes a
    /// larger value to libvlc.
    func testDelayClampsAtSixtySeconds() throws {
        try launch(with: try FixtureBuilder.filmWithSidecars())
        selectAnySubtitleTrack()

        for _ in 0..<61 { app.typeKey("j", modifierFlags: [.shift]) }

        let clamped = session.waitForEntry(
            "tracks.delay.clamped", where: { ($0["atMs"] as? Int) == 60_000 }, timeout: 10)
        XCTAssertNotNil(clamped)

        let values = session.entries(named: "tracks.delay.changed")
            .compactMap { $0.payload["toMs"] as? Int }
        XCTAssertEqual(values.max(), 60_000, "never past the rail")
        XCTAssertEqual(values.last, 60_000)
    }

    /// impl: TRACK-002-S2 rule 6 — with no subtitle showing, the keys do nothing
    /// visible and say why. A readout for something invisible is confusing.
    func testDelayWithNoSubtitleTrackIsIgnoredWithAReason() throws {
        try launch(with: try FixtureBuilder.colorBars10s())

        for _ in 0..<3 { app.typeKey("j", modifierFlags: []) }

        XCTAssertNotNil(session.waitForEntry(
            "tracks.delay.ignored",
            where: { $0["reason"] as? String == "noSubtitleTrack" }, timeout: 5))
        XCTAssertEqual(session.entries(named: "tracks.delay.ignored").count, 3)
        XCTAssertTrue(session.entries(named: "tracks.delay.changed").isEmpty,
                      "no value moved, so libvlc was never called")

        let readout = app.windows.firstMatch.descendants(matching: .any)[
            A11yID.overlaySubtitleDelay.rawValue]
        XCTAssertFalse(readout.exists, "no readout for a delay that does not apply")

        let key = session.entries(named: "input.key")
            .filter { $0.payload["action"] as? String == "subtitleDelayLater" }
        XCTAssertEqual(key.count, 3)
        XCTAssertTrue(key.allSatisfy { $0.payload["accepted"] as? Bool == false })
    }
}
