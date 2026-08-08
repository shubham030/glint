import CoreImage
import Foundation
import ScreenCaptureKit

/// M2: mirror the main display to the panel via ScreenCaptureKit.
/// Frames arrive on a serial queue; the send is synchronous, so SCStream's
/// own frame dropping provides backpressure when USB+SPI can't keep up.
final class MirrorSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let dev: USBDevice
    private let hello: Hello
    private let landscape: Bool
    private let vivid: Bool
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var seq: UInt16 = 0
    private var frames = 0
    private var bytes = 0
    private let started = Date()
    private var stream: SCStream?

    /// Capture target; nil = the main display.
    private let targetDisplayID: CGDirectDisplayID?

    init(
        dev: USBDevice, hello: Hello, landscape: Bool,
        displayID: CGDirectDisplayID? = nil, vivid: Bool = false
    ) {
        self.dev = dev
        self.hello = hello
        self.landscape = landscape
        self.targetDisplayID = displayID
        self.vivid = vivid
    }

    func start(fps: Int) async throws {
        /* A freshly created virtual display can take a beat to appear in
         * shareable content — poll briefly instead of failing. */
        let wanted = targetDisplayID ?? CGMainDisplayID()
        var display: SCDisplay?
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            display = content.displays.first { $0.displayID == wanted }
            if display == nil && targetDisplayID == nil {
                display = content.displays.first
            }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let display else {
            throw NSError(
                domain: "vdisp", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "display \(wanted) never appeared in shareable content"
                ])
        }

        let filter = SCContentFilter(
            display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        /* Capture at 2× the panel's logical geometry and downscale ourselves
         * (Lanczos + sharpen) — much crisper small text than the stream
         * scaler, and the virtual desktop is exactly 2× anyway. */
        cfg.width = (landscape ? hello.panelH : hello.panelW) * 2
        cfg.height = (landscape ? hello.panelW : hello.panelH) * 2
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        cfg.showsCursor = true
        cfg.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(
            self, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "vdisp.mirror"))
        try await stream.startCapture()
        self.stream = stream
        print(
            "mirroring \(display.width)x\(display.height) → "
                + "\(cfg.width)x\(cfg.height) @ \(fps)fps cap")
    }

    func stop() async {
        try? await stream?.stopCapture()
        let dt = Date().timeIntervalSince(started)
        print(String(
            format: "mirrored %d frames, %.2f MB/s, %.1f fps",
            frames, Double(bytes) / dt / 1_000_000, Double(frames) / dt))
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sb.isValid,
            let pb = sb.imageBuffer
        else { return }

        let logicalW = landscape ? hello.panelH : hello.panelW
        let logicalH = landscape ? hello.panelW : hello.panelH
        let ci = CIImage(cvPixelBuffer: pb)
            .applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1.0,
                ])
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [kCIInputSharpnessKey: 0.4])
        let rect = CGRect(
            x: 0, y: 0, width: CGFloat(logicalW), height: CGFloat(logicalH))
        guard let cg = ciContext.createCGImage(ci, from: rect),
            let px = renderRGB565(
                img: cg, width: hello.panelW, height: hello.panelH,
                mode: .fill, landscape: landscape, vivid: vivid)
        else { return }

        do {
            bytes += try sendFrame(
                dev, hello, px: px, seq: seq, fullRefresh: seq == 0)
            seq &+= 1
            frames += 1
        } catch {
            FileHandle.standardError.write(
                Data("vdisp: send failed: \(error)\n".utf8))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            Data("vdisp: stream stopped: \(error)\n".utf8))
    }
}
