#if DEBUG
import AppKit
import PosleCore
import SwiftUI

/// Own native views and synthetic text only. Compare the drawn placeholder's
/// first glyph against actual inserted text, rather than assuming an inset.
@MainActor
enum PlainNoteInputChecks {
    static func run(root: URL) async throws {
        let theme = ThemeController.shared
        theme.configure(root: root)
        let original = theme.palette
        defer { theme.change { $0 = original } }
        let state = Fixture()
        let host = NSHostingView(rootView: FixtureView(state: state))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 430, height: 150)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        try await wait(host, window: window) { editor(in: host) != nil }
        guard let input = editor(in: host) else { throw AppError.message("Native note input missing") }
        let phrase = "Новая заметка…"
        for appearance in ["light", "dark"] {
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            for size in [14, 18] {
                theme.change { $0.textSize = size }
                state.text = ""; state.focused = true
                try await wait(host, window: window) { input.string.isEmpty && input.font?.pointSize == CGFloat(size) }
                for inset in [NSSize.zero, NSSize(width: 11, height: 9)] {
                    input.textContainerInset = inset
                    input.textContainer?.lineFragmentPadding = inset == .zero ? 5 : 8
                    input.needsDisplay = true; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    try expect(input.placeholderVisible && input.string.isEmpty, "A placeholder must not become document content")
                    guard let placeholder = input.placeholderFirstBaseline() else { throw AppError.message("Placeholder glyph layout missing") }
                    if inset == .zero { try capture(host, at: root.appendingPathComponent("note-input-\(size)pt-\(appearance).png")) }
                    input.insertText(phrase, replacementRange: NSRange(location: 0, length: 0))
                    try await wait(host, window: window) { state.text == phrase && input.string == phrase }
                    guard let manager = input.layoutManager, let container = input.textContainer else { throw AppError.message("Native text layout missing") }
                    manager.ensureLayout(for: container)
                    let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                    let glyph = manager.location(forGlyphAt: 0)
                    let actual = NSPoint(x: input.textContainerOrigin.x + line.minX + glyph.x,
                                         y: input.textContainerOrigin.y + line.minY + glyph.y)
                    try expect(abs(actual.x - placeholder.x) < 0.5 && abs(actual.y - placeholder.y) < 0.5,
                               "Placeholder baseline differs from entered text at \(size)pt \(appearance), inset \(inset): \(placeholder) vs \(actual)")
                    try expect(!input.placeholderVisible, "Typing must hide the placeholder")
                    input.breakUndoCoalescing(); input.undoManager?.undo()
                    try await wait(host, window: window) { state.text.isEmpty && input.string.isEmpty && input.placeholderVisible }
                }
            }
        }
        state.text = "Черновик без потери при смене размера"
        try await wait(host, window: window) { input.string == state.text }
        input.setSelectedRange(NSRange(location: 9, length: 3))
        theme.change { $0.textSize = 14 }
        try await wait(host, window: window) { input.font?.pointSize == 14 }
        try expect(input.string == state.text && input.selectedRange() == NSRange(location: 9, length: 3), "Live font changes must preserve draft text and selection")
        state.text = ""; state.focused = true
        try await wait(host, window: window) { input.string.isEmpty }
        input.insertText("Текст только из первой встречи", replacementRange: NSRange(location: 0, length: 0))
        try await wait(host, window: window) { state.text == "Текст только из первой встречи" }
        input.breakUndoCoalescing()
        input.insertText("", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
        try await wait(host, window: window) { input.string.isEmpty && state.text.isEmpty }
        try expect(input.undoManager?.canUndo == true, "The first empty draft must have a real native Undo history")
        state.documentID = "another-meeting"
        try await wait(host, window: window) { input.undoManager?.canUndo == false }
        try expect(editor(in: host) === input && input.string.isEmpty && state.text.isEmpty,
                   "Changing document identity with equal empty text must clear Undo without copying another draft")
        input.insertText("Вторая встреча", replacementRange: NSRange(location: 0, length: 0))
        try await wait(host, window: window) { state.text == "Вторая встреча" }
        input.breakUndoCoalescing(); input.undoManager?.undo()
        try await wait(host, window: window) { input.string.isEmpty && state.text.isEmpty && input.undoManager?.canUndo == false }
        print("PASS: equal empty drafts clear native Undo on document change; the new document's typing and Undo remain independent")
        print("PASS: native placeholder baseline matches inserted text at 14/18pt in light/dark and changed insets; typing/Undo, live font and selection stay intact")
    }
    @MainActor private final class Fixture: ObservableObject {
        @Published var text = ""
        @Published var focused = false
        @Published var documentID = "first-meeting"
    }
    private struct FixtureView: View {
        @ObservedObject var state: Fixture
        var body: some View {
            PlainNoteInput(text: $state.text, placeholder: "Новая заметка…", isFocused: $state.focused, documentID: state.documentID)
                .padding(12).background(Ink.field)
        }
    }
    private static func editor(in view: NSView) -> PlainNoteTextView? {
        if let value = view as? PlainNoteTextView { return value }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    private static func wait(_ host: NSView, window: NSWindow, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Native note input did not reach expected state")
    }
    private static func capture(_ view: NSView, at url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Note input snapshot failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Note input PNG failed") }
        try data.write(to: url)
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}
#endif
