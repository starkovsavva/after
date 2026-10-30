import AppKit
import Combine
import SwiftUI

@MainActor
final class RichNoteCommands: ObservableObject {
    weak var editor: NSTextView?
    private func recordUndo(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let before = NSAttributedString(attributedString: storage)
        let selection = view.selectedRange(), typing = view.typingAttributes
        view.undoManager?.registerUndo(withTarget: self) { [weak view] owner in
            guard let view else { return }
            owner.restore(before, selection: selection, typing: typing, view: view)
        }
        view.undoManager?.setActionName(L("Форматирование"))
    }
    private func restore(_ value: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any], view: NSTextView) {
        recordUndo(view)
        view.textStorage?.setAttributedString(value); view.typingAttributes = typing
        view.setSelectedRange(NSRange(location: min(selection.location, value.length), length: min(selection.length, max(0, value.length - selection.location))))
        view.didChangeText()
    }
    func trait(_ trait: NSFontTraitMask) {
        guard let view = editor else { return }; view.window?.makeFirstResponder(view)
        recordUndo(view)
        let range = view.selectedRange()
        let font = (range.length > 0 ? view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) : view.typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: CGFloat(ThemeRuntime.shared.palette.textSize))
        let manager = NSFontManager.shared
        let target = manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        if range.length == 0 { view.typingAttributes[.font] = target }
        else { view.textStorage?.addAttribute(.font, value: target, range: range); view.didChangeText() }
    }
    func style(_ size: CGFloat, bold: Bool = false) {
        guard let view = editor else { return }; view.window?.makeFirstResponder(view)
        recordUndo(view)
        let range = (view.string as NSString).paragraphRange(for: view.selectedRange())
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if range.length == 0 { view.typingAttributes[.font] = font }
        else { view.textStorage?.addAttribute(.font, value: font, range: range); view.didChangeText() }
    }
    func underline() {
        guard let view = editor else { return }; view.window?.makeFirstResponder(view)
        recordUndo(view)
        let range = view.selectedRange()
        let current = (range.length > 0 ? view.textStorage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil) : view.typingAttributes[.underlineStyle]) as? Int ?? 0
        if range.length == 0 { view.typingAttributes[.underlineStyle] = current == 0 ? 1 : 0 }
        else { view.textStorage?.addAttribute(.underlineStyle, value: current == 0 ? 1 : 0, range: range); view.didChangeText() }
    }
    func list(_ marker: String) {
        guard let view = editor else { return }; view.window?.makeFirstResponder(view)
        let range = (view.string as NSString).paragraphRange(for: view.selectedRange())
        let original = (view.string as NSString).substring(with: range)
        let lines = original.components(separatedBy: "\n")
        let text = lines.enumerated().map { index, line in
            if index == lines.count - 1 && line.isEmpty { return line }
            if line.hasPrefix("☐ ") { return "☑ " + line.dropFirst(2) }
            if line.hasPrefix("☑ ") { return "☐ " + line.dropFirst(2) }
            return marker + line
        }.joined(separator: "\n")
        view.insertText(text, replacementRange: range)
    }
    func table() {
        guard let view = editor else { return }; view.window?.makeFirstResponder(view)
        let table = NSTextTable(); table.numberOfColumns = 2; table.collapsesBorders = true
        let result = NSMutableAttributedString(string: "")
        for row in 0..<3 {
            for column in 0..<2 {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                block.setContentWidth(50, type: .percentageValueType)
                let paragraph = NSMutableParagraphStyle(); paragraph.textBlocks = [block]
                result.append(NSAttributedString(string: row == 0 ? LF("Столбец {0}\n", arguments: [String(describing: (column + 1))]) : "\t\n", attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: CGFloat(ThemeRuntime.shared.palette.textSize)), .foregroundColor: NSColor.labelColor]))
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: CGFloat(ThemeRuntime.shared.palette.textSize)), .foregroundColor: NSColor.labelColor]))
        view.insertText(result, replacementRange: view.selectedRange())
    }
    func undo() { editor?.undoManager?.undo() }
    func redo() { editor?.undoManager?.redo() }
}

struct RichNoteToolbar: View {
    @ObservedObject private var theme = ThemeController.shared
    @ObservedObject var commands: RichNoteCommands
    var body: some View {
        HStack(spacing: 5) {
            Menu {
                Button(L("Заголовок")) { commands.style(24, bold: true) }
                Button(L("Подзаголовок")) { commands.style(18, bold: true) }
                Button(L("Основной текст")) { commands.style(CGFloat(theme.palette.textSize)) }
            } label: { Text("Aa").font(AppTypography.bodyStrong) }.menuStyle(.borderlessButton).frame(width: 42).help(L("Стиль текста"))
            Divider().frame(height: 18)
            control("bold", L("Жирный")) { commands.trait(.boldFontMask) }
            control("italic", L("Курсив")) { commands.trait(.italicFontMask) }
            control("underline", L("Подчёркнутый")) { commands.underline() }
            Divider().frame(height: 18)
            control("checklist", L("Чеклист; нажмите квадратик в тексте, чтобы отметить пункт")) { commands.list("☐ ") }
            control("list.bullet", L("Маркированный список")) { commands.list("• ") }
            control("tablecells", L("Вставить таблицу")) { commands.table() }
            Spacer(minLength: 4)
            control("arrow.uturn.backward", L("Отменить")) { commands.undo() }
            control("arrow.uturn.forward", L("Повторить")) { commands.redo() }
        }.frame(height: 34).buttonStyle(.borderless)
    }
    private func control(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 26, height: 26) }.help(title).accessibilityLabel(title)
    }
}

private final class ChecklistTextView: NSTextView {
    // Window-wide undo actions can reference ranges from another note. Keep
    // undo local to this editor and reset it only on authoritative reloads.
    private let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }
    var attachmentPaste: ((NSPasteboard) -> Void)?
    private func containsAttachments(_ board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]), !urls.isEmpty { return true }
        return NSImage(pasteboard: board) != nil
    }
    override func paste(_ sender: Any?) {
        if isEditable, let attachmentPaste, containsAttachments(.general) { attachmentPaste(.general) }
        else { super.paste(sender) }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isEditable, attachmentPaste != nil, containsAttachments(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isEditable, let attachmentPaste, containsAttachments(sender.draggingPasteboard) { attachmentPaste(sender.draggingPasteboard); return true }
        return super.performDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        if let manager = layoutManager, let container = textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let location = manager.characterIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let value = string as NSString
            if location < value.length {
                let paragraph = value.paragraphRange(for: NSRange(location: location, length: 0))
                let prefix = value.substring(with: NSRange(location: paragraph.location, length: min(2, paragraph.length)))
                if location <= paragraph.location + 1 && ["☐ ", "☑ "].contains(prefix) {
                    let replacement = prefix == "☐ " ? "☑" : "☐"
                    if shouldChangeText(in: NSRange(location: paragraph.location, length: 1), replacementString: replacement) {
                        insertText(replacement, replacementRange: NSRange(location: paragraph.location, length: 1))
                    }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

struct RichNoteEditor: NSViewRepresentable {
    @ObservedObject private var theme = ThemeController.shared
    @Binding var text: String
    @Binding var rtf: String
    let commands: RichNoteCommands
    var editable = true
    var onAttachmentPaste: ((NSPasteboard) -> Void)? = nil
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = ChecklistTextView(frame: .zero)
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isEditable = editable; editor.isSelectable = true; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: CGFloat(ThemeRuntime.shared.palette.textSize)); editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 4, height: 12)
        editor.autoresizingMask = [.width]; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true; editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticLinkDetectionEnabled = true; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.attachmentPaste = onAttachmentPaste
        editor.delegate = context.coordinator; editor.setAccessibilityLabel(L("Содержимое заметки"))
        scroll.documentView = editor; commands.editor = editor
        context.coordinator.load(editor, text: text, rtf: rtf)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChecklistTextView else { return }
        editor.attachmentPaste = onAttachmentPaste
        commands.editor = editor; editor.isEditable = editable
        if editor.string != text || context.coordinator.lastRTF != rtf { context.coordinator.load(editor, text: text, rtf: rtf) }
        if rtf.isEmpty { context.coordinator.applyDefaultFont(editor, size: CGFloat(theme.palette.textSize)) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichNoteEditor
        private var loading = false
        var lastRTF = ""
        init(_ parent: RichNoteEditor) { self.parent = parent }
        func load(_ editor: NSTextView, text: String, rtf: String) {
            loading = true; lastRTF = rtf; defer { loading = false }
            editor.undoManager?.removeAllActions()
            if let data = Data(base64Encoded: rtf), data.count <= 1_500_000,
               let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), attributed.string == text {
                let readable = NSMutableAttributedString(attributedString: attributed)
                readable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: readable.length)) { value, range, _ in
                    guard let color = (value as? NSColor)?.usingColorSpace(.deviceRGB) else { return }
                    let components = [color.redComponent, color.greenComponent, color.blueComponent]
                    if (components.max() ?? 1) - (components.min() ?? 0) < 0.08 && ((components.max() ?? 1) < 0.2 || (components.min() ?? 0) > 0.85) {
                        readable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                    }
                }
                editor.textStorage?.setAttributedString(readable)
            } else {
                editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(ThemeRuntime.shared.palette.textSize)), .foregroundColor: NSColor.labelColor]))
                applyDefaultFont(editor, size: CGFloat(ThemeRuntime.shared.palette.textSize))
            }
        }
        func applyDefaultFont(_ editor: NSTextView, size: CGFloat) {
            let font = NSFont.systemFont(ofSize: size)
            editor.textStorage?.addAttribute(.font, value: font, range: NSRange(location: 0, length: editor.string.utf16.count))
            editor.typingAttributes[.font] = font
        }
        func textDidChange(_ notification: Notification) {
            guard !loading, let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
            parent.text = view.string
            lastRTF = (try? storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))?.base64EncodedString() ?? ""
            parent.rtf = lastRTF
        }
    }
}

#if DEBUG
@MainActor
enum RichNoteNativeChecks {
    static func run() throws {
        let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; view.allowsUndo = true
        view.textStorage?.setAttributedString(NSAttributedString(string: "Проверка текста", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        let commands = RichNoteCommands(); commands.editor = view
        func bold() -> Bool { (view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false }
        commands.trait(.boldFontMask)
        guard bold(), view.undoManager?.canUndo == true else { throw AppError.message("Bold did not register native Undo") }
        commands.undo(); guard !bold() && view.string == "Проверка текста" else { throw AppError.message("Undo removed typing instead of formatting") }
        commands.redo(); guard bold() else { throw AppError.message("Redo did not restore formatting") }
        commands.style(24, bold: true); commands.undo()
        guard (view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 14 else { throw AppError.message("Heading Undo did not restore font size") }
        commands.underline(); commands.undo()
        guard (view.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0) == 0 else { throw AppError.message("Underline Undo did not restore content") }
        commands.table()
        guard let content = view.textStorage else { throw AppError.message("Table has no text storage") }
        let data = try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        guard restored.string == view.string else { throw AppError.message("Table rich text roundtrip lost text") }
        let another = ChecklistTextView(frame: view.frame)
        guard view.undoManager !== another.undoManager else { throw AppError.message("Notes share an Undo manager") }
        view.insertText("Long pending edit", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
        guard view.undoManager?.canUndo == true else { throw AppError.message("Typing Undo is missing") }
        let editor = RichNoteEditor(text: .constant("x"), rtf: .constant(""), commands: commands)
        let coordinator = editor.makeCoordinator()
        coordinator.load(view, text: "x", rtf: "")
        guard view.string == "x", view.undoManager?.canUndo == false else { throw AppError.message("External reload retained stale Undo ranges") }
        commands.undo()
        guard view.string == "x" else { throw AppError.message("Reload Undo changed authoritative content") }
        window.orderOut(nil)
    }
}
#endif
