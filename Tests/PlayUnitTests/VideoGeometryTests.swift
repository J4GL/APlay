// impl: WIN-003 rules 2, 6, 13 — the ratio arithmetic, tested without a window.
//
// The lock itself is AppKit's (`contentAspectRatio`); what is ours is the number
// handed to it and the size the window is moved to. Both are pure here, which is
// the only part of WIN-003 a test can pin down to the pixel.

import XCTest
@testable import Play

final class VideoGeometryTests: XCTestCase {
    private func geometry(_ w: Int, _ h: Int, sar: (Int, Int) = (1, 1)) -> VideoGeometry {
        VideoGeometry(pixelSize: NSSize(width: w, height: h), sarNum: sar.0, sarDen: sar.1)!
    }

    // MARK: - Rule 2, the display aspect ratio

    func testSquarePixelsGiveTheStorageRatio() {
        XCTAssertEqual(geometry(640, 360).displayAspectRatio, 16.0 / 9, accuracy: 0.001)
        XCTAssertEqual(geometry(640, 480).displayAspectRatio, 4.0 / 3, accuracy: 0.001)
    }

    /// impl: WIN-003 rule 2 — the whole reason the SAR is read at all: 720 x 576
    /// stored, 16:9 displayed. Reading the storage ratio gives 1.25 and a
    /// visibly squashed picture.
    func testAnamorphicPixelsGiveTheDisplayRatioNotTheStorageRatio() {
        let anamorphic = geometry(720, 576, sar: (64, 45))
        XCTAssertEqual(anamorphic.displayAspectRatio, 16.0 / 9, accuracy: 0.01)
        XCTAssertNotEqual(anamorphic.displayAspectRatio, 1.25, accuracy: 0.1)
    }

    /// A container that declares no SAR reports 0/0, which must read as square
    /// pixels and never as a zero-width picture.
    func testAMissingSampleAspectRatioIsSquare() {
        XCTAssertEqual(geometry(1920, 1080, sar: (0, 0)).sampleAspectRatio, 1)
        XCTAssertEqual(geometry(1920, 1080, sar: (0, 0)).displayAspectRatio,
                       16.0 / 9, accuracy: 0.001)
    }

    func testAZeroSizedVideoIsRejectedRatherThanDividedBy() {
        XCTAssertNil(VideoGeometry(pixelSize: NSSize(width: 0, height: 0), sarNum: 1, sarDen: 1))
        XCTAssertNil(VideoGeometry(pixelSize: NSSize(width: 640, height: 0), sarNum: 1, sarDen: 1))
    }

    // MARK: - Rule 13, the minimum that respects the ratio

    func testTheMinimumIs320x180OnSixteenNine() {
        let minimum = VideoGeometry.minimumContentSize(ratio: 16.0 / 9)
        XCTAssertEqual(minimum.width, 320, accuracy: 0.5)
        XCTAssertEqual(minimum.height, 180, accuracy: 0.5)
    }

    /// impl: WIN-003 rule 13 — on 4:3 the *width* binds, and a flat 320 x 180
    /// minimum would be a shape the lock forbids.
    func testTheMinimumGrowsInHeightOnFourThree() {
        let minimum = VideoGeometry.minimumContentSize(ratio: 4.0 / 3)
        XCTAssertEqual(minimum.width, 320, accuracy: 0.5)
        XCTAssertEqual(minimum.height, 240, accuracy: 0.5)
        XCTAssertEqual(minimum.width / minimum.height, 4.0 / 3, accuracy: 0.01)
    }

    /// impl: WIN-003 rule 13 — and on scope the *height* binds instead.
    func testTheMinimumGrowsInWidthOnCinemascope() {
        let minimum = VideoGeometry.minimumContentSize(ratio: 2.35)
        XCTAssertEqual(minimum.height, 180, accuracy: 0.5)
        XCTAssertEqual(minimum.width, 423, accuracy: 1)
        XCTAssertGreaterThanOrEqual(minimum.width, 320)
    }

    func testANonsenseRatioFallsBackToTheUnlockedFloor() {
        XCTAssertEqual(VideoGeometry.minimumContentSize(ratio: 0), VideoGeometry.unlockedMinimum)
        XCTAssertEqual(VideoGeometry.minimumContentSize(ratio: -3), VideoGeometry.unlockedMinimum)
    }

    // MARK: - Rule 6, the size the window takes

    func testTheWidthIsKeptAndTheHeightDerived() {
        let size = VideoGeometry.contentSize(ratio: 16.0 / 9,
                                             keepingWidthOf: NSSize(width: 960, height: 720),
                                             within: NSSize(width: 3000, height: 2000))
        XCTAssertEqual(size.width, 960, accuracy: 0.5)
        XCTAssertEqual(size.height, 540, accuracy: 0.5)
    }

    /// impl: WIN-003 rule 6 — when the derived height does not fit, *both* axes
    /// scale, because shrinking only the height would break the ratio.
    func testItScalesDownWhenTheDerivedHeightDoesNotFit() {
        let size = VideoGeometry.contentSize(ratio: 4.0 / 3,
                                             keepingWidthOf: NSSize(width: 1200, height: 500),
                                             within: NSSize(width: 1400, height: 600))
        XCTAssertEqual(size.width / size.height, 4.0 / 3, accuracy: 0.02)
        XCTAssertLessThanOrEqual(size.height, 600)
        XCTAssertLessThanOrEqual(size.width, 1400)
    }

    /// impl: WIN-003 rules 6, 13 — a screen too small for the minimum yields the
    /// minimum, not a sub-minimum window AppKit will refuse anyway.
    func testItNeverReturnsLessThanTheRatioMinimum() {
        let size = VideoGeometry.contentSize(ratio: 4.0 / 3,
                                             keepingWidthOf: NSSize(width: 340, height: 200),
                                             within: NSSize(width: 300, height: 200))
        XCTAssertEqual(size, VideoGeometry.minimumContentSize(ratio: 4.0 / 3))
    }

    func testAnUnknownLimitLeavesTheWidthAlone() {
        let size = VideoGeometry.contentSize(ratio: 2.35,
                                             keepingWidthOf: NSSize(width: 1000, height: 200),
                                             within: nil)
        XCTAssertEqual(size.width, 1000, accuracy: 0.5)
        XCTAssertEqual(size.width / size.height, 2.35, accuracy: 0.02)
    }

    // MARK: - Rule 6, around the centre and back onto the screen

    func testTheResizeHappensAroundTheCentre() {
        let before = NSRect(x: 100, y: 100, width: 960, height: 720)
        let after = VideoGeometry.recentred(before, toFrameSize: NSSize(width: 960, height: 540))
        XCTAssertEqual(after.midX, before.midX, accuracy: 0.5)
        XCTAssertEqual(after.midY, before.midY, accuracy: 0.5)
        XCTAssertEqual(after.height, 540, accuracy: 0.5)
    }

    func testAFrameGrownPastTheTopIsNudgedBackInside() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let grown = NSRect(x: 200, y: 700, width: 800, height: 450)
        let fixed = VideoGeometry.nudgedInside(grown, visibleFrame: visible)
        XCTAssertEqual(fixed.maxY, 900, accuracy: 0.5, "pushed back under the menu bar")
        XCTAssertEqual(fixed.size, grown.size, "nudged, never shrunk — the ratio survives")
    }

    func testAFrameAlreadyInsideIsLeftAlone() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 200, y: 200, width: 800, height: 450)
        XCTAssertEqual(VideoGeometry.nudgedInside(frame, visibleFrame: visible), frame)
    }
}
