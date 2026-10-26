import AppKit
import SwiftUI

/// Semantic colors resolve against the window appearance, including dark mode.
enum Ink {
    static var accent: Color { Color(nsColor: themedAccent(fill: false)) }
    static var actionFill: Color { Color(nsColor: themedAccent(fill: true)) }
    static let recordFill = Color(red: 0.72, green: 0.16, blue: 0.16)
    static let green = Color(nsColor: adaptive("success", light: (0.16, 0.43, 0.32), dark: (0.43, 0.80, 0.65)))
    static let warning = Color(nsColor: adaptive("warning", light: (0.57, 0.29, 0.04), dark: (1.0, 0.74, 0.39)))
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let soft = Color.primary.opacity(0.045)
    static let field = Color(nsColor: .textBackgroundColor)
    static let secondaryText = Color(nsColor: adaptive("secondaryText", light: (0.4314, 0.4314, 0.4314), dark: (0.62, 0.62, 0.62)))
    static let line = Color.primary.opacity(0.08)
    static let selection = Color.primary.opacity(0.075)
    static let sidebar = Color(nsColor: NSColor(name: "posle.sidebar") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .underPageBackgroundColor : .windowBackgroundColor
    })

    private static func themedAccent(fill: Bool) -> NSColor {
        let palette = ThemeRuntime.shared.palette
        return NSColor(name: NSColor.Name("posle.\(fill ? "actionFill" : "accent").\(palette.accent)")) { appearance in
            ThemeRuntime.accessibleAccent(palette.color,
                dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, fill: fill)
        }
    }

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
    static var body: Font { .system(size: CGFloat(ThemeRuntime.shared.palette.textSize)) }
    static let controlStrong = Font.system(size: 13, weight: .semibold)
    static let captionStrong = Font.system(size: 12, weight: .medium)
    static var bodyStrong: Font { .system(size: CGFloat(ThemeRuntime.shared.palette.textSize), weight: .semibold) }
    static var heading: Font { .system(size: CGFloat(max(17, ThemeRuntime.shared.palette.textSize + 2)), weight: .semibold) }
    static var sectionTitle: Font { .system(size: CGFloat(max(20, ThemeRuntime.shared.palette.textSize + 4)), weight: .semibold) }
    static let pageTitle = Font.system(size: 25, weight: .semibold)
    static let modalTitle = Font.system(size: 20, weight: .semibold)
    static let emptyTitle = Font.system(size: 20, weight: .medium)
    static let cardFront = Font.system(size: 26, weight: .medium)
    static let cardAnswer = Font.system(size: 17)
}

/// Layout values shared by every workspace and sheet. Content changes never
/// change the size of the app chrome or the typography of adjacent controls.
enum AppLayout {
    static var contentInset: CGFloat { ThemeRuntime.shared.palette.density == "compact" ? 20 : 28 }
    static let readableWidth: CGFloat = 740
    static let toolbarHeight: CGFloat = 48
    static let statusHeight: CGFloat = 48
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
}

struct AppPageHeader: View {
    let title: String
    var subtitle: String = ""
    var compact = false
    var modal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(modal ? AppTypography.modalTitle : compact ? AppTypography.sectionTitle : AppTypography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(AppTypography.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppContentLayout: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: AppLayout.readableWidth, alignment: .leading)
            .padding(AppLayout.contentInset).frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    func appContentLayout() -> some View { modifier(AppContentLayout()) }
    /// Native controls use the same regular size and font in windows and sheets.
    func appControlDefaults() -> some View { font(AppTypography.control).controlSize(.regular) }
}
