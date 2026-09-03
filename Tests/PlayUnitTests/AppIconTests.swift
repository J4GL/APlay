// impl: ICON-001-H1, ICON-001-S2 — the shipped icon, read from the running
// Play.app bundle rather than re-derived, so a regenerated `.icns` that never
// made it into the bundle (or a build that silently dropped it) is a red test,
// not a faded triangle discovered in the Dock. PlayUnitTests is host-hosted
// (TEST_HOST = Play.app, XcodeGen's default for a unit-test bundle depending on
// an app target), so `Bundle.main` here is Play.app's own bundle.

import XCTest
@testable import Play

final class AppIconTests: XCTestCase {
    private func largestRepresentation() throws -> NSBitmapImageRep {
        let info = try XCTUnwrap(Bundle.main.infoDictionary, "no Info.plist in the running bundle")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon",
                        "ICON-001 rule 5 — CFBundleIconFile must be declared")

        let url = try XCTUnwrap(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                                 "AppIcon.icns missing from Contents/Resources — ICON-001-S1")
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let largest = try XCTUnwrap(reps.max(by: { $0.pixelsWide < $1.pixelsWide }),
                                     "no bitmap representation in AppIcon.icns")
        XCTAssertGreaterThanOrEqual(largest.pixelsWide, 512, "expected the 1024 (or @2x 512) master")
        return largest
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Int {
        Int((rep.colorAt(x: x, y: y)?.alphaComponent ?? -1) * 255)
    }

    // MARK: - ICON-001-H1

    func testShippedIconHasTransparentCorners() throws {
        let rep = try largestRepresentation()
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
        for (x, y) in corners {
            XCTAssertLessThanOrEqual(alpha(rep, x, y), 8,
                                      "corner (\(x),\(y)) is not transparent — ICON-001 rule 3b")
        }
    }

    func testShippedIconCenterIsOpaque() throws {
        let rep = try largestRepresentation()
        let cx = rep.pixelsWide / 2, cy = rep.pixelsHigh / 2
        for (x, y) in [(cx, cy), (cx - 100, cy), (cx + 100, cy), (cx, cy - 100), (cx, cy + 100)] {
            XCTAssertEqual(alpha(rep, x, y), 255, "(\(x),\(y)) in the tile must be fully opaque")
        }
    }

    // MARK: - ICON-001-S2 — a global color key would eat the near-white triangle

    func testWhiteTriangleSurvives() throws {
        let rep = try largestRepresentation()
        let cx = rep.pixelsWide / 2, cy = rep.pixelsHigh / 2
        var sums = (r: 0.0, g: 0.0, b: 0.0)
        var count = 0
        for dy in -50 ..< 50 {
            for dx in -50 ..< 50 {
                guard let c = rep.colorAt(x: cx + dx, y: cy + dy) else { continue }
                XCTAssertEqual(Int(c.alphaComponent * 255), 255, "triangle patch must be fully opaque")
                sums.r += c.redComponent; sums.g += c.greenComponent; sums.b += c.blueComponent
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        let meanChannel = (sums.r + sums.g + sums.b) / Double(count * 3)
        XCTAssertGreaterThan(meanChannel, 240.0 / 255.0,
                              "center patch mean should read near-white (the triangle), not the tile")
    }
}
