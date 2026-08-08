import Foundation

// vdisp — M0 host CLI. Handshake, then colour bars (or one-off commands).
//
//   vdisp hello
//   vdisp bars [--seconds N] [--fps N]
//   vdisp backlight <0-255>
//   vdisp sleep <0|1>

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("vdisp: " + msg + "\n").utf8))
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
        var flags: VD.TileFlags = []
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

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bars"

do {
    let dev = try USBDevice(vid: VD.vid, pid: VD.pid)
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
        else { fail("usage: vdisp backlight <0-255>") }
        try dev.controlWrite(.backlight, value: v)

    case "sleep":
        guard CommandLine.arguments.count > 2,
            let v = UInt16(CommandLine.arguments[2]), v <= 1
        else { fail("usage: vdisp sleep <0|1>") }
        try dev.controlWrite(.sleep, value: v)

    case "image":
        guard CommandLine.arguments.count > 2 else {
            fail("usage: vdisp image <path> [--fill] [--landscape]")
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

    case "mirror":
        let fps = max(1, argValue("--fps", default: 12))
        let seconds = argValue("--seconds", default: 0) /* 0 = until ^C */
        let landscape = CommandLine.arguments.contains("--landscape")
        let session = MirrorSession(
            dev: dev, hello: hello, landscape: landscape)
        try await session.start(fps: fps)
        if seconds > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(seconds) * 1_000_000_000)
            await session.stop()
        } else {
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

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
            "unknown mode '\(mode)' — use hello | bars | image | mirror | backlight | sleep"
        )
    }
} catch {
    fail("\(error)")
}
