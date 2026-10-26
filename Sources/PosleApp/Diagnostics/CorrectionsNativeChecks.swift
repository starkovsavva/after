#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

@MainActor
private final class CorrectionCheckPresentation: ObservableObject { @Published var showing = true }
private struct CorrectionCheckSheet<Content: View>: View {
    @ObservedObject var state: CorrectionCheckPresentation
    let content: Content
    var body: some View {
        Color.clear.frame(width: 850, height: 620).sheet(isPresented: $state.showing) { content }
    }
}

/// Operates only this app's native controls and its explicitly empty fixture.
/// Tests real TextEditor/Pickers/Save actions; never assigns a View's @State.
@MainActor
enum CorrectionsNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Corrections checks require an explicit disposable preview root") }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable corrections root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let app = AppStore(preview: true)
        try expect(app.meetings.isEmpty && !UnsavedEditorRegistry.hasUnsaved, "Corrections checks require an empty fixture")
        let bridge = try RustBridge.shared.get()
        var meeting = Meeting(title: "Проверка сметы", source: "synthetic.wav", status: "ready")
        meeting.speakerNames = ["speaker_1": "Анна", "speaker_2": "Михаил"]
        let directory = app.meetingDirectory(meeting.id)
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        try Data("Synthetic unchanged source".utf8).write(to: directory.appendingPathComponent("synthetic.wav"))
        _ = try bridge.request(root: root, command: "write", arguments: ["path": "meetings/\(meeting.id)/transcript.json", "value": ["duration": 20, "model": "synthetic", "warnings": [], "segments": [
            ["id": 7, "start": 0, "end": 10, "speaker": "speaker_1", "text": "Отправим смету в четверг.", "overlap": false],
            ["id": 11, "start": 10, "end": 20, "speaker": "speaker_2", "text": "Проверю документ.", "overlap": false]]]])
        _ = try bridge.request(root: root, command: "write", arguments: ["path": "meetings/\(meeting.id)/summary.json", "value": ["overview": "Согласовали подготовку сметы.", "provider": "synthetic", "model": "fixture", "generatedAt": 1, "warnings": [], "cards": [], "overviewClaims": [], "items": [["kind": "action", "text": "Подготовить смету", "owner": "Анна", "due": "", "segmentIDs": [7]]]]])
        app.reloadLibrary(); app.selection = meeting.id; app.loadSelection()
        let transcript = present(TranscriptSegmentEditor(meetingID: meeting.id, segmentID: 7).environmentObject(app))
        defer { transcript.close() }
        try await wait(transcript) { !textViews(transcript.root).isEmpty && !descendants(transcript.root, as: NSPopUpButton.self).isEmpty }
        let text = textViews(transcript.root)[0]
        replace(text, with: "Отправим смету в пятницу.")
        let speaker = descendants(transcript.root, as: NSPopUpButton.self)[0]
        speaker.selectItem(withTitle: "Михаил")
        // SwiftUI's popup routes through each menu item's PickerOptionTarget;
        // the NSPopUpButton control itself intentionally has no target/action.
        guard let menu = speaker.menu, speaker.indexOfSelectedItem >= 0 else { throw AppError.message("Native speaker menu missing") }
        menu.performActionForItem(at: speaker.indexOfSelectedItem)
        try await wait(transcript) { UnsavedEditorRegistry.hasUnsaved }
        try press("transcript.edit.save")
        try await wait(transcript) { transcript.window.attachedSheet == nil }
        let first: Transcript = try read(bridge, root: root, path: "meetings/\(meeting.id)/transcript.json")
        try expect(first.segments[0].text == "Отправим смету в пятницу." && first.segments[0].speaker == "speaker_2", "Real transcript controls did not persist: text=\(first.segments[0].text); speaker=\(first.segments[0].speaker); nativeText=\(text.string); picker=\(speaker.titleOfSelectedItem ?? "nil"); items=\(speaker.itemTitles)")
        try expect(first.segments[0].start == 0 && first.segments[0].end == 10 && !UnsavedEditorRegistry.hasUnsaved, "Transcript save changed timing or left a dirty editor")
        transcript.close()
        print("PASS: actual transcript TextEditor + speaker picker → Save → Rust, stable timestamps and cleared exit gate")

        let stale = present(TranscriptSegmentEditor(meetingID: meeting.id, segmentID: 7).environmentObject(app))
        defer { stale.close() }
        try await wait(stale) { !textViews(stale.root).isEmpty }
        let local = textViews(stale.root)[0]; replace(local, with: "Мой несохранённый черновик")
        try await wait(stale) { UnsavedEditorRegistry.hasUnsaved }
        let fresh = try JSONSerialization.jsonObject(with: bridge.request(root: root, command: "meeting-content-snapshot", arguments: ["meetingID": meeting.id])) as! [String: Any]
        _ = try bridge.request(root: root, command: "transcript-segment-save", arguments: ["meetingID": meeting.id, "segmentID": 11, "text": "Внешняя правка другого окна", "speaker": "speaker_2", "expectedFingerprint": fresh["transcriptFingerprint"]!])
        try press("transcript.edit.save")
        try await wait(stale) { nodes().contains { $0.identifier == "transcript.edit.error" } }
        try expect(local.string == "Мой несохранённый черновик" && UnsavedEditorRegistry.hasUnsaved, "A stale save lost the local draft or cleared the exit gate")
        let winner: Transcript = try read(bridge, root: root, path: "meetings/\(meeting.id)/transcript.json")
        try expect(winner.segments[0].text == first.segments[0].text && winner.segments[1].text == "Внешняя правка другого окна", "Stale editor overwrote the winner")
        try press("transcript.edit.cancel")
        try await wait(stale) { nodes().contains { $0.identifier == "transcript.edit.discard" && $0.ready } }
        try press("transcript.edit.discard")
        try await wait(stale, "transcript discard") { stale.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        stale.close()
        print("PASS: concurrent CAS rejection preserves both drafts; actual Cancel/discard closes the dirty editor")

        let insight = present(SummaryInsightEditor(meetingID: meeting.id, itemIndex: 0).environmentObject(app))
        defer { insight.close() }
        try await wait(insight) { !textViews(insight.root).isEmpty && descendants(insight.root, as: NSTextField.self).contains { $0.placeholderString == "Ответственный" } }
        replace(textViews(insight.root)[0], with: "Подготовить смету и проверить расчёт")
        guard let owner = descendants(insight.root, as: NSTextField.self).first(where: { $0.placeholderString == "Ответственный" }) else { throw AppError.message("Native owner field missing") }
        insight.window.attachedSheet?.makeFirstResponder(owner)
        guard let fieldEditor = owner.currentEditor() as? NSTextView else { throw AppError.message("Native owner field editor missing") }
        replace(fieldEditor, with: "Михаил")
        try pressLabel("Завтра")
        try await wait(insight) { UnsavedEditorRegistry.hasUnsaved }
        try press("summary.edit.save")
        try await wait(insight) { insight.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        let summary: Summary = try read(bridge, root: root, path: "meetings/\(meeting.id)/summary.json")
        let expectedDate = TaskDueDate.storage(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        try expect(summary.items[0].text == "Подготовить смету и проверить расчёт" && summary.items[0].owner == "Михаил" && summary.items[0].due == expectedDate && summary.items[0].segmentIDs == [7], "Real summary text/owner/date controls failed or lost evidence")
        let source = try Data(contentsOf: directory.appendingPathComponent("synthetic.wav"))
        try expect(source == Data("Synthetic unchanged source".utf8), "Editing changed source audio")
        insight.close()
        print("PASS: actual summary TextEditor + owner field + Tomorrow → Save, source links preserved")
        let staleInsight = present(SummaryInsightEditor(meetingID: meeting.id, itemIndex: 0).environmentObject(app))
        defer { staleInsight.close() }
        try await wait(staleInsight) { !textViews(staleInsight.root).isEmpty }
        let unsavedInsight = textViews(staleInsight.root)[0]
        replace(unsavedInsight, with: "Мой черновик пункта")
        try await wait(staleInsight) { UnsavedEditorRegistry.hasUnsaved }
        let latest = try JSONSerialization.jsonObject(with: bridge.request(root: root, command: "meeting-content-snapshot", arguments: ["meetingID": meeting.id])) as! [String: Any]
        _ = try bridge.request(root: root, command: "summary-item-save", arguments: ["meetingID": meeting.id, "itemIndex": 0, "text": "Победившая правка другого окна", "owner": "Анна", "due": "", "expectedFingerprint": latest["summaryFingerprint"]!])
        try press("summary.edit.save")
        try await wait(staleInsight) { nodes().contains { $0.identifier == "summary.edit.error" } }
        try expect(unsavedInsight.string == "Мой черновик пункта" && UnsavedEditorRegistry.hasUnsaved, "A summary conflict discarded the user draft")
        let winnerSummary: Summary = try read(bridge, root: root, path: "meetings/\(meeting.id)/summary.json")
        try expect(winnerSummary.items[0].text == "Победившая правка другого окна" && winnerSummary.items[0].segmentIDs == [7], "Summary CAS overwrote the winner or its evidence")
        try press("summary.edit.cancel")
        try await wait(staleInsight) { nodes().contains { $0.identifier == "summary.edit.discard" && $0.ready } }
        try press("summary.edit.discard")
        try await wait(staleInsight) { staleInsight.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        staleInsight.close()
        print("PASS: stale summary editor preserves its draft and winning persisted version until explicit discard")
        var savedCard: CardSaveResult?
        let card = present(CardEditorView(request: CardEditorRequest(meeting: meeting)) { savedCard = $0 }.environmentObject(app))
        defer { card.close() }
        try await wait(card) { textViews(card.root).count == 2 }
        replace(textViews(card.root)[0], with: "follow up on the estimate")
        replace(textViews(card.root)[1], with: "Уточнить статус сметы")
        try await wait(card) { UnsavedEditorRegistry.hasUnsaved }
        try press("cards.edit.save")
        try await wait(card) { card.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        try expect(savedCard?.card.front == "follow up on the estimate" && savedCard?.card.back == "Уточнить статус сметы", "Actual card question/answer editors did not save")
        card.close()
        let cards = CardsWorkspace()
        await cards.reload(root: root, meetingID: meeting.id)
        guard let entry = cards.entries.first(where: { $0.card.id == savedCard?.card.id }) else { throw AppError.message("Saved card missing from Rust library") }
        let originalCard = entry.card
        let discardedCard = present(CardEditorView(request: CardEditorRequest(entry: entry)) { _ in }.environmentObject(app))
        defer { discardedCard.close() }
        try await wait(discardedCard) { textViews(discardedCard.root).count == 2 }
        replace(textViews(discardedCard.root)[0], with: "Этот черновик не должен сохраниться")
        try await wait(discardedCard) { UnsavedEditorRegistry.hasUnsaved }
        try press("cards.edit.cancel")
        try await wait(discardedCard) { nodes().contains { $0.identifier == "cards.edit.discard" && $0.ready } }
        try press("cards.edit.discard")
        try await wait(discardedCard) { discardedCard.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        await cards.reload(root: root, meetingID: meeting.id)
        try expect(cards.entries.first(where: { $0.card.id == originalCard.id })?.card == originalCard, "Discard changed a persisted card")
        print("PASS: actual card front/back Save and explicit Cancel/discard preserve Rust data and release the exit/update gate")
        discardedCard.close()
        try await noteModalDrafts(app: app, meeting: meeting)
        print("8 native correction editor workflows passed")
    }
    private static func noteModalDrafts(app: AppStore, meeting: Meeting) async throws {
        let notes = app.notes
        guard let original = notes.capture(text: "Черновик заметки", meetingID: meeting.id) else { throw AppError.message(notes.error ?? "Note fixture failed") }
        let note = present(NoteEditorView(notes: notes, note: original).environmentObject(app))
        defer { note.close() }
        try await wait(note) { !textViews(note.root).isEmpty }
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Opening an unchanged note must not block exit")
        replace(textViews(note.root)[0], with: "Сохранённая правка заметки")
        try await wait(note) { UnsavedEditorRegistry.hasUnsaved }
        try press("notes.edit.save")
        try await wait(note) { note.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        guard let saved = notes.notes.first(where: { $0.id == original.id }) else { throw AppError.message("Saved note missing") }
        try expect(saved.text == "Сохранённая правка заметки", "Real note editor did not persist its draft")
        note.close()
        let discarded = present(NoteEditorView(notes: notes, note: saved).environmentObject(app))
        defer { discarded.close() }
        try await wait(discarded) { !textViews(discarded.root).isEmpty }
        replace(textViews(discarded.root)[0], with: "Этот черновик заметки отменён")
        try await wait(discarded) { UnsavedEditorRegistry.hasUnsaved }
        try press("notes.edit.cancel")
        try await wait(discarded) { nodes().contains { $0.identifier == "notes.edit.discard" && $0.ready } }
        try press("notes.edit.discard")
        try await wait(discarded) { discarded.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        try expect(notes.notes.first(where: { $0.id == saved.id }) == saved, "Explicit note discard changed persisted content")
        discarded.close()
        print("PASS: actual note editor protects dirty drafts from exit, Save releases the gate, explicit discard preserves storage")

        let template = NoteTemplate(name: "Проверка черновика шаблона", body: "Исходная структура", focus: "")
        try expect(notes.saveTemplate(template), "Template fixture save failed")
        guard let templateOriginal = notes.templates.first(where: { $0.id == template.id }) else { throw AppError.message("Template fixture missing") }
        let editor = present(NotesEditorCheckViews.template(notes: notes, template: templateOriginal).environmentObject(app))
        defer { editor.close() }
        try await wait(editor) { textViews(editor.root).count == 2 }
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Opening an unchanged template must not block exit")
        replace(textViews(editor.root)[0], with: "Сохранённая структура шаблона")
        try await wait(editor) { UnsavedEditorRegistry.hasUnsaved }
        try press("notes.template.save")
        try await wait(editor) { editor.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        guard let savedTemplate = notes.templates.first(where: { $0.id == template.id }) else { throw AppError.message("Saved template missing") }
        try expect(savedTemplate.body == "Сохранённая структура шаблона", "Native template Save did not persist")
        editor.close()
        let discardedTemplate = present(NotesEditorCheckViews.template(notes: notes, template: savedTemplate).environmentObject(app))
        defer { discardedTemplate.close() }
        try await wait(discardedTemplate) { textViews(discardedTemplate.root).count == 2 }
        replace(textViews(discardedTemplate.root)[0], with: "Отменённая структура")
        try await wait(discardedTemplate) { UnsavedEditorRegistry.hasUnsaved }
        try press("notes.template.cancel")
        try await wait(discardedTemplate) { discardedTemplate.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        try expect(notes.templates.first(where: { $0.id == template.id }) == savedTemplate, "Template Cancel changed persisted content")
        discardedTemplate.close()
        print("PASS: actual template draft blocks exit until Save or explicit Cancel and leaves no stale dirty registration")

        let context = present(NotesEditorCheckViews.context(notes: notes, meeting: meeting).environmentObject(app))
        defer { context.close() }
        try await wait(context) { descendants(context.root, as: NSTextField.self).contains { $0.placeholderString == "Проект" } }
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Opening an unchanged context must not block exit")
        try editField("Проект", in: context, text: "Проект сметы")
        try await wait(context) { UnsavedEditorRegistry.hasUnsaved }
        try press("notes.context.save")
        try await wait(context) { context.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        let savedContext = notes.context(for: meeting.id)
        try expect(savedContext.project == "Проект сметы", "Native context Save did not persist")
        context.close()
        let discardedContext = present(NotesEditorCheckViews.context(notes: notes, meeting: meeting).environmentObject(app))
        defer { discardedContext.close() }
        try await wait(discardedContext) { descendants(discardedContext.root, as: NSTextField.self).contains { $0.placeholderString == "Проект" } }
        try editField("Проект", in: discardedContext, text: "Отменённый проект")
        try await wait(discardedContext) { UnsavedEditorRegistry.hasUnsaved }
        try press("notes.context.cancel")
        try await wait(discardedContext) { discardedContext.window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        try expect(notes.context(for: meeting.id) == savedContext, "Context Cancel changed persisted content")
        print("PASS: actual meeting context draft blocks exit until Save or explicit Cancel, unchanged sheets stay clean")
    }
    private static func editField(_ placeholder: String, in session: Session, text: String) throws {
        guard let field = descendants(session.root, as: NSTextField.self).first(where: { $0.placeholderString == placeholder }) else { throw AppError.message("Native field missing: \(placeholder)") }
        session.window.attachedSheet?.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Native field editor missing: \(placeholder)") }
        replace(editor, with: text)
    }
    @MainActor private struct Session {
        let window: NSWindow
        let host: NSView
        let state: CorrectionCheckPresentation
        var root: NSView { window.attachedSheet?.contentView ?? host }
        func close() { window.orderOut(nil); window.contentView = nil }
    }
    private static func present<Content: View>(_ content: Content) -> Session {
        let state = CorrectionCheckPresentation()
        let host = NSHostingView(rootView: CorrectionCheckSheet(state: state, content: content))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 850, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        return Session(window: window, host: host, state: state)
    }
    private static func textViews(_ root: NSView) -> [NSTextView] { descendants(root, as: NSTextView.self).filter { $0.isEditable && !$0.isFieldEditor } }
    private static func replace(_ view: NSTextView, with text: String) {
        let range = NSRange(location: 0, length: (view.string as NSString).length)
        if view.shouldChangeText(in: range, replacementString: text) { view.replaceCharacters(in: range, with: text); view.didChangeText() }
    }
    private static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) } }
    private static func wait(_ session: Session, _ step: String = "layout/action", condition: () -> Bool) async throws {
        for _ in 0..<200 { session.host.layoutSubtreeIfNeeded(); session.window.displayIfNeeded(); session.window.attachedSheet?.contentView?.layoutSubtreeIfNeeded(); if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw AppError.message("Native correction editor timed out at \(step): showing=\(session.state.showing), sheet=\(session.window.attachedSheet.map { String(describing: type(of: $0)) } ?? "nil"), dirty=\(UnsavedEditorRegistry.hasUnsaved), dialogIDs=\(nodes().compactMap(\.identifier).filter { $0.contains("edit.") })")
    }
    @MainActor private struct Node {
        let object: NSObject
        private func value(_ name: String) -> Any? { let selector = NSSelectorFromString(name); guard object.responds(to: selector) else { return nil }; return object.perform(selector)?.takeUnretainedValue() }
        var identifier: String? { value("accessibilityIdentifier") as? String }
        var label: String? { value("accessibilityLabel") as? String }
        var role: String? { value("accessibilityRole") as? String }
        var ready: Bool {
            let button = (object as? NSButtonCell)?.controlView as? NSButton ?? object as? NSButton
            guard let button else { return true }
            return button.isEnabled && button.window?.isVisible == true && button.window?.isKeyWindow == true
        }
        func press() -> Bool {
            // NSAlert exposes its button cell as the semantic AXButton. Route
            // that cell through its real control, as a normal native click does.
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton, button.isEnabled {
                button.performClick(nil); return true
            }
            if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(object, selector)
        }
        var children: [Any] { value("accessibilityChildren") as? [Any] ?? [] }
    }
    private static func nodes() -> [Node] {
        var result: [Node] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, _ depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { if let child = child as? NSObject { visit(child, depth + 1) } }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth + 1) } }
        }
        for window in NSApp.windows where window.isVisible { if let view = window.contentView { visit(view, 0) } }
        return result
    }
    private static func press(_ id: String) throws { guard let node = nodes().first(where: { $0.identifier == id }), node.press() else { throw AppError.message("Native control missing: \(id)") } }
    private static func pressLabel(_ title: String) throws { guard let node = nodes().first(where: { $0.label == title && $0.role == NSAccessibility.Role.button.rawValue }), node.press() else { throw AppError.message("Native button missing: \(title)") } }
    private static func read<T: Decodable>(_ bridge: RustBridge, root: URL, path: String) throws -> T { try JSONDecoder().decode(T.self, from: bridge.request(root: root, command: "read", arguments: ["path": path])) }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw AppError.message(message) } }
}
#endif
