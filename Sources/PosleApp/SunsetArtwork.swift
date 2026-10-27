import AppKit

/// Monochrome form of the sunset app icon for the macOS menu bar.
enum SunsetArtwork {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.labelColor.setFill()
            let sun = NSBezierPath()
            sun.move(to: NSPoint(x: 2, y: 8.5))
            sun.curve(to: NSPoint(x: 9, y: 1.5), controlPoint1: NSPoint(x: 2, y: 4.63), controlPoint2: NSPoint(x: 5.13, y: 1.5))
            sun.curve(to: NSPoint(x: 16, y: 8.5), controlPoint1: NSPoint(x: 12.87, y: 1.5), controlPoint2: NSPoint(x: 16, y: 4.63))
            sun.close(); sun.fill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 10.5, width: 14, height: 1.9), xRadius: 0.95, yRadius: 0.95).fill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 14.3, width: 8.9, height: 1.9), xRadius: 0.95, yRadius: 0.95).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "После"
        return image
    }
}
