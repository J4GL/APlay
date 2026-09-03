// impl: TEST-001 rule 1 — the fixture generator's command-line entry point.
//
// Compiled together with Tests/Fixtures/FixtureBuilder.swift by
// scripts/make_fixtures.sh. It exists because encoding test media *inside* an
// xcodebuild test run reproducibly kills Play with
// `SIGKILL (Code Signature Invalid)` on a libvlccore page; generating first, in
// a plain process, removes that interference entirely. See TEST-001's Notes.

import Foundation

let generators: [(name: String, make: () throws -> URL)] = [
    ("colorbars-10s", FixtureBuilder.colorBars10s),
    // impl: WIN-003-S1 — storage ratio 1.25, display ratio 1.778.
    ("anamorphic-576p", FixtureBuilder.anamorphic576p),
    ("dual-audio-10s", FixtureBuilder.dualAudio10s),
    // impl: PREF-001-H3 — two tracks of the *same* language, the only situation
    // the name filter exists for.
    ("two-french-audio-10s", FixtureBuilder.twoFrenchAudio10s),
    ("film-with-sidecars", FixtureBuilder.filmWithSidecars),
    ("standalone-subtitle", { try FixtureBuilder.standaloneSubtitle() }),
    ("queue-of-three", FixtureBuilder.queueOfThree),
    ("queue-broken-middle", FixtureBuilder.queueWithBrokenMiddleItem),
]

var failed = false
for generator in generators {
    do {
        let url = try generator.make()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        print("fixtures: ok      \(generator.name) (\(size) bytes)")
    } catch {
        print("fixtures: FAIL    \(generator.name): \(error)")
        failed = true
    }
}
print("fixtures: \(FixtureBuilder.generatedDirectory.path)")
exit(failed ? 1 : 0)
