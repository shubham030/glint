import CGVirtualDisplayShim
import CoreGraphics
import Foundation

/// Create a virtual display sized for the panel (landscape: the desk
/// orientation). Returns the display object — hold it; releasing it removes
/// the display — plus its CGDirectDisplayID for capture.
///
/// `hiDPI` doubles the backing pixels for crisper text; the capture path
/// scales back down to panel resolution either way.
func createVirtualDisplay(
    pointsW: Int, pointsH: Int, hiDPI: Bool, name: String
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
    desc.vendorID = UInt32(VD.vid)
    desc.productID = UInt32(VD.pid)
    desc.serialNum = 1
    desc.terminationHandler = { _, _ in
        FileHandle.standardError.write(
            Data("vdisp: virtual display terminated by WindowServer\n".utf8))
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
    return (display, display.displayID)
}
