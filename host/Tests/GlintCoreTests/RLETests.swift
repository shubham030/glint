import XCTest

@testable import GlintCore

/// The encoder here and the C decoder in `firmware/main/usb_vendor.c` must agree
/// byte for byte, so these tests pin the wire layout, not just round-tripping.
final class RLETests: XCTestCase {
    private func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    func testLongRunBecomesOneFourByteWord() {
        let px = [UInt16](repeating: 0x1234, count: 1000)
        let out = RLE.encode(px)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(u16(out, 0), 1000, "bit15 clear marks a RUN")
        XCTAssertEqual(u16(out, 2), 0x1234)
        XCTAssertEqual(RLE.decode(out, expected: 1000), px)
    }

    func testShortRunsStayInsideOneLiteral() {
        /* Two pixels each: below minRun, so they must not become RUN words. */
        let px: [UInt16] = [1, 1, 2, 2, 3, 3]
        let out = RLE.encode(px)
        XCTAssertEqual(u16(out, 0) & RLE.literalFlag, RLE.literalFlag)
        XCTAssertEqual(u16(out, 0) & 0x7FFF, 6)
        XCTAssertEqual(out.count, 2 + 6 * 2)
        XCTAssertEqual(RLE.decode(out, expected: 6), px)
    }

    func testMixedContentRoundTrips() {
        var px = [UInt16]()
        px.append(contentsOf: repeatElement(0xFFFF, count: 50))
        px.append(contentsOf: [1, 2, 3, 4, 5])
        px.append(contentsOf: repeatElement(0x0800, count: 300))
        px.append(contentsOf: [9, 9])
        XCTAssertEqual(RLE.decode(RLE.encode(px), expected: px.count), px)
    }

    func testRunsLongerThanTheCountFieldAreSplit() {
        let n = 40000 /* > 0x7FFF */
        let px = [UInt16](repeating: 0xABCD, count: n)
        let out = RLE.encode(px)
        XCTAssertEqual(out.count, 8, "two RUN words")
        XCTAssertEqual(Int(u16(out, 0)), 0x7FFF)
        XCTAssertEqual(Int(u16(out, 4)), n - 0x7FFF)
        XCTAssertEqual(RLE.decode(out, expected: n), px)
    }

    func testLiteralsLongerThanTheCountFieldAreSplit() {
        /* Alternating values never form a run, forcing a huge literal. */
        let n = 40000
        var px = [UInt16]()
        for i in 0..<n { px.append(UInt16(i % 2 == 0 ? 1 : 2)) }
        let out = RLE.encode(px)
        XCTAssertEqual(u16(out, 0) & 0x7FFF, 0x7FFF)
        XCTAssertEqual(RLE.decode(out, expected: n), px)
    }

    func testEmptyInputEncodesToNothing() {
        XCTAssertTrue(RLE.encode([]).isEmpty)
        XCTAssertEqual(RLE.decode([], expected: 0), [])
    }

    func testDecoderRejectsTruncatedAndOverlongStreams() {
        let out = RLE.encode([UInt16](repeating: 7, count: 100))
        XCTAssertNil(
            RLE.decode(out, expected: 99), "wrong pixel count must not decode")
        XCTAssertNil(RLE.decode(Array(out.dropLast()), expected: 100))
        XCTAssertNil(
            RLE.decode([0x00, 0x00], expected: 1), "zero count is malformed")
    }

    func testFlatTileCompressesEnormously() {
        /* The case that matters on the full-speed board: flat UI regions. */
        let tile = [UInt16](repeating: 0x2104, count: 64 * 64)
        let out = RLE.encode(tile)
        XCTAssertEqual(out.count, 4)
        XCTAssertLessThan(Double(out.count) / Double(tile.count * 2), 0.001)
    }
}
