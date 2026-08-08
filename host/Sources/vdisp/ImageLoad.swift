import CoreGraphics
import Foundation
import ImageIO

enum FitMode {
    case fit /* letterbox onto black */
    case fill /* cover the canvas, cropping overflow */
}

/// Decode any ImageIO-supported file (PNG/JPEG/HEIC/…), EXIF orientation
/// applied, scaled onto a width×height canvas, returned as RGB565 host-order.
/// `landscape` rotates the content 90° clockwise for a sideways-mounted panel.
func loadImageRGB565(
    path: String, width: Int, height: Int,
    mode: FitMode = .fit, landscape: Bool = false
) -> [UInt16]? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }

    /* Thumbnail-with-transform applies EXIF orientation and downsamples. */
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height) * 2,
    ]
    guard
        let img = CGImageSourceCreateThumbnailAtIndex(
            src, 0, opts as CFDictionary)
    else { return nil }

    guard
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    /* Logical drawing space: the panel as the viewer holds it. */
    var spaceW = width
    var spaceH = height
    if landscape {
        ctx.translateBy(x: CGFloat(width), y: 0)
        ctx.rotate(by: .pi / 2)
        spaceW = height
        spaceH = width
    }

    let sx = Double(spaceW) / Double(img.width)
    let sy = Double(spaceH) / Double(img.height)
    let scale = mode == .fit ? min(sx, sy) : max(sx, sy)
    let w = Double(img.width) * scale
    let h = Double(img.height) * scale
    ctx.draw(
        img,
        in: CGRect(
            x: (Double(spaceW) - w) / 2, y: (Double(spaceH) - h) / 2,
            width: w, height: h))

    guard let raw = ctx.data else { return nil }
    let bytes = raw.assumingMemoryBound(to: UInt8.self)

    var px = [UInt16](repeating: 0, count: width * height)
    for i in 0..<(width * height) {
        let r = UInt16(bytes[i * 4])
        let g = UInt16(bytes[i * 4 + 1])
        let b = UInt16(bytes[i * 4 + 2])
        px[i] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    }
    return px
}
