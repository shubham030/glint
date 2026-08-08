import CoreGraphics
import Foundation
import ImageIO

/// Decode any ImageIO-supported file (PNG/JPEG/HEIC/…), aspect-fit it onto a
/// black width×height canvas, and return RGB565 host-order pixels.
func loadImageRGB565(path: String, width: Int, height: Int) -> [UInt16]? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
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

    let scale = min(
        Double(width) / Double(img.width), Double(height) / Double(img.height))
    let w = Double(img.width) * scale
    let h = Double(img.height) * scale
    ctx.draw(
        img,
        in: CGRect(
            x: (Double(width) - w) / 2, y: (Double(height) - h) / 2,
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
