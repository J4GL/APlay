// impl: MEDIA-001 rules 2, 10 — the drop route's decisions, tested without a
// live libvlc instance.
//
// The first test is the regression test for the reported defect: the window
// accepted no drags at all because the video host never registered a dragged
// type. Everything downstream of that was correct and unreachable.

import AppKit
import XCTest
@testable import Play

final class MediaIntakeDropTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 15
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func touch(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    /// impl: MEDIA-001 rule 2 — the regression test for "la zone de drop ne
    /// marche pas". Without this registration AppKit never delivers a drag.
    @MainActor
    func testVideoHostRegistersFileURLDrags() {
        let host = VideoHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        XCTAssertTrue(host.registeredDraggedTypes.contains(.fileURL),
                      "the video host must accept .fileURL drags (MEDIA-001 rule 2)")
    }

    /// impl: MEDIA-001 rule 10 — acceptance is by recognised extension, and a
    /// directory is accepted because rule 2 expands it.
    @MainActor
    func testAcceptanceMatchesTheFormatCatalog() throws {
        let video = try touch("clip.mp4")
        let subtitle = try touch("clip.srt")
        let text = try touch("notes.txt")

        XCTAssertTrue(DropTarget.isAcceptable(video))
        XCTAssertTrue(DropTarget.isAcceptable(subtitle))
        XCTAssertTrue(DropTarget.isAcceptable(scratch), "a directory is accepted (rule 2)")
        XCTAssertFalse(DropTarget.isAcceptable(text), "an unrecognised extension is refused")
    }

    /// impl: MEDIA-001 rule 2 — a dropped directory is expanded exactly one
    /// level deep, and non-media siblings are dropped on the floor.
    @MainActor
    func testDirectoryExpansionIsOneLevelDeep() throws {
        _ = try touch("b-clip.mp4")
        _ = try touch("a-clip.mkv")
        _ = try touch("clip.srt")
        _ = try touch("readme.txt")
        let nested = scratch.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("deep.mp4"))

        let expanded = DirectoryExpander.expand([scratch])
        let names = Set(expanded.map(\.lastPathComponent))

        XCTAssertEqual(names, ["a-clip.mkv", "b-clip.mp4", "clip.srt"])
        XCTAssertFalse(names.contains("readme.txt"), "unsupported extensions are not expanded in")
        XCTAssertFalse(names.contains("deep.mp4"), "expansion is one level deep, not recursive")
    }

    /// impl: MEDIA-001 rule 2 — multiple files sort in Finder-style localised
    /// name order, which is what decides *which* file plays first.
    @MainActor
    func testMultipleFilesSortInLocalisedNameOrder() throws {
        _ = try touch("clip10.mp4")
        _ = try touch("clip2.mp4")
        _ = try touch("clip1.mp4")

        let sorted = DirectoryExpander.inNameOrder(
            DirectoryExpander.expand([scratch]).filter(FormatCatalog.isVideo))

        XCTAssertEqual(sorted.map(\.lastPathComponent), ["clip1.mp4", "clip2.mp4", "clip10.mp4"],
                       "localizedStandardCompare orders clip2 before clip10, unlike a plain sort")
    }

    /// impl: MEDIA-001 rule 9 — the highlight traces WIN-001's corner radius, so
    /// it follows the window's actual shape instead of overshooting the corners.
    @MainActor
    func testDropHighlightMatchesTheWindowCornerRadius() {
        let view = DropHighlightView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(view.layer?.cornerRadius, WindowShapeController.cornerRadius)
        XCTAssertEqual(view.layer?.borderWidth, 2)
        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)),
                     "the highlight must never swallow the drop it decorates")
    }
}
