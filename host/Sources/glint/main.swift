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
//                 [--sat P] [--con P] [--flat]       M3 extended virtual display
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

/// Send one full frame as max_tile-sized strips.
func sendFrame(
    _ dev: USBDevice, _ hello: Hello, px: [UInt16], seq: UInt16,
    fullRefresh: Bool
) throws -> Int {
    let stripH = hello.maxTileLen / (hello.panelW * 2)
    var sent = 0
    var y = 0
    while y < hello.panelH {
        let h = min(stripH, hello.panelH - y)
        var flags: Glint.TileFlags = []
        if fullRefresh { flags.insert(.fullRefresh) }
        if y + h >= hello.panelH { flags.insert(.lastInFrame) }

        let strip = Array(px[(y * hello.panelW)..<((y + h) * hello.panelW)])
        var packet = tileHeader(
            seq: seq, flags: flags,
            x: 0, y: UInt16(y),
            w: UInt16(hello.panelW), h: UInt16(h),
            payloadLen: UInt32(strip.count * 2))
        strip.withUnsafeBufferPointer {
            packet.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
        }
        try dev.bulkWrite(packet)
        sent += packet.count
        y += h
    }
    return sent
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

do {
    let dev = try USBDevice(vid: Glint.vid, pid: Glint.pid)
    guard let hello = Hello(try dev.controlRead(.hello, length: 24)) else {
        fail("bad HELLO reply — protocol mismatch?")
    }
    let fw = String(format: "%08x", hello.fwVer)
    print(
        "panel \(hello.panelW)x\(hello.panelH), fmt_mask=\(hello.fmtMask), "
            + "max_tile=\(hello.maxTileLen), touch=\(hello.touchPoints)pt, fw=\(fw), "
            + "usb=\(dev.maxPacket == 512 ? "high" : "full")-speed")

    switch mode {
    case "hello":
        exit(0)

    case "backlight":
        guard CommandLine.arguments.count > 2,
            let v = UInt16(CommandLine.arguments[2]), v <= 255
        else { fail("usage: glint backlight <0-255>") }
        try dev.controlWrite(.backlight, value: v)

    case "sleep":
        guard CommandLine.arguments.count > 2,
            let v = UInt16(CommandLine.arguments[2]), v <= 1
        else { fail("usage: glint sleep <0|1>") }
        try dev.controlWrite(.sleep, value: v)

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
        try dev.controlWrite(.reset)
        let n = try sendFrame(dev, hello, px: px, seq: 0, fullRefresh: true)
        print("sent \(path) (\(n) bytes)")

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
        guard
            let (glintlay, displayID) = createVirtualDisplay(
                pointsW: pointsW, pointsH: pointsH, hiDPI: hiDPI,
                name: "glint")
        else { fail("CGVirtualDisplay applySettings failed") }
        print(
            "virtual display 'glint' up: \(pointsW)x\(pointsH)"
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
        try await runSession(session, fps: fps, seconds: seconds)
        _ = glintlay /* keep the display alive for the session */

    case "mirror":
        let fps = max(1, argValue("--fps", default: 12))
        let seconds = argValue("--seconds", default: 0)
        let landscape = CommandLine.arguments.contains("--landscape")
        let session = MirrorSession(
            dev: dev, hello: hello, landscape: landscape,
            fullFrames: CommandLine.arguments.contains("--full"))
        try await runSession(session, fps: fps, seconds: seconds)

    case "bars":
        let seconds = argValue("--seconds", default: 10)
        let fps = max(1, argValue("--fps", default: 10))
        guard hello.maxTileLen / (hello.panelW * 2) > 0 else {
            fail("device max_tile_len too small")
        }

        try dev.controlWrite(.reset)

        var seq: UInt16 = 0
        var sentBytes = 0
        let start = Date()
        var lastReport = start

        while Date().timeIntervalSince(start) < Double(seconds) {
            let frameStart = Date()
            let px = renderColorBars(
                width: hello.panelW, height: hello.panelH, phase: Int(seq) * 4)
            sentBytes += try sendFrame(
                dev, hello, px: px, seq: seq, fullRefresh: seq == 0)
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

    default:
        fail(
            "unknown mode '\(mode)' — use hello | bars | image | mirror | display | backlight | sleep"
        )
    }
} catch {
    fail("\(error)")
}
