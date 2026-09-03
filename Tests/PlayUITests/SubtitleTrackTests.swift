// impl: TRACK-001-H3 · TRACK-001-S1 · TRACK-001 rules 5, 7, 10, 12 —
// subtitle tracks, asserted through the log and the HUD's own menu.

import PlayA11y
import XCTest

final class SubtitleTrackTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// Launches Play on a fixture and waits for playback, which is the point at
    /// which the ES list has settled enough for TRACK-001 rule 1 to have run.
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

    /// The selection as libvlc last **confirmed** it (TRACK-001 rule 5), read
    /// from the log rather than assumed from the number of key presses.
    private var confirmedSubtitleTrack: Int {
        session.entries(named: "tracks.subtitle.selected").last?
            .payload["trackId"] as? Int ?? -1
    }

    /// impl: TRACK-001-H3 rules 10, 12 — sidecars are found, added, and labelled
    /// with their stems, and none of it interrupts playback.
    func testSidecarsAreFoundAndLabelled() throws {
        try launch(with: try FixtureBuilder.filmWithSidecars())

        let found = session.waitForEntry("tracks.subtitle.sidecarsFound", timeout: 10)
        XCTAssertEqual(found?.payload["count"] as? Int, 2,
                       "fixture.srt and fixture.fr.srt are both picked up (rule 10)")

        let list = session.waitForEntry(
            "tracks.subtitle.listChanged",
            where: { ($0["count"] as? Int ?? 0) >= 2 }, timeout: 10)
        let names = list?.payload["names"] as? [String] ?? []
        XCTAssertEqual(names.count, 2,
                       """
                       exactly two subtitle tracks. Four means libvlc's own \
                       sidecar autodetection is back on and is duplicating \
                       rule 10 — see VLC-001 rule 15.
                       """)
        XCTAssertTrue(names.contains("fixture"),
                      "rule 12 — an external track carries its file's stem, got \(names)")

        // rule 9 — attaching never disturbs playback.
        XCTAssertTrue(session.entries(named: "playback.state.changed")
            .allSatisfy { $0.payload["to"] as? String != "paused" })
    }

    /// impl: TRACK-001 rules 5, 7 — `S` walks the ring and every step is
    /// confirmed by reading libvlc back.
    func testSKeyCyclesThroughTracksAndOff() throws {
        try launch(with: try FixtureBuilder.filmWithSidecars())
        session.waitForEntry("tracks.subtitle.listChanged",
                             where: { ($0["count"] as? Int ?? 0) >= 2 }, timeout: 10)

        // The ring is Off + 2 tracks, so three presses must return to the start
        // whatever rule 8's default left selected on this machine.
        var visited: [Int] = [confirmedSubtitleTrack]
        for _ in 0..<3 {
            let before = session.entries(named: "tracks.subtitle.cycled").count
            app.typeKey("s", modifierFlags: [])
            let log = session!
            _ = log.waitForEntry(
                "tracks.subtitle.cycled",
                where: { _ in log.entries(named: "tracks.subtitle.cycled").count > before },
                timeout: 5)
            visited.append(confirmedSubtitleTrack)
        }

        XCTAssertEqual(visited.first, visited.last,
                       "three presses on a three-entry ring return to the start")
        XCTAssertEqual(Set(visited).count, 3, "each press lands somewhere new: \(visited)")
        XCTAssertTrue(visited.contains(-1), "the ring passes through Off (rule 3)")

        let keys = session.entries(named: "input.key")
            .filter { $0.payload["action"] as? String == "cycleSubtitleTrack" }
        XCTAssertEqual(keys.count, 3)
        XCTAssertTrue(keys.allSatisfy { $0.payload["accepted"] as? Bool == true })
    }

    /// impl: TRACK-001-S1 — a film with no subtitles at all. The wrap-around on
    /// a one-element ring is the case naive modulo arithmetic gets wrong.
    func testFilmWithNoSubtitlesRefusesTheCycleAndSurvives() throws {
        try launch(with: try FixtureBuilder.colorBars10s())

        app.typeKey("s", modifierFlags: [])
        app.typeKey("s", modifierFlags: [])

        let refusals = session.waitForEntry(
            "input.key", where: { $0["action"] as? String == "cycleSubtitleTrack" }, timeout: 5)
        XCTAssertEqual(refusals?.payload["accepted"] as? Bool, false,
                       "rule 10 — refused with a reason, not attempted")
        XCTAssertTrue(session.entries(named: "tracks.subtitle.cycled").isEmpty,
                      "no cycle happened, because there is nothing to cycle")
        XCTAssertTrue(session.entries(named: "tracks.subtitle.selected").isEmpty)

        // The app is alive and still playing — the wrap-around did not crash it.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertNil(session.entries(named: "playback.state.illegal").first)
    }

    /// impl: TRACK-001 rule 7 / CTRL-003 — the menu button exists and its menu
    /// lists Off plus every track, with one row per entry.
    func testSubtitleMenuListsOffAndEveryTrack() throws {
        try launch(with: try FixtureBuilder.filmWithSidecars())
        session.waitForEntry("tracks.subtitle.listChanged",
                             where: { ($0["count"] as? Int ?? 0) >= 2 }, timeout: 10)

        let window = app.windows.firstMatch
        // The HUD is up while opening and hidden after 2.5 s of playing, so the
        // pointer is moved first to bring it back (CTRL-001 rule 4).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        let button = window.descendants(matching: .any)[A11yID.hudSubtitleMenuButton.rawValue]
        XCTAssertTrue(button.waitForExistence(timeout: 10),
                      "play.hud.subtitleMenuButton must be reachable (CTRL-003)")

        button.click()
        // Scoped by identifier, not `app.menuItems`: every process carries the
        // system menu bar, so an unscoped query counts ~70 items that are not
        // ours and the assertion means nothing.
        let rows = app.menuItems.matching(
            NSPredicate(format: "identifier BEGINSWITH %@",
                        "\(A11yID.menuSubtitleTracks.rawValue).row."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the menu opened")
        XCTAssertEqual(rows.count, 3, "rule 3 — Off, then the two tracks")

        // Row 0 is asserted to *be* Off by what selecting it does, not by its
        // label: AppKit reports an empty accessibility label for these items, and
        // behaviour is the stronger claim anyway.
        rows.element(boundBy: 0).click()
        let off = session.waitForEntry(
            "tracks.subtitle.selected", where: { $0["source"] as? String == "user" }, timeout: 5)
        XCTAssertEqual(off?.payload["trackId"] as? Int, -1, "row 0 is Off (rule 3)")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        rows.element(boundBy: 2).click()

        let selected = session.waitForEntry(
            "tracks.subtitle.selected",
            where: { $0["source"] as? String == "user" && ($0["trackId"] as? Int ?? -1) >= 0 },
            timeout: 5)
        XCTAssertEqual(selected?.payload["applied"] as? Bool, true,
                       "rule 5 — the selection was confirmed by reading libvlc back")
    }
}
