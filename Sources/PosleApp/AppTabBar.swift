import SwiftUI

/// Titles are presentation strings; values keep the caller's stable model identity.
struct AppTab<Value: Hashable>: Equatable {
    let title: String
    let value: Value
    var isEnabled: Bool

    init(_ title: String, value: Value, isEnabled: Bool = true) {
        self.title = title
        self.value = value
        self.isEnabled = isEnabled
    }
}

extension AppLayout {
    static let tabSpacing: CGFloat = 20
    static let tabHeight: CGFloat = 36
    static let tabIndicatorHeight: CGFloat = 2
}

/// A single selection control shared by workspaces and settings. Native buttons
/// retain their focus behavior; changing selection never recreates the content.
struct AppTabBar<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let tabs: [AppTab<Value>]
    let identifier: String
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var focusedTab: Value?

    init(label: String, selection: Binding<Value>, tabs: [AppTab<Value>], identifier: String, fillsWidth: Bool = false) {
        self.label = label
        _selection = selection
        self.tabs = tabs
        self.identifier = identifier
        self.fillsWidth = fillsWidth
    }

    var body: some View {
        HStack(spacing: AppLayout.tabSpacing) {
            ForEach(tabs, id: \.value) { tab in
                tabButton(tab)
            }
            if fillsWidth { Spacer(minLength: 0) }
        }
        .background(alignment: .bottom) {
            Rectangle().fill(Ink.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func tabButton(_ tab: AppTab<Value>) -> some View {
        let selected = selection == tab.value
        return Button {
            activate(tab.value)
        } label: {
            // Reserve the stronger label's width so adjacent tabs do not move
            // when a label changes weight after selecting it.
            ZStack {
                Text(tab.title).font(AppTypography.controlStrong).hidden().accessibilityHidden(true)
                Text(tab.title).font(selected ? AppTypography.controlStrong : AppTypography.control)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 1)
            .frame(minHeight: AppLayout.tabHeight)
            .foregroundStyle(selected ? Color.primary : Ink.secondaryText)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(selected ? Color.primary : .clear)
                    .frame(height: AppLayout.tabIndicatorHeight)
            }
            .opacity(tab.isEnabled && isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .focusable(tab.isEnabled && isEnabled)
        .focused($focusedTab, equals: tab.value)
        .disabled(!tab.isEnabled)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? L("Выбрана") : "")
        .accessibilityIdentifier(identifier + "." + String(describing: tab.value))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { press in
            navigate(press, from: tab.value)
        }
    }

    private func activate(_ value: Value) {
        guard isEnabled, tabs.contains(where: { $0.value == value && $0.isEnabled }) else { return }
        if selection != value { selection = value }
        focusedTab = value
    }

    private func navigate(_ press: KeyPress, from value: Value) -> KeyPress.Result {
        guard isEnabled, press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        let enabled = tabs.filter(\.isEnabled)
        guard !enabled.isEmpty else { return .ignored }
        let target: Value
        if press.key == .home {
            target = enabled[0].value
        } else if press.key == .end {
            target = enabled[enabled.count - 1].value
        } else {
            let current = enabled.firstIndex(where: { $0.value == value }) ?? 0
            let forward = press.key == .rightArrow
            let offset = (forward == (layoutDirection == .leftToRight)) ? 1 : -1
            target = enabled[(current + offset + enabled.count) % enabled.count].value
        }
        activate(target)
        return .handled
    }
}
