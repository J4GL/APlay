// impl: PREF-001 rules 2-6, 8, 10 — the matcher, tested without a live libvlc
// and without touching the machine's Language & Region settings.
//
// Rule 8 exists for this file. TRACK-003-H2 ("the preferred language is
// honoured") was unimplementable for as long as the answer came from
// `Locale.preferredLanguages`: no test may edit system settings. A pure function
// over an explicit preference is what makes it assertable at all.

import XCTest
@testable import Play

final class TrackPreferenceMatchingTests: XCTestCase {
    private func track(_ id: Int32,
                       _ name: String,
                       language: String?,
                       searchText: String = "") -> MediaTrack {
        MediaTrack(id: id, displayName: name, language: language,
                   channels: 2, isExternal: false, searchText: searchText)
    }

    private func preference(_ languages: [String], filter: String = "")
        -> TrackLanguagePreference {
        TrackLanguagePreference(languages: languages, nameFilter: filter)
    }

    // MARK: - Order

    /// impl: PREF-001 rule 4 — the list is walked in the *user's* order, not the
    /// track order. This is the exact defect TRACK-003-H2 forbids: matching by
    /// track order hands a French-first user the English stream because the
    /// container happens to declare it first.
    func testUserOrderWinsOverTrackOrder() {
        let tracks = [track(1, "English", language: "eng"),
                      track(2, "French", language: "fra")]

        XCTAssertEqual(TrackCatalog.firstPreferred(in: tracks, matching: preference(["fr"]))?.id, 2)
        XCTAssertEqual(TrackCatalog.firstPreferred(in: tracks, matching: preference(["fr", "en"]))?.id, 2,
                       "fr is first in the user's list, so fr wins even though English comes first")
        XCTAssertEqual(TrackCatalog.firstPreferred(in: tracks, matching: preference(["en", "fr"]))?.id, 1)
    }

    /// impl: PREF-001 rule 4 — a language with no track is skipped, not treated
    /// as a failure of the whole match.
    func testAbsentLanguagesAreSkipped() {
        let tracks = [track(1, "English", language: "eng")]
        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: tracks, matching: preference(["ja", "hu", "en"]))?.id, 1)
    }

    /// impl: TRACK-001 rule 8 / TRACK-003 rule 6 — no language match at all
    /// returns nil, and the *caller* decides what that means (Off for subtitles,
    /// track 0 for audio). The matcher never makes that choice itself.
    func testNoLanguageMatchReturnsNil() {
        let tracks = [track(1, "English", language: "eng")]
        XCTAssertNil(TrackCatalog.firstPreferred(in: tracks, matching: preference(["hu"])))
    }

    // MARK: - The filter is soft (rule 5)

    /// impl: PREF-001 rules 4-5 — with two tracks of the winning language, the
    /// one whose name contains the filter is taken.
    func testFilterBreaksATieWithinTheWinningLanguage() {
        let tracks = [track(1, "Français", language: "fra"),
                      track(2, "Français forced", language: "fra")]
        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: tracks, matching: preference(["fr"], filter: "forced"))?.id,
            2)
        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: tracks, matching: preference(["fr"]))?.id, 1,
            "with no filter the first track of the language wins")
    }

    /// impl: PREF-001 rule 5 — **the** rule of this feature. A filter that
    /// matches nothing must not lose the language, must not fall through to the
    /// next one, and must not produce nil (which for subtitles would mean Off).
    /// A tie-breaker that can lose the tie is a trap.
    func testFilterThatMatchesNothingStillKeepsTheLanguage() {
        let tracks = [track(1, "French", language: "fra"),
                      track(2, "English forced", language: "eng")]

        let chosen = TrackCatalog.firstPreferred(
            in: tracks, matching: preference(["fr", "en"], filter: "forced"))

        XCTAssertEqual(chosen?.id, 1, "fr had a candidate, so fr wins — the filter only ranks")
        XCTAssertNotEqual(chosen?.id, 2, "the filter must never cause a fallthrough to en")
        XCTAssertNotNil(chosen, "and must never yield nil, which would mean Off for subtitles")
    }

    /// impl: PREF-001 rule 5 — a whitespace-only filter is no filter.
    func testBlankFilterIsIgnored() {
        let tracks = [track(1, "Français", language: "fra"),
                      track(2, "Français forced", language: "fra")]
        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: tracks, matching: preference(["fr"], filter: "   "))?.id,
            1)
    }

    // MARK: - What the filter reads (rule 6)

    /// impl: PREF-001 rule 6 — the whole reason `searchText` exists. A track
    /// carrying only `lang=fra` is *named* "French" by TRACK-001 rule 2, which
    /// throws away the libvlc description where the word "forced" actually is.
    /// Matching `displayName` alone would work on well-labelled files and fail on
    /// exactly the ones that need it.
    func testFilterMatchesLibvlcsRawDescriptionNotOnlyTheCookedName() {
        let cooked = [track(1, "French", language: "fra"),
                      track(2, "French 2", language: "fra",
                            searchText: "Track 3 - [French] - [Forced]")]

        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: cooked, matching: preference(["fr"], filter: "forced"))?.id,
            2, "the match came from searchText, since neither displayName contains 'forced'")
    }

    /// impl: PREF-001 rule 6 — matching ignores case.
    func testFilterIsCaseInsensitive() {
        let tracks = [track(1, "Français", language: "fra"),
                      track(2, "Français SDH", language: "fra")]
        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: tracks, matching: preference(["fr"], filter: "sdh"))?.id,
            2)
    }

    /// impl: PREF-001 rule 6 — `searchText` is populated from libvlc's own
    /// strings while they are still in scope, before rule 2 discards them.
    func testSearchTextIsCarriedThroughNamingAndDisambiguation() {
        let named = TrackCatalog.name([
            MediaPlayer.RawTrack(id: 1, listName: "Track 1 - [French]", title: nil,
                                 language: "fra", channels: 2),
            MediaPlayer.RawTrack(id: 2, listName: "Track 2 - [French] - [Forced]", title: nil,
                                 language: "fra", channels: 2),
        ], externalStems: [])

        XCTAssertEqual(named.map(\.displayName), ["French", "French 2"],
                       "TRACK-001 rules 2 and 4 are unchanged by this addition")
        XCTAssertTrue(named[1].searchText.contains("Forced"),
                      "and disambiguation must not drop searchText on the way through")
    }

    // MARK: - Alphabets (rule 2)

    /// impl: PREF-001 rule 2 — libvlc reports ISO 639-2 (`fra`), the preference
    /// holds ISO 639-1 (`fr`). Comparing them without conversion never matches,
    /// which would look like "the setting does nothing".
    func testThreeLetterTrackCodesMatchTwoLetterPreferences() {
        let tracks = [track(1, "German", language: "deu"),
                      track(2, "Japanese", language: "jpn")]
        XCTAssertEqual(TrackCatalog.firstPreferred(in: tracks, matching: preference(["ja"]))?.id, 2)
        XCTAssertEqual(TrackCatalog.firstPreferred(in: tracks, matching: preference(["de"]))?.id, 1)
    }

    /// impl: PREF-001 rule 2 — ISO 639-2's **bibliographic** codes.
    ///
    /// Matroska routinely writes `fre` for French where Foundation only knows
    /// `fra`, so `alpha2` returned nothing and the track never matched `fr`.
    /// The failure was selective — twenty languages broken, every other one
    /// fine — which is why it read as "the setting does nothing".
    func testBibliographicLanguageCodesResolve() {
        let pairs = [("fre", "fr"), ("ger", "de"), ("chi", "zh"), ("dut", "nl"),
                     ("cze", "cs"), ("gre", "el"), ("ice", "is"), ("per", "fa"),
                     ("rum", "ro"), ("slo", "sk"), ("wel", "cy"), ("baq", "eu"),
                     ("alb", "sq"), ("arm", "hy"), ("bur", "my"), ("geo", "ka"),
                     ("mac", "mk"), ("mao", "mi"), ("may", "ms"), ("tib", "bo")]
        for (bibliographic, expected) in pairs {
            XCTAssertEqual(TrackCatalog.alpha2(bibliographic), expected,
                           "ISO 639-2/B \(bibliographic) must resolve to \(expected)")
        }
    }

    /// The terminological spellings must keep working, and languages without a
    /// bibliographic twin must be untouched by the table.
    func testTerminologicalAndUnpairedCodesAreUnaffected() {
        for (code, expected) in [("fra", "fr"), ("deu", "de"), ("zho", "zh"), ("nld", "nl"),
                                 ("jpn", "ja"), ("eng", "en"), ("spa", "es"), ("swe", "sv")] {
            XCTAssertEqual(TrackCatalog.alpha2(code), expected)
        }
    }

    /// impl: PREF-001 rule 4 — the end-to-end shape of the reported defect: two
    /// French tracks tagged `fre`, a `fr` preference and a "Full" filter.
    func testFrenchBibliographicTracksMatchAndTheFilterPicks() {
        let tracks = [track(3, "FR Forced [ASS] - Crunchyroll", language: "fre"),
                      track(4, "FR Full [ASS] - Crunchyroll", language: "fre")]
        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: tracks,
                                        matching: preference(["fr"], filter: "Full"))?.id,
            4, "the language must match, and the filter must then take the Full track")
        XCTAssertEqual(
            TrackCatalog.firstPreferred(in: tracks, matching: preference(["fr"]))?.id, 3,
            "with no filter, the first track of the language")
    }

    /// impl: PREF-001 rule 4 — an untagged track is never a language match.
    func testUndeterminedLanguageNeverMatches() {
        let tracks = [track(1, "Track 1", language: "und"),
                      track(2, "Track 2", language: nil)]
        XCTAssertNil(TrackCatalog.firstPreferred(in: tracks, matching: preference(["en"])))
    }

    // MARK: - Parsing (rule 10)

    /// impl: PREF-001 rule 10 — a list arrives as an array or as one
    /// comma-separated string, because `NSArgumentDomain` is how a test injects
    /// it through `launchArguments`.
    func testParseAcceptsBothArrayAndCommaSeparatedForms() {
        XCTAssertEqual(LanguageCode.parse(["fr", "en"]).codes, ["fr", "en"])
        XCTAssertEqual(LanguageCode.parse("fr,en").codes, ["fr", "en"])
        XCTAssertEqual(LanguageCode.parse(" FR , en ").codes, ["fr", "en"],
                       "trimmed and lowercased")
    }

    /// impl: PREF-001 rule 10 — anything that is not two letters is reported,
    /// not silently dropped, and duplicates keep their first position.
    func testParseReportsRejectionsAndDeduplicates() {
        let parsed = LanguageCode.parse("français, XX, 12, en, EN")
        XCTAssertEqual(parsed.codes, ["xx", "en"],
                       "XX is two letters, so it is structurally valid and kept")
        XCTAssertEqual(parsed.rejected, ["français", "12"])

        XCTAssertEqual(LanguageCode.parse("fr,en,fr").codes, ["fr", "en"],
                       "de-duplicated keeping first position — order is the preference")
    }

    /// impl: PREF-001 rules 3, 10 — nothing usable means the system list, which
    /// downstream is expressed as an empty `languages` array.
    func testEmptyAndMissingValuesParseToNothing() {
        XCTAssertTrue(LanguageCode.parse(nil).codes.isEmpty)
        XCTAssertTrue(LanguageCode.parse("").codes.isEmpty)
        XCTAssertTrue(LanguageCode.parse("  ,  ").codes.isEmpty)
        XCTAssertTrue(LanguageCode.parse(nil).rejected.isEmpty,
                      "absent is not the same as malformed, and must not warn")
    }

    /// impl: PREF-001 rule 3 — an unset preference must behave exactly as the
    /// app did before this feature existed.
    func testEmptyPreferenceFallsBackToTheSystemList() throws {
        let first = try XCTUnwrap(LanguageCode.systemPreferred().first,
                                  "the test machine reports no preferred language")
        let tracks = [track(1, "Hungarian", language: "hun"),
                      track(2, "System", language: first)]

        XCTAssertEqual(TrackCatalog.firstPreferred(in: tracks, matching: .unset)?.id, 2,
                       "rule 3 — an empty list means the system's, not 'no preference'")
    }

    /// impl: PREF-001 rule 2 — validation is the same everywhere: exactly two
    /// ASCII letters, stored lowercase.
    func testTwoLetterValidation() {
        XCTAssertEqual(LanguageCode.normalised("FR"), "fr")
        XCTAssertEqual(LanguageCode.normalised(" ja "), "ja")
        XCTAssertNil(LanguageCode.normalised("fra"), "three letters is the libvlc alphabet")
        XCTAssertNil(LanguageCode.normalised("f"))
        XCTAssertNil(LanguageCode.normalised("12"))
        XCTAssertNil(LanguageCode.normalised(""))
    }
}
