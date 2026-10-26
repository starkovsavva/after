import AppKit
import Foundation

// «Закат»: an apricot sun above two lines of notes. Geometry, gradients and
// colours mirror packaging/Logo.svg. The 50 pt inset gives the icon the same
// optical footprint as macOS app icons, with transparency outside the tile.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/icon.swift <output.iconset>\n", stderr)
    exit(1)
}
let output = CommandLine.arguments[1]
let sizes = [16, 32, 128, 256, 512]
let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colourSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ context: CGContext, path: CGPath, from: CGPoint, to: CGPoint,
              colours: [UInt32]) {
    let fill = CGGradient(colorsSpace: colourSpace,
                          colors: colours.map { colour($0) } as CFArray,
                          locations: [0, 1])!
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(fill, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

let tile = CGMutablePath()
tile.move(to: CGPoint(x: 154, y: 50))
tile.addLine(to: CGPoint(x: 358, y: 50))
tile.addCurve(to: CGPoint(x: 462, y: 154),
              control1: CGPoint(x: 430, y: 50), control2: CGPoint(x: 462, y: 82))
tile.addLine(to: CGPoint(x: 462, y: 358))
tile.addCurve(to: CGPoint(x: 358, y: 462),
              control1: CGPoint(x: 462, y: 430), control2: CGPoint(x: 430, y: 462))
tile.addLine(to: CGPoint(x: 154, y: 462))
tile.addCurve(to: CGPoint(x: 50, y: 358),
              control1: CGPoint(x: 82, y: 462), control2: CGPoint(x: 50, y: 430))
tile.addLine(to: CGPoint(x: 50, y: 154))
tile.addCurve(to: CGPoint(x: 154, y: 50),
              control1: CGPoint(x: 50, y: 82), control2: CGPoint(x: 82, y: 50))
tile.closeSubpath()

let sun = CGMutablePath()
sun.move(to: CGPoint(x: 128, y: 261))
sun.addCurve(to: CGPoint(x: 124, y: 257),
             control1: CGPoint(x: 125.8, y: 261), control2: CGPoint(x: 124, y: 259.2))
sun.addCurve(to: CGPoint(x: 256, y: 129),
             control1: CGPoint(x: 126.1, y: 185.9), control2: CGPoint(x: 184.3, y: 129))
sun.addCurve(to: CGPoint(x: 388, y: 257),
             control1: CGPoint(x: 327.7, y: 129), control2: CGPoint(x: 385.9, y: 185.9))
sun.addCurve(to: CGPoint(x: 384, y: 261),
             control1: CGPoint(x: 388, y: 259.2), control2: CGPoint(x: 386.2, y: 261))
sun.closeSubpath()

try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = CGContext(data: bitmap.bitmapData, width: pixels, height: pixels,
                                bitsPerComponent: 8, bytesPerRow: bitmap.bytesPerRow,
                                space: colourSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
        context.translateBy(x: 0, y: 512)
        context.scaleBy(x: 1, y: -1)
        gradient(context, path: tile, from: CGPoint(x: 50, y: 50),
                 to: CGPoint(x: 462, y: 462), colours: [0x383A3C, 0x292B2D])
        context.addPath(tile)
        context.setStrokeColor(colour(0xFFFFFF, alpha: 0.08))
        context.setLineWidth(1)
        context.strokePath()
        gradient(context, path: sun, from: CGPoint(x: 256, y: 129),
                 to: CGPoint(x: 256, y: 261), colours: [0xF3BE87, 0xE8A974])
        for line in [CGRect(x: 124, y: 287, width: 264, height: 32),
                     CGRect(x: 124, y: 341, width: 168, height: 32)] {
            let path = CGPath(roundedRect: line, cornerWidth: 16, cornerHeight: 16, transform: nil)
            gradient(context, path: path, from: CGPoint(x: 256, y: 287),
                     to: CGPoint(x: 256, y: 373), colours: [0xF4F2EB, 0xE8E5DD])
        }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        // The context writes sRGB components directly. Retag the bitmap instead
        // of converting those components from the initializer's device RGB space.
        let srgbBitmap = bitmap.retagging(with: NSColorSpace.sRGB)!
        try srgbBitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
