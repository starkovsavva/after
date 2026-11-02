import SwiftUI

/// Decorates the original TextField so its native editor, accessibility,
/// caller-owned focus binding and keyboard handlers remain in place.
struct AfterSearchFieldStyle: TextFieldStyle {
    var showsIcon = true
    var isFocused: Bool? = nil

    func _body(configuration: TextField<Self._Label>) -> some View {
        HStack(spacing: 8) {
            if showsIcon {
                Image(systemName: "magnifyingglass")
                    .font(AppTypography.control).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            configuration.textFieldStyle(.plain).font(AppTypography.control)
                .frame(maxWidth: .infinity)
        }
        .afterSearchFieldSurface(isFocused: isFocused)
    }
}

private struct AfterSearchFieldSurface: ViewModifier {
    let isFocused: Bool?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    private var highlighted: Bool { isEnabled && isFocused == true }
    private var border: Color {
        if highlighted { return Ink.accent.opacity(contrast == .increased ? 1 : 0.7) }
        return contrast == .increased ? Color.primary.opacity(0.32) : Ink.line
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.controlRadius)
                    .strokeBorder(border, lineWidth: highlighted ? 1.5 : 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

extension View {
    /// `isFocused` paints focus only; the caller retains the native focus binding.
    func afterSearchField(showsIcon: Bool = true, isFocused: Bool? = nil) -> some View {
        textFieldStyle(AfterSearchFieldStyle(showsIcon: showsIcon, isFocused: isFocused))
    }

    /// Shared chrome for existing search rows with their own icon, clear button
    /// or progress indicator. Apply `.plain` to the row's original TextField.
    func afterSearchFieldSurface(isFocused: Bool? = nil) -> some View {
        modifier(AfterSearchFieldSurface(isFocused: isFocused))
    }
}
