import Foundation

/// Classic 8-bar pattern, RGB565 host-order (little-endian memory layout ==
/// wire layout). `phase` rotates the bars so motion is visible on the panel.
func renderColorBars(width: Int, height: Int, phase: Int) -> [UInt16] {
    let bars: [(UInt8, UInt8, UInt8)] = [
        (255, 255, 255), // white
        (255, 255, 0), // yellow
        (0, 255, 255), // cyan
        (0, 255, 0), // green
        (255, 0, 255), // magenta
        (255, 0, 0), // red
        (0, 0, 255), // blue
        (0, 0, 0), // black
    ]
    let colors = bars.map { r, g, b -> UInt16 in
        (UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3)
    }

    var px = [UInt16](repeating: 0, count: width * height)
    let barWidth = max(1, width / colors.count)
    for y in 0..<height {
        for x in 0..<width {
            let bar = (((x + phase) / barWidth) % colors.count + colors.count)
                % colors.count
            px[y * width + x] = colors[bar]
        }
    }
    return px
}
