// impl: WIN-001 rule 9 — the drag-handle geometry, tested without a window.
//
// Rule 9.3 exists because this decision used to be spread across six
// `mouseDownCanMoveWindow` overrides, which is how the dead band came to be
// missing without anyone noticing. One pure function is also one testable
// function.

import XCTest
@testable import Play

final class WindowDragRegionTests: XCTestCase {
    /// A button-sized control at (100, 10), 24 x 24 — the shape of a HUD button.
    private let button = NSRect(x: 100, y: 10, width: 24, height: 24)
    /// A wide control, the shape of the seek bar.
    private let bar = NSRect(x: 16, y: 60, width: 400, height: 20)

    private func classify(_ x: CGFloat, _ y: CGFloat) -> WindowDragRegions.Classification {
        WindowDragRegions.classify(NSPoint(x: x, y: y), controls: [button, bar])
    }

    /// impl: WIN-001 rule 9 — on a control, the control takes the press.
    func testAPointOnAControlIsAControl() {
        XCTAssertEqual(classify(112, 22), .control, "the centre of the button")
        XCTAssertEqual(classify(100, 10), .control, "its bottom-left corner is inside")
        XCTAssertEqual(classify(200, 70), .control, "the middle of the seek bar")
    }

    /// impl: WIN-001 rule 9.2 — the 8 pt dead band, on every side.
    func testTheDeadBandSurroundsEachControl() {
        XCTAssertEqual(classify(96, 22), .deadBand, "4 pt to the left")
        XCTAssertEqual(classify(128, 22), .deadBand, "4 pt to the right")
        XCTAssertEqual(classify(112, 6), .deadBand, "4 pt below")
        XCTAssertEqual(classify(112, 40), .deadBand, "6 pt above")
        XCTAssertEqual(classify(95, 5), .deadBand, "diagonally, still within the inset rect")
    }

    /// impl: WIN-001 rule 9.1 — the band is bounded. This is the assertion that
    /// distinguishes a margin from a general dead zone: one point further out
    /// and the window drags again.
    func testTheDeadBandIsBoundedAtExactlyEightPoints() {
        XCTAssertEqual(WindowDragRegions.exclusionMargin, 8)
        XCTAssertEqual(classify(92.5, 22), .deadBand, "7.5 pt out — still dead")
        XCTAssertEqual(classify(91, 22), .dragHandle, "9 pt out — a handle again")
        XCTAssertEqual(classify(133, 22), .dragHandle)
    }

    /// impl: WIN-001 rule 9 — everything else drags, including the space
    /// *between* two controls when it is wide enough. This is what makes the
    /// HUD's own backdrop a drag handle (CTRL-001 rule 13).
    func testEverythingElseIsADragHandle() {
        XCTAssertEqual(classify(300, 300), .dragHandle, "the middle of the picture")
        XCTAssertEqual(classify(0, 0), .dragHandle, "the corner")
        XCTAssertEqual(classify(112, 200), .dragHandle, "directly above the button, far away")
    }

    /// impl: WIN-001 rule 9 — with no controls at all, every point drags. That
    /// is the empty state (rule 9.5) and the HUD-hidden case.
    func testWithNoControlsEveryPointIsAHandle() {
        XCTAssertEqual(WindowDragRegions.classify(NSPoint(x: 112, y: 22), controls: []),
                       .dragHandle)
    }

    /// impl: WIN-001 rule 9 — a point in two controls' bands is still just dead;
    /// `control` wins over `deadBand` when the point is inside either one.
    func testControlWinsOverAnOverlappingDeadBand() {
        let adjacent = NSRect(x: 130, y: 10, width: 24, height: 24)
        let point = NSPoint(x: 131, y: 22)  // inside `adjacent`, in `button`'s band
        XCTAssertEqual(WindowDragRegions.classify(point, controls: [button, adjacent]), .control,
                       "a press on a real control must never be swallowed by a neighbour's margin")
    }

    /// impl: WIN-001 rule 16 — the refusal names a control, so the dead band is
    /// visible in the trace instead of looking like a dropped press.
    func testNearestControlNamesTheClosestOne() {
        let controls = [(name: "play.hud.playPauseButton", rect: button),
                        (name: "play.hud.seekBar", rect: bar)]
        XCTAssertEqual(
            WindowDragRegions.nearestControl(to: NSPoint(x: 96, y: 22), among: controls),
            "play.hud.playPauseButton")
        XCTAssertEqual(
            WindowDragRegions.nearestControl(to: NSPoint(x: 200, y: 55), among: controls),
            "play.hud.seekBar")
        XCTAssertNil(WindowDragRegions.nearestControl(to: .zero, among: []))
    }
}
