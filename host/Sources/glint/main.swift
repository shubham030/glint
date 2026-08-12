import GlintCore
import CoreGraphics
import Foundation

// glint — host CLI. Every mode starts with the HELLO handshake and adapts to
// the panel geometry the device reports.
//
//   glint hello                                      probe + print handshake
//   glint bars [--seconds N] [--fps N]               M0 transport test
//   glint image <path> [--fill] [--landscape]        M1 static image
//   glint mirror [--fps N] [--landscape]             M2 mirror the main display
//   glint display [--portrait] [--width W --height H --1x]
//                 [--sat P] [--con P] [--flat] [--full]
//                 [--touch [--tp-swap --tp-flip-x --tp-flip-y]]
//                                                    M3/M4 extended display
//   glint touch [--calibrate]                        M5 touch, raw or guided
//   glint stats                                      device counters
//   glint doctor                                     check device + permissions
//   glint bootloader                                 reboot into the ROM loader
//   glint backlight <0-255>
//   glint sleep <0|1>
//
// Session modes run until Ctrl-C unless --seconds is given.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("glint: " + msg + "\n").utf8))
    exit(1)
}

func argValue(_ name: String, default def: Int) -> Int {
    guard let i = CommandLine.arguments.firstIndex(of: name),
        i + 1 < CommandLine.arguments.count,
        let v = Int(CommandLine.arguments[i + 1])
    else { return def }
    return v
}

/// Writes one whole frame, reusing the tiling path so every mode shares one
/// encoder (and gets RLE for free where the device supports it).
func sendFullFrame(
    _ dev: Link, _ tiles: TileSender, px: [UInt16]
) throws -> Int {
    let (packets, stats) = tiles.packets(px: px, forceFull: true)
    try dev.send(packets)
    return stats.bytes
}

/// Run a capture session until Ctrl-C, or for --seconds if given.
func runSession(_ session: MirrorSession, fps: Int, seconds: Int) async throws {
    try await session.start(fps: fps)
    if seconds > 0 {
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        await session.stop()
    } else {
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bars"

/* Runs before any device is opened: it reports on a missing panel rather than
 * failing on one. */
if mode == "doctor" {
    runDoctor()
}

/* With more than one panel attached the firmware's fixed serial number cannot
 * distinguish them, so list bus/address and let the caller pick with --dev. */
if CommandLine.arguments.contains("--list") {
    let found = (try? USBDevice.list(vid: Glint.vid, pid: Glint.pid)) ?? []
    if found.isEmpty {
        print("no glint devices found")
    }
    for (i, d) in found.enumerated() {
        print("--dev \(i): \(d.description)")
    }
    exit(0)
}

/// Long-running modes wait for the panel; one-shot commands fail fast.
let sessionModes: Set<String> = ["display", "mirror", "touch", "stats"]
let waitForDevice =
    sessionModes.contains(mode) && !CommandLine.arguments.contains("--no-wait")

do {
    /* --net picks the wireless transport; everything above the Link protocol
     * is identical either way. */
    let dev: Link
    if let i = CommandLine.arguments.firstIndex(of: "--net"),
        i + 1 < CommandLine.arguments.count
    {
        dev = try NetLink(
            host: CommandLine.arguments[i + 1],
            port: UInt16(argValue("--port", default: 7788)))
    } else {
        dev = try USBDevice.open(
            vid: Glint.vid, pid: Glint.pid, waitForDevice: waitForDevice,
            index: argValue("--dev", default: 0))
    }
    let hello = try dev.handshake()
    let fw = String(format: "%08x", hello.fwVer)
    print(
        "panel \(hello.panelW)x\(hello.panelH), fmt_mask=\(hello.fmtMask), "
            + "max_tile=\(hello.maxTileLen), touch=\(hello.touchPoints)pt, "
            + "id=\(String(format: "%04x", hello.devId)), fw=\(fw), "
            + "link=\(dev.describeLink)")

    switch mode {
    case "hello":
        exit(0)

    case "backlight":
        guard CommandLine.arguments.count > 2,
            let v = UInt16(CommandLine.arguments[2]), v <= 255
        else { fail("usage: glint backlight <0-255>") }
        try dev.control(.backlight, value: v)

    case "bootloader":
        /* Removes the BOOT-button dance on boards with no UART bridge. */
        try dev.control(.bootloader, value: 0)
        print("device rebooting into its download loader — flash now")

    case "sleep":
        guard CommandLine.arguments.count > 2,
            let v = UInt16(CommandLine.arguments[2]), v <= 1
        else { fail("usage: glint sleep <0|1>") }
        try dev.control(.sleep, value: v)

    case "image":
        guard CommandLine.arguments.count > 2 else {
            fail("usage: glint image <path> [--fill] [--landscape]")
        }
        let path = CommandLine.arguments[2]
        let mode: FitMode =
            CommandLine.arguments.contains("--fill") ? .fill : .fit
        let landscape = CommandLine.arguments.contains("--landscape")
        guard
            let px = loadImageRGB565(
                path: path, width: hello.panelW, height: hello.panelH,
                mode: mode, landscape: landscape)
        else { fail("could not decode '\(path)'") }
        try dev.control(.reset, value: 0)
        let tiles = TileSender(
            panelW: hello.panelW, panelH: hello.panelH,
            maxTileLen: hello.maxTileLen, allowRLE: hello.supports(.rle))
        let n = try sendFullFrame(dev, tiles, px: px)
        print("sent \(path) (\(n) bytes on the wire)")

    case "display":
        /* Tiles make a typical frame ~18KB, so a higher cap costs little and
         * cuts latency for small changes; a full-screen change still
         * self-limits on the SPI bus because the send is synchronous. */
        let tiled = !CommandLine.arguments.contains("--full")
        let fps = max(1, argValue("--fps", default: tiled ? 30 : 12))
        let seconds = argValue("--seconds", default: 0) /* 0 = until ^C */
        let landscape = !CommandLine.arguments.contains("--portrait")
        /* Default 2× backing: WindowServer coerces a literal 480×320 mode
         * down to 240×160 (observed on macOS 26.5), and 960×640 gives a
         * desktop real windows actually fit on. --1x tries panel-native;
         * --width/--height override for experimentation. */
        let hiDPI = !CommandLine.arguments.contains("--1x")
        /* The virtual desktop is the panel as the viewer sees it. */
        var pointsW = landscape ? hello.panelH : hello.panelW
        var pointsH = landscape ? hello.panelW : hello.panelH
        let ow = argValue("--width", default: 0)
        let oh = argValue("--height", default: 0)
        if ow > 0 && oh > 0 {
            pointsW = ow
            pointsH = oh
        }
        /* Identify the virtual display by the panel's own id, not by transport
         * position. WindowServer keys on vendor/product/serial: two panels
         * sharing a triple means the second display is created but never
         * becomes visible to ScreenCaptureKit, and a stale registration from an
         * earlier session blocks a new one the same way. */
        let panelID =
            hello.devId != 0
            ? UInt32(hello.devId) : UInt32(1 + argValue("--dev", default: 0))
        let panelName =
            hello.devId != 0
            ? String(format: "glint %04x", hello.devId) : "glint"
        guard
            let (virtualDisplay, displayID) = createVirtualDisplay(
                pointsW: pointsW, pointsH: pointsH, hiDPI: hiDPI,
                name: panelName, serial: panelID)
        else { fail("CGVirtualDisplay applySettings failed") }
        print(
            "virtual display '\(panelName)' up: \(pointsW)x\(pointsH)"
                + (hiDPI ? " @2x" : "") + " (id \(displayID))")
        /* NOTE (macOS 26.5): WindowServer refuses desktops under ~800 px
         * wide — sub-800 modes are halved and CGDisplaySetDisplayMode to the
         * exact mode fails (1001). 960×640 (2:1) and 800×534 (1.67:1) are
         * the workable sizes; panel-native 480×320 is not possible. */
        let b = CGDisplayBounds(displayID)
        let m = CGDisplayCopyDisplayMode(displayID)
        print(
            "desktop \(Int(b.width))x\(Int(b.height)) pt, "
                + "mode \(m?.pixelWidth ?? 0)x\(m?.pixelHeight ?? 0) px")
        print("drag windows onto it; Ctrl-C removes it")

        let flat = CommandLine.arguments.contains("--flat")
        let session = MirrorSession(
            dev: dev, hello: hello, landscape: landscape,
            displayID: displayID,
            satPct: flat ? 100 : argValue("--sat", default: 130),
            conPct: flat ? 100 : argValue("--con", default: 110),
            fullFrames: CommandLine.arguments.contains("--full"))

        /* The reader always runs: STATS events share this pipe, and if nobody
         * drains it the device's FIFO fills and dropped-tile reports never
         * arrive — which would silently disable resync. Posting touch as cursor
         * events is the opt-in part, because an uncalibrated mapping would
         * fling the cursor across the desktop. */
        let touchToCursor = CommandLine.arguments.contains("--touch")
        let reader = TouchReader(
            dev: dev, hello: hello,
            mapping: TouchMapping.parse(CommandLine.arguments),
            bounds: touchToCursor ? CGDisplayBounds(displayID) : nil,
            raw: false, onDrops: { session.resync() })
        Thread { reader.run() }.start()
        print(
            touchToCursor
                ? "touch → cursor enabled"
                : "touch idle (pass --touch to move the cursor)")

        try await runSession(session, fps: fps, seconds: seconds)
        _ = virtualDisplay /* keep the display alive for the session */

    case "mirror":
        let fps = max(1, argValue("--fps", default: 12))
        let seconds = argValue("--seconds", default: 0)
        let landscape = CommandLine.arguments.contains("--landscape")
        let session = MirrorSession(
            dev: dev, hello: hello, landscape: landscape,
            fullFrames: CommandLine.arguments.contains("--full"))
        /* Drain STATS so dropped tiles still trigger a resync here too. */
        let reader = TouchReader(
            dev: dev, hello: hello, mapping: TouchMapping(),
            bounds: nil, raw: false, onDrops: { session.resync() })
        Thread { reader.run() }.start()
        try await runSession(session, fps: fps, seconds: seconds)

    case "touch":
        if CommandLine.arguments.contains("--calibrate") {
            calibrateTouch(
                dev: dev, hello: hello,
                landscape: !CommandLine.arguments.contains("--portrait"))
            exit(0)
        }
        /* Raw mode: prints panel coords so the mapping can be checked by eye. */
        let reader = TouchReader(
            dev: dev, hello: hello,
            mapping: TouchMapping.parse(CommandLine.arguments),
            bounds: nil, raw: true)
        print("tap the panel — Ctrl-C to stop")
        reader.run()

    case "stats":
        let reader = TouchReader(
            dev: dev, hello: hello, mapping: TouchMapping(),
            bounds: nil, raw: true)
        print("draining events (STATS + touch) — Ctrl-C to stop")
        reader.run()

    case "bars":
        let seconds = argValue("--seconds", default: 10)
        let fps = max(1, argValue("--fps", default: 10))
        guard hello.maxTileLen / (hello.panelW * 2) > 0 else {
            fail("device max_tile_len too small")
        }

        try dev.control(.reset, value: 0)

        /* A throughput test wants whole frames, not dirty tiles — and raw
         * pixels, since colour bars would compress unrealistically well. */
        let tiles = TileSender(
            panelW: hello.panelW, panelH: hello.panelH,
            maxTileLen: hello.maxTileLen, allowRLE: false)
        var seq: UInt16 = 0
        var sentBytes = 0
        let start = Date()
        var lastReport = start

        /* Split the frame time so a slow link can be told apart from slow
         * frame preparation — guessing at that wasted three attempts. */
        var renderSec = 0.0
        var encodeSec = 0.0
        var writeSec = 0.0

        while Date().timeIntervalSince(start) < Double(seconds) {
            let frameStart = Date()
            let px = renderColorBars(
                width: hello.panelW, height: hello.panelH, phase: Int(seq) * 4)
            let afterRender = Date()
            let (packets, pstats) = tiles.packets(px: px, forceFull: true)
            let afterEncode = Date()
            try dev.send(packets)
            let afterWrite = Date()

            renderSec += afterRender.timeIntervalSince(frameStart)
            encodeSec += afterEncode.timeIntervalSince(afterRender)
            writeSec += afterWrite.timeIntervalSince(afterEncode)
            sentBytes += pstats.bytes
            seq &+= 1

            if Date().timeIntervalSince(lastReport) >= 1 {
                let mbps = Double(sentBytes) / Date().timeIntervalSince(start)
                    / 1_000_000
                print(String(
                    format: "frame %d  %.2f MB/s avg", seq, mbps))
                lastReport = Date()
            }

            let frameTime = Date().timeIntervalSince(frameStart)
            let budget = 1.0 / Double(fps)
            if frameTime < budget {
                Thread.sleep(forTimeInterval: budget - frameTime)
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        print(String(
            format: "sent %d frames, %.1f KB, %.2f MB/s, effective %.1f fps",
            seq, Double(sentBytes) / 1024,
            Double(sentBytes) / elapsed / 1_000_000, Double(seq) / elapsed))
        let n = max(1.0, Double(seq))
        print(String(
            format:
                "per frame: render %.1f ms, encode %.1f ms, usb write %.1f ms "
                + "(%.0f%% of the frame)",
            renderSec / n * 1000, encodeSec / n * 1000, writeSec / n * 1000,
            writeSec / max(0.001, renderSec + encodeSec + writeSec) * 100))

    default:
        fail(
            "unknown mode '\(mode)' — use doctor | hello | bars | image | "
                + "mirror | display | touch | stats | backlight | sleep"
        )
    }
} catch {
    fail("\(error)")
}
