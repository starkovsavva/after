import AppKit
import Foundation

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
        let s = CGFloat(pixels)
        NSColor(red: 0.31, green: 0.29, blue: 0.76, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88), xRadius: s * 0.20, yRadius: s * 0.20).fill()
        let heights: [CGFloat] = [0.20, 0.36, 0.54, 0.31, 0.46, 0.25, 0.14]
        for (i, height) in heights.enumerated() {
            NSColor.white.withAlphaComponent(i > 4 ? 0.65 : 1).setFill()
            let w = s * 0.045
            let x = s * (0.27 + CGFloat(i) * 0.075)
            NSBezierPath(roundedRect: NSRect(x: x, y: s * (0.5 - height / 2), width: w, height: s * height), xRadius: w / 2, yRadius: w / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
