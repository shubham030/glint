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

    return renderRGB565(
        img: img, width: width, height: height, mode: mode,
        landscape: landscape)
}

/// Scale + optionally rotate a CGImage onto a width×height black canvas and
/// convert to RGB565 host-order. Shared by file loading and screen mirroring.
func renderRGB565(
    img: CGImage, width: Int, height: Int,
    mode: FitMode = .fit, landscape: Bool = false, vivid: Bool = false
) -> [UInt16]? {
    guard
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    /* TEMP: pre-mirror panel X to compensate the ST7796's mirrored scan.
     * The real fix (esp_lcd_panel_mirror, mapcast parity) is committed in
     * firmware but unflashed — needs the UART cable. Remove after flashing. */
    ctx.translateBy(x: CGFloat(width), y: 0)
    ctx.scaleBy(x: -1, y: 1)

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
    if vivid {
        /* Saturation ×1.3 and contrast ×1.1 in integer math — compensates
         * the panel's flat generic gamma until the firmware-side init table
         * can be tuned. */
        for i in 0..<(width * height) {
            let ir = Int(bytes[i * 4])
            let ig = Int(bytes[i * 4 + 1])
            let ib = Int(bytes[i * 4 + 2])
            let avg = (ir + ig + ib) / 3
            func boost(_ c: Int) -> UInt16 {
                var v = avg + (c - avg) * 13 / 10
                v = 128 + (v - 128) * 11 / 10
                return UInt16(min(255, max(0, v)))
            }
            let r = boost(ir)
            let g = boost(ig)
            let b = boost(ib)
            px[i] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        }
    } else {
        for i in 0..<(width * height) {
            let r = UInt16(bytes[i * 4])
            let g = UInt16(bytes[i * 4 + 1])
            let b = UInt16(bytes[i * 4 + 2])
            px[i] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        }
    }
    return px
}
