import XCTest

@testable import GlintCore

/// The mapping arithmetic, pinned against both panels' real measurements. These
/// numbers came off the hardware; if a refactor changes what they derive, the
/// panels stop matching their documented flags.
final class TouchTests: XCTestCase {
    func testDerivesTheP4Mapping() {
        /* Waveshare ESP32-P4 3.5", FT6336, viewed in landscape (HARDWARE.md). */
        let m = deriveMapping(
            topLeft: (25, 453), topRight: (33, 24), bottomLeft: (297, 449))

        XCTAssertEqual(m, TouchMapping(swapXY: true, flipX: true, flipY: false))
        XCTAssertEqual(m.flags, ["--tp-swap", "--tp-flip-x"])
    }

    func testDerivesTheAmoledMapping() {
        /* S3 AMOLED 1.75", CST9217. Panel coords implied by the corner taps
         * recorded in HARDWARE.md: moving right swings y, moving down swings x
         * the other way. */
        let m = deriveMapping(
            topLeft: (415, 107), topRight: (350, 419), bottomLeft: (61, 84))

        XCTAssertEqual(m, TouchMapping(swapXY: true, flipX: false, flipY: true))
        XCTAssertEqual(m.flags, ["--tp-swap", "--tp-flip-y"])
    }

    func testDerivesTheIdentityMappingWhenTheGlassAgreesWithThePanel() {
        let m = deriveMapping(
            topLeft: (10, 10), topRight: (300, 14), bottomLeft: (12, 200))

        XCTAssertEqual(m, TouchMapping())
        XCTAssertTrue(m.flags.isEmpty)
    }

    func testCornersThatCannotBeReachedStillDerive() {
        /* Rounded glass: every tap lands well inside, symmetric about centre.
         * The relationships are unchanged, so the mapping must be too. */
        let full = deriveMapping(
            topLeft: (0, 0), topRight: (465, 8), bottomLeft: (4, 465))
        let inset = deriveMapping(
            topLeft: (117, 118), topRight: (354, 121), bottomLeft: (119, 350))

        XCTAssertEqual(full, inset)
    }

    func testUnitPlacesACornerAtTheMatchingCorner() {
        let panel = (w: 320, h: 480)
        let swapped = TouchMapping(swapXY: true, flipX: true)

        /* Panel (0,0) under swap+flipX: x and y trade places, then u inverts. */
        let a = swapped.unit(x: 0, y: 0, panelW: panel.w, panelH: panel.h)
        XCTAssertEqual(a.u, 1.0, accuracy: 0.001)
        XCTAssertEqual(a.v, 0.0, accuracy: 0.001)

        let b = swapped.unit(
            x: panel.w - 1, y: panel.h - 1, panelW: panel.w, panelH: panel.h)
        XCTAssertEqual(b.u, 0.0, accuracy: 0.001)
        XCTAssertEqual(b.v, 1.0, accuracy: 0.001)
    }

    func testUnitIsClampedToASaneRangeForADegeneratePanel() {
        let m = TouchMapping()
        let p = m.unit(x: 0, y: 0, panelW: 1, panelH: 1)

        XCTAssertEqual(p.u, 0.0, accuracy: 0.001)
        XCTAssertEqual(p.v, 0.0, accuracy: 0.001)
    }

    func testParseAndFlagsRoundTrip() {
        for args in [
            [] as [String], ["--tp-swap"], ["--tp-flip-x"], ["--tp-flip-y"],
            ["--tp-swap", "--tp-flip-x"], ["--tp-swap", "--tp-flip-y"],
            ["--tp-swap", "--tp-flip-x", "--tp-flip-y"],
        ] {
            XCTAssertEqual(TouchMapping.parse(args).flags, args)
        }
    }
}
