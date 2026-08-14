import XCTest

@testable import GlintCore

final class OptionsTests: XCTestCase {
    private func opts(_ args: String...) -> Options {
        Options(["glint"] + args)
    }

    func testModeDefaultsAndPositionals() {
        XCTAssertEqual(opts().mode, "bars")
        XCTAssertEqual(opts("display").mode, "display")
        /* A leading flag is not a mode; it should not become one. */
        XCTAssertEqual(opts("--list").mode, "bars")
        XCTAssertEqual(opts("image", "photo.heic", "--fill").positional,
                       ["photo.heic"])
    }

    func testNetAloneMeansDiscoverAndNetHostNamesOne() {
        XCTAssertNil(opts("display").netHost)
        XCTAssertEqual(opts("display", "--net").netHost, "auto")
        XCTAssertEqual(opts("display", "--net", "auto").netHost, "auto")
        XCTAssertEqual(opts("display", "--net", "glint-335b.local").netHost,
                       "glint-335b.local")
        /* A following flag is not a hostname. */
        XCTAssertEqual(opts("display", "--net", "--touch").netHost, "auto")
    }

    func testTransportSelectors() {
        XCTAssertTrue(opts("display", "--usb").usbOnly)
        XCTAssertEqual(opts("display", "--dev", "2").devIndex, 2)
        XCTAssertEqual(opts("display", "--port", "9000").port, 9000)
        XCTAssertEqual(opts("display", "--serial", "glint-6204").serial,
                       "glint-6204")
        XCTAssertNil(opts("display").serial)
        XCTAssertEqual(opts("display").port, 7788)
    }

    func testDisplayNameIsOptionalAndKeepsSpaces() {
        XCTAssertNil(opts("display").name)
        XCTAssertEqual(opts("display", "--name", "Studio Panel").name,
                       "Studio Panel")
        /* A following flag is not a name. */
        XCTAssertNil(opts("display", "--name", "--touch").name)
    }

    func testFlatOverridesColourShaping() {
        let shaped = opts("display", "--sat", "150", "--con", "120")
        XCTAssertEqual(shaped.saturation, 150)
        XCTAssertEqual(shaped.contrast, 120)

        /* --flat means none, whatever else was asked for. */
        let flat = opts("display", "--flat", "--sat", "150")
        XCTAssertEqual(flat.saturation, 100)
        XCTAssertEqual(flat.contrast, 100)
    }

    func testFrameRateNeverZero() {
        XCTAssertEqual(opts("display").frameRate(default: 30), 30)
        XCTAssertEqual(opts("display", "--fps", "12").frameRate(default: 30), 12)
        XCTAssertEqual(opts("display", "--fps", "0").frameRate(default: 30), 1)
    }

    func testDesktopSizeFollowsOrientationAndOverrides() {
        let landscape = opts("display")
        XCTAssertEqual(landscape.desktopSize(panelW: 320, panelH: 480).w, 480)
        XCTAssertEqual(landscape.desktopSize(panelW: 320, panelH: 480).h, 320)

        let portrait = opts("display", "--portrait")
        XCTAssertEqual(portrait.desktopSize(panelW: 320, panelH: 480).w, 320)

        let forced = opts("display", "--width", "800", "--height", "534")
        XCTAssertEqual(forced.desktopSize(panelW: 320, panelH: 480).w, 800)
        XCTAssertEqual(forced.desktopSize(panelW: 320, panelH: 480).h, 534)

        /* A width with no height is not a size; fall back to the panel. */
        let half = opts("display", "--width", "800")
        XCTAssertEqual(half.desktopSize(panelW: 320, panelH: 480).w, 480)
    }

    func testTouchFlagsBecomeAMapping() {
        let o = opts("display", "--touch", "--tp-swap", "--tp-flip-y")
        XCTAssertTrue(o.touch)
        XCTAssertEqual(o.mapping, TouchMapping(swapXY: true, flipY: true))
        XCTAssertFalse(opts("touch").touch)
        XCTAssertTrue(opts("touch", "--calibrate").calibrate)
    }
}
