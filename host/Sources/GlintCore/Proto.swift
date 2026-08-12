import Foundation

/// Wire protocol constants — mirrors `protocol/protocol.h` (the C header is
/// the source of truth). Little-endian throughout; the Mac is little-endian,
/// so `[UInt16]` pixel buffers can be reinterpreted as wire bytes directly.
public enum Glint {
    public static let vid: UInt16 = 0xCAFE
    public static let pid: UInt16 = 0x4010

    public static let magicHello: UInt32 = 0x4C48_3450 // 'P4HL'
    public static let magicTile: UInt32 = 0x4454_3450 // 'P4TD'
    public static let magicEvt: UInt32 = 0x5645_3450 // 'P4EV'
    public static let magicReq: UInt32 = 0x5152_3450 // 'P4RQ'
    public static let protoVer: UInt16 = 1

    public enum Cmd: UInt8 {
        case hello = 0x01
        case backlight = 0x02
        case reset = 0x03
        case sleep = 0x04
        /// Reboots the device into its ROM download loader, so a board with no
        /// UART bridge can be reflashed without holding BOOT.
        case bootloader = 0x05
    }

    /// Payload encodings. `fmt_mask` in the handshake advertises support as
    /// `1 << fmt`, so a device that predates a format simply never gets it.
    public enum Fmt: UInt16 {
        case rgb565 = 0
        case rle = 1
        case jpeg = 2

        public var maskBit: UInt16 { 1 << rawValue }
    }

    public struct TileFlags: OptionSet {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let lastInFrame = TileFlags(rawValue: 1 << 0)
        public static let fullRefresh = TileFlags(rawValue: 1 << 1)
    }
}

public struct Hello {
    public let panelW: Int
    public let panelH: Int
    public let fmtMask: UInt16
    public let maxTileLen: Int
    public let touchPoints: Int
    public let fwVer: UInt32

    public init?(_ data: Data) {
        guard data.count >= 24 else { return nil }
        let b = [UInt8](data)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
                | (UInt32(b[o + 3]) << 24)
        }
        guard u32(0) == Glint.magicHello, u16(4) == Glint.protoVer else {
            return nil
        }
        panelW = Int(u16(6))
        panelH = Int(u16(8))
        fmtMask = u16(10)
        maxTileLen = Int(u32(12))
        touchPoints = Int(u16(16))
        fwVer = u32(20)
    }

    /// Test seam: build a handshake without a device.
    public init(
        panelW: Int, panelH: Int, fmtMask: UInt16, maxTileLen: Int,
        touchPoints: Int = 2, fwVer: UInt32 = 0
    ) {
        self.panelW = panelW
        self.panelH = panelH
        self.fmtMask = fmtMask
        self.maxTileLen = maxTileLen
        self.touchPoints = touchPoints
        self.fwVer = fwVer
    }

    public func supports(_ fmt: Glint.Fmt) -> Bool {
        fmtMask & fmt.maskBit != 0
    }
}

/// 8-byte in-band control request, for transports with no control pipe.
public func requestPacket(_ cmd: Glint.Cmd, value: UInt16) -> Data {
    var d = Data(capacity: 8)
    let magic = Glint.magicReq
    d.append(UInt8(magic & 0xFF))
    d.append(UInt8((magic >> 8) & 0xFF))
    d.append(UInt8((magic >> 16) & 0xFF))
    d.append(UInt8((magic >> 24) & 0xFF))
    d.append(cmd.rawValue)
    d.append(0) // rsvd
    d.append(UInt8(value & 0xFF))
    d.append(UInt8(value >> 8))
    return d
}

/// 24-byte tile header, little-endian.
public func tileHeader(
    seq: UInt16, flags: Glint.TileFlags,
    x: UInt16, y: UInt16, w: UInt16, h: UInt16,
    fmt: Glint.Fmt = .rgb565, payloadLen: UInt32
) -> Data {
    var d = Data(capacity: 24)
    func put16(_ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    func put32(_ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }
    put32(Glint.magicTile)
    put16(seq)
    put16(flags.rawValue)
    put16(x)
    put16(y)
    put16(w)
    put16(h)
    put16(fmt.rawValue)
    put16(0) // rsvd
    put32(payloadLen)
    return d
}
