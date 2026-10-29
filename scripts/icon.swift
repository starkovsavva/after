import AppKit
import Foundation

// The approved After a. mark, in fixed outlines. Match packaging/Logo.svg and
// BrandArtwork.swift; no installed font or network resource is needed.
// The 50 pt inset keeps the normal macOS Dock footprint and transparent corners.
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

func letterPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 211.282, y: 162))
    path.addCurve(to: CGPoint(x: 299.077, y: 214.038), control1: CGPoint(x: 246.949, y: 162), control2: CGPoint(x: 297.705, y: 172.955))
    path.addLine(to: CGPoint(x: 299.077, y: 323.592))
    path.addCurve(to: CGPoint(x: 330.628, y: 340.025), control1: CGPoint(x: 299.077, y: 346.873), control2: CGPoint(x: 312.795, y: 353.72))
    path.addLine(to: CGPoint(x: 327.885, y: 360.567))
    path.addCurve(to: CGPoint(x: 241.462, y: 349.611), control1: CGPoint(x: 297.705, y: 383.847), control2: CGPoint(x: 252.436, y: 375.631))
    path.addCurve(to: CGPoint(x: 144.064, y: 361.936), control1: CGPoint(x: 208.538, y: 375.631), control2: CGPoint(x: 170.128, y: 381.108))
    path.addCurve(to: CGPoint(x: 126.231, y: 285.248), control1: CGPoint(x: 113.885, y: 345.503), control2: CGPoint(x: 111.141, y: 309.898))
    path.addCurve(to: CGPoint(x: 240.09, y: 238.688), control1: CGPoint(x: 149.551, y: 257.86), control2: CGPoint(x: 201.679, y: 253.752))
    path.addLine(to: CGPoint(x: 240.09, y: 214.038))
    path.addCurve(to: CGPoint(x: 203.051, y: 179.803), control1: CGPoint(x: 240.09, y: 188.019), control2: CGPoint(x: 222.256, y: 178.433))
    path.addCurve(to: CGPoint(x: 183.846, y: 197.605), control1: CGPoint(x: 189.333, y: 178.433), control2: CGPoint(x: 182.474, y: 186.65))
    path.addCurve(to: CGPoint(x: 187.962, y: 226.363), control1: CGPoint(x: 185.218, y: 208.561), control2: CGPoint(x: 192.077, y: 215.408))
    path.addCurve(to: CGPoint(x: 138.577, y: 231.841), control1: CGPoint(x: 182.474, y: 245.535), control2: CGPoint(x: 155.038, y: 244.166))
    path.addCurve(to: CGPoint(x: 141.321, y: 185.28), control1: CGPoint(x: 118, y: 218.146), control2: CGPoint(x: 126.231, y: 197.605))
    path.addCurve(to: CGPoint(x: 211.282, y: 162), control1: CGPoint(x: 160.526, y: 168.847), control2: CGPoint(x: 185.218, y: 162))
    path.closeSubpath()
    path.move(to: CGPoint(x: 241.462, y: 257.86))
    path.addCurve(to: CGPoint(x: 176.987, y: 316.745), control1: CGPoint(x: 201.679, y: 268.815), control2: CGPoint(x: 175.615, y: 286.618))
    path.addCurve(to: CGPoint(x: 204.423, y: 342.764), control1: CGPoint(x: 176.987, y: 335.917), control2: CGPoint(x: 187.962, y: 342.764))
    path.addCurve(to: CGPoint(x: 241.462, y: 327.701), control1: CGPoint(x: 219.513, y: 344.134), control2: CGPoint(x: 231.859, y: 337.287))
    path.closeSubpath()
    return path
}

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
                 to: CGPoint(x: 462, y: 462), colours: [0xFFFFFF, 0xF7F8FA])
        context.addPath(tile)
        context.setStrokeColor(colour(0x313538, alpha: 0.07))
        context.setLineWidth(1)
        context.strokePath()
        context.addPath(letterPath())
        context.setFillColor(colour(0x313538))
        context.drawPath(using: .eoFill)
        context.setFillColor(colour(0x476D90))
        context.fillEllipse(in: CGRect(x: 341.5, y: 304, width: 69, height: 69))
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        // The context writes sRGB components directly. Retag the bitmap instead
        // of converting those components from the initializer's device RGB space.
        let srgbBitmap = bitmap.retagging(with: NSColorSpace.sRGB)!
        try srgbBitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
