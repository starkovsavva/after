import AppKit
import SwiftUI

/// Semantic colors resolve against the window appearance, including dark mode.
enum Ink {
    static let accent = Color(nsColor: adaptive("accent", light: (0.31, 0.29, 0.76), dark: (0.69, 0.67, 1.0)))
    static let actionFill = Color(nsColor: adaptive("actionFill", light: (0.31, 0.29, 0.76), dark: (0.43, 0.40, 0.79)))
    static let recordFill = Color(red: 0.72, green: 0.16, blue: 0.16)
    static let green = Color(nsColor: adaptive("success", light: (0.16, 0.43, 0.32), dark: (0.43, 0.80, 0.65)))
    static let warning = Color(nsColor: adaptive("warning", light: (0.57, 0.29, 0.04), dark: (1.0, 0.74, 0.39)))
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let soft = Color.primary.opacity(0.055)
    static let line = Color.primary.opacity(0.10)

    private static func adaptive(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: NSColor.Name("posle.\(name)")) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}

enum AppTypography {
    static let caption = Font.system(size: 12)
    static let control = Font.system(size: 13)
    static let body = Font.system(size: 14)
    static let heading = Font.system(size: 17, weight: .semibold, design: .rounded)
}
