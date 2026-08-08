import XCTest

@testable import GlintCore

/// The panel these mirror: 320x480, 40960-byte max payload → 64x64 tiles,
/// 5 columns x 8 rows (rows are 64 tall, 480/64 = 7.5 → last row 32).
final class TileSenderTests: XCTestCase {
    let panelW = 320
    let panelH = 480
    let maxTile = 320 * 64 * 2

    private func sender(rle: Bool = false) -> TileSender {
        TileSender(
            panelW: panelW, panelH: panelH, maxTileLen: maxTile, allowRLE: rle)
    }

    private func blank() -> [UInt16] {
        [UInt16](repeating: 0, count: panelW * panelH)
    }

    /// Header field offsets, per protocol.h.
    private func hdr(_ packet: Data) -> (
        magic: UInt32, seq: UInt16, flags: UInt16, x: UInt16, y: UInt16,
        w: UInt16, h: UInt16, fmt: UInt16, len: UInt32
    ) {
        let b = [UInt8](packet)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
                | (UInt32(b[o + 3]) << 24)
        }
        return (u32(0), u16(4), u16(6), u16(8), u16(10), u16(12), u16(14),
                u16(16), u32(20))
    }

    func testFirstFrameIsAFullRefreshOfEveryRow() {
        let (packets, stats) = sender().packets(px: blank())

        /* Every row is dirty and coalesces into one full-width packet. */
        XCTAssertEqual(packets.count, 8)
        XCTAssertEqual(stats.tiles, 40)

        for packet in packets {
            let h = hdr(packet)
            XCTAssertEqual(h.magic, Glint.magicTile)
            XCTAssertEqual(h.x, 0)
            XCTAssertEqual(h.w, 320)
            XCTAssertEqual(h.fmt, Glint.Fmt.rgb565.rawValue)
            XCTAssertNotEqual(
                h.flags & Glint.TileFlags.fullRefresh.rawValue, 0,
                "first frame must be marked FULL_REFRESH")
            XCTAssertEqual(
                Int(h.len), Int(h.w) * Int(h.h) * 2,
                "raw payload length must match the tile geometry")
            XCTAssertEqual(packet.count, 24 + Int(h.len))
        }

        /* Only the final packet closes the frame. */
        let lastFlag = Glint.TileFlags.lastInFrame.rawValue
        XCTAssertEqual(hdr(packets[7]).flags & lastFlag, lastFlag)
        XCTAssertEqual(hdr(packets[0]).flags & lastFlag, 0)

        /* The bottom row is the 32px remainder, not a full 64. */
        XCTAssertEqual(hdr(packets[7]).y, 448)
        XCTAssertEqual(hdr(packets[7]).h, 32)
    }

    func testUnchangedFrameSendsNothing() {
        let s = sender()
        let px = blank()
        _ = s.packets(px: px)
        let (packets, stats) = s.packets(px: px)
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(stats.tiles, 0)
        XCTAssertEqual(stats.bytes, 0)
    }

    func testOneChangedPixelSendsOneTile() {
        let s = sender()
        var px = blank()
        _ = s.packets(px: px)

        /* Middle of tile column 2, row 3. */
        px[(3 * 64 + 10) * panelW + (2 * 64 + 10)] = 0xF800
        let (packets, stats) = s.packets(px: px)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(stats.tiles, 1)
        let h = hdr(packets[0])
        XCTAssertEqual(h.x, 128)
        XCTAssertEqual(h.y, 192)
        XCTAssertEqual(h.w, 64)
        XCTAssertEqual(h.h, 64)
        XCTAssertEqual(Int(h.len), 64 * 64 * 2)
        XCTAssertEqual(
            h.flags & Glint.TileFlags.fullRefresh.rawValue, 0,
            "an incremental frame must not claim FULL_REFRESH")
    }

    func testAdjacentDirtyTilesCoalesceButGapsDoNot() {
        let s = sender()
        var px = blank()
        _ = s.packets(px: px)

        /* Columns 0,1 dirty and column 3 dirty, all in tile row 0. */
        px[5 * panelW + 5] = 1
        px[5 * panelW + 70] = 1
        px[5 * panelW + 200] = 1
        let (packets, _) = s.packets(px: px)

        XCTAssertEqual(packets.count, 2, "a gap must break the run")
        let a = hdr(packets[0])
        XCTAssertEqual(a.x, 0)
        XCTAssertEqual(a.w, 128, "columns 0+1 coalesce into one 128px packet")
        let b = hdr(packets[1])
        XCTAssertEqual(b.x, 192)
        XCTAssertEqual(b.w, 64)
    }

    func testPayloadCarriesTheRightPixelsForAPartialWidthTile() {
        let s = sender()
        var px = blank()
        _ = s.packets(px: px)

        /* Fill tile (col 1, row 0) with a gradient so a stride bug shows up. */
        for y in 0..<64 {
            for x in 64..<128 {
                px[y * panelW + x] = UInt16(x - 64 + y * 64)
            }
        }
        let (packets, _) = s.packets(px: px)
        XCTAssertEqual(packets.count, 1)

        let payload = [UInt8](packets[0].dropFirst(24))
        XCTAssertEqual(payload.count, 64 * 64 * 2)
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 2
                let got = UInt16(payload[i]) | (UInt16(payload[i + 1]) << 8)
                XCTAssertEqual(
                    got, UInt16(x + y * 64),
                    "payload pixel (\(x),\(y)) came from the wrong offset")
            }
        }
    }

    func testInvalidateForcesAFullRefresh() {
        let s = sender()
        let px = blank()
        _ = s.packets(px: px)
        XCTAssertTrue(s.packets(px: px).packets.isEmpty)

        s.invalidate()
        let (packets, stats) = s.packets(px: px)
        XCTAssertEqual(packets.count, 8)
        XCTAssertEqual(stats.tiles, 40)
        XCTAssertNotEqual(
            hdr(packets[0]).flags & Glint.TileFlags.fullRefresh.rawValue, 0)
    }

    func testSequenceAdvancesOnlyWhenSomethingIsSent() {
        let s = sender()
        var px = blank()
        _ = s.packets(px: px) /* seq 0 */
        _ = s.packets(px: px) /* nothing sent → seq must not advance */
        px[0] = 0x1234
        let (packets, _) = s.packets(px: px)
        XCTAssertEqual(hdr(packets[0]).seq, 1)
    }

    func testRLEIsUsedForFlatTilesAndSkippedWhenItWouldGrow() {
        let s = sender(rle: true)
        var px = blank()

        /* A blank frame is maximally compressible. */
        let (flat, flatStats) = s.packets(px: px)
        XCTAssertEqual(flatStats.compressed, flat.count)
        for packet in flat {
            let h = hdr(packet)
            XCTAssertEqual(h.fmt, Glint.Fmt.rle.rawValue)
            XCTAssertEqual(Int(h.len), packet.count - 24)
            XCTAssertLessThan(
                Int(h.len), Int(h.w) * Int(h.h) * 2,
                "RLE must only be chosen when it is smaller")
        }

        /* Noise that defeats RLE must fall back to raw. */
        var rng: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in 0..<px.count {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            px[i] = UInt16(truncatingIfNeeded: rng >> 33)
        }
        let (noisy, noisyStats) = s.packets(px: px)
        XCTAssertEqual(noisyStats.compressed, 0)
        for packet in noisy {
            XCTAssertEqual(hdr(packet).fmt, Glint.Fmt.rgb565.rawValue)
        }
    }

    func testRLEIsNotUsedWhenTheDeviceDoesNotAdvertiseIt() {
        let s = sender(rle: false)
        let (packets, stats) = s.packets(px: blank())
        XCTAssertEqual(stats.compressed, 0)
        XCTAssertEqual(hdr(packets[0]).fmt, Glint.Fmt.rgb565.rawValue)
    }

    func testTileHeightIsCappedByTheDeviceLimit()  {
        /* A device that only accepts 16 rows at a time must get 16-row runs. */
        let small = TileSender(
            panelW: panelW, panelH: panelH, maxTileLen: panelW * 16 * 2)
        let (packets, _) = small.packets(px: blank())
        XCTAssertEqual(packets.count, 480 / 16)
        for packet in packets {
            XCTAssertLessThanOrEqual(Int(hdr(packet).len), panelW * 16 * 2)
        }
    }
}
