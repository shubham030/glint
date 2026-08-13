import ApplicationServices
import CoreGraphics
import Foundation
import GlintCore

/// M3/M4: a real extended display. Creates the virtual display, captures it and
/// streams the changed tiles to the panel for as long as the process lives.
func runDisplay(dev: Link, hello: Hello, opts: Options) async throws {
    let (pointsW, pointsH) = opts.desktopSize(
        panelW: hello.panelW, panelH: hello.panelH)
    let identity = PanelIdentity(hello: hello, devIndex: opts.devIndex)

    let (displayID, session) = try await attachDisplay(
        dev: dev, hello: hello, opts: opts,
        pointsW: pointsW, pointsH: pointsH, identity: identity)

    describeDisplay(displayID, name: identity.name, pointsW: pointsW,
                    pointsH: pointsH, hiDPI: !opts.oneX)
    startTouchReader(dev: dev, hello: hello, opts: opts,
                     displayID: displayID, session: session)

    try await holdSession(session, seconds: opts.seconds)
}

/// How macOS knows one panel from another.
///
/// WindowServer keys a virtual display on vendor/product/serial, so the panel's
/// own id is the right thing to use: two panels sharing a triple means the
/// second display is created but never becomes visible to ScreenCaptureKit.
/// Firmware predating `dev_id` reports 0, hence the positional fallback.
struct PanelIdentity {
    let serial: UInt32
    let name: String

    init(hello: Hello, devIndex: Int) {
        if hello.devId != 0 {
            serial = UInt32(hello.devId)
            name = String(format: "glint %04x", hello.devId)
        } else {
            serial = UInt32(1 + devIndex)
            name = "glint"
        }
    }
}

/// Creates the virtual display and starts capturing it, retrying on the
/// WindowServer race described below.
private func attachDisplay(
    dev: Link, hello: Hello, opts: Options,
    pointsW: Int, pointsH: Int, identity: PanelIdentity
) async throws -> (CGDirectDisplayID, MirrorSession) {
    for attempt in 1...4 {
        /* Vary the serial on retry. WindowServer does not always reap the
         * previous session's registration before the next one starts; the
         * display is then created (CGDisplayBounds even answers for it) but
         * never comes online or appears in shareable content. The conflict *is*
         * the serial, so reusing it fails identically every time. A different
         * serial is a different display identity, so macOS forgets this panel's
         * saved arrangement — worth it to get a working display, and the clean
         * id comes back on the next launch. */
        guard
            let (vd, displayID) = createVirtualDisplay(
                pointsW: pointsW, pointsH: pointsH, hiDPI: !opts.oneX,
                name: identity.name,
                serial: identity.serial &+ UInt32(attempt - 1))
        else { fail("CGVirtualDisplay applySettings failed") }
        /* Sole owner: a strong reference here would outlive the signal
         * handler's release and keep the registration alive past exit, which is
         * the race being avoided. */
        holdVirtualDisplay(vd)

        let session = MirrorSession(
            dev: dev, hello: hello, landscape: !opts.portrait,
            displayID: displayID,
            satPct: opts.saturation, conPct: opts.contrast,
            fullFrames: opts.full)
        do {
            /* Tiles make a typical frame ~18KB, so a higher cap costs little
             * and cuts latency for small changes; a full-screen change still
             * self-limits on the panel's bus because the send is synchronous. */
            try await session.start(fps: opts.frameRate(default: opts.full ? 12 : 30))
            return (displayID, session)
        } catch let error as NSError where error.domain == "glint" {
            if attempt == 4 { fail(error.localizedDescription) }
            print(
                "display \(displayID) did not attach (attempt \(attempt)) — "
                    + "WindowServer is still holding that identity; retrying "
                    + "with a different serial")
            holdVirtualDisplay(nil)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
    fail("could not bring up a virtual display")
}

private func describeDisplay(
    _ displayID: CGDirectDisplayID, name: String,
    pointsW: Int, pointsH: Int, hiDPI: Bool
) {
    print(
        "virtual display '\(name)' up: \(pointsW)x\(pointsH)"
            + (hiDPI ? " @2x" : "") + " (id \(displayID))")
    /* NOTE (macOS 26.5): WindowServer refuses desktops under ~800 px wide —
     * sub-800 modes are halved and CGDisplaySetDisplayMode to the exact mode
     * fails (1001). 960×640 (2:1) and 800×534 (1.67:1) are the workable sizes;
     * panel-native 480×320 is not possible. */
    let bounds = CGDisplayBounds(displayID)
    let mode = CGDisplayCopyDisplayMode(displayID)
    print(
        "desktop \(Int(bounds.width))x\(Int(bounds.height)) pt, "
            + "mode \(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0) px")
    print("drag windows onto it; Ctrl-C removes it")
}

/// The reader always runs: STATS events share this pipe, and if nobody drains
/// it the device's FIFO fills and dropped-tile reports never arrive — which
/// would silently disable resync. Posting touch as cursor events is the opt-in
/// part, because an uncalibrated mapping would fling the cursor across the
/// desktop.
private func startTouchReader(
    dev: Link, hello: Hello, opts: Options,
    displayID: CGDirectDisplayID, session: MirrorSession
) {
    let bounds = CGDisplayBounds(displayID)
    let reader = TouchReader(
        dev: dev, hello: hello, mapping: opts.mapping,
        bounds: opts.touch ? bounds : nil,
        raw: false, onDrops: { session.resync() })
    Thread { reader.run() }.start()

    guard opts.touch else {
        print("touch idle (pass --touch to move the cursor)")
        return
    }
    /* Print the rect taps are mapped into: a virtual display does not always
     * enumerate for other processes, and a zero rect would drop every tap at
     * (0,0) instead of on the panel's own region — indistinguishable from
     * "touch does nothing". */
    print(String(
        format: "touch → cursor enabled, mapping onto (%.0f, %.0f) %.0fx%.0f",
        bounds.origin.x, bounds.origin.y, bounds.width, bounds.height))
    if bounds.width == 0 || bounds.height == 0 {
        print("warning: that display reports no bounds — taps cannot be placed")
    }
    /* Posting synthetic events needs Accessibility, a separate grant from
     * Screen Recording: without it every tap is discarded silently. */
    if !AXIsProcessTrusted() {
        print(
            "warning: this binary is not trusted for Accessibility, so macOS "
                + "will DISCARD every synthetic click.\n"
                + "         System Settings → Privacy & Security → "
                + "Accessibility → add:\n         "
                + CommandLine.arguments[0])
    }
}
