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

/// Drains touch events and either prints them (calibration) or posts synthetic
/// mouse events onto the target display.
final class TouchReader {
    private let dev: Link
    private let hello: Hello
    private let mapping: TouchMapping
    private let bounds: CGRect?
    private let raw: Bool
    private let onDrops: (() -> Void)?
    private var dragging = false
    /// Negative until the first STATS report arrives.
    private var lastLosses = -1
    private var lastResyncs = -1

    init(
        dev: Link, hello: Hello, mapping: TouchMapping,
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
                data = try dev.readEvents(timeoutMs: 500)
            } catch let error where isLinkGone(error) {
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
            /* Either counter moving means a tile never reached the panel — a
             * resync is the device discarding bytes or rejecting a header, not
             * just bookkeeping — so the panel no longer matches the sender's
             * hash table.
             * Movement in any direction counts: a counter going backwards means
             * the device restarted its bookkeeping, which is equally divergent.
             * A first report with non-zero counters means losses happened
             * before this reader started watching. */
            let firstReport = lastLosses < 0
            let changed = evt.x != lastLosses || evt.y != lastResyncs
            let lostSomething = evt.x > 0 || evt.y > 0
            if firstReport ? lostSomething : changed {
                onDrops?()
            }
            lastLosses = evt.x
            lastResyncs = evt.y

            if raw {
                print("STATS losses=\(evt.x) resyncs=\(evt.y)")
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
