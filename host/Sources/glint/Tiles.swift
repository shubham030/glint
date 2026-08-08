import Foundation

/// M4: split each frame into a tile grid, hash every tile, and send only the
/// tiles whose contents changed. Horizontally adjacent dirty tiles are
/// coalesced into one packet to cut header overhead (README §5.2).
///
/// Hashing rather than `SCStreamFrameInfoDirtyRects`: dirty rects are known to
/// be unreliable on virtual displays, and hashing 307KB costs far less than a
/// wrongly-skipped tile costs in confusion.
final class TileSender {
    struct Stats {
        var bytes = 0
        var tiles = 0
        var packets = 0
    }

    private let panelW: Int
    private let panelH: Int
    private let tileW: Int
    private let tileH: Int
    private let cols: Int
    private let rows: Int
    private var hashes: [UInt64]
    private var seq: UInt16 = 0
    private var primed = false

    init(panelW: Int, panelH: Int, maxTileLen: Int, tileSize: Int = 64) {
        self.panelW = panelW
        self.panelH = panelH
        self.tileW = tileSize
        /* A coalesced run spans at most the full panel width, so the tile
         * height is capped by what the device accepts in one payload. */
        self.tileH = min(tileSize, max(1, maxTileLen / (panelW * 2)))
        self.cols = (panelW + tileSize - 1) / tileSize
        self.rows = (panelH + self.tileH - 1) / self.tileH
        self.hashes = [UInt64](repeating: 0, count: cols * rows)
    }

    var grid: String { "\(cols)x\(rows) tiles of \(tileW)x\(tileH)" }

    /// Marks every tile dirty so the next send is a full refresh.
    func invalidate() {
        primed = false
    }

    func send(
        _ dev: USBDevice, px: [UInt16], forceFull: Bool = false
    ) throws -> Stats {
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

        for (i, run) in runs.enumerated() {
            var flags: Glint.TileFlags = []
            if full { flags.insert(.fullRefresh) }
            if i == runs.count - 1 { flags.insert(.lastInFrame) }

            var packet = tileHeader(
                seq: seq, flags: flags,
                x: UInt16(run.x), y: UInt16(run.y),
                w: UInt16(run.w), h: UInt16(run.h),
                payloadLen: UInt32(run.w * run.h * 2))

            if run.x == 0 && run.w == panelW {
                /* Full-width run: rows are already contiguous. */
                let start = run.y * panelW
                let payload = Array(px[start..<(start + run.w * run.h)])
                payload.withUnsafeBufferPointer {
                    packet.append(
                        UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
                }
            } else {
                var payload = [UInt16](repeating: 0, count: run.w * run.h)
                for row in 0..<run.h {
                    let src = (run.y + row) * panelW + run.x
                    payload.replaceSubrange(
                        (row * run.w)..<((row + 1) * run.w),
                        with: px[src..<(src + run.w)])
                }
                payload.withUnsafeBufferPointer {
                    packet.append(
                        UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
                }
            }

            try dev.bulkWrite(packet)
            stats.bytes += packet.count
        }

        stats.packets = runs.count
        if !runs.isEmpty { seq &+= 1 }
        primed = true
        return stats
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
