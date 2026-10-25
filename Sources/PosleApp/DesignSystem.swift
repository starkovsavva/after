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
    static let soft = Color.primary.opacity(0.045)
    static let field = Color(nsColor: .textBackgroundColor)
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
    static let controlStrong = Font.system(size: 13, weight: .semibold)
    static let captionStrong = Font.system(size: 12, weight: .medium)
    static let bodyStrong = Font.system(size: 14, weight: .semibold)
    static let heading = Font.system(size: 17, weight: .semibold)
    static let sectionTitle = Font.system(size: 20, weight: .semibold)
    static let pageTitle = Font.system(size: 26, weight: .semibold)
    static let modalTitle = Font.system(size: 20, weight: .semibold)
    static let emptyTitle = Font.system(size: 20, weight: .medium)
    static let cardFront = Font.system(size: 26, weight: .medium)
    static let cardAnswer = Font.system(size: 17)
}

/// Layout values shared by every workspace and sheet. Content changes never
/// change the size of the app chrome or the typography of adjacent controls.
enum AppLayout {
    static let contentInset: CGFloat = 24
    static let readableWidth: CGFloat = 780
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
