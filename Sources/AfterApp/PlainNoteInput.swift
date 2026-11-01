import AppKit
import SwiftUI

/// A plain native editor whose empty-state text uses the editor's own TextKit
/// metrics. The placeholder is drawn, never inserted into the user's document.
struct PlainNoteInput: NSViewRepresentable {
    @ObservedObject private var theme = ThemeController.shared
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    /// Distinct destinations may contain identical text but must never share Undo.
    var documentID: String = ""
    var accessibilityLabel: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> PlainNoteScrollView {
        let scroll = PlainNoteScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let editor = PlainNoteTextView(frame: .zero)
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.delegate = context.coordinator
        editor.focusChanged = { [weak coordinator = context.coordinator] value in coordinator?.focusChanged(value) }
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: PlainNoteScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PlainNoteTextView else { return }
        let font = NSFont.systemFont(ofSize: CGFloat(theme.palette.textSize))
        if editor.font != font { editor.font = font }
        editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        editor.placeholder = placeholder
        editor.isEditable = enabled; editor.isSelectable = enabled
        editor.setAccessibilityLabel(accessibilityLabel ?? placeholder)
        editor.setAccessibilityHelp(placeholder)
        if context.coordinator.documentID != documentID || editor.string != text {
            // A destination change starts a new native document even when both
            // drafts are empty. Undo must never resurrect another note.
            editor.undoManager?.removeAllActions()
            editor.string = text; editor.needsDisplay = true
        }
        context.coordinator.documentID = documentID
        if isFocused && enabled, editor.window?.firstResponder !== editor {
            DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                guard let editor, coordinator?.parent.isFocused == true, editor.isEditable else { return }
                editor.window?.makeFirstResponder(editor)
            }
        } else if !isFocused, editor.window?.firstResponder === editor {
            DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                guard let editor, coordinator?.parent.isFocused == false, editor.window?.firstResponder === editor else { return }
                editor.window?.makeFirstResponder(nil)
            }
        }
    }
    static func dismantleNSView(_ scroll: PlainNoteScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? PlainNoteTextView else { return }
        editor.focusChanged = nil; editor.delegate = nil
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainNoteInput
        var documentID: String
        init(_ parent: PlainNoteInput) { self.parent = parent; documentID = parent.documentID }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PlainNoteTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
            editor.needsDisplay = true
        }
        func focusChanged(_ value: Bool) {
            if parent.isFocused != value { parent.isFocused = value }
        }
    }
}

final class PlainNoteScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? PlainNoteTextView else { return }
        let size = contentSize
        editor.minSize = NSSize(width: 0, height: size.height)
        if editor.frame.height < size.height { editor.setFrameSize(NSSize(width: size.width, height: size.height)) }
    }
}

final class PlainNoteTextView: NSTextView {
    private let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }
    var focusChanged: ((Bool) -> Void)?
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var placeholderVisible: Bool { string.isEmpty && !placeholder.isEmpty }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }
    override func didChangeText() {
        super.didChangeText(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard placeholderVisible, let layout = placeholderLayout() else { return }
        withExtendedLifetime(layout.storage) {
            layout.manager.drawGlyphs(forGlyphRange: layout.range, at: textContainerOrigin)
        }
    }
    /// Used by the native regression to compare the actual placeholder draw
    /// position against the same first glyph entered into the real document.
    func placeholderFirstBaseline() -> NSPoint? {
        guard placeholderVisible, let layout = placeholderLayout(), layout.range.length > 0 else { return nil }
        return withExtendedLifetime(layout.storage) {
            let line = layout.manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let glyph = layout.manager.location(forGlyphAt: 0)
            return NSPoint(x: textContainerOrigin.x + line.minX + glyph.x,
                           y: textContainerOrigin.y + line.minY + glyph.y)
        }
    }
    private func placeholderLayout() -> (storage: NSTextStorage, manager: NSLayoutManager, range: NSRange)? {
        guard let original = textContainer else { return nil }
        let storage = NSTextStorage(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default,
            .foregroundColor: NSColor.placeholderTextColor
        ])
        let manager = NSLayoutManager()
        manager.usesFontLeading = layoutManager?.usesFontLeading ?? true
        let container = NSTextContainer(containerSize: original.containerSize)
        container.lineFragmentPadding = original.lineFragmentPadding
        container.lineBreakMode = original.lineBreakMode
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, manager.glyphRange(for: container))
    }
}
