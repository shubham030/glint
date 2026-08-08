import AppKit
import CoreGraphics
import Foundation
import GlintCore

/// Checks the things that silently stop glint from working: the panel missing,
/// permissions not granted, or the private virtual-display API having changed
/// under a macOS update. Exists because each of those fails in a different and
/// non-obvious way at runtime.
func runDoctor() {
    var problems = 0

    func report(_ ok: Bool, _ label: String, fix: String? = nil) {
        print("\(ok ? "✓" : "✗") \(label)")
        if !ok {
            problems += 1
            if let fix { print("    → \(fix)") }
        }
    }

    print("glint doctor")
    print("")

    // 1. Is the panel on the bus, and does it talk?
    var hello: Hello?
    do {
        let dev = try USBDevice(vid: Glint.vid, pid: Glint.pid)
        hello = Hello(try dev.controlRead(.hello, length: 24))
        report(hello != nil, "panel responds to HELLO",
               fix: "device found but the handshake failed — firmware mismatch?")
        if let h = hello {
            print(
                "    panel \(h.panelW)x\(h.panelH), max_tile=\(h.maxTileLen), "
                    + "touch=\(h.touchPoints)pt, "
                    + "formats: raw\(h.supports(.rle) ? "+RLE" : "")")
            print(
                "    link: \(dev.maxPacket == 512 ? "high" : "full")-speed "
                    + "(\(dev.maxPacket)B packets)")
        }
    } catch {
        report(
            false, "panel present on USB",
            fix: "plug the OTG Type-C in — that port only enumerates in one "
                + "orientation, so flip the connector if nothing appears")
    }

    // 2. ScreenCaptureKit needs Screen Recording, and fails opaquely without it.
    let capture = CGPreflightScreenCaptureAccess()
    report(
        capture, "Screen Recording permission",
        fix: "System Settings → Privacy & Security → Screen Recording → "
            + "enable your terminal, then restart it")

    // 3. Touch → cursor needs Accessibility.
    let ax = AXIsProcessTrusted()
    report(
        ax, "Accessibility permission (only needed for --touch)",
        fix: "System Settings → Privacy & Security → Accessibility → "
            + "enable your terminal")

    // 4. The private API is the fragile part; prove it still works.
    if let (display, id) = createVirtualDisplay(
        pointsW: 960, pointsH: 640, hiDPI: false, name: "glint-doctor")
    {
        let bounds = CGDisplayBounds(id)
        report(true, "CGVirtualDisplay works (id \(id))")
        print(
            "    desktop \(Int(bounds.width))x\(Int(bounds.height)) pt "
                + "— macOS may coerce small modes; see README")
        _ = display
    } else {
        report(
            false, "CGVirtualDisplay works",
            fix: "the private API changed — this breaks on macOS updates and "
                + "is the known risk of every virtual-display tool")
    }

    print("")
    if problems == 0 {
        print("all good — `glint display` should work")
    } else {
        print("\(problems) problem(s) above")
    }
    exit(problems == 0 ? 0 : 1)
}
