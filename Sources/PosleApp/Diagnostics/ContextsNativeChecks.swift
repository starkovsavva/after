#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Disposable metadata and actual native controls; no account or model access.
@MainActor
enum ContextsNativeChecks {
    @MainActor private final class Appearance: ObservableObject { @Published var dark = false }
    private struct LibraryHarness: View {
        @ObservedObject var app: AppStore
        @ObservedObject var appearance: Appearance
        var body: some View { NotesContextsView(notes: app.notes).environmentObject(app).appControlDefaults().preferredColorScheme(appearance.dark ? .dark : .light).background(Ink.paper) }
    }
    @MainActor private final class SheetPresentation: ObservableObject { @Published var showing = true }
    private struct EditorHarness: View {
        @ObservedObject var app: AppStore
        @ObservedObject var presentation: SheetPresentation
        let meeting: Meeting
        var body: some View {
            Color.clear.frame(width: 850, height: 620)
                .sheet(isPresented: $presentation.showing) { NotesEditorCheckViews.context(notes: app.notes, meeting: meeting).environmentObject(app).appControlDefaults() }
        }
    }
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable context preview required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable context root required")
        let app = AppStore(preview: true); app.settings.features.tasks = true
        guard let english = app.notes.saveFolder(LibraryFolder(name: "Английский")), let work = app.notes.saveFolder(LibraryFolder(name: "Работа")) else { throw AppError.message("Context folders fixture failed") }
        let lesson = Meeting(title: "Практика разговорного английского", source: "synthetic.mp3")
        let planning = Meeting(title: "Планирование запуска", source: "synthetic.mp3")
        for meeting in [lesson, planning] {
            try FileManager.default.createDirectory(at: app.meetingDirectory(meeting.id), withIntermediateDirectories: true)
            try app.write(meeting, app.meetingDirectory(meeting.id).appendingPathComponent("meta.json"))
        }
        app.reloadLibrary()
        try expect(app.notes.assignMeetingFolder(lesson.id, folderID: english.id) && app.notes.assignMeetingFolder(planning.id, folderID: work.id), "Folder assignment fixture failed")
        var original = app.notes.context(for: lesson.id); original.person = "Анна"; original.templateID = app.notes.templates.first?.id
        try expect(app.notes.saveContext(original), "Context fixture save failed")
        let summary = Summary(overview: "Повторили вежливые просьбы и разобрали фразы для рабочего созвона.", items: [], cards: [], provider: "fixture", model: "fixture", generatedAt: 1, warnings: [])
        try app.write(summary, app.meetingDirectory(lesson.id).appendingPathComponent("summary.json"))
        try expect(app.notes.capture(text: "Подготовить три примера вежливых просьб к следующему занятию.", meetingID: lesson.id) != nil, "Context note fixture failed")
        app.notes.notice = nil
        app.folderSelection = english.id
        let appearance = Appearance()
        let view = NSHostingView(rootView: LibraryHarness(app: app, appearance: appearance))
        view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 1050, height: 760)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = view; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let priorAX = NSApp.accessibilityAttributeValue(ax); NSApp.accessibilitySetValue(true, forAttribute: ax)
        defer { NSApp.accessibilitySetValue(priorAX, forAttribute: ax) }
        try await wait(window) { ids(window).contains("contexts.add") }
        try expect(!ids(window).contains("contexts.selection"), "Empty project list must show an action rather than an unusable picker")
        try snapshot(view, root.appendingPathComponent("contexts-empty.png"))
        try press(window, "contexts.add")
        try await wait(window) { ids(window).contains("contexts.link.label") }
        try edit(window, placeholder: "Название проекта", value: "  Разговорная практика  ")
        try await wait(window) { UnsavedEditorRegistry.hasUnsaved }
        if let sheet = window.attachedSheet?.contentView { try snapshot(sheet, root.appendingPathComponent("contexts-link.png")) }
        try press(window, "contexts.link.save")
        try await wait(window) { app.notes.context(for: lesson.id).project == "Разговорная практика" && !ids(window).contains("contexts.link.save") }
        let saved = app.notes.context(for: lesson.id)
        try expect(saved.folderID == english.id && saved.person == "Анна" && saved.templateID == original.templateID && !UnsavedEditorRegistry.hasUnsaved,
                   "Native linking must preserve the folder, person, template and clean up the draft")
        try expect(app.notes.context(for: planning.id).project.isEmpty, "Linking must never affect another folder's meeting")
        try await wait(window) { ids(window).contains("contexts.edit." + lesson.id) }
        try snapshot(view, root.appendingPathComponent("contexts-project.png"))
        print("PASS: empty context action creates a project link through native fields and preserves the existing folder/person/template")

        // A second editor snapshots the whole context revision: moving the
        // meeting in another window must not be undone by this older label.
        var stale = ContextLinkDraft(baseline: saved, mode: "person", label: "Анна · преподаватель")
        try expect(app.notes.assignMeetingFolder(lesson.id, folderID: work.id), "Concurrent context move fixture failed")
        try expect(!app.notes.saveContext(stale.updated), "A stale context label must not overwrite a concurrent folder change")
        app.notes.error = nil; app.notes.reload()
        try expect(app.notes.context(for: lesson.id).folderID == work.id && app.notes.context(for: lesson.id).person == "Анна", "Revision conflict must preserve both the current folder and original person")
        stale = ContextLinkDraft(baseline: app.notes.context(for: lesson.id), mode: "person", label: stale.label)
        try expect(app.notes.saveContext(stale.updated), "An explicit fresh retry should save the label")
        try await wait(window) { ids(window).contains("contexts.openMeetings") }
        try expect(!ids(window).contains("contexts.edit." + lesson.id), "A meeting moved out of the selected folder cannot remain in its project view")
        let englishIndex = ContextLibraryIndex(meetings: app.noteMeetings, contexts: app.notes.workspace.contexts, mode: "project")
        try expect(englishIndex.labels.isEmpty, "Folder-scoped context index must not expose labels from another folder")
        app.folderSelection = nil
        try await wait(window) { ids(window).contains("contexts.edit." + lesson.id) }
        print("PASS: folder-scoped context navigation updates after moves; stale revision cannot undo concurrent metadata")

        let index = ContextLibraryIndex(meetings: [lesson, planning], contexts: [
            MeetingContext(meetingID: lesson.id, project: "Пилот", person: "Анна"),
            MeetingContext(meetingID: planning.id, project: "  пилот  ", person: "Борис"),
            MeetingContext(meetingID: "missing", project: "Скрытый проект")
        ], mode: "project")
        try expect(index.labels.count == 1 && index.meetings(for: "ПИЛОТ").count == 2 && index.meetings(for: "").isEmpty,
                   "Context labels must match case-insensitively, deduplicate and exclude unavailable meetings")
        let briefStore = ContextBriefStore()
        let load = Task { await briefStore.load(root: root, request: ContextBriefRequest(folderID: work.id, mode: "project", label: saved.project, meetings: [lesson])) }
        // Wait for the async loader to actually begin before cancelling its scope.
        for _ in 0..<100 where !briefStore.loading && briefStore.summaries.isEmpty { await Task.yield() }
        briefStore.cancel(); load.cancel(); await load.value
        try expect(briefStore.summaries.isEmpty && !briefStore.loading, "Cancelled scope loads cannot repopulate the old folder")
        print("PASS: context index handles labels and deleted meetings; cancelled summary loads do not refill a closed scope")
        try await verifyTemplateRetry(app: app, meeting: lesson, window: window, root: root, appearance: appearance)
        try await verifyInheritedDefault(app: app, template: app.notes.templates.first(where: { $0.name == "План занятия" })!, root: root)
        print("8 native context checks passed")
    }
    private static func verifyTemplateRetry(app: AppStore, meeting: Meeting, window: NSWindow, root: URL, appearance: Appearance) async throws {
        let notes = app.notes
        let template = NoteTemplate(name: "План занятия", body: "Повторить вежливые просьбы.\nПодготовить три примера к следующему уроку.")
        try expect(notes.saveTemplate(template), "Template retry fixture failed")
        notes.error = nil; notes.notice = nil
        let previous = notes.context(for: meeting.id), noteCount = notes.notes(for: meeting.id).count
        try await wait(window) { ids(window).contains("contexts.edit." + meeting.id) }
        try press(window, "contexts.edit." + meeting.id)
        try await wait(window) { ids(window).contains("notes.context.save") && window.attachedSheet != nil }
        try edit(window, placeholder: "Проект", value: "План английского")
        try await selectTemplate(window, title: template.name)
        try await wait(window) { ids(window).contains("notes.context.insertTemplate") }
        try press(window, "notes.context.insertTemplate")
        try await wait(window) { checked(window, "notes.context.insertTemplate") == true && UnsavedEditorRegistry.hasUnsaved }
        let failureTrigger = """
        CREATE TRIGGER posle_fixture_fail_template_note BEFORE INSERT ON workspace_entities
        WHEN NEW.kind = 'note' AND NOT EXISTS(SELECT 1 FROM workspace_entities WHERE kind='note' AND entity_id=NEW.entity_id)
        BEGIN SELECT RAISE(ABORT, 'Synthetic template note write failure'); END;
        """
        try fixtureSQL(root: root, sql: failureTrigger)
        defer { try? fixtureSQL(root: root, sql: "DROP TRIGGER IF EXISTS posle_fixture_fail_template_note;") }
        try press(window, "notes.context.save")
        try await wait(window) { ids(window).contains("notes.context.templateFailure") }
        let partial = notes.context(for: meeting.id)
        try expect(partial.project == "План английского" && partial.templateID == template.id && partial.revision == previous.revision + 1,
                   "The context stage must persist once before the real note transaction fails")
        try expect(notes.notes(for: meeting.id).count == noteCount && checked(window, "notes.context.insertTemplate") == true && UnsavedEditorRegistry.hasUnsaved,
                   "A failed template note must remain pending and cannot create partial or duplicate notes")
        try expect(notes.error == nil, "The form must show concise partial-success feedback while preserving technical detail in its disclosure")
        for dark in [false, true] {
            appearance.dark = dark
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.attachedSheet?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await wait(window) { ids(window).contains("notes.context.templateFailure") }
            if let sheet = window.attachedSheet?.contentView { try snapshot(sheet, root.appendingPathComponent(dark ? "context-template-retry-dark.png" : "context-template-retry-light.png")) }
            let save = roots(window).flatMap(nodes).filter { $0.identifier == "notes.context.save" }.compactMap(\.frame).max { $0.width * $0.height < $1.width * $1.height }
            let cancel = roots(window).flatMap(nodes).filter { $0.identifier == "notes.context.cancel" }.compactMap(\.frame).max { $0.width * $0.height < $1.width * $1.height }
            try expect(save != nil && cancel != nil && abs(save!.midY - cancel!.midY) <= 1 && abs(save!.height - cancel!.height) <= 2,
                       "Native Save and Cancel must stay aligned in the complete error sheet in light and dark appearances")
        }
        appearance.dark = false; window.appearance = NSAppearance(named: .aqua); window.attachedSheet?.appearance = NSAppearance(named: .aqua)
        try fixtureSQL(root: root, sql: "DROP TRIGGER posle_fixture_fail_template_note;")
        try press(window, "notes.context.save")
        postKey(window, character: "\r", code: 36)
        try await wait(window) { window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        notes.reload()
        try expect(notes.context(for: meeting.id).revision == partial.revision && notes.notes(for: meeting.id).count == noteCount + 1,
                   "Retry must create exactly one note without a redundant context write, including a second queued default action")
        try expect(notes.notes(for: meeting.id).filter { $0.text == template.body }.count == 1, "The complete template body must persist exactly once")
        let reopened = NotesStore(root: root)
        try expect(reopened.context(for: meeting.id) == notes.context(for: meeting.id) && reopened.notes(for: meeting.id).contains { $0.text == template.body },
                   "Both committed stages must survive reopening the real SQLite library")
        print("PASS: native Save survives a real SQLite template-note failure, keeps the pending intent and retries exactly once without rewriting the committed context")

        let clean = notes.context(for: meeting.id), countAfterRetry = notes.notes(for: meeting.id).count
        try await wait(window) { ids(window).contains("contexts.edit." + meeting.id) }
        try press(window, "contexts.edit." + meeting.id)
        try await wait(window) { ids(window).contains("notes.context.save") }
        postKey(window, character: "\r", code: 36)
        try await wait(window) { window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        try expect(notes.context(for: meeting.id) == clean && notes.notes(for: meeting.id).count == countAfterRetry,
                   "Return on an unchanged editor must close without incrementing the context or copying a template")
        print("PASS: Return invokes the real default action and an unchanged editor performs no persistence")

        try press(window, "contexts.edit." + meeting.id)
        try await wait(window) { ids(window).contains("notes.context.save") }
        try edit(window, placeholder: "Проект", value: "Мой несохранённый учебный план")
        try await wait(window) { UnsavedEditorRegistry.hasUnsaved }
        let external = NotesStore(root: root)
        var winner = external.context(for: meeting.id); winner.project = "План из другого окна"
        try expect(external.saveContext(winner), "External context fixture failed")
        try press(window, "notes.context.save")
        try await wait(window) { notes.error?.contains("Контекст уже изменён") == true }
        try expect(window.attachedSheet != nil && fieldValue(window, placeholder: "Проект") == "Мой несохранённый учебный план" && UnsavedEditorRegistry.hasUnsaved,
                   "A genuine external metadata conflict must retain the native draft and pending editor")
        let persisted = NotesStore(root: root).context(for: meeting.id)
        try expect(persisted.project == winner.project && persisted.folderID == clean.folderID && persisted.person == clean.person,
                   "A rejected context edit must preserve the other window's metadata and folder")
        postKey(window, character: "\u{1b}", code: 53)
        try await wait(window) { window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        try expect(notes.notes(for: meeting.id).count == countAfterRetry, "Escape cannot duplicate or remove a template note")
        notes.error = nil; notes.reload()
        print("PASS: external context CAS conflict retains the native draft; Escape invokes Cancel without overwriting the winning metadata")

        var noTemplate = notes.context(for: meeting.id); noTemplate.templateID = nil
        try expect(notes.saveContext(noTemplate), "No-template baseline fixture failed")
        let noneBaseline = notes.context(for: meeting.id)
        try await wait(window) { ids(window).contains("contexts.edit." + meeting.id) }
        try press(window, "contexts.edit." + meeting.id)
        try await wait(window) { ids(window).contains("notes.context.save") }
        try await selectTemplate(window, title: template.name)
        try await wait(window) { ids(window).contains("notes.context.insertTemplate") }
        try press(window, "notes.context.insertTemplate")
        try await wait(window) { checked(window, "notes.context.insertTemplate") == true }
        try await selectTemplate(window, title: "Без шаблона")
        try await wait(window) { !ids(window).contains("notes.context.insertTemplate") && !UnsavedEditorRegistry.hasUnsaved }
        try press(window, "notes.context.save")
        try await wait(window) { window.attachedSheet == nil }
        try expect(notes.context(for: meeting.id) == noneBaseline && notes.notes(for: meeting.id).count == countAfterRetry && notes.error == nil,
                   "Selecting a template, enabling insertion and returning to None must remain a clean no-op without a hidden note intent")
        print("PASS: selecting None clears the hidden insertion intent and Save leaves revisions, notes and errors unchanged")
    }
    private static func verifyInheritedDefault(app: AppStore, template: NoteTemplate, root: URL) async throws {
        let previousDefault = app.settings.defaultTemplateID
        defer { app.settings.defaultTemplateID = previousDefault }
        app.settings.defaultTemplateID = template.id
        let meeting = Meeting(title: "Новый разговорный урок", source: "synthetic.mp3")
        try FileManager.default.createDirectory(at: app.meetingDirectory(meeting.id), withIntermediateDirectories: true)
        try app.write(meeting, app.meetingDirectory(meeting.id).appendingPathComponent("meta.json")); app.reloadLibrary()
        try expect(app.notes.context(for: meeting.id).revision == 0, "Inherited-default fixture must not have a persisted context")
        let presentation = SheetPresentation()
        let view = NSHostingView(rootView: EditorHarness(app: app, presentation: presentation, meeting: meeting))
        view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 850, height: 620)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { presentation.showing = false; window.orderOut(nil); window.contentView = nil }
        try await wait(window) { window.attachedSheet != nil && ids(window).contains("notes.context.insertTemplate") }
        try expect(selectedTemplate(window) == template.name && !UnsavedEditorRegistry.hasUnsaved, "A new editor must display the inherited default without inventing a dirty change")
        try await selectTemplate(window, title: "Без шаблона")
        try await wait(window) { !ids(window).contains("notes.context.insertTemplate") && UnsavedEditorRegistry.hasUnsaved }
        postKey(window, character: "\r", code: 36)
        try await wait(window) { window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        let saved = app.notes.context(for: meeting.id)
        try expect(saved.revision == 1 && saved.templateID == nil && app.notes.notes(for: meeting.id).isEmpty,
                   "Explicit None must persist a first context row without inserting a note")
        presentation.showing = true
        try await wait(window) { window.attachedSheet != nil && ids(window).contains("notes.context.save") }
        try expect(selectedTemplate(window) == "Без шаблона" && !ids(window).contains("notes.context.insertTemplate"),
                   "Reopening the new meeting must retain None instead of reapplying the global default")
        postKey(window, character: "\r", code: 36)
        try await wait(window) { window.attachedSheet == nil }
        let persisted = NotesStore(root: root).context(for: meeting.id)
        try expect(persisted == saved && app.notes.notes(for: meeting.id).isEmpty && app.notes.error == nil,
                   "A subsequent unchanged Save cannot add another context revision or template note")
        print("PASS: explicit None overrides an inherited default on a fresh meeting and survives reopening without redundant writes")
    }
    private static func selectedTemplate(_ window: NSWindow) -> String? {
        NativePickerChecks.value("notes.context.template", in: roots(window))
    }
    private static func fixtureSQL(root: URL, sql: String) throws {
        let canonical = root.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(canonical.deletingLastPathComponent().path) && canonical.lastPathComponent.hasPrefix("posle-native-check-"), "SQL fault injection must remain inside the explicit temporary fixture")
        let database = canonical.appendingPathComponent("core.sqlite")
        let values = try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try expect(values.isRegularFile == true && values.isSymbolicLink != true, "SQL fixture database must be an ordinary temporary file")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); process.arguments = [database.path, sql]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try expect(process.terminationStatus == 0, "Synthetic SQLite fixture command failed: " + output)
    }
    private static func selectTemplate(_ window: NSWindow, title: String) async throws {
        try await NativePickerChecks.select(title: title, identifier: "notes.context.template", in: roots(window))
    }
    private static func fieldValue(_ window: NSWindow, placeholder: String) -> String? {
        func fields(_ root: NSView) -> [NSTextField] { (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields) }
        return roots(window).reversed().flatMap(fields).first(where: { $0.placeholderString == placeholder })?.stringValue
    }
    private static func checked(_ window: NSWindow, _ id: String) -> Bool? {
        let matching = roots(window).reversed().flatMap(nodes).filter { $0.identifier == id }
        let checkboxes = matching.filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
        return (checkboxes.isEmpty ? matching : checkboxes).compactMap(\.checked).first
    }
    private static func postKey(_ window: NSWindow, character: String, code: UInt16) {
        let target = window.attachedSheet ?? window; target.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) { NSApp.postEvent(event, atStart: false) }
        }
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw AppError.message(message) } }
    private static func roots(_ window: NSWindow) -> [NSView] { [window.contentView, window.attachedSheet?.contentView].compactMap { $0 } }
    private static func ids(_ window: NSWindow) -> Set<String> { Set(roots(window).flatMap(nodes).compactMap(\.identifier)) }
    private static func wait(_ window: NSWindow, line: UInt = #line, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline {
                if let root = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"], let view = window.attachedSheet?.contentView ?? window.contentView {
                    try? snapshot(view, URL(fileURLWithPath: root).appendingPathComponent("context-failure.png"))
                }
                throw AppError.message("Context native control timeout at line \(line); window=\(window.frame), sheet=\(String(describing: window.attachedSheet?.frame)), screen=\(String(describing: NSScreen.main?.frame)): " + ids(window).sorted().joined(separator: ", "))
            }
            window.contentView?.layoutSubtreeIfNeeded(); window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        window.contentView?.layoutSubtreeIfNeeded(); window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
    }
    private static func edit(_ window: NSWindow, placeholder: String, value: String) throws {
        func fields(_ root: NSView) -> [NSTextField] { (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields) }
        guard let field = roots(window).reversed().flatMap(fields).first(where: { $0.placeholderString == placeholder }) else { throw AppError.message("Context field missing: " + placeholder) }
        let target = window.attachedSheet ?? window; target.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Context field editor missing") }
        editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange())
    }
    private static func press(_ window: NSWindow, _ id: String) throws {
        let target = window.attachedSheet ?? window
        NSApp.activate(ignoringOtherApps: true); target.makeKeyAndOrderFront(nil)
        target.contentView?.layoutSubtreeIfNeeded()
        let matching = roots(window).reversed().flatMap(nodes).filter { $0.identifier == id }
        // A Toggle's identifier can also appear on its containing SwiftUI
        // element. Operate/read the checkbox itself when macOS exposes it.
        let checkboxes = matching.filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
        let actionable = checkboxes.isEmpty ? matching : checkboxes
        for node in actionable { if node.press() { return } }
        if let frame = actionable.compactMap(\.frame).first(where: { $0.width > 0 && $0.height > 0 }) {
            let target = window.attachedSheet ?? window; target.makeKeyAndOrderFront(nil)
            let point = target.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            // Post the complete pair before yielding: AppKit's mouse tracking
            // may require the matching mouse-up inside its nested event loop.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
            }
            return
        }
        throw AppError.message("Context native action missing: " + id + " " + matching.map { String(describing: type(of: $0.object)) }.joined(separator: ", "))
    }
    private static func snapshot(_ view: NSView, _ url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Context snapshot failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let rendered = bitmap.cgImage,
              let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: opaque) else { throw AppError.message("Opaque context snapshot failed") }
        // A native sheet's window paints the background behind its transparent
        // hosting view. Composite that same resolved AppKit color, so inspecting
        // the exported PNG cannot mistake alpha for a black application surface.
        var background = NSColor.windowBackgroundColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        graphics.cgContext.setFillColor(background.cgColor); graphics.cgContext.fill(bounds)
        graphics.cgContext.draw(rendered, in: bounds)
        guard let data = opaque.representation(using: .png, properties: [:]) else { throw AppError.message("Context PNG failed") }
        try data.write(to: url)
    }
    private static func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, _ depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth + 1) } }
        }
        visit(root, 0); return result
    }
    @MainActor private struct Node {
        let object: NSObject
        private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func get(_ name: String) -> Any? { let selector = NSSelectorFromString(name); return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil }
        var identifier: String? { modern?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var role: String? { modern?.accessibilityRole()?.rawValue ?? get("accessibilityRole") as? String }
        var children: [Any] {
            let children = modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? []
            return children + (get("accessibilityVisibleChildren") as? [Any] ?? [])
                + (get("accessibilityContents") as? [Any] ?? [])
                + (get("accessibilityChildrenInNavigationOrder") as? [Any] ?? [])
        }
        var checked: Bool? {
            let value = modern?.accessibilityValue() ?? get("accessibilityValue")
            if let value = value as? NSNumber { return value.boolValue }
            if let value = value as? String { return value == "1" || value == "on" }
            return nil
        }
        var frame: NSRect? {
            if let modern { return modern.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(method, to: Frame.self)(object, selector)
        }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let control = cell.controlView as? NSButton, control.isEnabled { control.performClick(nil); return true }
            if let control = object as? NSControl, control.isEnabled { control.performClick(nil); return true }
            if let modern { return modern.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
}
#endif
