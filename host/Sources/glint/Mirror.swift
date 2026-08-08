import CoreImage
import Foundation
import GlintCore
import ScreenCaptureKit

/// M2: mirror the main display to the panel via ScreenCaptureKit.
/// Frames arrive on a serial queue; the send is synchronous, so SCStream's
/// own frame dropping provides backpressure when USB+SPI can't keep up.
final class MirrorSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let dev: USBDevice
    private let hello: Hello
    private let landscape: Bool
    private let satPct: Int
    private let conPct: Int
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let tiles: TileSender
    private let fullFrames: Bool
    private var frames = 0
    private var bytes = 0
    private var tilesSent = 0
    private var compressed = 0
    private var idleFrames = 0
    private let resyncLock = NSLock()
    private var resyncPending = false
    private let started = Date()
    private var stream: SCStream?

    /// Capture target; nil = the main display.
    private let targetDisplayID: CGDirectDisplayID?

    init(
        dev: USBDevice, hello: Hello, landscape: Bool,
        displayID: CGDirectDisplayID? = nil, satPct: Int = 100,
        conPct: Int = 100, fullFrames: Bool = false
    ) {
        self.dev = dev
        self.hello = hello
        self.landscape = landscape
        self.targetDisplayID = displayID
        self.satPct = satPct
        self.conPct = conPct
        self.fullFrames = fullFrames
        self.tiles = TileSender(
            panelW: hello.panelW, panelH: hello.panelH,
            maxTileLen: hello.maxTileLen,
            allowRLE: hello.supports(.rle))
    }

    /// Called from the event-reader thread when the device reports dropped
    /// tiles: the panel and our hash table have diverged, so the next frame
    /// must be a full refresh.
    ///
    /// This only raises a flag. `TileSender` is not concurrency-safe and the
    /// capture queue may be inside `packets(px:)` right now, so the
    /// invalidation itself happens on the frame path.
    func resync() {
        resyncLock.lock()
        resyncPending = true
        resyncLock.unlock()
    }

    private func takeResyncRequest() -> Bool {
        resyncLock.lock()
        defer { resyncLock.unlock() }
        let pending = resyncPending
        resyncPending = false
        return pending
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
                domain: "glint", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "display \(wanted) never appeared in shareable content"
                ])
        }

        let filter = SCContentFilter(
            display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        /* Capture at the panel's logical (viewer) geometry; SCStream scales. */
        cfg.width = landscape ? hello.panelH : hello.panelW
        cfg.height = landscape ? hello.panelW : hello.panelH
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        cfg.showsCursor = true
        cfg.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(
            self, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "glint.mirror"))
        try await stream.startCapture()
        self.stream = stream
        print(
            "mirroring \(display.width)x\(display.height) → "
                + "\(cfg.width)x\(cfg.height) @ \(fps)fps cap, "
                + (fullFrames ? "full frames" : "dirty tiles (\(tiles.grid))"))
    }

    func stop() async {
        try? await stream?.stopCapture()
        let dt = Date().timeIntervalSince(started)
        let fullFrameKB = Double(hello.panelW * hello.panelH * 2) / 1024
        print(String(
            format: "%d frames, %.2f MB/s, %.1f fps",
            frames, Double(bytes) / dt / 1_000_000, Double(frames) / dt))
        print(String(
            format:
                "%.1f KB/frame avg (full frame is %.0f KB), %.1f tiles/frame, "
                + "%d frames unchanged, %d packets RLE",
            frames > 0 ? Double(bytes) / Double(frames) / 1024 : 0,
            fullFrameKB,
            frames > 0 ? Double(tilesSent) / Double(frames) : 0,
            idleFrames, compressed))
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sb.isValid,
            let pb = sb.imageBuffer
        else { return }

        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent),
            let px = renderRGB565(
                img: cg, width: hello.panelW, height: hello.panelH,
                mode: .fill, landscape: landscape, satPct: satPct,
                conPct: conPct)
        else { return }

        if takeResyncRequest() {
            print("device reported losses — forcing a full refresh")
            tiles.invalidate()
        }

        do {
            let (packets, s) = tiles.packets(px: px, forceFull: fullFrames)
            for packet in packets {
                try dev.bulkWrite(packet)
            }
            bytes += s.bytes
            tilesSent += s.tiles
            compressed += s.compressed
            frames += 1
            if s.packets == 0 { idleFrames += 1 }
        } catch let error as USBError where error.isDisconnect {
            /* The panel was unplugged. Exiting beats spraying one error per
             * frame; a supervisor (or the user) restarts us and the session
             * waits for the device to come back. */
            FileHandle.standardError.write(
                Data("glint: panel disconnected — exiting\n".utf8))
            exit(3)
        } catch {
            /* A frame can fail part-written, and the hashes were already
             * updated for every tile in it — including ones the panel never
             * received. Without this the missed regions would stay stale
             * until their content happened to change again. */
            tiles.invalidate()
            FileHandle.standardError.write(
                Data("glint: send failed (\(error)) — resyncing\n".utf8))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            Data("glint: stream stopped: \(error)\n".utf8))
    }
}
