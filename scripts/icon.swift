import AppKit
import Foundation

// «Реплика»: two complementary turns in a conversation. This is the same
// vector geometry as packaging/Logo.svg, rendered directly at every icon size.
let output = CommandLine.arguments[1]
let sizes = [16, 32, 128, 256, 512]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(translationByX: 0, byY: CGFloat(pixels))
        var geometry = transform
        geometry.scale(x: CGFloat(pixels) / 512, y: -CGFloat(pixels) / 512)
        (geometry as NSAffineTransform).concat()
        NSColor(srgbRed: 41 / 255, green: 43 / 255, blue: 46 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 496, height: 496), xRadius: 110, yRadius: 110).fill()
        NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 241 / 255, alpha: 1).setFill()
        let upper = NSBezierPath()
        upper.move(to: NSPoint(x: 132, y: 206))
        upper.curve(to: NSPoint(x: 218, y: 120), controlPoint1: NSPoint(x: 132, y: 158), controlPoint2: NSPoint(x: 170, y: 120))
        upper.line(to: NSPoint(x: 350, y: 120)); upper.line(to: NSPoint(x: 350, y: 180))
        upper.line(to: NSPoint(x: 222, y: 180))
        upper.curve(to: NSPoint(x: 192, y: 210), controlPoint1: NSPoint(x: 205, y: 180), controlPoint2: NSPoint(x: 192, y: 193))
        upper.line(to: NSPoint(x: 192, y: 264)); upper.line(to: NSPoint(x: 132, y: 264)); upper.close(); upper.fill()
        let lower = NSBezierPath()
        lower.move(to: NSPoint(x: 380, y: 306))
        lower.curve(to: NSPoint(x: 294, y: 392), controlPoint1: NSPoint(x: 380, y: 354), controlPoint2: NSPoint(x: 342, y: 392))
        lower.line(to: NSPoint(x: 162, y: 392)); lower.line(to: NSPoint(x: 162, y: 332))
        lower.line(to: NSPoint(x: 290, y: 332))
        lower.curve(to: NSPoint(x: 320, y: 302), controlPoint1: NSPoint(x: 307, y: 332), controlPoint2: NSPoint(x: 320, y: 319))
        lower.line(to: NSPoint(x: 320, y: 248)); lower.line(to: NSPoint(x: 380, y: 248)); lower.close(); lower.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
