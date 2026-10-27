#if DEBUG
import AppKit
import Foundation
import PosleCore

/// Disposable fixtures only: no model, network, microphone, screen or personal archive.
@MainActor
enum NotesNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Notes checks require an explicit preview fixture") }
        let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["/tmp", "/private/tmp"].contains(directory.deletingLastPathComponent().path), directory.lastPathComponent.hasPrefix("posle-native-check-") else { throw AppError.message("Notes checks require an empty /private/tmp/posle-native-check-* fixture") }
        let app = AppStore(preview: true)
        let notes = app.notes
        try QuickCaptureController.verifyDraftPreservation(store: app)
        print("PASS: quick capture preserves native closed/reopened drafts, destination and zero timestamp")
        try expect(notes.notes.isEmpty && notes.templates.count >= 4, "Builtin templates without captured data")
        let meeting = Meeting(title: "Демо · закупки", source: "source.mp3")
        let meetingURL = app.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try app.write(meeting, meetingURL.appendingPathComponent("meta.json"))
        guard let original = notes.capture(text: "Проверить доставку", kind: "important", meetingID: meeting.id, timestamp: 0) else { throw AppError.message(notes.error ?? "Capture failed") }
        notes.reload()
        try expect(notes.notes.first?.timestamp == 0 && notes.notes.first?.text == original.text, "Zero-second marker roundtrip")
        var edited = original; edited.text = "Проверить доставку и скидку"
        guard let saved = notes.save(edited) else { throw AppError.message(notes.error ?? "Edit failed") }
        try expect(saved.revision > original.revision, "Revision increments")
        edited.text = "Устаревшее изменение"; notes.error = nil
        try expect(notes.save(edited) == nil && notes.error != nil, "Stale note cannot overwrite current text")
        notes.error = nil; notes.reload()
        try expect(notes.notes.first?.text == saved.text, "Original edit survives conflict")
        print("PASS: note capture, zero timestamp, edit revisions and conflict preservation")
        guard var task = notes.capture(text: "Уточнить срок", kind: "task") else { throw AppError.message(notes.error ?? "Task capture failed") }
        task.owner = "Анна"; task.due = "до пятницы"; task = notes.save(task) ?? task
        notes.loadTasks()
        guard let item = notes.tasks.first(where: { $0.noteID == task.id }) else { throw AppError.message("Manual task missing") }
        notes.complete(item, completed: true)
        try expect(notes.tasks.first(where: { $0.noteID == task.id })?.completed == true, "Task completion persists")
        var context = MeetingContext(meetingID: meeting.id, project: "Пилот", person: "Анна")
        notes.saveContext(context); context = notes.context(for: meeting.id)
        try expect(context.project == "Пилот" && context.revision > 0, "Meeting context roundtrip")
        let template = NoteTemplate(name: "Своя повестка", body: "Цена\nДоставка", focus: "Сроки и цены")
        notes.saveTemplate(template)
        try expect(notes.templates.contains(where: { $0.id == template.id }), "Custom template saved")
        print("PASS: global manual tasks, completion, contexts and custom templates")
        let imageURL = directory.appendingPathComponent("synthetic-ocr.png")
        try syntheticImage().write(to: imageURL)
        let bytes = try Data(contentsOf: imageURL)
        var editingSession = NoteEditingSession(note: saved)
        notes.attach([imageURL], to: saved.id)
        editingSession.draft.text = "Продолжаю ввод во время копирования вложения"
        try await waitUntil { !notes.attachmentBusy }
        guard let attached = notes.notes.first(where: { $0.id == saved.id }), let attachment = attached.attachments.first else { throw AppError.message(notes.error ?? "Attachment missing") }
        try expect(try Data(contentsOf: imageURL) == bytes, "Attaching never modifies source image")
        editingSession.receive(attached)
        try expect(editingSession.draft.text == "Продолжаю ввод во время копирования вложения" && editingSession.draft.revision == attached.revision && !editingSession.conflicted, "Attachment completion advances revision without replacing text typed during copy")
        notes.recognize(attachment, note: attached)
        editingSession.draft.text += " и распознавания текста"
        editingSession.draft.owner = "Моя новая правка"
        try await waitUntil { !notes.attachmentBusy }
        guard let ocrSaved = notes.notes.first(where: { $0.id == saved.id }) else { throw AppError.message("OCR note missing") }
        editingSession.receive(ocrSaved)
        try expect(editingSession.draft.owner == "Моя новая правка" && editingSession.draft.text.contains("распознавания") && editingSession.draft.revision == ocrSaved.revision && !editingSession.conflicted, "OCR completion rebases metadata against persisted baseline while preserving typed fields")
        guard let typedSaved = notes.save(editingSession.draft) else { throw AppError.message(notes.error ?? "Draft became unsavable after OCR") }
        editingSession.didPersist(typedSaved)
        editingSession.receive(attached)
        try expect(editingSession.draft.revision == typedSaved.revision && editingSession.baseline.revision == typedSaved.revision, "Late older metadata cannot roll an editor revision backwards")
        guard let recognized = notes.notes.first(where: { $0.id == saved.id })?.attachments.first?.extractedText else { throw AppError.message(notes.error ?? "OCR did not save") }
        try expect(recognized.localizedCaseInsensitiveContains("Delivery"), "Native Vision recognizes synthetic English text")
        try expect(recognized.contains("42") && recognized.contains("Поставка"), "Native Vision preserves numeric detail and recognizes Russian")
        print("PASS: attachment copy, unchanged source and real on-device Vision OCR")
        editingSession.draft.text = "Локальный текст, который нужно сохранить"
        var external = typedSaved; external.text = "Изменение из другого окна"
        guard let externalSaved = notes.save(external) else { throw AppError.message(notes.error ?? "External edit failed") }
        editingSession.receive(externalSaved)
        try expect(editingSession.conflicted && editingSession.draft.text == "Локальный текст, который нужно сохранить" && editingSession.draft.revision == typedSaved.revision, "Real external text edits retain local draft and old revision")
        try expect(notes.save(editingSession.draft) == nil, "Concurrent external text remains protected by Rust CAS")
        guard let copiedDraft = notes.save(editingSession.asNewNote()) else { throw AppError.message(notes.error ?? "Save-as-new failed") }
        try expect(copiedDraft.id != externalSaved.id && copiedDraft.text == editingSession.draft.text && copiedDraft.attachments.isEmpty, "Conflicting draft can be saved as a new text note without stealing attachment references")
        try expect(notes.notes.first(where: { $0.id == externalSaved.id })?.text == externalSaved.text, "Saving a new note preserves the other window's text")
        print("PASS: typing during attachment/OCR remains saveable, external edits stay protected and save-as-new preserves both texts")
        guard let deletionOriginal = notes.capture(text: "Проверка повторного удаления") else { throw AppError.message("Deletion fixture failed") }
        var deletionEdit = deletionOriginal; deletionEdit.text = "Актуальная версия"
        guard let deletionCurrent = notes.save(deletionEdit) else { throw AppError.message("Deletion revision fixture failed") }
        notes.delete(deletionOriginal)
        try expect(notes.error != nil && notes.notes.contains(where: { $0.id == deletionCurrent.id }), "Stale delete must report a conflict and preserve the current note")
        notes.delete(deletionCurrent)
        try expect(notes.error == nil && !notes.notes.contains(where: { $0.id == deletionCurrent.id }), "Successful delete retry must clear the obsolete error")
        guard let trashed = notes.workspace.notes.first(where: { $0.id == deletionCurrent.id }) else { throw AppError.message("Trashed deletion fixture missing") }
        notes.purge(deletionCurrent)
        try expect(notes.error != nil && notes.workspace.notes.contains(where: { $0.id == trashed.id }), "Stale purge must preserve the trashed note")
        notes.purge(trashed)
        try expect(notes.error == nil && !notes.workspace.notes.contains(where: { $0.id == trashed.id }), "Successful purge retry must clear the obsolete error")
        print("PASS: stale delete/purge preserve data; successful retries clear their old error messages")
        notes.delete(notes.notes.first(where: { $0.id == task.id }) ?? task)
        notes.reload(); notes.loadTasks()
        try expect(!notes.notes.contains(where: { $0.id == task.id }) && !notes.tasks.contains(where: { $0.noteID == task.id }), "Deleted notes disappear from task index")
        app.reloadLibrary(); app.openMeeting(meeting.id, tab: "notes")
        try expect(app.selection == meeting.id && app.tab == "notes" && !app.isPlaying, "Own note navigation opens silently")
        let orphanMeeting = Meeting(title: "Демо · удаляемая встреча", source: "source.mp3")
        let orphanDirectory = app.meetingDirectory(orphanMeeting.id)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try app.write(orphanMeeting, orphanDirectory.appendingPathComponent("meta.json"))
        guard let orphan = notes.capture(text: "Пометка сохраняется после удаления встречи", meetingID: orphanMeeting.id) else { throw AppError.message(notes.error ?? "Orphan fixture capture failed") }
        try FileManager.default.removeItem(at: orphanDirectory)
        app.reloadLibrary(); notes.reload()
        try expect(notes.inbox(meetingIDs: Set(app.noteMeetings.map(\.id))).contains(where: { $0.id == orphan.id && $0.meetingID == orphanMeeting.id }), "Notes from removed meetings remain in Inbox without silently detaching their source")
        var orphanEdit = orphan; orphanEdit.text = "Заметку можно редактировать после удаления встречи"
        try expect(notes.save(orphanEdit)?.meetingID == orphanMeeting.id, "Existing orphan notes remain editable without erasing their original meeting link")
        print("PASS: deletion removes tasks, orphan notes remain editable in Inbox and navigation does not autoplay")
        struct Preview: Decodable { var cards: [Flashcard]; var total: Int; var skipped: Int; var warnings: [String] }
        struct Imported: Decodable { var meeting: Meeting; var count: Int; var skipped: Int; var warnings: [String] }
        let tsv = directory.appendingPathComponent("legacy-anki.tsv")
        try "#separator:Tab\n#html:true\n#columns:Front\tBack\tTags\nfollow up\tУточнить результат\tposle phrase\n".write(to: tsv, atomically: true, encoding: .utf8)
        let bridge = try RustBridge.shared.get()
        let previewData = try bridge.request(root: app.root, command: "cards-import-preview", arguments: ["path": tsv.path, "separator": "auto"])
        let preview = try JSONDecoder().decode(Preview.self, from: previewData)
        try expect(preview.cards.count == 1 && preview.cards[0].front == "follow up" && preview.cards[0].context.isEmpty && preview.cards[0].segmentIDs.isEmpty, "Legacy three-column Anki format decodes Flashcard without false source or tag context")
        let importData = try bridge.request(root: app.root, command: "cards-import", arguments: ["path": tsv.path, "separator": "auto", "title": "Демо · английский"])
        let imported = try JSONDecoder().decode(Imported.self, from: importData)
        try expect(imported.count == 1 && imported.meeting.libraryKind == "cards", "Imported deck decodes Meeting libraryKind")
        try app.write(imported.meeting, app.meetingDirectory(imported.meeting.id).appendingPathComponent("meta.json"))
        let reloaded: Meeting? = app.read(app.meetingDirectory(imported.meeting.id).appendingPathComponent("meta.json"))
        try expect(reloaded?.libraryKind == "cards", "Swift metadata edits preserve imported deck identity")
        app.reloadLibrary()
        try expect(app.noteMeetings.contains(where: { $0.id == meeting.id }) && !app.noteMeetings.contains(where: { $0.id == imported.meeting.id }), "Card decks cannot be destinations for meeting notes")
        let previousFilter = app.libraryFilter; app.libraryFilter = "No matching sidebar title"
        try expect(app.noteMeetings.contains(where: { $0.id == meeting.id }), "Note destinations are independent of the sidebar title filter")
        app.libraryFilter = previousFilter
        guard let legacyDeckNote = notes.capture(text: "Заметка старой версии, прикреплённая к колоде", meetingID: imported.meeting.id, timestamp: 0) else { throw AppError.message(notes.error ?? "Legacy deck note fixture failed") }
        let availableMeetingIDs = Set(app.noteMeetings.map(\.id))
        try expect(notes.inbox(meetingIDs: availableMeetingIDs).contains(where: { $0.id == legacyDeckNote.id && $0.meetingID == imported.meeting.id }), "Legacy notes attached to a deck remain accessible in Inbox without rewriting their identity or source")
        app.openGlobalSearch(); app.searchQuery = "прикреплённая"; app.updateSearch(immediate: true)
        try await waitUntil { !app.searching }
        guard let legacyHit = app.searchHits.first(where: { $0.noteID == legacyDeckNote.id }) else { throw AppError.message("Legacy deck note must remain searchable") }
        app.openSearchHit(legacyHit)
        try await waitUntil { app.searchOpeningID == nil }
        try expect(app.librarySection == "inbox" && notes.highlightedNoteID == legacyDeckNote.id && !app.isPlaying, "Search opens a legacy deck note in accessible Inbox without audio")
        let retainedDraft = QuickCaptureDraft(); retainedDraft.prepare(meetingID: imported.meeting.id, timestamp: 0)
        retainedDraft.text = "Черновик не должен потеряться в скрытой колоде"
        let fallback = retainedDraft.destination(in: app.meetings)
        try expect(fallback.meetingID == nil && fallback.timestamp == nil && retainedDraft.meetingID == imported.meeting.id && !retainedDraft.text.isEmpty, "A retained deck destination falls back to Inbox without changing the unfinished draft")
        guard let fallbackNote = notes.capture(text: retainedDraft.text, kind: retainedDraft.kind, meetingID: fallback.meetingID, timestamp: fallback.timestamp) else { throw AppError.message(notes.error ?? "Inbox fallback capture failed") }
        try expect(fallbackNote.meetingID == nil && fallbackNote.timestamp == nil && notes.inbox(meetingIDs: availableMeetingIDs).contains(where: { $0.id == fallbackNote.id }), "Saving a draft with an unavailable deck destination creates an accessible Inbox note without a foreign timestamp")
        let exported = directory.appendingPathComponent("roundtrip.tsv")
        try Exporter.anki(cards: preview.cards, title: "Демо").write(to: exported, atomically: true, encoding: .utf8)
        let roundtripData = try bridge.request(root: app.root, command: "cards-import-preview", arguments: ["path": exported.path, "separator": "auto"])
        let roundtrip = try JSONDecoder().decode(Preview.self, from: roundtripData)
        try expect(roundtrip.total == 1 && roundtrip.cards.first?.front == "follow up" && roundtrip.cards.first?.segmentIDs.isEmpty == true, "App export imports as cards with no invented source references")
        print("PASS: native cards import/export, deck identity, real meeting destinations and accessible Inbox fallback for legacy deck notes")
        var formatted = CapturedNote(text: "План\n☐ Проверить договор", title: "Договор на пилот", folder: "Проект", tags: ["пилот", "договор"], pinned: true)
        let styled = NSAttributedString(string: formatted.text, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold)])
        formatted.contentRTF = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).base64EncodedString()
        guard let richSaved = notes.save(formatted) else { throw AppError.message(notes.error ?? "Rich note did not save") }
        notes.reload()
        guard let rich = notes.notes.first(where: { $0.id == richSaved.id }) else { throw AppError.message("Rich note disappeared") }
        try expect(rich.title == formatted.title && rich.folder == "Проект" && rich.tags == formatted.tags && rich.pinned && rich.contentRTF == formatted.contentRTF, "Formatting, folder, tags and pin survive native Rust roundtrip")
        notes.delete(rich); notes.loadTasks()
        guard let trashed = notes.workspace.notes.first(where: { $0.id == rich.id }) else { throw AppError.message("Trash removed the recoverable document") }
        try expect(trashed.trashedAt != nil && !notes.notes.contains(where: { $0.id == rich.id }) && !trashed.contentRTF.isEmpty, "Trash preserves rich content without appearing in active notes")
        let hidden = try bridge.request(root: app.root, command: "notes-search", arguments: ["query": "Договор на пилот"])
        let hiddenJSON = try JSONSerialization.jsonObject(with: hidden) as? [String: Any]
        try expect((hiddenJSON?["notes"] as? [Any])?.isEmpty == true, "Trashed documents stay out of global note search")
        notes.restore(trashed)
        guard var restoredRich = notes.notes.first(where: { $0.id == rich.id }) else { throw AppError.message("Restore failed") }
        restoredRich.text += "\nПравка из обычного редактора"
        guard let plainSaved = notes.save(restoredRich) else { throw AppError.message(notes.error ?? "Plain edit failed") }
        try expect(plainSaved.contentRTF.isEmpty && plainSaved.folder == rich.folder, "Plain edits cannot retain stale rich text and keep note organization")
        notes.purge(plainSaved)
        try expect(!notes.workspace.notes.contains(where: { $0.id == rich.id }), "Explicit permanent deletion removes the restored document")
        print("PASS: rich note metadata/RTF roundtrip, recoverable Trash, search exclusion, restore and stale formatting safety")
        try NoteDraftPersistence.verifyImmediatePersistence(notes: notes)
        print("PASS: immediate quit flushes debounce, failed CAS retains both versions and the draft recovers as a copy")
        try RichNoteNativeChecks.run()
        print("PASS: native formatting Undo/Redo preserves typed text, heading size and table RTF")
        print("11 native notes checks passed")
    }
    private static func syntheticImage() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw AppError.message("Cannot create synthetic image") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 160).fill()
        NSString(string: "Delivery 42 · Поставка").draw(at: NSPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 35), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Cannot encode synthetic image") }
        return data
    }
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw AppError.message("Native notes check timed out")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}
#endif
