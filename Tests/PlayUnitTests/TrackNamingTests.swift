// impl: TRACK-001 rules 2, 4 · TRACK-002 rule 3 · TRACK-003 rule 2 — the pure
// policies, tested without a live libvlc.
//
// TRACK-002 rule 3 asks for the ms→µs conversion to be unit-tested by name: a
// 1000× error there is silent, and this is the cheapest place to catch it.

import XCTest
@testable import Play

final class TrackNamingTests: XCTestCase {
    private func raw(id: Int32, listName: String = "", title: String? = nil,
                     language: String? = nil, channels: Int = 0) -> MediaPlayer.RawTrack {
        MediaPlayer.RawTrack(id: id, listName: listName, title: title,
                             language: language, channels: channels)
    }

    /// impl: TRACK-001 rule 2 — title, else localised language, else "Track n".
    func testDisplayNameFallsBackInOrder() {
        let tracks = TrackCatalog.name([
            raw(id: 1, title: "Director commentary", language: "eng"),
            raw(id: 2, language: "fra"),
            raw(id: 3),
        ], externalStems: [])

        XCTAssertEqual(tracks[0].displayName, "Director commentary", "a title wins")
        XCTAssertEqual(tracks[1].displayName, "French", "then the localised language name")
        XCTAssertEqual(tracks[2].displayName, "Track 3", "then the index")
    }

    /// libvlc's own "Track 1 - [English]" carries nothing rule 2 has not already
    /// produced, and must not leak into the menu.
    func testGenericLibvlcNamesAreNotUsedAsTitles() {
        let tracks = TrackCatalog.name([raw(id: 7, listName: "Track 1 - [English]")],
                                       externalStems: [])
        XCTAssertEqual(tracks[0].displayName, "Track 1")
    }

    /// impl: TRACK-001 rule 4 — two English tracks must be distinguishable.
    func testDuplicateNamesAreDisambiguated() {
        let tracks = TrackCatalog.name([
            raw(id: 1, language: "eng"),
            raw(id: 2, language: "eng"),
            raw(id: 3, language: "fra"),
        ], externalStems: [])
        XCTAssertEqual(tracks.map(\.displayName), ["English", "English 2", "French"])
    }

    /// impl: TRACK-003 rule 2 — the layout beats a bare index when it is what
    /// actually differs between two same-language tracks.
    func testChannelLayoutDisambiguatesSameLanguageAudio() {
        let tracks = TrackCatalog.name([
            raw(id: 1, language: "eng", channels: 2),
            raw(id: 2, language: "eng", channels: 6),
        ], externalStems: [])
        XCTAssertEqual(tracks.map(\.displayName), ["English", "English 5.1"])
        XCTAssertNil(TrackCatalog.channelLayout(2), "stereo is not worth saying")
        XCTAssertEqual(TrackCatalog.channelLayout(8), "7.1")
    }

    /// impl: TRACK-001 rule 12 — an external track is labelled with its stem.
    func testExternalTracksTakeTheirFileStem() {
        let tracks = TrackCatalog.name(
            [raw(id: 4, listName: "fixture.srt", language: "eng")],
            externalStems: ["fixture"])
        XCTAssertEqual(tracks[0].displayName, "fixture")
        XCTAssertTrue(tracks[0].isExternal)
    }

    /// libvlc reports ISO 639-2 (`eng`); preferredLanguages is 639-1 (`en`).
    /// Comparing them without conversion never matches, which would silently
    /// turn rules TRACK-001 r8 and TRACK-003 r6 into "always the fallback".
    func testLanguageCodesAreComparedInTheSameAlphabet() {
        XCTAssertEqual(TrackCatalog.alpha2("eng"), "en")
        XCTAssertEqual(TrackCatalog.alpha2("fra"), "fr")
        XCTAssertEqual(TrackCatalog.alpha2("fr"), "fr")
        XCTAssertNil(TrackCatalog.alpha2("und"))
        XCTAssertNil(TrackCatalog.alpha2(nil))
    }

    /// impl: TRACK-002 rule 3 — the one conversion, in the unit the C API uses.
    func testSubtitleDelayConvertsMillisecondsToMicroseconds() {
        XCTAssertEqual(SubtitleDelayController.microseconds(forMs: 1_400), 1_400_000)
        XCTAssertEqual(SubtitleDelayController.microseconds(forMs: -2_500), -2_500_000)
        XCTAssertEqual(SubtitleDelayController.microseconds(forMs: 0), 0)
        XCTAssertEqual(
            SubtitleDelayController.microseconds(forMs: SubtitleDelayController.limitMs),
            60_000_000, "rule 2's rail, expressed in µs — never more")
    }

    /// impl: TRACK-002 rule 4 — the sign and the single decimal are part of the
    /// readout; one that drops the sign is worse than none.
    func testDelayReadoutFormatting() {
        XCTAssertEqual(SubtitleDelayController.readout(forMs: 0), "Subtitle delay 0 s")
        XCTAssertEqual(SubtitleDelayController.readout(forMs: 1_400), "Subtitle delay +1.4 s")
        XCTAssertEqual(SubtitleDelayController.readout(forMs: -2_500), "Subtitle delay −2.5 s")
        XCTAssertEqual(SubtitleDelayController.readout(forMs: 60_000), "Subtitle delay +60.0 s")
    }
}
