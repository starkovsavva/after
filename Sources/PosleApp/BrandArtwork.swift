import AppKit

/// Approved After lettermark. Fixed outlines match packaging/Logo.svg and
/// scripts/icon.swift; the menu bar uses a monochrome template without a tile.
enum BrandArtwork {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: 1.5, y: 3.5)
            context.scaleBy(x: 15 / 292.5, y: 15 / 292.5)
            context.translateBy(x: -118, y: -162)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(letterPath())
            context.drawPath(using: .eoFill)
            context.fillEllipse(in: CGRect(x: 341.5, y: 304, width: 69, height: 69))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("After")
        return image
    }

    private static func letterPath() -> CGPath {
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

    // Also used by the browser handoff and its embedded favicon. The native
    // auth check compares these exact bytes with packaging/Logo.svg.
    static let svg = #"""
    <svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" role="img" aria-label="After — a.">
      <defs>
        <linearGradient id="tile" gradientUnits="userSpaceOnUse" x1="50" y1="50" x2="462" y2="462">
          <stop stop-color="#FFFFFF"/>
          <stop offset="1" stop-color="#F7F8FA"/>
        </linearGradient>
      </defs>
      <path d="M154 50 H358 C430 50 462 82 462 154 V358 C462 430 430 462 358 462 H154 C82 462 50 430 50 358 V154 C50 82 82 50 154 50 Z" fill="url(#tile)" stroke="#313538" stroke-opacity="0.07" stroke-width="1"/>
      <path d="M211.282 162 C246.949 162 297.705 172.955 299.077 214.038 L299.077 323.592 C299.077 346.873 312.795 353.72 330.628 340.025 L327.885 360.567 C297.705 383.847 252.436 375.631 241.462 349.611 C208.538 375.631 170.128 381.108 144.064 361.936 C113.885 345.503 111.141 309.898 126.231 285.248 C149.551 257.86 201.679 253.752 240.09 238.688 L240.09 214.038 C240.09 188.019 222.256 178.433 203.051 179.803 C189.333 178.433 182.474 186.65 183.846 197.605 C185.218 208.561 192.077 215.408 187.962 226.363 C182.474 245.535 155.038 244.166 138.577 231.841 C118 218.146 126.231 197.605 141.321 185.28 C160.526 168.847 185.218 162 211.282 162 Z M241.462 257.86 C201.679 268.815 175.615 286.618 176.987 316.745 C176.987 335.917 187.962 342.764 204.423 342.764 C219.513 344.134 231.859 337.287 241.462 327.701 Z" fill="#313538" fill-rule="evenodd"/>
      <circle cx="376" cy="338.5" r="34.5" fill="#476D90"/>
    </svg>
    """#
}
