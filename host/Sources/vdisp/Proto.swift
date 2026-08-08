import Foundation

/// Wire protocol constants — mirrors `protocol/protocol.h` (the C header is
/// the source of truth). Little-endian throughout; the Mac is little-endian,
/// so `[UInt16]` pixel buffers can be reinterpreted as wire bytes directly.
enum VD {
    static let vid: UInt16 = 0xCAFE
    static let pid: UInt16 = 0x4010

    static let magicHello: UInt32 = 0x4C48_3450 // 'P4HL'
    static let magicTile: UInt32 = 0x4454_3450 // 'P4TD'
    static let protoVer: UInt16 = 1

    enum Cmd: UInt8 {
        case hello = 0x01
        case backlight = 0x02
        case reset = 0x03
        case sleep = 0x04
    }

    struct TileFlags: OptionSet {
        let rawValue: UInt16
        static let lastInFrame = TileFlags(rawValue: 1 << 0)
        static let fullRefresh = TileFlags(rawValue: 1 << 1)
    }
}

struct Hello {
    let panelW: Int
    let panelH: Int
    let fmtMask: UInt16
    let maxTileLen: Int
    let touchPoints: Int
    let fwVer: UInt32

    init?(_ data: Data) {
        guard data.count >= 24 else { return nil }
        let b = [UInt8](data)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
                | (UInt32(b[o + 3]) << 24)
        }
        guard u32(0) == VD.magicHello, u16(4) == VD.protoVer else { return nil }
        panelW = Int(u16(6))
        panelH = Int(u16(8))
        fmtMask = u16(10)
        maxTileLen = Int(u32(12))
        touchPoints = Int(u16(16))
        fwVer = u32(20)
    }
}

/// 24-byte tile header, little-endian.
func tileHeader(
    seq: UInt16, flags: VD.TileFlags,
    x: UInt16, y: UInt16, w: UInt16, h: UInt16,
    fmt: UInt16 = 0, payloadLen: UInt32
) -> Data {
    var d = Data(capacity: 24)
    func put16(_ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    func put32(_ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }
    put32(VD.magicTile)
    put16(seq)
    put16(flags.rawValue)
    put16(x)
    put16(y)
    put16(w)
    put16(h)
    put16(fmt)
    put16(0) // rsvd
    put32(payloadLen)
    return d
}
