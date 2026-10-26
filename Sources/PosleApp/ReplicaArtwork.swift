import AppKit

/// Template version of the selected «Реплика» artwork for the macOS menu bar.
enum ReplicaArtwork {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let factor: CGFloat = 16 / 272
            var transform = AffineTransform(translationByX: (18 - 248 * factor) / 2, byY: 1)
            transform.scale(x: factor, y: factor)
            transform.translate(x: -132, y: -120)
            (transform as NSAffineTransform).concat()
            NSColor.labelColor.setFill()
            let a = NSBezierPath()
            a.move(to: NSPoint(x: 132, y: 206))
            a.curve(to: NSPoint(x: 218, y: 120), controlPoint1: NSPoint(x: 132, y: 158), controlPoint2: NSPoint(x: 170, y: 120))
            a.line(to: NSPoint(x: 350, y: 120)); a.line(to: NSPoint(x: 350, y: 180)); a.line(to: NSPoint(x: 222, y: 180))
            a.curve(to: NSPoint(x: 192, y: 210), controlPoint1: NSPoint(x: 205, y: 180), controlPoint2: NSPoint(x: 192, y: 193))
            a.line(to: NSPoint(x: 192, y: 264)); a.line(to: NSPoint(x: 132, y: 264)); a.close(); a.fill()
            let b = NSBezierPath()
            b.move(to: NSPoint(x: 380, y: 306))
            b.curve(to: NSPoint(x: 294, y: 392), controlPoint1: NSPoint(x: 380, y: 354), controlPoint2: NSPoint(x: 342, y: 392))
            b.line(to: NSPoint(x: 162, y: 392)); b.line(to: NSPoint(x: 162, y: 332)); b.line(to: NSPoint(x: 290, y: 332))
            b.curve(to: NSPoint(x: 320, y: 302), controlPoint1: NSPoint(x: 307, y: 332), controlPoint2: NSPoint(x: 320, y: 319))
            b.line(to: NSPoint(x: 320, y: 248)); b.line(to: NSPoint(x: 380, y: 248)); b.close(); b.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "После"
        return image
    }
}
