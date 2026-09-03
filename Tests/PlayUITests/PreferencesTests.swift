// impl: PREF-001-H1 · H2 · H3 · H4 · S1 · S2 · S3 — the language preference and
// the settings window.
//
// PREF-001-H1 is also TRACK-003-H2, which had been unimplementable since it was
// written: it asked for "the system's preferred language set to French", and no
// test may change the machine's Language & Region settings. Moving the list into
// the app turned it into a launch argument.

import PlayA11y
import XCTest

final class PreferencesTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// Launch arguments are `-key value` pairs landing in `NSArgumentDomain`
    /// (PREF-001 rule 10) — the seam `AppDelegate.openCommandLineArguments`
    /// already accounts for, and the reason rule 10 accepts a comma-separated
    /// string as well as an array.
    private func launch(with fixture: URL,
                        preferences: [String: String] = [:],
                        waitForPlaying: Bool = true) throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let launchedAt = Date()
        app = XCUIApplication()
        var arguments = [fixture.path, "-audio.volume", "60", "-audio.muted", "NO"]
        // Every preference key is passed on every launch, defaulting to empty.
        // PREF-001 rule 11 persists each edit immediately, so a test that
        // asserted on "nothing configured" would otherwise read whatever an
        // earlier test's settings window had written — which is exactly how
        // PREF-001-S2 failed the first time it ran.
        let keys = ["tracks.audio.languages", "tracks.audio.nameFilter",
                    "tracks.subtitle.languages", "tracks.subtitle.nameFilter"]
        for key in keys {
            arguments += ["-\(key)", preferences[key] ?? ""]
        }
        app.launchArguments = arguments
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
        if waitForPlaying {
            session.waitForEntry("playback.state.changed",
                                 where: { $0["to"] as? String == "playing" }, timeout: 20)
        }
    }

    private func defaultAudioName() -> String? {
        session.entries(named: "tracks.audio.selected")
            .last(where: { $0.payload["source"] as? String == "default" })?
            .payload["name"] as? String
    }

    // MARK: - H1 — the headline, and TRACK-003-H2 at last

    /// impl: PREF-001-H1 / TRACK-003-H2 — a configured language decides the
    /// default, with no user interaction and no system settings touched.
    func testConfiguredLanguageDecidesTheDefaultTrack() throws {
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "fr"])

        let restored = session.waitForEntry("preferences.restored", timeout: 10)
        XCTAssertEqual(restored?.payload["audioLanguages"] as? [String], ["fr"])
        XCTAssertEqual(restored?.payload["source"] as? String, "arguments",
                       "rule 20 — a test must be able to tell 'applied' from 'never read'")

        session.waitForEntry("tracks.audio.listChanged", where: { ($0["count"] as? Int) == 2 },
                             timeout: 10)
        let chosen = session.waitForEntry(
            "tracks.audio.selected", where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(chosen?.payload["name"] as? String, "French",
                       "rule 4 — the user's order wins over the container's")
        XCTAssertEqual(chosen?.payload["applied"] as? Bool, true,
                       "TRACK-003 rule 5 — confirmed by reading libvlc back")

        // No user interaction occurred: the only selection was the default one.
        XCTAssertTrue(session.entries(named: "tracks.audio.selected")
            .allSatisfy { $0.payload["source"] as? String != "user" })
    }

    /// impl: PREF-001-H1 — the mirror image, proving the preference is what
    /// decided it rather than the container order happening to agree.
    func testTheOppositePreferenceChoosesTheOppositeTrack() throws {
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "en,fr"])
        session.waitForEntry("tracks.audio.listChanged", timeout: 10)
        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(defaultAudioName(), "English")
    }

    // MARK: - H2 — independence

    /// impl: PREF-001-H2 rule 1 — the two preferences are separate lists, and a
    /// subtitle setting must not reach the audio default.
    func testAudioAndSubtitlePreferencesAreIndependent() throws {
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "fr",
                                 "tracks.subtitle.languages": "en"])

        let restored = session.waitForEntry("preferences.restored", timeout: 10)
        XCTAssertEqual(restored?.payload["audioLanguages"] as? [String], ["fr"])
        XCTAssertEqual(restored?.payload["subtitleLanguages"] as? [String], ["en"])

        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(defaultAudioName(), "French",
                       "the English *subtitle* preference must not reach the audio default")
    }

    // MARK: - H3 / S1 — the filter, and its softness

    /// impl: PREF-001-H3 rules 4-5 — with two tracks of the winning language,
    /// the filter decides which. The fixture is two `fra` tracks, so the
    /// language match cannot separate them and only the filter can.
    func testFilterBreaksTheTieBetweenSameLanguageTracks() throws {
        try launch(with: try FixtureBuilder.twoFrenchAudio10s(),
                   preferences: ["tracks.audio.languages": "fr",
                                 "tracks.audio.nameFilter": "French 2"])

        let list = session.waitForEntry("tracks.audio.listChanged", timeout: 10)
        XCTAssertEqual(list?.payload["names"] as? [String], ["French", "French 2"],
                       "TRACK-001 rule 4 gives the same-language pair distinct names")

        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(defaultAudioName(), "French 2",
                       "rule 4 — the filter picked the second of two equally-matching tracks")
    }

    /// impl: PREF-001-H3 — the control run: the same fixture with no filter
    /// takes the first track of the language, so the previous test's result is
    /// attributable to the filter and to nothing else.
    func testWithoutAFilterTheFirstTrackOfTheLanguageWins() throws {
        try launch(with: try FixtureBuilder.twoFrenchAudio10s(),
                   preferences: ["tracks.audio.languages": "fr"])
        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(defaultAudioName(), "French")
    }

    /// impl: PREF-001-S1 rule 5 — **the** rule of this feature. A filter that
    /// matches nothing keeps the language: it does not fall through to the next
    /// one, and for audio it does not reach the track-0 fallback either.
    func testAFilterThatMatchesNothingStillKeepsTheLanguage() throws {
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "fr,en",
                                 "tracks.audio.nameFilter": "forced"])

        session.waitForEntry("tracks.audio.listChanged", timeout: 10)
        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(defaultAudioName(), "French",
                       "no French track contains 'forced', and French still wins")
        XCTAssertNotEqual(defaultAudioName(), "English",
                          "the filter must never cause a fallthrough to the next language")
    }

    // MARK: - H4 — a change reaches the media already playing

    /// impl: PREF-001-H4 rules 12, 14, 16, 19 — ⌘, opens the window, adding a
    /// language applies to the film already playing, and the change persists.
    func testAddingALanguageAppliesToTheMediaAlreadyPlaying() throws {
        // Start with a preference that matches nothing, so the default landed on
        // the container's first track and there is a change to observe.
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "hu"])
        session.waitForEntry("tracks.audio.listChanged", timeout: 10)
        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(defaultAudioName(), "English",
                       "TRACK-003 rule 6 — no language match falls back to track 0")

        app.typeKey(",", modifierFlags: .command)
        let opened = session.waitForEntry("preferences.window.opened", timeout: 10)
        XCTAssertNotNil(opened, "rule 14 — ⌘, opens the settings window")

        let window = app.windows["Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let add = window.comboBoxes[A11yID.preferencesAudioAdd.rawValue]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "rule 16 — the add control")
        add.click()
        add.typeText("fr\r")

        let added = session.waitForEntry(
            "preferences.language.added",
            where: { $0["kind"] as? String == "audio" && $0["code"] as? String == "fr" },
            timeout: 10)
        // The list started as ["hu"], so `fr` lands at index 1 — the identifier
        // is the *current* position (CTRL-003 rule 4), not a fresh count.
        XCTAssertEqual(added?.payload["index"] as? Int, 1)

        let changed = session.waitForEntry("preferences.changed",
                                           where: { $0["kind"] as? String == "audio" },
                                           timeout: 10)
        XCTAssertEqual(changed?.payload["languages"] as? [String], ["hu", "fr"])

        // rule 12 — the film already playing follows the new preference.
        session.waitForEntry(
            "tracks.audio.selected",
            where: { $0["source"] as? String == "default" && $0["name"] as? String == "French" },
            timeout: 10)
        XCTAssertEqual(defaultAudioName(), "French")

        // …and playback was not disturbed on the way.
        XCTAssertTrue(session.entries(named: "playback.state.changed")
            .allSatisfy { $0.payload["to"] as? String != "paused" })
        XCTAssertNil(session.entries(named: "playback.state.illegal").first)
    }

    /// impl: PREF-001-H4 rule 12 — a track the user picked by hand outranks a
    /// later preference change. A default is a default.
    func testAHandPickedTrackSurvivesAPreferenceChange() throws {
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "fr"])
        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)

        // `A` cycles to the other track — an explicit choice.
        app.typeKey("a", modifierFlags: [])
        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "cycle" }, timeout: 10)
        let afterCycle = session.entries(named: "tracks.audio.selected").last?.payload["trackId"] as? Int

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 10))
        let filter = app.windows["Settings"]
            .textFields[A11yID.preferencesAudioNameFilter.rawValue]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.click()
        filter.typeText("English")

        session.waitForEntry("preferences.changed",
                             where: { $0["kind"] as? String == "audio" }, timeout: 10)

        let latest = session.entries(named: "tracks.audio.selected").last
        XCTAssertEqual(latest?.payload["trackId"] as? Int, afterCycle,
                       "userHasChosen — the preference must not override a hand-picked track")
    }

    // MARK: - S2 — malformed input

    /// impl: PREF-001-S2 rule 10 — every rejected entry is named, the survivors
    /// are used, and the app neither crashes nor ends up silent.
    func testMalformedPreferenceIsReportedAndTheRestSurvives() throws {
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "français, 12, en"])

        let rejected = session.waitForEntry("preferences.language.rejected", timeout: 10)
        XCTAssertEqual(rejected?.level, "warn")
        let names = rejected?.payload["rejected"] as? [String] ?? []
        XCTAssertTrue(names.contains("français"), "each rejected entry is named: \(names)")
        XCTAssertTrue(names.contains("12"))

        let restored = session.waitForEntry("preferences.restored", timeout: 10)
        XCTAssertEqual(restored?.payload["audioLanguages"] as? [String], ["en"])

        session.waitForEntry("tracks.audio.selected",
                             where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertEqual(defaultAudioName(), "English")
        XCTAssertNil(session.entries(named: "tracks.audio.disabled").first,
                     "a malformed setting must never leave the film silent")
    }

    /// impl: PREF-001-S2 rule 3 — with nothing configured the app behaves
    /// exactly as it did before this feature existed.
    func testAnUnsetPreferenceFallsBackToTheSystemList() throws {
        try launch(with: try FixtureBuilder.dualAudio10s())

        let restored = session.waitForEntry("preferences.restored", timeout: 10)
        XCTAssertEqual(restored?.payload["audioLanguages"] as? [String], [])
        XCTAssertEqual(restored?.payload["source"] as? String, "systemFallback")

        // TRACK-003 rule 6 — audio never defaults to silence, whatever the
        // system list happens to contain on this machine.
        let chosen = session.waitForEntry(
            "tracks.audio.selected", where: { $0["source"] as? String == "default" }, timeout: 10)
        XCTAssertNotEqual(chosen?.payload["trackId"] as? Int, -1)
        XCTAssertTrue(session.entries(named: "preferences.language.rejected").isEmpty,
                      "absent is not malformed, and must not warn")
    }

    // MARK: - S3 — typing is not playing

    /// impl: PREF-001-S3 rule 17 — the escape CTRL-002 rule 4 always required.
    /// Typing letters that are player shortcuts into the filter field must reach
    /// the field and nothing else.
    func testTypingInTheFilterFieldDrivesNoPlayback() throws {
        try launch(with: try FixtureBuilder.dualAudio10s(),
                   preferences: ["tracks.audio.languages": "fr"])
        session.waitForEntry("tracks.audio.listChanged", timeout: 10)

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))

        let filter = settings.textFields[A11yID.preferencesSubtitleNameFilter.rawValue]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.click()

        let keyEntriesBefore = session.entries(named: "input.key").count
        let cyclesBefore = session.entries(named: "tracks.audio.cycled").count
        let togglesBefore = session.entries(named: "playback.transport.toggle").count

        // Every one of these characters is a player binding: s, a, m, f.
        filter.typeText("sam forced")

        session.waitForEntry("preferences.filter.changed",
                             where: { ($0["filter"] as? String)?.contains("sam forced") == true },
                             timeout: 10)

        XCTAssertEqual(session.entries(named: "tracks.audio.cycled").count, cyclesBefore,
                       "`a` must not cycle the audio track")
        XCTAssertEqual(session.entries(named: "playback.transport.toggle").count, togglesBefore,
                       "the space in 'sam forced' must not pause the film")
        XCTAssertTrue(session.entries(named: "tracks.subtitle.cycled").isEmpty,
                      "`s` must not cycle subtitles")
        XCTAssertTrue(session.entries(named: "window.fullscreen.enter").isEmpty,
                      "`f` must not go fullscreen")
        XCTAssertEqual(session.entries(named: "input.key").count, keyEntriesBefore,
                       "rule 17 — no keystroke reached the player's dispatcher at all")

        XCTAssertEqual(filter.value as? String, "sam forced",
                       "the characters landed in the field")
    }
}
