import Foundation

/// Classic 8-bar pattern, RGB565 host-order (little-endian memory layout ==
/// wire layout). `phase` rotates the bars so motion is visible on the panel.
public func renderColorBars(width: Int, height: Int, phase: Int) -> [UInt16] {
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

/// Which corner a calibration target marks, in the orientation the viewer sees
/// (panel coordinate (0,0) is the viewed top-left, since the firmware's mirror
/// settings already make images render the right way round).
public enum TargetCorner {
    case topLeft, topRight, bottomLeft

    public var label: String {
        switch self {
        case .topLeft: return "TOP-LEFT"
        case .topRight: return "TOP-RIGHT"
        case .bottomLeft: return "BOTTOM-LEFT"
        }
    }
}

/// A black frame with one bright square in `corner`, so calibration can ask for
/// a tap *there* instead of describing a corner of an unlit screen. Returned as
/// RGB565 in the panel's own layout.
public func calibrationTarget(
    width: Int, height: Int, corner: TargetCorner, box: Int = 72
) -> [UInt16] {
    var px = [UInt16](repeating: 0, count: max(0, width * height))
    guard width > 0, height > 0 else { return px }
    let side = min(box, min(width, height))
    let x0: Int
    let y0: Int
    switch corner {
    case .topLeft: (x0, y0) = (0, 0)
    case .topRight: (x0, y0) = (width - side, 0)
    case .bottomLeft: (x0, y0) = (0, height - side)
    }
    /* White, with a darker inner square so the centre to aim at is obvious. */
    let white: UInt16 = 0xFFFF
    let inner: UInt16 = 0xF800 /* red */
    for y in y0..<(y0 + side) {
        for x in x0..<(x0 + side) {
            let edge = min(min(x - x0, y - y0), min(x0 + side - 1 - x, y0 + side - 1 - y))
            px[y * width + x] = edge < side / 4 ? white : inner
        }
    }
    return px
}
