// impl: TEST-001 rules 8-10, 13 — the fixtures other specs depend on are
// themselves asserted, because a fixture that quietly lost its second audio
// track would make TRACK-003's tests pass for the wrong reason.
//
// These live in the UI test target, whose runner is a plain process, and NOT in
// PlayUnitTests, which is hosted **inside Play itself**. Generating the
// dual-audio fixture in the app host reproducibly killed it with
// `SIGKILL (Code Signature Invalid)` on a libvlccore page — see TEST-001's Notes
// for the evidence. Encoding test media inside a process that is simultaneously
// running libvlc has no reason to be, and this is where it stops.

import AVFoundation
import XCTest

final class MediaFixtureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 120
    }

    /// impl: TEST-001 rule 9 — two audio tracks, tagged `eng` and `fra`.
    func testDualAudioFixtureHasTwoTaggedAudioTracks() async throws {
        let url = try FixtureBuilder.dualAudio10s()
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 2, "TRACK-003 needs two selectable audio streams")

        var languages: [String] = []
        for track in audio {
            let code = try await track.load(.languageCode)
            languages.append(code ?? "")
        }
        XCTAssertEqual(languages.sorted(), ["eng", "fra"],
                       "rule 9's language tags are what libvlc reports as psz_language")

        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
    }

    /// impl: TEST-001 rule 10 — the colour-bars fixture carries no audio, which
    /// is what makes it TRACK-003-S3's video-only case.
    func testColorBarsFixtureHasNoAudioStream() async throws {
        let asset = AVURLAsset(url: try FixtureBuilder.colorBars10s())
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "colour bars is the video-only fixture")
    }

    /// impl: TEST-001 rule 8 — the film and its two sidecars share a directory
    /// and a basename, which is exactly what TRACK-001 rule 10 scans for.
    func testSidecarFixtureLayout() throws {
        let film = try FixtureBuilder.filmWithSidecars()
        let directory = film.deletingLastPathComponent()
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["fixture.fr.srt", "fixture.mp4", "fixture.srt"])

        let english = try String(
            contentsOf: directory.appendingPathComponent("fixture.srt"), encoding: .utf8)
        XCTAssertTrue(english.contains("PLAY SUBTITLE ENGLISH 3"),
                      "a cue exists at the white-frame second, so the two are comparable")
    }
}
