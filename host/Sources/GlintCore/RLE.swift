import Foundation

/// RGB565_RLE (fmt 1). A stream of runs, each introduced by a 2-byte
/// little-endian count word:
///
///   bit15 clear → RUN: low 15 bits are a pixel count (1…32767), followed by
///                 one little-endian RGB565 value repeated that many times.
///                 4 bytes on the wire regardless of run length.
///   bit15 set   → LITERAL: low 15 bits are a pixel count, followed by exactly
///                 that many little-endian RGB565 values verbatim.
///
/// Decoded pixel count must equal the tile's `w * h`. Flat UI regions collapse
/// enormously; photos do not, which is why the encoder is only used when it
/// actually wins.
public enum RLE {
    static let literalFlag: UInt16 = 0x8000
    static let maxRun = 0x7FFF

    /// Runs of this length or longer are worth a RUN word (4 bytes) instead of
    /// staying inside a LITERAL (2 bytes/pixel).
    static let minRun = 3

    public static func encode(_ px: [UInt16]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(px.count * 2 / 2)

        func emit16(_ v: UInt16) {
            out.append(UInt8(v & 0xFF))
            out.append(UInt8(v >> 8))
        }

        var literal = [UInt16]()

        func flushLiteral() {
            var start = 0
            while start < literal.count {
                let n = min(maxRun, literal.count - start)
                emit16(UInt16(n) | literalFlag)
                for i in start..<(start + n) { emit16(literal[i]) }
                start += n
            }
            literal.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < px.count {
            let v = px[i]
            var run = 1
            while i + run < px.count && px[i + run] == v && run < maxRun {
                run += 1
            }

            if run >= minRun {
                flushLiteral()
                emit16(UInt16(run))
                emit16(v)
            } else {
                for _ in 0..<run { literal.append(v) }
            }
            i += run
        }
        flushLiteral()
        return out
    }

    /// Returns nil if the stream is malformed or does not decode to exactly
    /// `expected` pixels — a decoder that guesses would paint garbage.
    public static func decode(_ bytes: [UInt8], expected: Int) -> [UInt16]? {
        var out = [UInt16]()
        out.reserveCapacity(expected)
        var i = 0

        while i + 1 < bytes.count {
            let word = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            i += 2
            let count = Int(word & UInt16(maxRun))
            if count == 0 { return nil }

            if word & literalFlag != 0 {
                guard i + count * 2 <= bytes.count else { return nil }
                for k in 0..<count {
                    out.append(
                        UInt16(bytes[i + k * 2])
                            | (UInt16(bytes[i + k * 2 + 1]) << 8))
                }
                i += count * 2
            } else {
                guard i + 1 < bytes.count else { return nil }
                let v = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
                i += 2
                out.append(contentsOf: repeatElement(v, count: count))
            }
            if out.count > expected { return nil }
        }
        return out.count == expected ? out : nil
    }
}
