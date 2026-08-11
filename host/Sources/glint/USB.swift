import GlintCore
import Clibusb
import Foundation

enum USBError: Error, CustomStringConvertible {
    case notFound
    case libusb(String, Int32)

    /// True when the device went away rather than misbehaved — the caller
    /// should exit so a supervisor can restart it, not retry the transfer.
    var isDisconnect: Bool {
        switch self {
        case .notFound:
            return true
        case let .libusb(_, code):
            return code == LIBUSB_ERROR_NO_DEVICE.rawValue
                || code == LIBUSB_ERROR_IO.rawValue
                || code == LIBUSB_ERROR_PIPE.rawValue
        }
    }

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

    /// One matching device on the bus. Firmware currently reports a fixed
    /// serial number, so bus/address is the only way to tell two panels apart.
    struct Found {
        let bus: UInt8
        let address: UInt8
        let speed: String

        var description: String {
            "bus \(bus) addr \(address) (\(speed)-speed)"
        }
    }

    /// Every device matching vid:pid, in libusb's enumeration order.
    static func list(vid: UInt16, pid: UInt16) throws -> [Found] {
        var ctx: OpaquePointer?
        let rc = libusb_init(&ctx)
        guard rc == 0 else { throw USBError.libusb("libusb_init", rc) }
        defer { libusb_exit(ctx) }

        var devices: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &devices)
        guard count >= 0, let devices else { return [] }
        defer { libusb_free_device_list(devices, 1) }

        var found = [Found]()
        for i in 0..<Int(count) {
            guard let dev = devices[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0,
                desc.idVendor == vid, desc.idProduct == pid
            else { continue }

            let speed = libusb_get_device_speed(dev)
            found.append(
                Found(
                    bus: libusb_get_bus_number(dev),
                    address: libusb_get_device_address(dev),
                    speed: speed >= LIBUSB_SPEED_HIGH.rawValue
                        ? "high" : "full"))
        }
        return found
    }

    /// Opens the device, optionally waiting for it to appear. Cables on this
    /// board get swapped constantly, so a long-running session should sit and
    /// wait rather than fail at startup.
    static func open(
        vid: UInt16, pid: UInt16, waitForDevice: Bool, index: Int = 0
    ) throws -> USBDevice {
        var announced = false
        while true {
            do {
                return try USBDevice(vid: vid, pid: pid, index: index)
            } catch let error as USBError {
                guard waitForDevice, case .notFound = error else { throw error }
                if !announced {
                    let id = String(format: "%04x:%04x", vid, pid)
                    print("waiting for the panel (\(id))…")
                    announced = true
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// `index` picks among several matching devices (see `list`); 0 is the
    /// first, which is what libusb would have chosen anyway.
    init(vid: UInt16, pid: UInt16, index: Int = 0) throws {
        var c: OpaquePointer?
        let rc = libusb_init(&c)
        guard rc == 0 else { throw USBError.libusb("libusb_init", rc) }
        ctx = c

        guard let h = USBDevice.openMatching(ctx, vid, pid, index) else {
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

    private static func openMatching(
        _ ctx: OpaquePointer?, _ vid: UInt16, _ pid: UInt16, _ index: Int
    ) -> OpaquePointer? {
        if index == 0 {
            return libusb_open_device_with_vid_pid(ctx, vid, pid)
        }
        var devices: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &devices)
        guard count > 0, let devices else { return nil }
        defer { libusb_free_device_list(devices, 1) }

        var seen = 0
        for i in 0..<Int(count) {
            guard let dev = devices[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0,
                desc.idVendor == vid, desc.idProduct == pid
            else { continue }
            if seen == index {
                var handle: OpaquePointer?
                return libusb_open(dev, &handle) == 0 ? handle : nil
            }
            seen += 1
        }
        return nil
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

    /// Writes several packets as one transfer.
    ///
    /// The device parses a byte stream and does not care where transfer
    /// boundaries fall, so a frame's packets can be concatenated. Each separate
    /// `bulkWrite` costs a blocking round trip during which the link is idle —
    /// at full speed that overhead dominates, since a 64-byte packet is emptied
    /// far faster than the next transfer can be submitted.
    func bulkWriteBatched(
        endpoint: UInt8 = 0x01, _ packets: [Data],
        maxBatch: Int = 256 * 1024, timeoutMs: UInt32 = 5000
    ) throws {
        var batch = Data()
        batch.reserveCapacity(min(maxBatch, 64 * 1024))

        for packet in packets {
            if !batch.isEmpty && batch.count + packet.count > maxBatch {
                try bulkWrite(endpoint: endpoint, batch, timeoutMs: timeoutMs)
                batch.removeAll(keepingCapacity: true)
            }
            batch.append(packet)
        }
        if !batch.isEmpty {
            try bulkWrite(endpoint: endpoint, batch, timeoutMs: timeoutMs)
        }
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
