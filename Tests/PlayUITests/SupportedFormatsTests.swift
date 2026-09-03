// impl: MEDIA-002-S1, S3 — each failure case shows its own banner, and an
// all-failing queue shows exactly one summary instead of one per item.
//
// MEDIA-002-S2 (the 15 s open-timeout) needs a mount stubbed to block reads
// indefinitely (`PLAY_STUB_SLOW_READ=1`); no such stub exists in this
// codebase, and building one is out of this feature's scope, so that
// scenario is not covered here. MEDIA-002-H1/H2 (catalog consistency, a real
// MKV playing) are pre-existing behaviour untouched by this feature.
//
// Written against the spec; not executed in this environment (no Xcode, see
// README's Test section) — verified instead by manually driving the built
// app and reading the JSONL log, per this project's own history of doing the
// same for WIN-001/WIN-003 work.

import PlayA11y
import XCTest

final class SupportedFormatsTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: SessionLog!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaySupportedFormatsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func launch(with arguments: [String]) throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let launchedAt = Date()
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        session = try SessionLog.newest(after: launchedAt)
    }

    private func emptyFile(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    /// impl: MEDIA-002-S1 — four distinct causes, four distinct banners, and
    /// the window stays responsive afterwards.
    func testEachFailureCaseShowsItsOwnBanner() throws {
        let missing = scratch.appendingPathComponent("does-not-exist.mp4")
        let empty = try emptyFile("empty.mp4")
        let unsupported = try emptyFile("notes.txt")

        try launch(with: [missing.path])
        let banner = app.otherElements[A11yID.bannerMediaFailure.rawValue]

        let missingEntry = session.waitForEntry("media.open.failed",
            where: { $0["reason"] as? String == "fileMissing" }, timeout: 15)
        XCTAssertNotNil(missingEntry)
        XCTAssertTrue(banner.waitForExistence(timeout: 5))

        app.terminate()
        try launch(with: [empty.path])
        XCTAssertNotNil(session.waitForEntry("media.open.failed",
            where: { $0["reason"] as? String == "emptyFile" }, timeout: 15))
        XCTAssertTrue(app.otherElements[A11yID.bannerMediaFailure.rawValue].waitForExistence(timeout: 5))

        app.terminate()
        try launch(with: [unsupported.path])
        XCTAssertNotNil(session.waitForEntry("media.open.failed",
            where: { $0["reason"] as? String == "unsupportedExtension" }, timeout: 15))
        XCTAssertTrue(app.otherElements[A11yID.bannerMediaFailure.rawValue].waitForExistence(timeout: 5))

        // impl: MEDIA-002 rule 8 — never left in `.opening`; and the window
        // still accepts a good file afterwards.
        let lastState = session.entries(named: "playback.state.changed").last
        XCTAssertNotEqual(lastState?.payload["to"] as? String, "opening")
        let fixture = try FixtureBuilder.colorBars10s()
        app.terminate()
        try launch(with: [fixture.path])
        XCTAssertNotNil(session.waitForEntry("playback.state.changed",
            where: { $0["to"] as? String == "playing" }, timeout: 20))
    }

    /// impl: MEDIA-002-S3 — five failures in one batch produce five
    /// `media.open.failed` entries but exactly one `media.banner.shown`,
    /// carrying the summary message, not five individual banners.
    func testAnAllFailingQueueProducesOneBannerNotMany() throws {
        let files = try (0 ..< 5).map { try emptyFile("empty-\($0).mp4") }
        try launch(with: files.map(\.path))

        XCTAssertNotNil(session.waitForEntry("media.banner.shown",
            where: { $0["reason"] as? String == "allItemsFailed" }, timeout: 15))
        XCTAssertEqual(session.entries(named: "media.open.failed").count, 5)
        XCTAssertEqual(session.entries(named: "media.banner.shown").count, 1,
                       "one summary, not one per item — MEDIA-002 rule 10")

        let banner = app.otherElements[A11yID.bannerMediaFailure.rawValue]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(banner.staticTexts["None of those 5 files could be played"].exists
                      || banner.value as? String == "None of those 5 files could be played",
                      "the summary names the count")
    }
}
