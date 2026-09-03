// impl: LIST-002-H1 · H2 · H3 · S1 · S2 · S3 — the queue panel.

import PlayA11y
import XCTest

final class QueueOverlayTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launch(with path: String) throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = [path, "-audio.volume", "60", "-audio.muted", "YES"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        session.waitForEntry("playlist.built", timeout: 20)
    }

    private var window: XCUIElement { app.windows.firstMatch }

    private func element(_ identifier: String) -> XCUIElement {
        window.descendants(matching: .any)[identifier]
    }

    private func openPanel() {
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(element(A11yID.queuePanel.rawValue).waitForExistence(timeout: 10),
                      "⌘L opens the panel")
    }

    // MARK: - Happy paths

    /// impl: LIST-002-H1 rules 2, 5-6, 8 — the panel lists the queue, marks the
    /// current row, and jumps on click.
    func testPanelListsTheQueueAndJumpsOnClick() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)
        openPanel()

        let opened = session.waitForEntry("playlist.panel.opened", timeout: 5)
        XCTAssertEqual(opened?.payload["trigger"] as? String, "keyboard")
        for index in 0..<3 {
            XCTAssertTrue(element(A11yID.queueRow(index)).exists,
                          "row \(index) is listed")
        }

        // rule 5 — the row's state is exposed as its accessibility value, so
        // "which row is playing" is assertable without reading pixels.
        XCTAssertEqual(element(A11yID.queueRow(0)).value as? String, "playing")

        // The spec's UI requirement: the element is captured before and after
        // the interaction, and the *change* is what is proven — a single frame
        // of a panel says nothing about whether clicking a row did anything.
        let before = element(A11yID.queuePanel.rawValue).screenshot().pngRepresentation

        element(A11yID.queueRow(2)).click()
        let clicked = session.waitForEntry("playlist.row.clicked", timeout: 5)
        XCTAssertEqual(clicked?.payload["index"] as? Int, 2)
        session.waitForEntry("playlist.advanced",
                             where: { $0["toIndex"] as? Int == 2 && $0["reason"] as? String == "row" },
                             timeout: 10)
        XCTAssertTrue(element(A11yID.queueRow(2)).waitForExistence(timeout: 5))
        XCTAssertEqual(element(A11yID.queueRow(2)).value as? String, "playing")
        XCTAssertEqual(element(A11yID.queueRow(0)).value as? String, "played",
                       "rule 8 — earlier items become played")
        let after = element(A11yID.queuePanel.rawValue).screenshot().pngRepresentation
        XCTAssertNotEqual(before, after,
                          "the ▸ and ✓ glyphs and the accent highlight moved with the selection")
    }

    /// impl: LIST-002-H3 rule 10 — removing the current item advances to the
    /// next one, and is not a failure.
    func testRemovingTheCurrentItemAdvances() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)
        openPanel()

        // The ✕ only exists while the row is hovered (rule 10).
        element(A11yID.queueRow(0)).hover()
        let remove = element(A11yID.queueRowRemove(0))
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the ✕ appears on hover")
        remove.click()

        let removed = session.waitForEntry("playlist.removed", timeout: 5)
        XCTAssertEqual(removed?.payload["index"] as? Int, 0)
        XCTAssertEqual(removed?.payload["wasCurrent"] as? Bool, true)
        session.waitForEntry("playlist.advanced", where: { $0["toIndex"] as? Int == 0 }, timeout: 10)
        XCTAssertFalse(element(A11yID.queueRow(2)).exists, "two rows remain, not three")
        XCTAssertTrue(session.entries(named: "media.open.failed").isEmpty,
                      "removal is not a failure")
    }

    // MARK: - Sad paths

    /// impl: LIST-002-S2 rule 3 — a one-item queue has no panel, and ⌘L is
    /// refused rather than opening an empty one.
    func testPanelDoesNotExistForASingleItemQueue() throws {
        try launch(with: try FixtureBuilder.colorBars10s().path)

        app.typeKey("l", modifierFlags: .command)
        app.typeKey("l", modifierFlags: .command)
        let key = session.waitForEntry("input.key",
                                       where: { $0["action"] as? String == "toggleQueuePanel" },
                                       timeout: 5)
        XCTAssertEqual(key?.payload["accepted"] as? Bool, false)
        XCTAssertFalse(element(A11yID.queuePanel.rawValue).exists)
        XCTAssertTrue(session.entries(named: "playlist.panel.opened").isEmpty)

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        XCTAssertTrue(element(A11yID.hudPlayPauseButton.rawValue).waitForExistence(timeout: 10))
        XCTAssertFalse(element(A11yID.hudQueueButton.rawValue).exists,
                       "rule 3 / LIST-001 rule 12 — no queue, no queue button")
    }

    /// impl: LIST-002-S3 rule 4 — the HUD stays up while the panel is open, and
    /// starts hiding again once it closes.
    func testHUDDoesNotAutoHideWhileThePanelIsOpen() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        openPanel()

        // Well past CTRL-001's 2.5 s idle delay, with the pointer parked away
        // from the HUD's own tracking regions.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).hover()
        Thread.sleep(forTimeInterval: 6)

        XCTAssertTrue(element(A11yID.hudRoot.rawValue).exists, "the HUD is still up")
        XCTAssertTrue(element(A11yID.queuePanel.rawValue).exists)
        XCTAssertNotNil(session.entries(named: "hud.autoHide.suppressed")
            .first(where: { ($0.payload["reason"] as? String)?.contains("queuePanelOpen") == true }),
                        "rule 4 — suppressed, and the reason says which overlay did it")

        // Esc closes the panel (CTRL-002 rule 2's fallthrough, not fullscreen).
        app.typeKey(.escape, modifierFlags: [])
        let closed = session.waitForEntry("playlist.panel.closed", timeout: 5)
        XCTAssertEqual(closed?.payload["trigger"] as? String, "escape")

        // …and the suppression was scoped to the panel, not permanent.
        session.waitForEntry("hud.hidden", timeout: 20)
    }

    /// impl: LIST-002-H2 rule 9 — a pending row moves by drag, and the model
    /// moves with it.
    func testPendingRowsReorderByDrag() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)
        openPanel()
        let names = (0..<3).map { element(A11yID.queueRow($0)).label }
        XCTAssertEqual(names, ["a-first", "b-second", "c-third"], "the starting order")

        element(A11yID.queueRow(2)).press(forDuration: 0.3,
                                          thenDragTo: element(A11yID.queueRow(1)))
        let reordered = session.waitForEntry("playlist.reordered", timeout: 5)
        XCTAssertEqual(reordered?.payload["fromIndex"] as? Int, 2)
        XCTAssertEqual(reordered?.payload["toIndex"] as? Int, 1)
        XCTAssertEqual((0..<3).map { element(A11yID.queueRow($0)).label },
                       ["a-first", "c-third", "b-second"],
                       "the visible order follows the model, and the identifiers "
                       + "re-index by position (CTRL-003 rule 4)")
    }

    /// impl: LIST-002-S1 rule 9 — the current row refuses to move, and nothing
    /// may be dropped above it.
    func testTheCurrentRowRefusesReordering() throws {
        try launch(with: try FixtureBuilder.queueOfThree().path)
        openPanel()

        element(A11yID.queueRow(0)).press(forDuration: 0.3,
                                          thenDragTo: element(A11yID.queueRow(2)))
        XCTAssertNotNil(session.waitForEntry("playlist.reorderRejected",
                                             where: { $0["reason"] as? String == "playedOrCurrent" },
                                             timeout: 5))
        XCTAssertTrue(session.entries(named: "playlist.reordered").isEmpty)
        XCTAssertEqual((0..<3).map { element(A11yID.queueRow($0)).label },
                       ["a-first", "b-second", "c-third"], "the order is unchanged")
    }
}
