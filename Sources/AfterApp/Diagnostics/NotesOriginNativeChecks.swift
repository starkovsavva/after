#if DEBUG
import AfterCore
import AfterPlatform
import AfterLocalization
import AfterPlatformMacOS
import AppKit
import Foundation
import SwiftUI

/// Canonical fixture data is seeded before migration in a separate disposable
/// library. Controls use the real SwiftUI view, NotesStore and Rust CAS saves.
@MainActor
enum NotesOriginNativeChecks {
    private actor RefreshTopicFixture {
        let selectedID: String
        let otherID: String
        private var excludesSelected = false
        init(selectedID: String, otherID: String) { self.selectedID = selectedID; self.otherID = otherID }
        func excludeSelected() { excludesSelected = true }
        func respond(_ command: String) async throws -> Data {
            if command == "kb-snapshot" { return Data("{\"workspaceRevision\":1,\"kbRevision\":1}".utf8) }
            if command.hasSuffix("-cancel") { return Data("{\"cancelled\":true}".utf8) }
            if command == "kb-topics" {
                let id = excludesSelected ? otherID : selectedID
                if excludesSelected { try await Task.sleep(for: .milliseconds(350)) }
                let payload: [String: Any] = [
                    "topics": [["id": "continuity", "terms": ["Controlled source"], "sources": [["noteID": id]]]],
                    "collections": [], "nextOffset": NSNull(), "partial": false,
                    "noteLimitReached": false, "topicLimitReached": false
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            }
            if command == "kb-mixed-topics" {
                return Data("{\"topics\":[],\"examined\":0,\"total\":0,\"semanticIndexed\":0,\"offset\":0,\"nextOffset\":null,\"partial\":false}".utf8)
            }
            throw AppError.message("Unexpected editor-continuity fixture request: " + command)
        }
    }
    static func run(parentRoot: URL, app: AppStore) async throws {
        let parent = parentRoot.resolvingSymlinksInPath()
        guard app.isPreview, ProcessInfo.processInfo.arguments.contains("--preview"),
              ["/private/tmp", "/tmp"].contains(parent.deletingLastPathComponent().path),
              parent.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Origin checks require a disposable notes preview")
        }
        let root = parent.appendingPathComponent("notes-origins-" + UUID().uuidString.lowercased())
        let noteDirectory = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let originalFolder = app.folderSelection
        app.folderSelection = nil
        defer { app.folderSelection = originalFolder }
        let folderA = LibraryFolder(id: "origin-alpha", name: "Origin Alpha", revision: 1)
        let folderB = LibraryFolder(id: "origin-beta", name: "Origin Beta", revision: 1)
        func raw(_ id: String, _ text: String, origin: String?, folder: String? = nil,
                 pinned: Bool = false, trash: Bool = false, meeting: String? = nil, kind: String = "note") -> [String: Any] {
            var value: [String: Any] = ["id": id, "kind": kind, "title": text, "text": text,
                                        "createdAt": 1.0, "updatedAt": 1.0, "revision": 1, "pinned": pinned]
            value["creationOrigin"] = origin; value["folderID"] = folder; value["meetingID"] = meeting
            if trash { value["trashedAt"] = Date().timeIntervalSince1970 }
            return value
        }
        let rows = [
            raw("origin-manual", "common manual", origin: "manual", folder: folderA.id, pinned: true),
            raw("origin-ai", "common ai", origin: "ai", folder: folderA.id, pinned: true),
            raw("origin-imported", "imported", origin: "imported", folder: folderB.id),
            raw("origin-legacy", "legacy source", origin: nil, meeting: "origin-source"),
            raw("origin-future", "future source", origin: "future-origin", folder: folderB.id, meeting: "origin-source"),
            raw("origin-other-manual", "other manual", origin: "manual", folder: folderB.id, kind: "important"),
            raw("origin-trash", "common ai trash", origin: "ai", trash: true)
        ]
        let folders = try JSONSerialization.jsonObject(with: JSONEncoder().encode([folderA, folderB]))
        try JSONSerialization.data(withJSONObject: ["notes": rows, "folders": folders], options: [.sortedKeys])
            .write(to: noteDirectory.appendingPathComponent("workspace.json"), options: .atomic)
        let notes = NotesStore(root: root)
        try expect(notes.error == nil && notes.notes.count == 6, "Canonical origin fixture did not migrate")
        try expect(notes.notes.first(where: { $0.id == "origin-legacy" })?.creationOrigin == .unknown
                   && notes.notes.first(where: { $0.id == "origin-future" })?.creationOrigin == .unknown
                   && notes.notes.first(where: { $0.id == "origin-imported" })?.creationOrigin == .imported,
                   "Missing/future provenance must remain unknown even with meeting links")
        var forged = CapturedNote(text: "caller cannot claim AI"); forged.creationOrigin = .ai
        guard let created = notes.save(forged) else { throw AppError.message(notes.error ?? "Cannot create manual fixture") }
        try expect(created.creationOrigin == .manual, "The creation operation must own a new manual note's origin")
        notes.purge(created)
        let canonicalBefore = try Data(contentsOf: noteDirectory.appendingPathComponent("workspace.json"))
        let preferences = OriginFilterPreferences(); preferences.configure(root: root)
        preferences.cardsFilters = MaterialFilterSet(origins: [.manual]); preferences.notesFilters = MaterialFilterSet()
        let document = LibraryNoteDocument.shared(notes: notes)
        let host = NSHostingView(rootView: NotesLibraryView(notes: notes).environmentObject(app).frame(width: 980, height: 740))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 980, height: 740)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { document.reloadPersisted(); _ = document.clear(); window.orderOut(nil); window.contentView = nil }
        func count(_ value: Int) -> Bool {
            NativeTabNavigation.nodes(in: host).contains { $0.identifier == "notes.count" && $0.value == String(value) }
        }
        func choose(_ origin: MaterialOriginFilter, count expected: Int) async throws {
            try await setOrigin(origin, prefix: "notes.filters", host: host, window: window)
            try await wait(host, window) { hasOrigin(origin, root: root) && count(expected) }
        }
        func search(_ text: String, count expected: Int) async throws {
            guard let field = descendants(host, as: NSTextField.self).first(where: { $0.placeholderString == L("Поиск заметок") }) else {
                throw AppError.message("Notes search field missing")
            }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Notes search editor missing") }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            guard editor.shouldChangeText(in: range, replacementString: text) else { throw AppError.message("Notes search typing rejected") }
            editor.replaceCharacters(in: range, with: text); editor.didChangeText(); window.makeFirstResponder(nil)
            try await wait(host, window) { count(expected) }
        }
        try await wait(host, window) { NativeTabNavigation.contains("notes.filters.button", in: host) && count(6) }
        try expect(!MaterialFilterNativeNavigation.contains("notes.filters.origin.ai", host: host),
                   "Origin choices must live inside the unified filter editor")
        try capture(host, at: root.appendingPathComponent("notes-origin-all.png"))
        try await choose(.manual, count: 3)
        try expect(document.draft?.creationOrigin == .manual, "Origin changes must select a visible matching note")
        try capture(host, at: root.appendingPathComponent("notes-origin-manual.png"))
        try await choose(.ai, count: 1)
        try await wait(host, window) { document.selectedID == "origin-ai" }
        try expect(MaterialFilterNativeNavigation.contains("notes.filters.chip.origin", host: host),
                   "An applied origin condition needs a removable chip")
        try expect(NativeTabNavigation.contains("notes.editor.origin", in: host), "The editor must expose actual creation provenance")
        try capture(host, at: root.appendingPathComponent("notes-origin-ai.png"))
        try MaterialFilterNativeNavigation.press("notes.filters.button", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.origin.manual", host: host) }
        try MaterialFilterNativeNavigation.press("notes.filters.origin.manual", host: host)
        if let popup = MaterialFilterNativeNavigation.roots(host).first(where: { NativeTabNavigation.contains("notes.filters.popover", in: $0) }) {
            popup.layoutSubtreeIfNeeded(); popup.window?.displayIfNeeded()
            try capture(popup, at: root.appendingPathComponent("notes-filters-editor.png"))
        }
        try MaterialFilterNativeNavigation.press("notes.filters.apply", host: host)
        try await wait(host, window) { count(4) }
        let multiple = OriginFilterPreferences(); multiple.configure(root: root)
        try expect(multiple.notesFilters.origins == [.manual, .ai], "Multiple origins must combine with OR inside one condition")
        try MaterialFilterNativeNavigation.press("notes.filters.button", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.origin.manual", host: host) }
        try MaterialFilterNativeNavigation.press("notes.filters.origin.manual", host: host)
        try MaterialFilterNativeNavigation.press("notes.filters.cancel", host: host)
        try await wait(host, window) { !MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host) && count(4) }
        try await choose(.ai, count: 1)
        try MaterialFilterNativeNavigation.press("notes.filters.button", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host) }
        try await MaterialFilterNativeNavigation.add(L("Тип заметки"), prefix: "notes.filters", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.kind.important", host: host) }
        try MaterialFilterNativeNavigation.press("notes.filters.kind.important", host: host)
        try MaterialFilterNativeNavigation.press("notes.filters.apply", host: host)
        try await wait(host, window) { count(0) && MaterialFilterNativeNavigation.contains("notes.filters.remove.kind", host: host) }
        try MaterialFilterNativeNavigation.press("notes.filters.remove.origin", host: host)
        try await wait(host, window) { count(1) && document.draft?.kind == "important" }
        try MaterialFilterNativeNavigation.press("notes.filters.remove.kind", host: host)
        try await wait(host, window) { count(6) }
        try await choose(.ai, count: 1)

        try MaterialFilterNativeNavigation.press("notes.filters.button", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host) }
        try await MaterialFilterNativeNavigation.add(L("Тема"), prefix: "notes.filters", host: host)
        try await wait(host, window) {
            MaterialFilterNativeNavigation.contains("notes.filters.topic.search", host: host)
                && MaterialFilterNativeNavigation.contains("notes.filters.origin.ai", host: host)
        }
        try expect(!MaterialFilterNativeNavigation.contains("notes.filters.add.meaning", host: host)
                   && !MaterialFilterNativeNavigation.contains("notes.filters.meaning", host: host),
                   "Topic and origin conditions must not expose a freephrase editor")
        try MaterialFilterNativeNavigation.press("notes.filters.row.remove.topic", host: host)
        try await wait(host, window) { !MaterialFilterNativeNavigation.contains("notes.filters.topic.search", host: host) }
        try await MaterialFilterNativeNavigation.add(L("Тип заметки"), prefix: "notes.filters", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.kind.important", host: host) }
        try expect(MaterialFilterNativeNavigation.contains("notes.filters.origin.ai", host: host)
                   && !MaterialFilterNativeNavigation.contains("notes.filters.add.meaning", host: host)
                   && !MaterialFilterNativeNavigation.contains("notes.filters.meaning", host: host),
                   "Notes filters must retain origin/topic/kind without a freephrase condition")
        try MaterialFilterNativeNavigation.press("notes.filters.cancel", host: host)
        try await wait(host, window) { !MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host) && count(1) }
        try await NativePickerChecks.select(title: folderA.name, identifier: "notes.folder", in: [host])
        try await wait(host, window) { count(1) }
        try await choose(.manual, count: 1)
        try await search("common", count: 1)
        try await search("ai", count: 0)
        try expect(NativeTabNavigation.contains("notes.filters.clear-empty", in: host), "Filter intersection needs an actionable empty state")
        try MaterialFilterNativeNavigation.press("notes.filters.remove.origin", host: host)
        try await wait(host, window) { hasOrigin(.all, root: root) && count(1) }
        try expect(NativePickerChecks.value("notes.folder", in: [host]) == folderA.name,
                   "Clearing origin must retain the selected folder")
        try await NativePickerChecks.select(title: L("Закреплённые"), identifier: "notes.section", in: [host])
        try await wait(host, window) { count(1) }
        try await choose(.ai, count: 1)
        try await NativePickerChecks.select(title: L("Корзина"), identifier: "notes.section", in: [host])
        try await wait(host, window) { count(1) && document.selectedID == "origin-trash" }
        try await choose(.manual, count: 0)
        try MaterialFilterNativeNavigation.press("notes.filters.remove.origin", host: host)
        try await wait(host, window) { count(1) && NativePickerChecks.value("notes.section", in: [host]) == L("Корзина") }
        notes.selectedNoteID = "origin-legacy"
        try await wait(host, window) {
            count(6) && document.selectedID == "origin-legacy" && hasOrigin(.all, root: root)
                && !NativeTabNavigation.contains("notes.editor.origin", in: host)
        }
        try expect(!NativeTabNavigation.contains("notes.editor.origin", in: host),
                   "Legacy notes must remain available without an unknown-origin badge")
        try await choose(.ai, count: 1)
        notes.reload()
        try await wait(host, window) { count(1) && hasOrigin(.ai, root: root) }
        let reopened = OriginFilterPreferences(); reopened.configure(root: root)
        try expect(reopened.notesFilters.origins == [.ai] && reopened.cardsFilters.origins == [.manual] && reopened.error == nil,
                   "Notes origin must persist independently of the cards origin")
        let persistedFilters = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("material-filters.json"))) as? [String: Any]
        try expect((persistedFilters?["notes"] as? [String: Any])?["origins"] as? [String] == ["ai"]
                   && (persistedFilters?["cards"] as? [String: Any])?["origins"] as? [String] == ["manual"],
                   "Unified filters must persist structured conditions separately for notes and cards")
        let canonicalAfter = try Data(contentsOf: noteDirectory.appendingPathComponent("workspace.json"))
        try expect(canonicalAfter == canonicalBefore,
                   "Filtering/navigation must not modify canonical note content or future provenance")

        notes.selectedNoteID = "origin-legacy"
        try await wait(host, window) { document.selectedID == "origin-legacy" }
        document.edit { $0.text = "Recovered orphan draft" }
        guard var legacyForeign = notes.notes.first(where: { $0.id == "origin-legacy" }) else { throw AppError.message("Orphan fixture missing") }
        legacyForeign.text = "Other editor orphan change"
        guard notes.save(legacyForeign) != nil else { throw AppError.message(notes.error ?? "Orphan conflict fixture failed") }
        try await wait(host, window) { !document.saveError.isEmpty }
        try NativeTabNavigation.press("notes.conflict.copy", in: host)
        try await wait(host, window) { document.selectedID != "origin-legacy" && document.saveError.isEmpty }
        try expect(document.draft?.meetingID == nil && document.draft?.text == "Recovered orphan draft"
                   && document.draft?.creationOrigin == .unknown,
                   "An orphan draft copy must detach an unavailable meeting and retain canonical unknown provenance")
        try await choose(.ai, count: 1)

        // A concurrent save must leave both rich user draft and selected origin
        // untouched when a native filter button attempts to leave the document.
        guard let source = notes.notes.first(where: { $0.id == "origin-ai" }) else { throw AppError.message("AI source missing") }
        let styled = NSAttributedString(string: "Unsaved rich AI draft", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        let rich = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).base64EncodedString()
        document.edit { $0.text = styled.string; $0.contentRTF = rich }
        var foreign = source; foreign.text = "Other editor canonical change"
        guard notes.save(foreign) != nil else { throw AppError.message(notes.error ?? "Concurrent origin fixture failed") }
        try await setOrigin(.manual, prefix: "notes.filters", host: host, window: window, accepted: false)
        try await wait(host, window) { !document.saveError.isEmpty }
        try expect(hasOrigin(.ai, root: root) && count(1)
                   && document.selectedID == source.id && document.draft?.text == styled.string && document.draft?.contentRTF == rich,
                   "A failed origin transition hid or discarded the rich conflicting draft")
        try expect(MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host),
                   "A rejected filter Apply must retain the editable filter draft")
        try MaterialFilterNativeNavigation.press("notes.filters.cancel", host: host)
        try await wait(host, window) { !MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host) }
        let stillAI = OriginFilterPreferences(); stillAI.configure(root: root)
        try expect(stillAI.notesFilters.origins == [.ai], "A rejected origin choice must not overwrite the stored filter")
        try NativeTabNavigation.press("notes.conflict.copy", in: host)
        try await wait(host, window) { document.selectedID != source.id && document.saveError.isEmpty && count(2) }
        try expect(document.draft?.creationOrigin == .ai && document.draft?.contentRTF == rich,
                   "A recovered copy must retain canonical AI provenance and rich formatting")
        guard let copied = document.draft else { throw AppError.message("Recovered copy missing") }
        document.edit { $0.text = "Recovery after source deletion"; $0.contentRTF = "" }
        notes.purge(copied)
        try await wait(host, window) { document.session?.conflicted == true }
        try NativeTabNavigation.press("notes.conflict.copy", in: host)
        try await wait(host, window) { document.draft?.creationOrigin == .unknown && document.saveError.isEmpty && hasOrigin(.all, root: root) }
        try await choose(.ai, count: 1)
        notes.newLibraryNoteRequest = UUID()
        try await wait(host, window) { document.draft?.creationOrigin == .manual && hasOrigin(.all, root: root) }
        try await choose(.ai, count: 1)

        window.orderOut(nil); window.contentView = nil
        let reopenedHost = NSHostingView(rootView: NotesLibraryView(notes: notes).environmentObject(app).frame(width: 780, height: 620))
        reopenedHost.sizingOptions = []; reopenedHost.frame = NSRect(x: 0, y: 0, width: 780, height: 620)
        let reopenedWindow = NSWindow(contentRect: reopenedHost.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        reopenedWindow.isReleasedWhenClosed = false; reopenedWindow.contentView = reopenedHost; reopenedWindow.makeKeyAndOrderFront(nil)
        defer { reopenedWindow.orderOut(nil); reopenedWindow.contentView = nil }
        try await wait(reopenedHost, reopenedWindow) { NativeTabNavigation.contains("notes.filters.chip.origin", in: reopenedHost) && hasOrigin(.ai, root: root) }
        reopenedWindow.orderOut(nil); reopenedWindow.contentView = nil
        try await verifyMeetingNotes(root: root, notes: notes, app: app)
        try await verifyPassiveRefresh(parentRoot: root, app: app)
        print("PASS: native note origins, search/folder/pinned/trash intersections, navigation, separate persistence and rich CAS/copy recovery")
    }
    private static func verifyPassiveRefresh(parentRoot: URL, app: AppStore) async throws {
        let root = parentRoot.appendingPathComponent("editor-continuity")
        let notes = NotesStore(root: root)
        guard let selected = notes.capture(text: "Keep this editing session"), let other = notes.capture(text: "New topic member") else {
            throw AppError.message("Cannot create editor-continuity notes")
        }
        let originalFeatures = app.settings.features
        app.settings.features.knowledgeBase = true
        defer { app.settings.features = originalFeatures }
        let fixture = RefreshTopicFixture(selectedID: selected.id, otherID: other.id)
        let controller = MaterialFilterController(request: { _, command, _ in try await fixture.respond(command) })
        notes.selectedNoteID = selected.id
        let document = LibraryNoteDocument.shared(notes: notes)
        let host = NSHostingView(rootView: NotesLibraryView(notes: notes, filterController: controller).environmentObject(app).frame(width: 980, height: 740))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 980, height: 740)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { document.reloadPersisted(); _ = document.clear(); window.orderOut(nil); window.contentView = nil }
        try await wait(host, window) { document.selectedID == selected.id && NativeTabNavigation.contains("notes.filters.button", in: host) }
        func applyTopic() async throws {
            try MaterialFilterNativeNavigation.press("notes.filters.button", host: host)
            try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host) }
            try await MaterialFilterNativeNavigation.add(L("Тема"), prefix: "notes.filters", host: host)
            try await wait(host, window) { MaterialFilterNativeNavigation.contains("notes.filters.topic.topic:continuity", host: host) }
            try MaterialFilterNativeNavigation.press("notes.filters.topic.topic:continuity", host: host)
            try MaterialFilterNativeNavigation.press("notes.filters.apply", host: host)
            try await wait(host, window) { !MaterialFilterNativeNavigation.contains("notes.filters.popover", host: host) }
        }
        try await applyTopic()
        try await wait(host, window) { !controller.topicsLoading && document.selectedID == selected.id }
        guard let editor = descendants(host, as: NSTextView.self).first(where: { $0.isEditable && $0.string == selected.text }) else {
            throw AppError.message("Editor-continuity native rich editor missing")
        }
        window.makeFirstResponder(editor); editor.breakUndoCoalescing()
        await fixture.excludeSelected()
        let suffix = " · text typed before autosave"
        editor.insertText(suffix, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        try await wait(host, window) { notes.notes.first(where: { $0.id == selected.id })?.text == selected.text + suffix && controller.topicsLoading }
        try expect(document.selectedID == selected.id && window.firstResponder === editor && editor.undoManager?.canUndo == true,
                   "Passive pending topic refresh replaced the live editor, focus or Undo after autosave")
        try await wait(host, window) { !controller.topicsLoading && controller.matchesNote(noteID: other.id, meetingID: nil, filters: MaterialFilterSet(topicIDs: ["topic:continuity"])) }
        try expect(!controller.matchesNote(noteID: selected.id, meetingID: nil, filters: MaterialFilterSet(topicIDs: ["topic:continuity"]))
                   && document.selectedID == selected.id && document.draft?.text == selected.text + suffix
                   && window.firstResponder === editor && editor.undoManager?.canUndo == true,
                   "Settled passive results must retain the editor even when its note no longer matches")
        try MaterialFilterNativeNavigation.press("notes.filters.remove.topic", host: host)
        try await applyTopic()
        try await wait(host, window) { document.selectedID == other.id }
        print("PASS: real native typing/autosave keeps its editor, focus and Undo through pending/settled topic refresh; explicit Apply still changes selection")
    }
    private static func verifyMeetingNotes(root: URL, notes: NotesStore, app: AppStore) async throws {
        let meeting = Meeting(title: "Embedded note filters", source: "fixture.mp3")
        let directory = root.appendingPathComponent("meetings").appendingPathComponent(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bridge = try RustBridge.shared.get()
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting))
        _ = try bridge.request(root: root, command: "write", arguments: ["path": "meetings/" + meeting.id + "/meta.json", "value": raw])
        for id in ["origin-manual", "origin-ai", "origin-imported", "origin-legacy", "origin-future"] {
            guard var note = notes.notes.first(where: { $0.id == id }) else { throw AppError.message("Embedded origin fixture missing") }
            note.meetingID = meeting.id; note.timestamp = nil
            guard notes.save(note) != nil else { throw AppError.message(notes.error ?? "Cannot link embedded origin fixture") }
        }
        let preferences = OriginFilterPreferences(); preferences.configure(root: root); preferences.notesFilters = MaterialFilterSet(origins: [.ai])
        notes.captureDrafts[meeting.id] = "Meeting draft remains while filtering"
        notes.highlightedNoteID = "origin-manual"
        let host = NSHostingView(rootView: NotesWorkspaceView(notes: notes, meeting: meeting).environmentObject(app).frame(width: 780, height: 760))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 780, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func count(_ value: Int) -> Bool {
            NativeTabNavigation.nodes(in: host).contains { $0.identifier == "notes.meeting.count" && $0.value == String(value) }
        }
        try await wait(host, window) { count(1) && MaterialFilterNativeNavigation.contains("notes.meeting.filters.chip.origin", host: host) }
        try expect(hasOrigin(.ai, root: root) && descendants(host, as: PlainNoteTextView.self).first?.string == notes.captureDrafts[meeting.id],
                   "Opening meeting notes with an old hidden highlight must retain persisted filters and composer draft")
        try capture(host, at: root.appendingPathComponent("notes-filters-meeting-ai.png"))
        try await setOrigin(.manual, prefix: "notes.meeting.filters", host: host, window: window)
        try await wait(host, window) { count(2) && hasOrigin(.manual, root: root) }
        try expect(notes.captureDrafts[meeting.id] == "Meeting draft remains while filtering",
                   "Filtering meeting notes must retain the unfinished composer text")
        try MaterialFilterNativeNavigation.press("notes.meeting.filters.remove.origin", host: host)
        try await wait(host, window) { count(5) }
        try capture(host, at: root.appendingPathComponent("notes-filters-meeting-all.png"))
        try await setOrigin(.ai, prefix: "notes.meeting.filters", host: host, window: window)
        notes.highlightedNoteID = "origin-future"
        try await wait(host, window) { count(5) && hasOrigin(.all, root: root) }
        try expect(notes.captureDrafts[meeting.id] == "Meeting draft remains while filtering",
                   "Revealing an explicitly requested hidden note must not clear the composer")
        try await setOrigin(.ai, prefix: "notes.meeting.filters", host: host, window: window)
        try NativeTabNavigation.press("note.composer.save", in: host)
        try await wait(host, window) { count(6) && hasOrigin(.all, root: root) && notes.captureDrafts[meeting.id] == "" }
        guard let savedID = notes.highlightedNoteID, let saved = notes.notes.first(where: { $0.id == savedID }) else {
            throw AppError.message("Meeting composer save missing")
        }
        try expect(saved.creationOrigin == .manual && saved.text == "Meeting draft remains while filtering",
                   "A manual composer save under an AI condition must be visible and retain canonical manual origin")
        try await setOrigin(.ai, prefix: "notes.meeting.filters", host: host, window: window)
        notes.captureDrafts[meeting.id] = "Retained after meeting notes reopen"
        window.orderOut(nil); window.contentView = nil
        let reopenedHost = NSHostingView(rootView: NotesWorkspaceView(notes: notes, meeting: meeting).environmentObject(app).frame(width: 780, height: 760))
        reopenedHost.sizingOptions = []; reopenedHost.frame = NSRect(x: 0, y: 0, width: 780, height: 760)
        let reopenedWindow = NSWindow(contentRect: reopenedHost.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        reopenedWindow.isReleasedWhenClosed = false; reopenedWindow.contentView = reopenedHost; reopenedWindow.makeKeyAndOrderFront(nil)
        defer { reopenedWindow.orderOut(nil); reopenedWindow.contentView = nil }
        try await wait(reopenedHost, reopenedWindow) {
            hasOrigin(.ai, root: root) && NativeTabNavigation.nodes(in: reopenedHost).contains { $0.identifier == "notes.meeting.count" && $0.value == "1" }
                && descendants(reopenedHost, as: PlainNoteTextView.self).first?.string == "Retained after meeting notes reopen"
        }
        print("PASS: meeting Notes uses unified conditions, keeps composer drafts, reveals explicit targets/new notes and preserves filters on reopen")
    }
    private static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }
    private static func hasOrigin(_ value: MaterialOriginFilter, root: URL) -> Bool {
        let preferences = OriginFilterPreferences(); preferences.configure(root: root)
        switch value {
        case .all: return preferences.notesFilters.origins.isEmpty
        case .manual: return preferences.notesFilters.origins == [.manual]
        case .ai: return preferences.notesFilters.origins == [.ai]
        }
    }
    private static func setOrigin(_ origin: MaterialOriginFilter, prefix: String, host: NSView, window: NSWindow, accepted: Bool = true) async throws {
        try MaterialFilterNativeNavigation.press(prefix + ".button", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains(prefix + ".popover", host: host) }
        if MaterialFilterNativeNavigation.roots(host).flatMap({ NativeTabNavigation.nodes(in: $0) }).contains(where: { $0.identifier == prefix + ".clear" && $0.enabled }) {
            try MaterialFilterNativeNavigation.press(prefix + ".clear", host: host)
            try await wait(host, window) { !MaterialFilterNativeNavigation.contains(prefix + ".origin.manual", host: host) }
        }
        if origin != .all {
            try await MaterialFilterNativeNavigation.add(L("Происхождение"), prefix: prefix, host: host)
            try await wait(host, window) { MaterialFilterNativeNavigation.contains(prefix + ".origin." + origin.rawValue, host: host) }
            try MaterialFilterNativeNavigation.press(prefix + ".origin." + origin.rawValue, host: host)
        }
        try MaterialFilterNativeNavigation.press(prefix + ".apply", host: host)
        if accepted { try await wait(host, window) { !MaterialFilterNativeNavigation.contains(prefix + ".popover", host: host) } }
    }
    private static func capture(_ host: NSView, at url: URL) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Notes origin bitmap unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Notes origin PNG unavailable") }
        try png.write(to: url, options: .atomic)
        print("NOTES ORIGIN SNAPSHOT: " + url.path)
    }
    private static func wait(_ host: NSView, _ window: NSWindow, line: UInt = #line, condition: () -> Bool) async throws {
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("NOTES FILTER NODES", MaterialFilterNativeNavigation.roots(host).flatMap { NativeTabNavigation.nodes(in: $0) }.filter { $0.identifier?.hasPrefix("notes.filters") == true }.map { ($0.identifier, $0.role, $0.frame) })
        if let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] { try? capture(host, at: URL(fileURLWithPath: path).appendingPathComponent("notes-filter-failure.png")) }
        throw AppError.message("Native notes origin workflow timed out at line \(line)")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
}
#endif
