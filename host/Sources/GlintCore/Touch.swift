import Foundation

/// How panel coordinates map onto the display's own axes.
///
/// Which combination is right depends on how the touch glass is wired relative
/// to the panel's scan direction — three stacked transforms that are measured,
/// not reasoned about. It lives here, away from the CLI, because the arithmetic
/// is the part that has actually been got wrong: reading corners by hand and
/// deciding "the axes look swapped" is exactly the mistake `deriveMapping`
/// exists to prevent.
public struct TouchMapping: Equatable {
    public var swapXY: Bool
    public var flipX: Bool
    public var flipY: Bool

    public init(swapXY: Bool = false, flipX: Bool = false, flipY: Bool = false) {
        self.swapXY = swapXY
        self.flipX = flipX
        self.flipY = flipY
    }

    public static func parse(_ args: [String]) -> TouchMapping {
        TouchMapping(
            swapXY: args.contains("--tp-swap"),
            flipX: args.contains("--tp-flip-x"),
            flipY: args.contains("--tp-flip-y"))
    }

    /// The flags that reproduce this mapping, in the order the CLI takes them.
    public var flags: [String] {
        var out: [String] = []
        if swapXY { out.append("--tp-swap") }
        if flipX { out.append("--tp-flip-x") }
        if flipY { out.append("--tp-flip-y") }
        return out
    }

    /// Panel coords → a unit position on the display, honouring the mapping.
    public func unit(x: Int, y: Int, panelW: Int, panelH: Int)
        -> (u: Double, v: Double)
    {
        var u = Double(x) / Double(max(1, panelW - 1))
        var v = Double(y) / Double(max(1, panelH - 1))
        if swapXY { swap(&u, &v) }
        if flipX { u = 1 - u }
        if flipY { v = 1 - v }
        return (u, v)
    }
}

/// Derives the mapping from three taps, given in panel coordinates: the
/// top-left, top-right and bottom-left of the display as the viewer sees it.
///
/// Only the *relationships* matter, never the absolute values — a finger cannot
/// reach the true corner of a panel with rounded glass, and on the 1.75" AMOLED
/// the corner taps land around 25%/76% of the way across. Comparing which axis
/// moved, and in which direction, is immune to that.
public func deriveMapping(
    topLeft tl: (x: Int, y: Int),
    topRight tr: (x: Int, y: Int),
    bottomLeft bl: (x: Int, y: Int)
) -> TouchMapping {
    /* Whichever panel axis changes as the finger moves right is the axis
     * carrying the display's X — that alone settles swapXY. */
    let rightDx = abs(tr.x - tl.x)
    let rightDy = abs(tr.y - tl.y)
    let swapXY = rightDy > rightDx

    return TouchMapping(
        swapXY: swapXY,
        flipX: swapXY ? (tr.y < tl.y) : (tr.x < tl.x),
        flipY: swapXY ? (bl.x < tl.x) : (bl.y < tl.y))
}
