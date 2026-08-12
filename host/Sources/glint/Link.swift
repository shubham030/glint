import Foundation
import GlintCore

/// What the tiling pipeline needs from a transport. USB and TCP differ only in
/// how the handshake is asked for: USB has a control pipe, a socket carries the
/// request in-band (see `glint_req_t` in protocol.h).
protocol Link: AnyObject {
    func handshake() throws -> Hello
    func send(_ packets: [Data]) throws
    /// Returns an empty Data on timeout rather than throwing — an idle link is
    /// the normal case, not an error.
    func readEvents(timeoutMs: UInt32) throws -> Data
    func control(_ cmd: Glint.Cmd, value: UInt16) throws
    /// Shown in the startup line, e.g. "high-speed USB" or "wifi 192.168.4.1".
    var describeLink: String { get }
}

extension USBDevice: Link {
    func handshake() throws -> Hello {
        guard let hello = Hello(try controlRead(.hello, length: 24)) else {
            throw USBError.libusb("bad HELLO reply — protocol mismatch?", 0)
        }
        return hello
    }

    func send(_ packets: [Data]) throws {
        try bulkWriteBatched(packets)
    }

    func readEvents(timeoutMs: UInt32) throws -> Data {
        try bulkRead(length: 512, timeoutMs: timeoutMs)
    }

    func control(_ cmd: Glint.Cmd, value: UInt16) throws {
        try controlWrite(cmd, value: value)
    }

    var describeLink: String {
        "\(maxPacket == 512 ? "high" : "full")-speed USB"
    }
}

enum NetError: Error, CustomStringConvertible {
    case connect(String, Int32)
    case closed
    case badHello
    case noPanelAnywhere
    case allBusy([String])

    var description: String {
        switch self {
        case let .allBusy(hosts):
            return """
                \(hosts.joined(separator: ", ")) \(hosts.count == 1 ? "is" : "are") \
                up but already serving a client — the panel takes one at a time. \
                Stop the other glint session (`pkill -f "glint display"`) or \
                plug in over USB.
                """
        case .noPanelAnywhere:
            return """
                no panel found — nothing on USB, nothing answering on the \
                network. Check the cable, or that the board joined Wi-Fi \
                (`make monitor`). `glint --list` shows both.
                """
        case let .connect(host, code):
            return code == 0
                ? "cannot reach \(host)"
                : "cannot reach \(host): \(String(cString: strerror(code)))"
        case .closed:
            return "the panel closed the connection"
        case .badHello:
            return "bad HELLO reply over the network — protocol mismatch?"
        }
    }
}

/// TCP transport. The panel runs a SoftAP, so `host` is normally 192.168.4.1.
final class NetLink: Link {
    private var fd: Int32 = -1
    private let host: String
    private let port: UInt16

    init(host: String, port: UInt16 = 7788, timeoutSec: Int = 5) throws {
        self.host = host
        self.port = port

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0,
            let first = info
        else { throw NetError.connect(host, errno) }
        defer { freeaddrinfo(info) }

        let s = socket(first.pointee.ai_family, first.pointee.ai_socktype, 0)
        guard s >= 0 else { throw NetError.connect(host, errno) }
        /* Bounded connect: a panel that is powered but off the network would
         * otherwise hang here for the OS default of over a minute. */
        guard
            connectWithTimeout(
                s, first.pointee.ai_addr, first.pointee.ai_addrlen, timeoutSec)
        else {
            let e = errno
            close(s)
            throw NetError.connect(host, e == 0 ? ETIMEDOUT : e)
        }

        /* Tiles are latency-sensitive and already batched, so Nagle only adds
         * delay. */
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    private func writeAll(_ bytes: UnsafeRawPointer, _ count: Int) throws {
        var sent = 0
        while sent < count {
            let n = write(fd, bytes.advanced(by: sent), count - sent)
            if n > 0 {
                sent += n
                continue
            }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            throw NetError.closed
        }
    }

    func send(_ packets: [Data]) throws {
        /* One write per frame: the device parses a stream, so packet boundaries
         * carry no meaning, and fewer syscalls means fewer TCP segments. */
        var batch = Data()
        for packet in packets { batch.append(packet) }
        guard !batch.isEmpty else { return }
        try batch.withUnsafeBytes { try writeAll($0.baseAddress!, $0.count) }
    }

    private func setReadTimeout(_ ms: UInt32) {
        var tv = timeval(
            tv_sec: Int(ms / 1000), tv_usec: Int32((ms % 1000) * 1000))
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
            socklen_t(MemoryLayout<timeval>.size))
    }

    func readEvents(timeoutMs: UInt32) throws -> Data {
        setReadTimeout(timeoutMs)
        var buf = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buf, buf.count)
        if n > 0 { return Data(buf.prefix(n)) }
        if n == 0 { throw NetError.closed }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return Data()
        }
        throw NetError.closed
    }

    func control(_ cmd: Glint.Cmd, value: UInt16) throws {
        try send([requestPacket(cmd, value: value)])
    }

    func handshake() throws -> Hello {
        try control(.hello, value: 0)
        /* The reply is the only thing on the stream at this point. */
        setReadTimeout(3000)
        var buf = [UInt8](repeating: 0, count: 24)
        var got = 0
        while got < 24 {
            let n = read(fd, &buf[got], 24 - got)
            if n > 0 {
                got += n
                continue
            }
            if n < 0 && (errno == EINTR) { continue }
            throw NetError.closed
        }
        guard let hello = Hello(Data(buf)) else { throw NetError.badHello }
        return hello
    }

    var describeLink: String { "wifi \(host):\(port)" }
}

/// How the caller wants the panel found.
enum LinkChoice: Equatable {
    /// USB if a panel is plugged in, otherwise whatever is on the network.
    case auto
    case usbOnly
    case netOnly
    case host(String)
}

/// Opens a panel without being told where it is.
///
/// USB wins when both are available: it is an order of magnitude faster, and a
/// plugged-in cable is a clearer statement of intent than a board that merely
/// happens to be on the same network. When `wait` is set this keeps looking, so
/// the session can be started before the panel exists — that is what makes the
/// login agent work for both transports.
func openPanel(
    _ choice: LinkChoice, wait: Bool, devIndex: Int = 0,
    port: UInt16 = UInt16(GlintNetPort)
) throws -> Link {
    if case let .host(h) = choice {
        return try NetLink(host: h, port: port)
    }

    var announcedWait = false
    while true {
        if choice != .netOnly {
            do {
                return try USBDevice.open(
                    vid: Glint.vid, pid: Glint.pid, waitForDevice: false,
                    index: devIndex)
            } catch let error as USBError {
                /* Only "nothing plugged in" is worth falling back on; a
                 * permissions or claim failure must surface as itself. */
                guard case .notFound = error else { throw error }
            }
        }

        var busy: [String] = []
        if choice != .usbOnly {
            let (link, occupied) = openFirstAnsweringPanel(port: port)
            busy = occupied
            if let link {
                if !occupied.isEmpty {
                    print(
                        "skipped \(occupied.joined(separator: ", ")) — "
                            + "already in use")
                }
                return link
            }
        }

        guard wait else {
            if !busy.isEmpty { throw NetError.allBusy(busy) }
            switch choice {
            case .usbOnly: throw USBError.notFound
            case .netOnly:
                throw NetError.connect("any panel on the network", 0)
            default:
                throw NetError.noPanelAnywhere
            }
        }
        if !announcedWait {
            let where_ =
                choice == .usbOnly
                ? "USB" : (choice == .netOnly ? "the network" : "USB or Wi-Fi")
            print("waiting for a panel on \(where_)…")
            announcedWait = true
        }
        /* Discovery already spent ~2s of this; a USB-only wait needs the sleep. */
        if choice == .usbOnly { Thread.sleep(forTimeInterval: 1.0) }
    }
}

/// True when the transport is gone rather than merely erroring — a USB unplug or
/// a closed socket. Callers exit instead of retrying a dead link.
func isLinkGone(_ error: Error) -> Bool {
    if let usb = error as? USBError { return usb.isDisconnect }
    if let net = error as? NetError {
        switch net {
        case .closed, .connect, .noPanelAnywhere, .allBusy: return true
        case .badHello: return false
        }
    }
    return false
}
