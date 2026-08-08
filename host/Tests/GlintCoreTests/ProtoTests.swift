import XCTest

@testable import GlintCore

final class ProtoTests: XCTestCase {
    func testHelloParsesAWellFormedHandshake() {
        var d = Data()
        func put16(_ v: UInt16) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8(v >> 8))
        }
        func put32(_ v: UInt32) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }
        put32(Glint.magicHello)
        put16(1) // proto_ver
        put16(320)
        put16(480)
        put16(0b11) // RGB565 | RLE
        put32(40960)
        put16(2)
        put16(0) // rsvd
        put32(0x0000_0100)

        XCTAssertEqual(d.count, 24, "hello must be exactly 24 bytes")
        guard let hello = Hello(d) else {
            return XCTFail("well-formed hello failed to parse")
        }
        XCTAssertEqual(hello.panelW, 320)
        XCTAssertEqual(hello.panelH, 480)
        XCTAssertEqual(hello.maxTileLen, 40960)
        XCTAssertEqual(hello.touchPoints, 2)
        XCTAssertEqual(hello.fwVer, 0x0000_0100)
        XCTAssertTrue(hello.supports(.rgb565))
        XCTAssertTrue(hello.supports(.rle))
        XCTAssertFalse(hello.supports(.jpeg))
    }

    func testHelloRejectsBadMagicWrongVersionAndShortData() {
        let good = Hello(
            panelW: 320, panelH: 480, fmtMask: 1, maxTileLen: 40960)
        XCTAssertEqual(good.panelW, 320)

        var bad = Data([0xFF, 0xFF, 0xFF, 0xFF])
        bad.append(Data(repeating: 0, count: 20))
        XCTAssertNil(Hello(bad), "bad magic must not parse")

        var wrongVer = Data([0x50, 0x34, 0x48, 0x4C, 0x63, 0x00])
        wrongVer.append(Data(repeating: 0, count: 18))
        XCTAssertNil(Hello(wrongVer), "unknown proto_ver must not parse")

        XCTAssertNil(Hello(Data(repeating: 0, count: 12)))
    }

    func testTileHeaderLayoutMatchesTheCStruct() {
        let d = tileHeader(
            seq: 0x1234, flags: [.lastInFrame, .fullRefresh],
            x: 64, y: 448, w: 320, h: 32, fmt: .rle, payloadLen: 0xDEAD_BEEF)
        XCTAssertEqual(d.count, 24)
        let b = [UInt8](d)

        XCTAssertEqual(Array(b[0..<4]), [0x50, 0x34, 0x54, 0x44], "'P4TD' LE")
        XCTAssertEqual(Array(b[4..<6]), [0x34, 0x12], "seq little-endian")
        XCTAssertEqual(Array(b[6..<8]), [0x03, 0x00], "both flag bits")
        XCTAssertEqual(Array(b[8..<10]), [64, 0])
        XCTAssertEqual(Array(b[10..<12]), [0xC0, 0x01], "448")
        XCTAssertEqual(Array(b[12..<14]), [0x40, 0x01], "320")
        XCTAssertEqual(Array(b[14..<16]), [32, 0])
        XCTAssertEqual(Array(b[16..<18]), [0x01, 0x00], "fmt = RLE")
        XCTAssertEqual(Array(b[18..<20]), [0, 0], "rsvd")
        XCTAssertEqual(Array(b[20..<24]), [0xEF, 0xBE, 0xAD, 0xDE])
    }

    func testFormatMaskBits() {
        XCTAssertEqual(Glint.Fmt.rgb565.maskBit, 0b001)
        XCTAssertEqual(Glint.Fmt.rle.maskBit, 0b010)
        XCTAssertEqual(Glint.Fmt.jpeg.maskBit, 0b100)
    }

    func testColourBarsFillTheFrameAndProduceDistinctBars() {
        let px = renderColorBars(width: 320, height: 480, phase: 0)
        XCTAssertEqual(px.count, 320 * 480)
        XCTAssertEqual(px[0], 0xFFFF, "first bar is white")
        XCTAssertEqual(px[319], 0x0000, "last bar is black")
        XCTAssertEqual(Set(px.prefix(320)).count, 8, "eight distinct bars")

        /* Phase shifts the pattern horizontally. */
        let shifted = renderColorBars(width: 320, height: 480, phase: 40)
        XCTAssertNotEqual(Array(px.prefix(320)), Array(shifted.prefix(320)))
    }
}
