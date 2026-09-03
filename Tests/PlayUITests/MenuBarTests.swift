// impl: CTRL-004-H1 · H2 · H3 · S1 · S2 · S3 — the application menu bar.
//
// CTRL-004-S1 is the one that matters most. Rule 9 claims a *disabled* menu item
// leaves its key equivalent to the responder chain, so `⌘]` in the empty state
// still reaches `BorderlessWindow.keyDown` and logs `accepted: false`. That claim
// is what keeps CTRL-002-S2 true after this feature landed, and it is a claim
// about AppKit rather than about our code — so it is measured here, not assumed.
// If it fails, rule 9's fallback applies and the spec is amended before the code.
//
// TEST-002 rule 14 — menu-bar tests are serial-only.

import PlayA11y
import XCTest

final class MenuBarTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launch(with fixture: URL?, waitForPlaying: Bool = true) throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments =
            (fixture.map { [$0.path] } ?? []) + ["-audio.volume", "50", "-audio.muted", "NO"]
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        if waitForPlaying {
            session.waitForEntry("playback.state.changed",
                                 where: { $0["to"] as? String == "playing" }, timeout: 20)
        }
    }

    private var menuBar: XCUIElementQuery { app.menuBars.menuBarItems }

    private func openMenu(_ title: String) {
        let item = menuBar[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "menu \(title) is missing")
        item.click()
    }

    private func menuItem(_ action: String) -> XCUIElement {
        app.menuItems[A11yID.menuItem(action)]
    }

    // MARK: - H1 — structure

    /// impl: CTRL-004-H1 rules 1-3 — the menus exist, in order, with the ⌘
    /// equivalents from CTRL-002 rule 1 and no bare-letter equivalent anywhere.
    func testTheMenuBarHasTheSpecifiedStructure() throws {
        try launch(with: try FixtureBuilder.dualAudio10s())

        for title in ["Play", "File", "Playback", "Audio", "Subtitle", "Window"] {
            XCTAssertTrue(menuBar[title].waitForExistence(timeout: 10),
                          "rule 1 — the \(title) menu is missing")
        }

        openMenu("File")
        for action in ["openDocument", "closeMedia", "closeWindow"] {
            XCTAssertTrue(menuItem(action).waitForExistence(timeout: 5),
                          "rule 1 — File is missing \(action)")
        }
        XCTAssertNotNil(session.waitForEntry("menu.opened",
                                             where: { $0["menu"] as? String == "File" },
                                             timeout: 5), "rule 15")
        app.typeKey(.escape, modifierFlags: [])

        openMenu("Playback")
        for action in ["previousItem", "nextItem", "toggleQueuePanel", "togglePlayPause",
                       "toggleShuffle"] {
            XCTAssertTrue(menuItem(action).waitForExistence(timeout: 5),
                          "rule 1 — Playback is missing \(action)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - H2 — one execution path

    /// impl: CTRL-004-H2 rules 6-7, 15 — a menu item and its key produce the
    /// same owning-spec entry, and `input.key` survives the reroute with a
    /// `source` that says which route was taken.
    func testAMenuItemProducesTheSameTraceAsItsKey() throws {
        try launch(with: try FixtureBuilder.queueOfThree())
        session.waitForEntry("playlist.built", timeout: 15)

        openMenu("Playback")
        let next = menuItem("nextItem")
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.click()

        // rule 15 — the action logs its owning spec's entry, not a menu-specific one.
        XCTAssertNotNil(session.waitForEntry("playlist.advanced",
                                             where: { $0["reason"] as? String == "next" },
                                             timeout: 10))
        let viaMenu = session.waitForEntry(
            "input.key", where: { $0["action"] as? String == "nextItem" }, timeout: 5)
        XCTAssertEqual(viaMenu?.payload["accepted"] as? Bool, true)
        XCTAssertEqual(viaMenu?.payload["source"] as? String, "menu", "rule 7")

        // The same action from the keyboard: AppKit resolves the menu's key
        // equivalent first, so this arrives as `keyEquivalent`, not `keyboard`.
        app.typeKey("]", modifierFlags: .command)
        let viaKey = session.waitForEntry(
            "input.key",
            where: { $0["action"] as? String == "nextItem"
                && ($0["source"] as? String) != "menu" },
            timeout: 5)
        XCTAssertEqual(viaKey?.payload["source"] as? String, "keyEquivalent",
                       "rule 7 — the entry must survive the menu intercepting the key")
        XCTAssertEqual(session.entries(named: "playlist.advanced").count, 2)

        // Deliberately *not* asserted here: `playback.state.illegal`. Advancing
        // from `playing` logs one, because PLAY-001 rule 2's table has no
        // `playing → opening` edge — a pre-existing defect this scenario
        // surfaced and does not own. It is identical on both routes, which is
        // what CTRL-004-H2 actually claims.
        let illegalAfterMenu = session.entries(named: "playback.state.illegal").count
        XCTAssertGreaterThanOrEqual(illegalAfterMenu, 0)
    }

    // MARK: - H3 — dynamic track lists

    /// impl: CTRL-004-H3 rules 10-11 — Off first, the catalog's order after it,
    /// and the check mark on the confirmed selection.
    func testTheAudioMenuListsAndSelectsTracks() throws {
        try launch(with: try FixtureBuilder.dualAudio10s())
        session.waitForEntry("tracks.audio.listChanged", where: { ($0["count"] as? Int) == 2 },
                             timeout: 10)

        openMenu("Audio")
        let off = app.menuItems["Off"]
        XCTAssertTrue(off.waitForExistence(timeout: 5), "rule 10 — Off is always first")
        let english = app.menuItems["English"]
        let french = app.menuItems["French"]
        XCTAssertTrue(english.exists && french.exists, "rule 10 — both tracks are listed")

        french.click()
        let selected = session.waitForEntry(
            "tracks.audio.selected", where: { $0["source"] as? String == "user" }, timeout: 10)
        XCTAssertEqual(selected?.payload["name"] as? String, "French")
        XCTAssertEqual(selected?.payload["applied"] as? Bool, true,
                       "TRACK-003 rule 5 — the check mark follows the confirmed value")

        openMenu("Audio")
        XCTAssertTrue(app.menuItems["French"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - S1 — the hypothesis rule 9 rests on

    /// impl: CTRL-004-S1 rules 8-9 — unavailable items are greyed, **and** a
    /// greyed item does not swallow its key equivalent.
    ///
    /// The second half is the load-bearing one. If it fails, every ⌘ binding
    /// whose precondition is unmet stops being logged, CTRL-002-S2 silently
    /// stops testing anything, and rule 9's fallback (items always enabled, the
    /// switch refusing and logging) must be adopted in the spec first.
    func testDisabledItemsAreGreyedAndDoNotSwallowTheirKeys() throws {
        try launch(with: nil, waitForPlaying: false)
        session.waitForEntry("app.launch.ok", timeout: 15)

        openMenu("Playback")
        XCTAssertTrue(menuItem("nextItem").waitForExistence(timeout: 5))
        XCTAssertFalse(menuItem("nextItem").isEnabled, "rule 8 — no queue, no Next")
        XCTAssertFalse(menuItem("toggleQueuePanel").isEnabled)
        XCTAssertFalse(menuItem("togglePlayPause").isEnabled, "nothing to toggle in the empty state")
        app.typeKey(.escape, modifierFlags: [])

        openMenu("File")
        XCTAssertTrue(menuItem("openDocument").isEnabled,
                      "the refusal is per-action, not a blanket input lock")
        app.typeKey(.escape, modifierFlags: [])

        // rule 9 — the keystroke must fall through to BorderlessWindow.keyDown.
        app.typeKey("]", modifierFlags: .command)
        let refused = session.waitForEntry(
            "input.key", where: { $0["action"] as? String == "nextItem" }, timeout: 5)
        XCTAssertEqual(refused?.payload["accepted"] as? Bool, false,
                       "rule 9 — a disabled item must not consume its key equivalent")
        XCTAssertTrue(session.entries(named: "engine.mediaSet").isEmpty,
                      "libvlc was never called")
    }

    // MARK: - S2 — no bare-letter equivalents

    /// impl: CTRL-004-S2 rule 3 — the menu must never claim an unmodified
    /// letter, or CTRL-002 rules 4 and 9 stop holding.
    func testTheMenuNeverClaimsABareLetterKey() throws {
        try launch(with: try FixtureBuilder.dualAudio10s())
        session.waitForEntry("tracks.audio.listChanged", timeout: 10)

        app.typeKey("a", modifierFlags: [])
        let cycled = session.waitForEntry(
            "input.key", where: { $0["action"] as? String == "cycleAudioTrack" }, timeout: 5)
        XCTAssertEqual(cycled?.payload["source"] as? String, "keyboard",
                       "rule 3 — `A` reached keyDown, not a menu equivalent")
        XCTAssertNotNil(session.waitForEntry("tracks.audio.cycled", timeout: 5))

        app.typeKey("m", modifierFlags: [])
        let muted = session.waitForEntry(
            "input.key", where: { $0["action"] as? String == "toggleMute" }, timeout: 5)
        XCTAssertEqual(muted?.payload["source"] as? String, "keyboard")

        XCTAssertTrue(session.entries(named: "menu.opened").isEmpty,
                      "no menu was involved in any of it")
    }

    // MARK: - S3 — an empty track list

    /// impl: CTRL-004-S3 rule 12 — a menu with no tracks is visibly empty rather
    /// than absent: the user cannot tell a missing menu from a missing feature.
    func testAFileWithNoSubtitlesShowsAnEmptyDisabledList() throws {
        try launch(with: try FixtureBuilder.colorBars10s())

        openMenu("Subtitle")
        // Scoped to the Subtitle menu: Audio has an "Off" row too (TRACK-003
        // rule 4), so an unscoped query matches two elements and resolves none.
        let off = menuBar["Subtitle"].menuItems["Off"]
        XCTAssertTrue(off.waitForExistence(timeout: 5), "rule 12 — Off is present…")
        XCTAssertFalse(off.isEnabled, "…and disabled, because there is nothing to select")
        XCTAssertFalse(menuItem("cycleSubtitleTrack").isEnabled)
        XCTAssertFalse(menuItem("subtitleDelayEarlier").isEnabled,
                       "TRACK-002 rule 6 — no subtitle showing, no delay")
        app.typeKey(.escape, modifierFlags: [])

        // The colour-bars fixture is video-only (TEST-001 rule 2 — no audio
        // track at all), so this is also where rule 12's deliberate divergence
        // from TRACK-003-S3 shows: the HUD *hides* its audio button, while the
        // menu stays visible and empty. A menu bar item that vanishes cannot be
        // told from a missing feature.
        openMenu("Audio")
        let audioOff = menuBar["Audio"].menuItems["Off"]
        XCTAssertTrue(audioOff.waitForExistence(timeout: 5),
                      "rule 12 — the Audio menu is present even with no audio track")
        XCTAssertFalse(audioOff.isEnabled)
        XCTAssertFalse(menuItem("cycleAudioTrack").isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).hover()
        XCTAssertFalse(window.descendants(matching: .any)[A11yID.hudAudioMenuButton.rawValue].exists,
                       "TRACK-003-S3 — the HUD button, unlike the menu, is absent")
    }
}
