import Foundation
import GlintCore

/// Derives the touch mapping by asking for taps in a known order and looking at
/// which panel axis moved. This exists because the mapping depends on how the
/// touch glass is wired relative to the panel's scan direction — three stacked
/// transforms that are far easier to measure than to reason about.
func calibrateTouch(dev: USBDevice, hello: Hello, landscape: Bool) {
    let corners = [
        "TOP-LEFT", "TOP-RIGHT", "BOTTOM-LEFT",
    ]
    var taps: [(x: Int, y: Int)] = []

    print("""
        Calibration: as you are looking at the panel \
        (\(landscape ? "landscape" : "portrait")), tap and release each corner \
        when prompted. Ctrl-C to abort.
        """)

    for corner in corners {
        print("→ tap \(corner) …", terminator: " ")
        fflush(stdout)
        guard let tap = waitForTap(dev: dev) else {
            print("no tap seen; is the touch firmware flashed?")
            return
        }
        taps.append(tap)
        print("got panel=(\(tap.x),\(tap.y))")
    }

    let tl = taps[0], tr = taps[1], bl = taps[2]

    /* Whichever panel axis changes as the finger moves right is the axis that
     * carries the display's X — that alone settles swapXY. */
    let rightDx = abs(tr.x - tl.x), rightDy = abs(tr.y - tl.y)
    let swapXY = rightDy > rightDx

    let flipX = swapXY ? (tr.y < tl.y) : (tr.x < tl.x)
    let flipY = swapXY ? (bl.x < tl.x) : (bl.y < tl.y)

    var flags = [String]()
    if swapXY { flags.append("--tp-swap") }
    if flipX { flags.append("--tp-flip-x") }
    if flipY { flags.append("--tp-flip-y") }

    print("")
    print("mapping: swapXY=\(swapXY) flipX=\(flipX) flipY=\(flipY)")
    print(
        "run:     glint display --touch"
            + (flags.isEmpty ? "" : " " + flags.joined(separator: " ")))
    print("(add these flags to the display command; they are stable per board)")
}

/// Returns the coordinates of the next DOWN event, ignoring MOVE/UP/STATS.
private func waitForTap(dev: USBDevice, timeoutSec: Int = 60) -> (x: Int, y: Int)? {
    let deadline = Date().addingTimeInterval(Double(timeoutSec))
    while Date() < deadline {
        guard let data = try? dev.bulkRead(length: 12, timeoutMs: 500),
            data.count == 12, let evt = TouchEvent(data)
        else { continue }
        if evt.type == .down { return (evt.x, evt.y) }
    }
    return nil
}
