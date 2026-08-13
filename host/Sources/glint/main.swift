import GlintCore
import ApplicationServices
import CoreGraphics
import Foundation

// glint — host CLI. Every mode starts with the HELLO handshake and adapts to
// the panel geometry the device reports.
//
// A panel is found on its own: USB when a cable is in, otherwise the first
// panel answering on the network. `--net <host>` names one, `--net` alone means
// wireless only, `--usb` the reverse, `--list` shows everything reachable.
//
//   glint hello                                      probe + print handshake
//   glint bars [--seconds N] [--fps N]               M0 transport test
//   glint image <path> [--fill] [--landscape]        M1 static image
//   glint mirror [--fps N] [--landscape]             M2 mirror the main display
//   glint display [--portrait] [--width W --height H --1x]   auto: USB, else Wi-Fi
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

/* Under launchd stdout is a file (/tmp/glint.log), and full buffering would
 * hold progress lines — "waiting for a panel…", the handshake summary — until
 * the buffer filled or the process exited. Line buffering costs nothing at this
 * print volume and makes the log readable while a session runs. */
setvbuf(stdout, nil, _IOLBF, 0)

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
    try await holdSession(session, seconds: seconds)
}

/// Keeps a started session running: for `seconds`, or until Ctrl-C.
func holdSession(_ session: MirrorSession, seconds: Int) async throws {
    if seconds > 0 {
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        await session.stop()
    } else {
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

let opts = Options(CommandLine.arguments)
let mode = opts.mode

/* Runs before any device is opened: it reports on a missing panel rather than
 * failing on one. */
if mode == "doctor" {
    runDoctor()
}

/* Every panel reachable right now, on either transport. With more than one
 * attached the firmware's fixed serial number cannot distinguish them, so list
 * bus/address and let the caller pick with --dev. */
if opts.list {
    let usb = (try? USBDevice.list(vid: Glint.vid, pid: Glint.pid)) ?? []
    for (i, d) in usb.enumerated() {
        print("USB      --dev \(i): \(d.description)")
    }
    /* Every candidate is probed, so a stale mDNS registration is not offered as
     * something to connect to and a panel in use says so rather than looking
     * absent. */
    let net = probePanels()
    for p in net {
        print(
            "network  --net \(p.host)"
                + (p.status == .busy ? "   (in use by another session)" : ""))
    }
    if usb.isEmpty && net.isEmpty {
        print("no panels found on USB or on the network")
    }
    exit(0)
}

/// Long-running modes wait for the panel; one-shot commands fail fast.
let sessionModes: Set<String> = ["display", "mirror", "touch", "stats"]
let waitForDevice =
    sessionModes.contains(mode) && !opts.noWait

/* Where to look for a panel. The default is "wherever it is": USB when a cable
 * is in, otherwise the first panel answering on the network. `--net <host>`
 * names one explicitly, `--net` alone means wireless-only, `--usb` the reverse.
 * Everything above the Link protocol is identical either way. */
func linkChoice(_ opts: Options) -> LinkChoice {
    if opts.usbOnly { return .usbOnly }
    switch opts.netHost {
    case nil: return .auto
    case "auto": return .netOnly
    case let host?: return .host(host)
    }
}

do {
    let dev = try openPanel(
        linkChoice(opts), wait: waitForDevice, devIndex: opts.devIndex,
        serial: opts.serial, port: UInt16(opts.port))
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
        guard let raw = opts.positional.first, let v = UInt16(raw), v <= 255
        else { fail("usage: glint backlight <0-255>") }
        try dev.control(.backlight, value: v)

    case "bootloader":
        /* Removes the BOOT-button dance on boards with no UART bridge. */
        try dev.control(.bootloader, value: 0)
        print("device rebooting into its download loader — flash now")

    case "sleep":
        guard let raw = opts.positional.first, let v = UInt16(raw), v <= 1
        else { fail("usage: glint sleep <0|1>") }
        try dev.control(.sleep, value: v)

    case "image":
        guard let path = opts.positional.first else {
            fail("usage: glint image <path> [--fill] [--landscape]")
        }
        let mode: FitMode = opts.fill ? .fill : .fit
        let landscape = opts.landscape
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
        try await runDisplay(dev: dev, hello: hello, opts: opts)

    case "mirror":
        let session = MirrorSession(
            dev: dev, hello: hello, landscape: opts.landscape,
            fullFrames: opts.full)
        /* Drain STATS so dropped tiles still trigger a resync here too. */
        let reader = TouchReader(
            dev: dev, hello: hello, mapping: TouchMapping(),
            bounds: nil, raw: false, onDrops: { session.resync() })
        Thread { reader.run() }.start()
        try await runSession(
            session, fps: opts.frameRate(default: 12), seconds: opts.seconds)

    case "touch":
        if opts.calibrate {
            calibrateTouch(dev: dev, hello: hello)
            exit(0)
        }
        /* Raw mode: prints panel coords so the mapping can be checked by eye. */
        let reader = TouchReader(
            dev: dev, hello: hello,
            mapping: opts.mapping, bounds: nil, raw: true)
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
                /* Suspends rather than blocking the thread: this loop is async,
                 * and Thread.sleep here is an error under Swift 6. */
                try? await Task.sleep(
                    nanoseconds: UInt64((budget - frameTime) * 1_000_000_000))
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
