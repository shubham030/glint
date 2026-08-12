import Foundation
import Network

/// A panel advertising itself on the network.
///
/// `host` is simply `<instance name>.local`, which is safe because the firmware
/// sets its mDNS hostname and its instance name from the same board id (see
/// `mdns_hostname_set`/`mdns_instance_name_set` in firmware/main/net.c). That
/// keeps discovery to a browse — no separate resolve step.
struct FoundPanel {
    let name: String
    let port: UInt16
    var status: PanelStatus = .free

    var host: String { "\(name).local" }
}

/// What a probe learned about an advertised panel.
enum PanelStatus {
    /// Accepted a connection: usable right now.
    case free
    /// Its name resolves — so the board is up and its mDNS responder answered —
    /// but it did not answer a handshake. The firmware serves one client at a
    /// time (`listen(listener, 1)` in net.c), so this is nearly always another
    /// glint session already holding it.
    case busy
    /// The name does not resolve at all: a stale registration left in the
    /// responder's cache by a board that is no longer on the network.
    case gone
}

/// Browses for `_glint._tcp` and returns what answered, sorted by name so the
/// same board is picked on every run.
///
/// mDNSResponder caches registrations, so this can also return panels that are
/// no longer up (a board that was renamed by a firmware change leaves its old
/// name behind for a while). Callers must treat the result as candidates and
/// let the connection attempt decide — see `reachablePanels`.
func discoverPanels(timeout: TimeInterval = 2.0) -> [FoundPanel] {
    let browser = NWBrowser(
        for: .bonjour(type: "_glint._tcp", domain: "local."), using: .tcp)

    let lock = NSLock()
    var names = Set<String>()
    let firstResult = DispatchSemaphore(value: 0)

    browser.browseResultsChangedHandler = { results, _ in
        lock.lock()
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                names.insert(name)
            }
        }
        let empty = names.isEmpty
        lock.unlock()
        if !empty { firstResult.signal() }
    }
    browser.stateUpdateHandler = { state in
        if case .failed = state { firstResult.signal() }
    }
    browser.start(queue: .global())

    /* Cached answers all arrive together, but a board answering live is a
     * round-trip behind. Wait up to `timeout` for anything at all, then a short
     * grace period so a second panel is not missed by a few milliseconds. */
    if firstResult.wait(timeout: .now() + timeout) == .success {
        Thread.sleep(forTimeInterval: 0.35)
    }
    browser.cancel()

    lock.lock()
    let found = names.sorted()
    lock.unlock()
    return found.map { FoundPanel(name: $0, port: UInt16(GlintNetPort)) }
}

let GlintNetPort = 7788

/// Discovery with every candidate probed, so a stale mDNS entry is never
/// offered as a target and a panel someone else is using says so. Probes
/// concurrently: a busy panel costs a handshake timeout, and doing those in
/// sequence would dominate the wait.
func probePanels(timeout: TimeInterval = 2.0) -> [FoundPanel] {
    let candidates = discoverPanels(timeout: timeout)
    guard !candidates.isEmpty else { return [] }

    let lock = NSLock()
    var probed: [FoundPanel] = []
    DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
        var panel = candidates[i]
        panel.status = probeStatus(panel)
        lock.lock()
        probed.append(panel)
        lock.unlock()
    }
    /* Sorted by name so the same board is chosen on every run — "whichever
     * answered first" would move the desktop between panels. */
    return probed.filter { $0.status != .gone }.sorted { $0.name < $1.name }
}

/// Classifies one panel, by asking it for a handshake and closing again.
///
/// A completed TCP connection is *not* enough: lwIP's listen backlog finishes
/// the handshake for a queued connection while the firmware is still serving its
/// one client, so `connect` succeeds against a panel that will never answer.
/// Only a HELLO round trip distinguishes the two — which is why this was
/// observed reporting the same board free and busy in consecutive runs.
func probeStatus(_ panel: FoundPanel) -> PanelStatus {
    guard resolves(panel.host) else { return .gone }
    guard let link = try? NetLink(host: panel.host, port: panel.port,
                                  timeoutSec: 2),
        (try? link.handshake()) != nil
    else { return .busy }
    return .free
}

/// Whether the name resolves at all. Separates a board that is off the network
/// from one that is up but occupied, and it is the cheap test, so it goes first.
func resolves(_ host: String) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &info) == 0 else { return false }
    freeaddrinfo(info)
    return true
}

/// Opens the first advertised panel that answers a handshake, keeping that
/// connection rather than reconnecting — probing and then connecting separately
/// would leave a window for another session to take it in between. Also returns
/// the panels that were up but occupied, for the error message.
func openFirstAnsweringPanel(port: UInt16) -> (Link?, [String]) {
    var busy: [String] = []
    for panel in discoverPanels() {
        guard resolves(panel.host) else { continue } /* stale registration */
        guard let link = try? NetLink(host: panel.host, port: port,
                                      timeoutSec: 2),
            (try? link.handshake()) != nil
        else {
            busy.append(panel.host)
            continue
        }
        return (link, busy)
    }
    return (nil, busy)
}

/// `connect(2)` bounded by `timeoutSec`, instead of the OS default of over a
/// minute. Probing candidates and reporting an unreachable panel both need an
/// answer in seconds.
func connectWithTimeout(
    _ s: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t,
    _ timeoutSec: Int
) -> Bool {
    let flags = fcntl(s, F_GETFL, 0)
    guard flags >= 0, fcntl(s, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        return false
    }
    defer { _ = fcntl(s, F_SETFL, flags) }

    if connect(s, addr, len) == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    /* poll rather than select: the FD_SET macros are not exposed to Swift. */
    var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, Int32(timeoutSec * 1000)) > 0 else { return false }

    /* Writable also means "failed" — SO_ERROR is what distinguishes them. */
    var err: Int32 = 0
    var errLen = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0 else {
        return false
    }
    if err != 0 { errno = err }
    return err == 0
}
