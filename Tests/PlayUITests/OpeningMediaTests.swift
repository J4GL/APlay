// impl: MEDIA-001-S2 · CTRL-002-S2 — the ⌘O route.
//
// The open panel is the one piece of standard AppKit chrome in a player that has
// none, and it is the only way to open a file with the keyboard. It is asserted
// as a real sheet on the window, not as "the key was accepted".

import PlayA11y
import XCTest

final class OpeningMediaTests: XCTestCase {
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
        app.launchArguments = arguments + ["-audio.volume", "60", "-audio.muted", "YES"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
    }

    /// impl: MEDIA-001 rule 1 / MEDIA-001-S2 — ⌘O opens the panel over playing
    /// media, and cancelling it changes nothing at all.
    func testCommandOOpensThePanelAndCancellingChangesNothing() throws {
        try launch(with: [try FixtureBuilder.colorBars10s().path])
        session.waitForEntry("playback.state.changed",
                             where: { $0["to"] as? String == "playing" }, timeout: 20)

        // Paused first, exactly as MEDIA-001-S2 describes. It is also what makes
        // the assertion stable: a playing 10 s fixture reaches `ended` on its
        // own while the panel is up, and "nothing changed" would then be false
        // for a reason that has nothing to do with the panel.
        app.typeKey(" ", modifierFlags: [])
        let paused = session.waitForEntry("playback.state.changed",
                                          where: { $0["to"] as? String == "paused" }, timeout: 10)
        let pausedAt = paused?.payload["positionMs"] as? Int ?? -1

        app.typeKey("o", modifierFlags: .command)
        let key = session.waitForEntry("input.key",
                                       where: { $0["action"] as? String == "openDocument" },
                                       timeout: 5)
        XCTAssertEqual(key?.payload["accepted"] as? Bool, true)

        // rule 1 — a real sheet on the one window, not a separate panel window.
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "⌘O presents the open panel")

        let requestsBefore = session.entries(named: "media.open.requested").count
        let mediaSetBefore = session.entries(named: "engine.media.set").count
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotNil(session.waitForEntry("media.open.cancelled", timeout: 10))
        XCTAssertEqual(session.entries(named: "media.open.requested").count, requestsBefore,
                       "cancelling opens nothing")
        XCTAssertEqual(session.entries(named: "engine.media.set").count, mediaSetBefore,
                       "and never reached libvlc — the item at launch is the only one")
        let last = session.entries(named: "playback.state.changed").last
        XCTAssertEqual(last?.payload["to"] as? String, "paused",
                       "the transport state is untouched by the panel")
        XCTAssertEqual(last?.payload["positionMs"] as? Int, pausedAt,
                       "and so is the position")
    }

    /// impl: CTRL-002-S2 — in the empty state every transport key is refused,
    /// and ⌘O is not: the refusal is per-action, not a blanket input lock.
    func testCommandOIsAcceptedInTheEmptyStateWhereTransportKeysAreNot() throws {
        try launch(with: [])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        app.typeKey("]", modifierFlags: .command)
        XCTAssertEqual(session.waitForEntry("input.key",
                                            where: { $0["action"] as? String == "nextItem" },
                                            timeout: 5)?.payload["accepted"] as? Bool, false)

        app.typeKey("o", modifierFlags: .command)
        XCTAssertEqual(session.waitForEntry("input.key",
                                            where: { $0["action"] as? String == "openDocument" },
                                            timeout: 5)?.payload["accepted"] as? Bool, true)
        XCTAssertTrue(app.windows.firstMatch.sheets.firstMatch.waitForExistence(timeout: 15),
                      "the panel is reachable with no media open — otherwise there is no way in")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertNotNil(session.waitForEntry("media.open.cancelled", timeout: 10))
        XCTAssertTrue(session.entries(named: "engine.media.set").isEmpty,
                      "libvlc was never asked to open anything")
    }
}
