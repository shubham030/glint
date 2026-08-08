import GlintCore
import CoreGraphics
import Foundation

/// M5: read touch events off the bulk IN pipe.
enum TouchEventType: UInt8 {
    case down = 1
    case move = 2
    case up = 3
    case hello = 4
    case stats = 5
}

struct TouchEvent {
    let type: TouchEventType
    let id: UInt8
    /// Panel-native coordinates for touch types; for STATS, `x` carries the
    /// dropped-tile count and `y` the resync count.
    let x: Int
    let y: Int

    init?(_ data: Data) {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
                | (UInt32(b[o + 3]) << 24)
        }
        guard u32(0) == Glint.magicEvt,
            let t = TouchEventType(rawValue: b[4])
        else { return nil }
        type = t
        id = b[5]
        x = Int(u16(6))
        y = Int(u16(8))
    }
}

/// How panel coordinates map onto the display's own axes. Which combination is
/// right depends on how the touch glass is wired relative to the panel scan
/// direction, so it is calibrated by tapping known corners, not derived.
struct TouchMapping {
    var swapXY = false
    var flipX = false
    var flipY = false

    static func parse(_ args: [String]) -> TouchMapping {
        TouchMapping(
            swapXY: args.contains("--tp-swap"),
            flipX: args.contains("--tp-flip-x"),
            flipY: args.contains("--tp-flip-y"))
    }

    /// Panel coords → a unit position on the display, honouring the mapping.
    func unit(x: Int, y: Int, panelW: Int, panelH: Int) -> (u: Double, v: Double)
    {
        var u = Double(x) / Double(max(1, panelW - 1))
        var v = Double(y) / Double(max(1, panelH - 1))
        if swapXY { swap(&u, &v) }
        if flipX { u = 1 - u }
        if flipY { v = 1 - v }
        return (u, v)
    }
}

/// Drains touch events and either prints them (calibration) or posts synthetic
/// mouse events onto the target display.
final class TouchReader {
    private let dev: USBDevice
    private let hello: Hello
    private let mapping: TouchMapping
    private let bounds: CGRect?
    private let raw: Bool
    private let onDrops: (() -> Void)?
    private var dragging = false
    private var lastDrops = 0

    init(
        dev: USBDevice, hello: Hello, mapping: TouchMapping,
        bounds: CGRect?, raw: Bool, onDrops: (() -> Void)? = nil
    ) {
        self.dev = dev
        self.hello = hello
        self.mapping = mapping
        self.bounds = bounds
        self.raw = raw
        self.onDrops = onDrops
    }

    /// Blocking loop; returns when the device goes away.
    func run() {
        /* Read a whole max packet, not one event: TinyUSB can coalesce several
         * 12-byte events into a single packet, and a short read would fail with
         * OVERFLOW and lose them. */
        while true {
            let data: Data
            do {
                data = try dev.bulkRead(length: 512, timeoutMs: 500)
            } catch let error as USBError where error.isDisconnect {
                FileHandle.standardError.write(
                    Data("glint: event pipe closed (panel gone)\n".utf8))
                return
            } catch {
                /* Transient: back off rather than spin a core on the error. */
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            var offset = 0
            while offset + 12 <= data.count {
                if let evt = TouchEvent(data.subdata(in: offset..<(offset + 12)))
                {
                    handle(evt)
                }
                offset += 12
            }
        }
    }

    private func handle(_ evt: TouchEvent) {
        if evt.type == .stats {
            /* The device drops tiles when its queue overruns, so the panel no
             * longer matches our hash table — force a full refresh. */
            if evt.x > lastDrops {
                lastDrops = evt.x
                onDrops?()
            }
            if raw {
                print("STATS dropped=\(evt.x) resyncs=\(evt.y)")
            }
            return
        }

        if raw {
            print("\(evt.type) id=\(evt.id) panel=(\(evt.x),\(evt.y))")
            return
        }
        post(evt)
    }

    private func post(_ evt: TouchEvent) {
        guard evt.id == 0, let bounds else { return } /* single-touch → mouse */

        let (u, v) = mapping.unit(
            x: evt.x, y: evt.y, panelW: hello.panelW, panelH: hello.panelH)
        let pt = CGPoint(
            x: bounds.origin.x + u * bounds.width,
            y: bounds.origin.y + v * bounds.height)

        switch evt.type {
        case .down:
            dragging = true
            CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: pt, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        case .move:
            CGEvent(
                mouseEventSource: nil,
                mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                mouseCursorPosition: pt, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        case .up:
            dragging = false
            CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: pt, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        default:
            break
        }
    }
}
