import Foundation

/// M4: split each frame into a tile grid, hash every tile, and emit packets
/// only for tiles whose contents changed. Horizontally adjacent dirty tiles are
/// coalesced into one packet to cut header overhead (README §5.2).
///
/// Hashing rather than `SCStreamFrameInfoDirtyRects`: dirty rects are known to
/// be unreliable on virtual displays, and hashing a frame costs far less than a
/// wrongly-skipped tile costs in confusion.
///
/// This type performs no I/O — it returns packets for a caller to write, which
/// is what makes it testable without a device.
public final class TileSender {
    public struct Stats {
        public var bytes = 0
        public var tiles = 0
        public var packets = 0
        public var compressed = 0 /* packets sent as RLE */
    }

    private let panelW: Int
    private let panelH: Int
    private let tileW: Int
    private let tileH: Int
    private let cols: Int
    private let rows: Int
    private let useRLE: Bool
    private var hashes: [UInt64]
    private var seq: UInt16 = 0
    private var primed = false

    public init(
        panelW: Int, panelH: Int, maxTileLen: Int, allowRLE: Bool = false,
        tileSize: Int = 64
    ) {
        self.panelW = panelW
        self.panelH = panelH
        self.tileW = tileSize
        /* A coalesced run spans at most the full panel width, so the tile
         * height is capped by what the device accepts in one raw payload. */
        self.tileH = min(tileSize, max(1, maxTileLen / (panelW * 2)))
        self.cols = (panelW + tileSize - 1) / tileSize
        self.rows = (panelH + self.tileH - 1) / self.tileH
        self.useRLE = allowRLE
        self.hashes = [UInt64](repeating: 0, count: cols * rows)
    }

    public var grid: String {
        "\(cols)x\(rows) tiles of \(tileW)x\(tileH)"
            + (useRLE ? ", RLE when smaller" : "")
    }

    /// Forces the next frame to be a full refresh. Required on connect, on
    /// resume, when the device reports dropped tiles, and — easy to miss —
    /// whenever a write fails: the hashes are updated during `packets(px:)`, so
    /// tiles from a part-written frame are already recorded as delivered.
    public func invalidate() {
        primed = false
    }

    /// Dirty runs for this frame, as ready-to-write packets.
    public func packets(
        px: [UInt16], forceFull: Bool = false
    ) -> (packets: [Data], stats: Stats) {
        precondition(px.count == panelW * panelH, "frame size mismatch")
        var stats = Stats()
        let full = forceFull || !primed
        var runs: [(x: Int, y: Int, w: Int, h: Int)] = []

        px.withUnsafeBufferPointer { buf in
            for r in 0..<rows {
                let y = r * tileH
                let h = min(tileH, panelH - y)
                var runStart = -1

                /* One past the last column so a trailing run gets flushed. */
                for c in 0...cols {
                    var dirty = false
                    if c < cols {
                        let x = c * tileW
                        let w = min(tileW, panelW - x)
                        let hv = hash(buf, x: x, y: y, w: w, h: h)
                        let idx = r * cols + c
                        dirty = full || hashes[idx] != hv
                        if dirty { hashes[idx] = hv }
                    }

                    if dirty {
                        if runStart < 0 { runStart = c }
                    } else if runStart >= 0 {
                        let x = runStart * tileW
                        let w = min(panelW - x, (c - runStart) * tileW)
                        runs.append((x, y, w, h))
                        stats.tiles += c - runStart
                        runStart = -1
                    }
                }
            }
        }

        var out = [Data]()
        out.reserveCapacity(runs.count)

        for (i, run) in runs.enumerated() {
            var flags: Glint.TileFlags = []
            if full { flags.insert(.fullRefresh) }
            if i == runs.count - 1 { flags.insert(.lastInFrame) }

            let tile = extract(px, run)
            var fmt = Glint.Fmt.rgb565
            var payload = [UInt8]()

            if useRLE {
                let encoded = RLE.encode(tile)
                if encoded.count < tile.count * 2 {
                    fmt = .rle
                    payload = encoded
                    stats.compressed += 1
                }
            }

            var packet = tileHeader(
                seq: seq, flags: flags,
                x: UInt16(run.x), y: UInt16(run.y),
                w: UInt16(run.w), h: UInt16(run.h),
                fmt: fmt,
                payloadLen: UInt32(fmt == .rle ? payload.count : tile.count * 2))

            if fmt == .rle {
                packet.append(contentsOf: payload)
            } else {
                tile.withUnsafeBufferPointer {
                    packet.append(
                        UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
                }
            }

            stats.bytes += packet.count
            out.append(packet)
        }

        stats.packets = out.count
        if !out.isEmpty { seq &+= 1 }
        primed = true
        return (out, stats)
    }

    private func extract(
        _ px: [UInt16], _ run: (x: Int, y: Int, w: Int, h: Int)
    ) -> [UInt16] {
        if run.x == 0 && run.w == panelW {
            let start = run.y * panelW
            return Array(px[start..<(start + run.w * run.h)])
        }
        var tile = [UInt16](repeating: 0, count: run.w * run.h)
        for row in 0..<run.h {
            let src = (run.y + row) * panelW + run.x
            tile.replaceSubrange(
                (row * run.w)..<((row + 1) * run.w),
                with: px[src..<(src + run.w)])
        }
        return tile
    }

    /// FNV-1a over the tile's pixels.
    @inline(__always)
    private func hash(
        _ buf: UnsafeBufferPointer<UInt16>, x: Int, y: Int, w: Int, h: Int
    ) -> UInt64 {
        var hv: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in y..<(y + h) {
            let base = row * panelW + x
            for i in base..<(base + w) {
                hv = (hv ^ UInt64(buf[i])) &* 0x100_0000_01b3
            }
        }
        return hv
    }
}
