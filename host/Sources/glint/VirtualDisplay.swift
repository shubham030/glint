import GlintCore
import CGVirtualDisplayShim
import CoreGraphics
import Foundation

/// Create a virtual display sized for the panel (landscape: the desk
/// orientation). Returns the display object — hold it; releasing it removes
/// the display — plus its CGDirectDisplayID for capture.
///
/// `hiDPI` doubles the backing pixels for crisper text; the capture path
/// scales back down to panel resolution either way.
/// `serial` must differ between concurrent displays: WindowServer rejects a
/// second descriptor carrying the same vendor/product/serial triple, which is
/// how driving two panels at once fails (applySettings returns false).
func createVirtualDisplay(
    pointsW: Int, pointsH: Int, hiDPI: Bool, name: String, serial: UInt32 = 1
) -> (display: CGVirtualDisplay, id: CGDirectDisplayID)? {
    let scale = hiDPI ? 2 : 1

    let desc = CGVirtualDisplayDescriptor()
    desc.queue = DispatchQueue.main
    desc.name = name
    desc.maxPixelsWide = UInt32(pointsW * scale)
    desc.maxPixelsHigh = UInt32(pointsH * scale)
    /* The physical panel is ~74×49 mm (165 PPI) — but reporting that makes
     * WindowServer auto-Retina the display into a 240×160-point desktop.
     * Report 2× the physical size (~82 PPI) so macOS keeps a 1:1 480×320
     * point desktop; the panel is small, but that's README §11's deal. */
    desc.sizeInMillimeters = CGSize(width: 148, height: 98)
    desc.vendorID = UInt32(Glint.vid)
    desc.productID = UInt32(Glint.pid)
    desc.serialNum = serial
    desc.terminationHandler = { _, _ in
        FileHandle.standardError.write(
            Data("glint: virtual display terminated by WindowServer\n".utf8))
    }

    guard let display = CGVirtualDisplay(descriptor: desc) else { return nil }

    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = hiDPI ? 1 : 0
    settings.modes = [
        CGVirtualDisplayMode(
            width: UInt32(pointsW * scale), height: UInt32(pointsH * scale),
            refreshRate: 30)
    ]
    guard display.apply(settings) else { return nil }

    /* WindowServer may bring a new display up mirroring the main one —
     * force it to extend instead. */
    var config: CGDisplayConfigRef?
    if CGBeginDisplayConfiguration(&config) == .success {
        CGConfigureDisplayMirrorOfDisplay(
            config, display.displayID, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    return (display, display.displayID)
}
