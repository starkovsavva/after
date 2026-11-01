import AfterLocalization
import AppKit
import SwiftUI

/// Shared action treatment. Native Button keeps its keyboard shortcut and focus.
struct AfterSoftButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary }
    var emphasis: Emphasis
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ emphasis: Emphasis = .secondary, tint: Color? = nil) {
        self.emphasis = emphasis
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        let primary = emphasis == .primary
        let actionColor = tint ?? (configuration.role == .destructive ? Ink.recordFill : Ink.actionFill)
        return configuration.label
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(minHeight: 32)
            .foregroundStyle(primary ? Color.white : tint ?? (configuration.role == .destructive ? Ink.destructiveText : Color.primary))
            .background(primary ? actionColor : Ink.controlSurface, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.controlRadius)
                    .strokeBorder(primary ? actionColor : Color.primary.opacity(contrast == .increased ? 0.55 : 0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isEnabled && !configuration.isPressed ? (colorScheme == .dark ? 0.20 : 0.08) : 0), radius: 2, y: 1)
            .brightness(configuration.isPressed ? (colorScheme == .dark ? 0.05 : -0.035) : 0)
            .opacity(isEnabled ? 1 : 0.48)
            .contentShape(RoundedRectangle(cornerRadius: AppLayout.controlRadius))
    }
}

struct AfterPickerOption<Value: Hashable>: Identifiable, Equatable {
    let title: String
    let value: Value
    var isEnabled = true
    var id: Value { value }
}

/// Short catalogs remain native menus, including checked selection and keyboard
/// navigation. Only callers with large catalogs opt into the searchable list.
struct AfterCompactPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [AfterPickerOption<Value>]
    var showsLabel = true
    var maxWidth: CGFloat = 300
    var searchable = false
    var identifier: String?
    @State private var showingSearch = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, selection: Binding<Value>, options: [AfterPickerOption<Value>],
         showsLabel: Bool = true, maxWidth: CGFloat = 300, searchable: Bool = false, identifier: String? = nil) {
        self.title = title
        _selection = selection
        self.options = options
        self.showsLabel = showsLabel
        self.maxWidth = maxWidth
        self.searchable = searchable
        self.identifier = identifier
    }

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? String(describing: selection)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { if showsLabel { Text(title) }; control }
            VStack(alignment: .leading, spacing: 7) { if showsLabel { Text(title) }; control }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var control: some View {
        if searchable && options.count > 8 {
            Button { showingSearch = true } label: { valueLabel }
                .buttonStyle(AfterSoftButtonStyle())
                .accessibilityLabel(title).accessibilityValue(selectedTitle)
                .accessibilityIdentifier(identifier ?? title)
                .popover(isPresented: $showingSearch) {
                    AfterPickerSearch(title: title, selection: $selection, options: options, identifier: identifier ?? title) { showingSearch = false }
                        .disabled(!isEnabled)
                }
        } else {
            AfterNativePicker(title: title, selection: $selection, options: options,
                              maxWidth: maxWidth, identifier: identifier ?? title)
                .fixedSize(horizontal: true, vertical: false)
                .shadow(color: .black.opacity(isEnabled ? (colorScheme == .dark ? 0.20 : 0.08) : 0), radius: 2, y: 1)
        }
    }

    private var valueLabel: some View {
        AfterIntrinsicWidth(maxWidth: max(64, maxWidth - 22)) {
            HStack(spacing: 9) {
                Text(selectedTitle).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }.help(selectedTitle)
    }
}

/// AppKit owns menu tracking, checked values, accessibility, and keyboard focus.
/// Only the closed control's drawing differs from the standard pop-up button.
private struct AfterNativePicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [AfterPickerOption<Value>]
    let maxWidth: CGFloat
    let identifier: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeNSView(context: Context) -> AfterNativePopUpButton {
        AfterNativePopUpButton(frame: .zero, pullsDown: false)
    }

    func updateNSView(_ view: AfterNativePopUpButton, context: Context) {
        view.isEnabled = isEnabled
        if !isEnabled { view.menu?.cancelTracking() }
        view.maximumWidth = maxWidth
        view.increasedContrast = contrast == .increased
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        view.onSelection = { [weak view] item in
            guard let view, view.isEnabled, isEnabled,
                  let entry = item.representedObject as? AfterNativePickerValue<Value>,
                  options.contains(where: { $0.value == entry.value && $0.isEnabled }) else { return false }
            if selection != entry.value { selection = entry.value }
            // Some settings reject a change while a protected draft is open.
            return selection == entry.value
        }

        var entries = options
        if !entries.contains(where: { $0.value == selection }) {
            // A missing value remains visible without inventing a new choice.
            entries.insert(.init(title: String(describing: selection), value: selection, isEnabled: false), at: 0)
        }
        let existing = view.menu?.items ?? []
        let matches = existing.count == entries.count && zip(existing, entries).allSatisfy { item, entry in
            (item.representedObject as? AfterNativePickerValue<Value>)?.value == entry.value
                && item.title == entry.title && item.isEnabled == entry.isEnabled
        }
        if !matches {
            view.menu?.cancelTracking()
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            for entry in entries {
                let item = NSMenuItem(title: entry.title, action: #selector(AfterNativePopUpButton.chooseMenuItem(_:)), keyEquivalent: "")
                item.target = view
                item.representedObject = AfterNativePickerValue(entry.value)
                item.isEnabled = entry.isEnabled
                menu.addItem(item)
            }
            view.menu = menu
        }
        let selected = view.menu?.items.first { ($0.representedObject as? AfterNativePickerValue<Value>)?.value == selection }
        view.select(selected)
        view.boundSelectionItem = selected
        view.displayedTitle = selected?.title ?? String(describing: selection)
        view.toolTip = view.displayedTitle
        view.menu?.items.forEach { $0.state = $0 === selected ? .on : .off }
        view.invalidateIntrinsicContentSize()
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AfterNativePopUpButton, context: Context) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }
}

private final class AfterNativePickerValue<Value>: NSObject {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class AfterNativePopUpButton: NSPopUpButton {
    var displayedTitle = "" {
        didSet {
            if displayedTitle != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) }
        }
    }
    var maximumWidth: CGFloat = 300
    var increasedContrast = false
    var boundSelectionItem: NSMenuItem?
    var onSelection: ((NSMenuItem) -> Bool)?

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        isBordered = false
        autoenablesItems = false
        altersStateOfSelectedItem = true
        font = .systemFont(ofSize: 13)
        focusRingType = .exterior
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // NSViewRepresentable publishes this view rather than its native NSCell.
    // Expose the pop-up contract on that element while AppKit keeps interaction.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityValue() -> Any? { displayedTitle }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused && isEnabled { window?.makeFirstResponder(self) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, window != nil else { return false }
        performClick(nil)
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }

    override var intrinsicContentSize: NSSize {
        let width = (displayedTitle as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width + 40
        return NSSize(width: min(max(54, ceil(width)), max(54, maximumWidth)), height: 32)
    }

    @objc func chooseMenuItem(_ item: NSMenuItem) {
        guard isEnabled, item.isEnabled, onSelection?(item) == true else {
            select(boundSelectionItem)
            return
        }
        select(item)
        boundSelectionItem = item
        displayedTitle = item.title
        toolTip = item.title
        menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.48)
        let bezel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: AppLayout.controlRadius, yRadius: AppLayout.controlRadius)
        Ink.controlSurfaceColor.setFill()
        bezel.fill()
        if isHighlighted {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.035)).setFill()
            bezel.fill()
        }
        NSColor.labelColor.withAlphaComponent(increasedContrast ? 0.55 : 0.18).setStroke()
        bezel.lineWidth = 1
        bezel.stroke()
        if window?.isKeyWindow == true && window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            bezel.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13),
                                                        .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let height = (displayedTitle as NSString).size(withAttributes: attributes).height
        (displayedTitle as NSString).draw(in: NSRect(x: 11, y: (bounds.height - height) / 2,
                                                    width: max(0, bounds.width - 40), height: height), withAttributes: attributes)
        let arrowConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        if let arrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(arrowConfiguration), arrow.size.width > 0 {
            let width = min(9, arrow.size.width)
            let height = arrow.size.height * width / arrow.size.width
            let rect = NSRect(x: bounds.maxX - 12 - width, y: bounds.midY - height / 2, width: width, height: height)
            arrow.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: AppLayout.controlRadius, yRadius: AppLayout.controlRadius).fill()
    }
}

private struct AfterPickerSearch<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [AfterPickerOption<Value>]
    let identifier: String
    let close: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var query = ""
    @State private var highlighted: Value?
    @FocusState private var searchFocused: Bool
    private var filtered: [AfterPickerOption<Value>] {
        options.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(AppTypography.controlStrong)
            TextField(L("Поиск"), text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityIdentifier(identifier + ".search")
                .onSubmit { choose(highlighted) }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let enabled = filtered.filter(\.isEnabled)
                    guard !enabled.isEmpty else { return .handled }
                    let current = enabled.firstIndex(where: { $0.value == highlighted }) ?? (press.key == .downArrow ? -1 : 0)
                    highlighted = enabled[(current + (press.key == .downArrow ? 1 : -1) + enabled.count) % enabled.count].value
                    return .handled
                }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { option in
                            Button { choose(option.value) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "checkmark").opacity(selection == option.value ? 1 : 0)
                                        .frame(width: 14).accessibilityHidden(true)
                                    Text(option.title).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(highlighted == option.value ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!option.isEnabled)
                                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                                .id(option.value)
                        }
                        if filtered.isEmpty { Text(L("Ничего не найдено")).foregroundStyle(.secondary).padding(8) }
                    }
                }.frame(maxHeight: 300)
                    .onChange(of: highlighted) { _, value in if let value { proxy.scrollTo(value) } }
            }
        }.padding(16).frame(width: 340).appControlDefaults()
            .onAppear { highlighted = selection; searchFocused = true }
            .onChange(of: query) { _, _ in highlighted = filtered.first(where: \.isEnabled)?.value }
            .onChange(of: options) { _, _ in
                if !filtered.contains(where: { $0.value == highlighted && $0.isEnabled }) {
                    highlighted = filtered.first(where: \.isEnabled)?.value
                }
            }
            .onChange(of: isEnabled) { _, enabled in if !enabled { close() } }
            .onExitCommand(perform: close)
    }
    private func choose(_ value: Value?) {
        guard isEnabled, let value, filtered.contains(where: { $0.value == value && $0.isEnabled }) else { return }
        selection = value
        close()
    }
}

/// Parameter choices are separate buttons, not navigation tabs. Selection has a
/// radio mark as well as a border; native Button activation and focus are kept.
struct AfterChoicePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [AfterPickerOption<Value>]
    var showsLabel = true
    @Environment(\.isEnabled) private var isEnabled
    var identifier: String?
    @Environment(\.layoutDirection) private var direction
    @FocusState private var focused: Value?

    init(_ title: String, selection: Binding<Value>, options: [AfterPickerOption<Value>], showsLabel: Bool = true, identifier: String? = nil) {
        self.title = title
        _selection = selection
        self.options = options
        self.showsLabel = showsLabel
        self.identifier = identifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel { Text(title) }
            AfterControlFlow {
                ForEach(options) { option in
                    Button { activate(option.value) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: selection == option.value ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 11)).foregroundStyle(selection == option.value ? Ink.accent : Ink.secondaryText)
                                .accessibilityHidden(true)
                            Text(option.title).fixedSize(horizontal: false, vertical: true)
                        }
                    }.buttonStyle(AfterSoftButtonStyle())
                        .overlay { RoundedRectangle(cornerRadius: AppLayout.controlRadius).strokeBorder(selection == option.value ? Ink.secondaryText : .clear) }
                        .disabled(!option.isEnabled).focusable(option.isEnabled && isEnabled).focused($focused, equals: option.value)
                        .accessibilityLabel(option.title).accessibilityAddTraits(selection == option.value ? .isSelected : [])
                        .accessibilityValue(selection == option.value ? L("Выбрана") : "")
                        .accessibilityIdentifier((identifier ?? title) + "." + String(describing: option.value))
                        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in navigate(press, from: option.value) }
                }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private func activate(_ value: Value) {
        guard isEnabled, options.contains(where: { $0.value == value && $0.isEnabled }) else { return }
        if selection != value { selection = value }
        focused = value
    }
    private func navigate(_ press: KeyPress, from value: Value) -> KeyPress.Result {
        guard isEnabled, press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        let enabled = options.filter(\.isEnabled)
        guard !enabled.isEmpty else { return .ignored }
        if press.key == .home { activate(enabled[0].value) }
        else if press.key == .end { activate(enabled[enabled.count - 1].value) }
        else {
            let current = enabled.firstIndex(where: { $0.value == value }) ?? 0
            let forward = press.key == .downArrow || (press.key == .rightArrow && direction == .leftToRight) || (press.key == .leftArrow && direction == .rightToLeft)
            activate(enabled[(current + (forward ? 1 : -1) + enabled.count) % enabled.count].value)
        }
        return .handled
    }
}

/// Measures the natural label width, then caps long values without giving every
/// short menu the width of its enclosing form.
private struct AfterIntrinsicWidth: Layout {
    let maxWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let width = min(view.sizeThatFits(.unspecified).width, maxWidth, proposal.width ?? maxWidth)
        return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct AfterControlFlow: Layout {
    var spacing: CGFloat = 8
    private var gap: CGFloat { spacing }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + gap; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width); x += size.width + gap; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}
