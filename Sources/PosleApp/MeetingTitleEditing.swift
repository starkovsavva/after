import AppKit
import PosleCore
import SwiftUI

/// Drafts belong to a meeting, so leaving its screen never loses a failed edit.
/// The existing quit/update guard protects dirty titles just like note editors.
@MainActor
final class MeetingTitleEdits: ObservableObject {
    struct Draft {
        let token = UUID()
        let original: String
        var text: String
        var error: String?
    }
    struct FocusRequest: Equatable {
        let meetingID: String
        let token = UUID()
    }
    @Published private(set) var drafts: [String: Draft] = [:]
    @Published private(set) var focusRequest: FocusRequest?

    func begin(_ meeting: Meeting, requestFocus: Bool = true) {
        if drafts[meeting.id] == nil { drafts[meeting.id] = Draft(original: meeting.title, text: meeting.title) }
        if requestFocus { focusRequest = FocusRequest(meetingID: meeting.id) }
    }
    func focus(_ id: String) { focusRequest = FocusRequest(meetingID: id) }

    func edit(_ id: String, text: String) {
        guard var draft = drafts[id] else { return }
        draft.text = text; draft.error = nil; drafts[id] = draft
        UnsavedEditorRegistry.set(id: draft.token, title: "Название встречи «\(draft.original.prefix(60))»", dirty: text != draft.original)
    }
    func cancel(_ id: String) {
        // A completed edit must not replay its menu focus request when this
        // meeting's native field is mounted again after navigating elsewhere.
        if focusRequest?.meetingID == id { focusRequest = nil }
        guard let draft = drafts.removeValue(forKey: id) else { return }
        UnsavedEditorRegistry.remove(id: draft.token)
    }
    @discardableResult func commit(_ id: String, store: AppStore) -> Bool {
        guard var draft = drafts[id] else { return true }
        let title = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            draft.error = "Введите название встречи."; drafts[id] = draft; return false
        }
        // Returning to the original text is a cancellation, including after a
        // concurrent rename; it must never restore the outdated original title.
        if title == draft.original { cancel(id); return true }
        do {
            try store.renameMeeting(id, title: title, expectedTitle: draft.original)
            cancel(id); return true
        } catch {
            draft.error = error.localizedDescription; drafts[id] = draft; return false
        }
    }
}

extension AppStore {
    func renameMeeting(_ id: String, title: String, expectedTitle: String) throws {
        guard meetings.contains(where: { $0.id == id }) else { throw AppError.message("Встреча недоступна. Ваше название осталось в поле.") }
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "meeting-rename", arguments: [
                "meetingID": id, "title": title, "expectedTitle": expectedTitle
            ])
            let saved = try JSONDecoder().decode(Meeting.self, from: data)
            if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = saved }
        } catch {
            // A concurrent editor may have changed the name. Refresh the saved
            // value while keeping our separate draft, so Escape reveals it.
            if let latest: Meeting = read(meetingDirectory(id).appendingPathComponent("meta.json")),
               let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = latest }
            throw error
        }
    }
}

struct MeetingTitleHeading: View {
    @ObservedObject var store: AppStore
    @ObservedObject var edits: MeetingTitleEdits
    let meeting: Meeting
    private var canEdit: Bool { store.captureMeetingID != meeting.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeMeetingTitle(title: meeting.title, draft: edits.drafts[meeting.id]?.text,
                               enabled: canEdit,
                               focusToken: edits.focusRequest?.meetingID == meeting.id ? edits.focusRequest?.token : nil,
                               changed: { text in
                                   if edits.drafts[meeting.id] == nil { edits.begin(meeting, requestFocus: false) }
                                   edits.edit(meeting.id, text: text)
                               },
                               commit: { edits.commit(meeting.id, store: store) },
                               cancel: { edits.cancel(meeting.id) })
                .id(meeting.id).frame(height: 33).frame(maxWidth: .infinity, alignment: .leading)
            if let error = edits.drafts[meeting.id]?.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("meeting.rename.error")
                    Button("Отменить") { edits.cancel(meeting.id) }.buttonStyle(.borderless).font(AppTypography.caption)
                        .accessibilityIdentifier("meeting.rename.cancel")
                }
            }
        }
        .onChange(of: meeting.id) { old, new in
            _ = edits.commit(old, store: store)
            if edits.drafts[new] != nil { edits.focus(new) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PosleRenameMeeting"))) { note in
            if note.object as? String == meeting.id, canEdit { edits.begin(meeting) }
        }
        .onAppear { if edits.drafts[meeting.id] != nil { edits.focus(meeting.id) } }
        .onDisappear { _ = edits.commit(meeting.id, store: store) }
    }
}

/// Always editable like a native document name. Its delegate owns the complete
/// edit lifecycle, including moving focus into the AppKit note editor.
private struct NativeMeetingTitle: NSViewRepresentable {
    let title: String
    let draft: String?
    let enabled: Bool
    let focusToken: UUID?
    let changed: (String) -> Void
    let commit: () -> Bool
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> TitleField {
        let field = TitleField()
        field.font = .systemFont(ofSize: 25, weight: .semibold)
        field.isBezeled = false; field.drawsBackground = false; field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true; field.focusRingType = .exterior
        field.placeholderString = "Название встречи"
        field.identifier = NSUserInterfaceItemIdentifier("meeting.title")
        field.setAccessibilityIdentifier("meeting.title"); field.setAccessibilityLabel("Название встречи")
        field.setAccessibilityHelp("Return — сохранить, Escape — отменить.")
        field.toolTip = "Нажмите на название, чтобы переименовать"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: TitleField, context: Context) {
        context.coordinator.parent = self
        field.isEditable = enabled; field.isSelectable = enabled
        let value = draft ?? title
        if let editor = field.currentEditor() {
            if draft == nil, editor.string != value { editor.string = value; field.stringValue = value }
        } else if field.stringValue != value { field.stringValue = value }
        if let focusToken {
            if context.coordinator.lastFocusToken != focusToken {
                context.coordinator.lastFocusToken = focusToken
                field.pendingFocus = focusToken; field.focusWhenAttached()
            }
        } else {
            // Invalidate an async request already queued by a previous update.
            field.pendingFocus = nil; context.coordinator.lastFocusToken = nil
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeMeetingTitle
        var lastFocusToken: UUID?
        private var completing = false
        init(_ parent: NativeMeetingTitle) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard !completing, let field = notification.object as? NSTextField else { return }
            parent.changed(field.stringValue)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !completing else { return }
            completing = true; defer { completing = false }
            _ = parent.commit()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            guard !completing else { return true }
            completing = true; defer { completing = false }
            let cancelled = commandSelector == #selector(NSResponder.cancelOperation(_:))
            if cancelled { parent.cancel() }
            if cancelled || parent.commit() {
                control.abortEditing(); control.window?.makeFirstResponder(nil)
            }
            return true
        }
    }
    final class TitleField: NSTextField {
        var pendingFocus: UUID?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusWhenAttached() }
        func focusWhenAttached() {
            guard let request = pendingFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingFocus == request, let window = self.window, window.isKeyWindow else { return }
                self.pendingFocus = nil
                if window.makeFirstResponder(self) { self.selectText(nil) }
            }
        }
    }
}
