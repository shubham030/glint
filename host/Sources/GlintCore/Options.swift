import Foundation

/// Every command-line flag, parsed once.
///
/// This exists because the CLI grew by reaching into the argument array
/// wherever a flag was needed — thirty-odd lookups spread across the file, with
/// nothing to check them against. A flag could be renamed in one place, or
/// documented and never read, and nothing would notice. Parsing in one place
/// makes the flag set inspectable and, more importantly, testable off-device.
///
/// Defaults that differ per mode (frame rate, mainly) stay `nil` here so each
/// mode can apply its own; this type reports what was *asked for*.
public struct Options {
    public let mode: String
    /// Positional arguments after the mode, e.g. an image path or a level.
    public let positional: [String]

    // Transport
    public let list: Bool
    public let usbOnly: Bool
    /// nil when --net was absent; "auto" when given without a host.
    public let netHost: String?
    public let port: Int
    public let devIndex: Int
    /// --serial glint-6204: names a panel by its own id rather than by position.
    public let serial: String?
    public let noWait: Bool

    // Geometry and appearance
    public let portrait: Bool
    public let landscape: Bool
    public let fill: Bool
    public let full: Bool
    public let flat: Bool
    public let oneX: Bool
    public let width: Int
    public let height: Int
    public let saturation: Int
    public let contrast: Int

    // Session
    public let fps: Int?
    public let seconds: Int
    public let touch: Bool
    public let calibrate: Bool
    public let mapping: TouchMapping

    public init(_ argv: [String]) {
        let args = Array(argv.dropFirst()) /* argv[0] is the binary */
        mode = args.first.map { $0.hasPrefix("-") ? "bars" : $0 } ?? "bars"
        positional = args.dropFirst().filter { !$0.hasPrefix("-") }

        func flag(_ name: String) -> Bool { args.contains(name) }
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else {
                return nil
            }
            let next = args[i + 1]
            return next.hasPrefix("--") ? nil : next
        }
        func int(_ name: String, _ fallback: Int) -> Int {
            value(name).flatMap(Int.init) ?? fallback
        }

        list = flag("--list")
        usbOnly = flag("--usb")
        /* --net with no host means "find one"; with a host it names that one. */
        netHost = flag("--net") ? (value("--net") ?? "auto") : nil
        port = int("--port", 7788)
        devIndex = int("--dev", 0)
        serial = value("--serial")
        noWait = flag("--no-wait")

        portrait = flag("--portrait")
        landscape = flag("--landscape")
        fill = flag("--fill")
        full = flag("--full")
        flat = flag("--flat")
        oneX = flag("--1x")
        width = int("--width", 0)
        height = int("--height", 0)
        saturation = flat ? 100 : int("--sat", 130)
        contrast = flat ? 100 : int("--con", 110)

        fps = value("--fps").flatMap(Int.init)
        seconds = int("--seconds", 0)
        touch = flag("--touch")
        calibrate = flag("--calibrate")
        mapping = TouchMapping.parse(args)
    }

    /// Frame rate for a mode, honouring --fps and never zero.
    public func frameRate(default fallback: Int) -> Int {
        max(1, fps ?? fallback)
    }

    /// The desktop the panel should show, in points, for a panel of this size.
    /// Landscape is the default because these panels are portrait-native and
    /// almost always mounted on their side.
    public func desktopSize(panelW: Int, panelH: Int) -> (w: Int, h: Int) {
        if width > 0 && height > 0 { return (width, height) }
        return portrait ? (panelW, panelH) : (panelH, panelW)
    }
}
