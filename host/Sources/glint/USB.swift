import GlintCore
import Clibusb
import Foundation

enum USBError: Error, CustomStringConvertible {
    case notFound
    case libusb(String, Int32)

    var description: String {
        switch self {
        case .notFound:
            return "device \(String(format: "%04x:%04x", Glint.vid, Glint.pid)) not found — is the panel plugged in and running glint firmware?"
        case let .libusb(op, code):
            let msg = String(cString: libusb_error_name(code))
            return "\(op) failed: \(msg)"
        }
    }
}

final class USBDevice {
    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?
    /// Bulk max packet size — 64 on Full Speed, 512 on High Speed. Needed for
    /// the ZLP rule: transfers that are an exact multiple must be terminated.
    let maxPacket: Int

    init(vid: UInt16, pid: UInt16) throws {
        var c: OpaquePointer?
        let rc = libusb_init(&c)
        guard rc == 0 else { throw USBError.libusb("libusb_init", rc) }
        ctx = c

        guard let h = libusb_open_device_with_vid_pid(ctx, vid, pid) else {
            libusb_exit(ctx)
            ctx = nil
            throw USBError.notFound
        }
        handle = h

        let speed = libusb_get_device_speed(libusb_get_device(h))
        maxPacket = speed >= LIBUSB_SPEED_HIGH.rawValue ? 512 : 64

        let claim = libusb_claim_interface(h, 0)
        guard claim == 0 else {
            libusb_close(h)
            handle = nil
            libusb_exit(ctx)
            ctx = nil
            throw USBError.libusb("claim_interface", claim)
        }
    }

    deinit {
        if let h = handle {
            libusb_release_interface(h, 0)
            libusb_close(h)
        }
        if ctx != nil { libusb_exit(ctx) }
    }

    /// Vendor control read (bmRequestType 0xC1: IN | vendor | interface).
    func controlRead(
        _ cmd: Glint.Cmd, value: UInt16 = 0, length: Int, timeoutMs: UInt32 = 1000
    ) throws -> Data {
        var buf = [UInt8](repeating: 0, count: length)
        let rc = libusb_control_transfer(
            handle, 0xC1, cmd.rawValue, value, 0, &buf, UInt16(length),
            timeoutMs)
        guard rc >= 0 else { throw USBError.libusb("control read", rc) }
        return Data(buf.prefix(Int(rc)))
    }

    /// Vendor control write with no data stage (bmRequestType 0x41).
    func controlWrite(
        _ cmd: Glint.Cmd, value: UInt16 = 0, timeoutMs: UInt32 = 1000
    ) throws {
        let rc = libusb_control_transfer(
            handle, 0x41, cmd.rawValue, value, 0, nil, 0, timeoutMs)
        guard rc >= 0 else { throw USBError.libusb("control write", rc) }
    }

    /// Reads one bulk IN packet. Returns empty on timeout (no events pending).
    func bulkRead(
        endpoint: UInt8 = 0x81, length: Int, timeoutMs: UInt32 = 500
    ) throws -> Data {
        var buf = [UInt8](repeating: 0, count: length)
        var got: Int32 = 0
        let rc = libusb_bulk_transfer(
            handle, endpoint, &buf, Int32(length), &got, timeoutMs)
        if rc == LIBUSB_ERROR_TIMEOUT.rawValue { return Data() }
        guard rc == 0 else { throw USBError.libusb("bulk read", rc) }
        return Data(buf.prefix(Int(got)))
    }

    func bulkWrite(
        endpoint: UInt8 = 0x01, _ data: Data, timeoutMs: UInt32 = 2000
    ) throws {
        var bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            var sent: Int32 = 0
            let rc = bytes[offset...].withUnsafeMutableBufferPointer {
                libusb_bulk_transfer(
                    handle, endpoint, $0.baseAddress, Int32($0.count), &sent,
                    timeoutMs)
            }
            guard rc == 0 else { throw USBError.libusb("bulk write", rc) }
            offset += Int(sent)
        }
        if bytes.count % maxPacket == 0 {
            var sent: Int32 = 0
            let rc = libusb_bulk_transfer(
                handle, endpoint, nil, 0, &sent, timeoutMs)
            guard rc == 0 else { throw USBError.libusb("bulk ZLP", rc) }
        }
    }
}
