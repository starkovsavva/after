#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Uses a disposable library, real folder persistence and native editor controls.
@MainActor
enum FolderNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable preview required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable folder UI root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let oldConnection = TrackerSyncConfiguration()
        let oldConnectionData = try JSONEncoder().encode(oldConnection)
        try expect(try JSONDecoder().decode(TrackerSyncConfiguration.self, from: oldConnectionData).folderID == nil,
                   "Older tracker configuration without folderID must remain readable")
        var scopedConnection = oldConnection; scopedConnection.folderID = "english"
        try expect(try JSONDecoder().decode(TrackerSyncConfiguration.self, from: JSONEncoder().encode(scopedConnection)).folderID == "english",
                   "Tracker folder destination must survive Codable roundtrip")
        let app = AppStore(preview: true)
        app.settings.features = AppFeatures()
        app.settings.mode = "local"; app.settings.localProvider = "lmstudio"; app.settings.localModel = "local/qwen"
        app.saveSettings()
        let main = Host(AnyView(MainView().environmentObject(app)), width: 1260, height: 820)
        defer { main.close() }
        try await settle(main) { ids(main).contains("folder.new") }
        try snapshot(main.view, root.appendingPathComponent("folder-sidebar-empty.png"))
        let originalNotes = app.notes.workspace.notes.count
        try press(main, "folder.new")
        try await settle(main) { ids(main).contains("folder.quick.name") }
        try editName(main, text: "Личный проект")
        try await settle(main) { UnsavedEditorRegistry.hasUnsaved }
        if let sheet = main.window.attachedSheet?.contentView { try snapshot(sheet, root.appendingPathComponent("folder-create.png")) }
        try press(main, "folder.quick.save")
        try await settle(main) { app.notes.folders.contains { $0.name == "Личный проект" } && sheetsClosed(main) && !ids(main).contains("folder.quick.save") }
        guard let quickFolder = app.notes.folders.first(where: { $0.name == "Личный проект" }) else { throw AppError.message("Quick folder missing") }
        try expect(app.folderSelection == quickFolder.id && quickFolder.overrides == FolderOverrides() && app.notes.workspace.notes.count == originalNotes,
                   "Quick creation must select a real empty folder inheriting app defaults")
        try snapshot(main.view, root.appendingPathComponent("folder-project.png"))
        try doubleClick(main, "folder.select." + quickFolder.id)
        try await settle(main) { ids(main).contains("folder.quick.name") }
        try editName(main, text: "Личный проект · план")
        try await settle(main) { UnsavedEditorRegistry.hasUnsaved }
        try press(main, "folder.quick.save")
        try await settle(main) { app.notes.folder(quickFolder.id)?.name == "Личный проект · план" && sheetsClosed(main) && !ids(main).contains("folder.quick.save") }
        try expect(app.notes.folder(quickFolder.id)?.id == quickFolder.id, "Double-click folder rename must preserve stable identity")
        let renamedRevision = app.notes.folder(quickFolder.id)?.revision
        try doubleClick(main, "folder.select." + quickFolder.id)
        try await settle(main) { ids(main).contains("folder.quick.save") }
        try press(main, "folder.quick.save")
        try await settle(main) { sheetsClosed(main) && !ids(main).contains("folder.quick.save") }
        try expect(app.notes.folder(quickFolder.id)?.revision == renamedRevision, "Saving an unchanged folder name must not invalidate active model jobs")
        print("PASS: visible sidebar creation and double-click rename use short native name sheets; no-op save preserves profile revision")

        let movedMeeting = Meeting(title: "План личного проекта", source: "synthetic.mp3")
        try FileManager.default.createDirectory(at: app.meetingDirectory(movedMeeting.id), withIntermediateDirectories: true)
        try app.write(movedMeeting, app.meetingDirectory(movedMeeting.id).appendingPathComponent("meta.json")); app.reloadLibrary()
        try await settle(main) { ids(main).contains("folder.addMeetings") }
        try press(main, "folder.addMeetings")
        try await settle(main) { ids(main).contains("folder.add.meeting." + movedMeeting.id) }
        try press(main, "folder.add.meeting." + movedMeeting.id)
        try await settle(main) { app.folderID(for: movedMeeting.id) == quickFolder.id && app.selection == movedMeeting.id && sheetsClosed(main) && !ids(main).contains("folder.add.cancel") }
        try expect(app.folderSelection == quickFolder.id && app.filteredMeetings.contains { $0.id == movedMeeting.id },
                   "Selecting an existing meeting must populate its destination folder and keep the detail selected")
        app.busy = true
        NotificationCenter.default.post(name: Notification.Name("PosleMoveMeeting"), object: movedMeeting.id)
        try await settle(main) { ids(main).contains("folder.move.to.none") }
        try press(main, "folder.move.to.none")
        try await settle(main) { app.folderID(for: movedMeeting.id) == nil && app.selection == movedMeeting.id && sheetsClosed(main) && !ids(main).contains("folder.move.cancel") }
        try expect(app.folderSelection == nil && app.filteredMeetings.contains { $0.id == movedMeeting.id }, "Move must follow the destination instead of displaying a meeting under its previous folder")
        app.busy = false
        let movedRevision = app.notes.context(for: movedMeeting.id).revision
        NotificationCenter.default.post(name: Notification.Name("PosleMoveMeeting"), object: movedMeeting.id)
        try await settle(main) { ids(main).contains("folder.move.to.none") }
        try press(main, "folder.move.to.none")
        try await settle(main) { sheetsClosed(main) && !ids(main).contains("folder.move.cancel") }
        try expect(app.notes.context(for: movedMeeting.id).revision == movedRevision, "Selecting the current destination must not create a new context revision")
        try press(main, "folder.select." + quickFolder.id)
        try await settle(main) { ids(main).contains("folder.current.settings") }
        try press(main, "folder.current.settings")
        try await settle(main) { ids(main).contains("folder.delete") }
        let settingsRevision = app.notes.folder(quickFolder.id)?.revision
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) && !ids(main).contains("folder.save") }
        try expect(app.notes.folder(quickFolder.id)?.revision == settingsRevision, "Saving unchanged folder settings must preserve profile revision")
        try press(main, "folder.current.settings")
        try await settle(main) { ids(main).contains("folder.delete") }
        try press(main, "folder.delete")
        try await settle(main) { ids(main).contains("folder.delete.confirm") }
        try press(main, "folder.delete.confirm")
        try await settle(main) { app.notes.folder(quickFolder.id) == nil && sheetsClosed(main) && !ids(main).contains("folder.delete") }
        try expect(app.meetings.contains { $0.id == movedMeeting.id }, "Deleting a folder through native controls must retain the existing meeting")
        print("PASS: native empty-folder picker, destination move and confirmed deletion preserve meetings")

        var english = LibraryFolder(name: "Английский")
        english.overrides.features = FolderFeatureOverrides(); english.overrides.features?.cards = true; english.overrides.features?.tasks = true
        english.overrides.language = "en"; english.overrides.generateCards = true
        english.overrides.focus = "Фразы для практики и домашние задания"
        var created: LibraryFolder?
        let create = Host(AnyView(FolderSettingsView(folder: english, isNew: true, onSaved: { created = $0 }).environmentObject(app)), width: 840, height: 650)
        defer { create.close() }
        try await settle(create) { ids(create).contains("folder.save") }
        try press(create, "folder.save")
        try await settle(main) { created != nil && ids(main).contains("folder.select." + (created?.id ?? "")) }
        english = created!
        try expect(app.notes.folder(english.id)?.overrides.language == "en", "Native folder save must persist profile")
        try expect(app.notes.workspace.notes.allSatisfy { $0.folderID != english.id }, "Creating an empty folder must not create a dummy note")
        print("PASS: native folder editor creates persistent empty folder without changing app defaults")
        create.close()

        try press(main, "folder.select." + english.id)
        try await settle(main) { app.folderSelection == english.id && ids(main).contains("library.cards") }
        try expect(!app.settings.features.cards && app.activeSettings.features.cards, "Folder enables cards without rewriting app defaults")
        let meeting = Meeting(title: "Разговорная практика", source: "source.mp3")
        let directory = app.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        app.reloadLibrary()
        try expect(app.notes.assignMeetingFolder(meeting.id, folderID: english.id), "Meeting folder assignment failed")
        app.selection = meeting.id; app.loadSelection()
        try expect(app.filteredMeetings.contains(where: { $0.id == meeting.id }), "Folder navigation must include its meeting")
        try expect(app.effectiveSettings(for: meeting.id).language == "en", "Meeting must resolve the folder language")
        var note = CapturedNote(text: "Практиковать вежливые просьбы", title: "К следующему уроку", folderID: english.id)
        guard let saved = app.notes.save(note) else { throw AppError.message(app.notes.error ?? "Cannot create folder note") }
        note = saved
        try expect(app.notes.folder(note.folderID)?.id == english.id && note.folder == english.name, "Note and legacy display name must share the canonical folder")
        print("PASS: folder selection applies capabilities and language to meeting and standalone notes")

        var copied: LibraryFolder?
        let editor = Host(AnyView(FolderSettingsView(folder: english, onSaved: { copied = $0 }).environmentObject(app)), width: 840, height: 650)
        defer { editor.close() }
        try await settle(editor) { ids(editor).contains("folder.tab.model") }
        try press(editor, "folder.tab.features")
        try await settle(editor) { ids(editor).contains("folder.feature.cards") }
        try snapshot(editor.view, root.appendingPathComponent("folder-features-settings.png"))
        try press(editor, "folder.tab.summary")
        try await settle(editor) { ids(editor).contains("folder.language") }
        try snapshot(editor.view, root.appendingPathComponent("folder-summary-settings.png"))
        try press(editor, "folder.tab.model")
        try await settle(editor) { ids(editor).contains("folder.model.inherit") }
        try press(editor, "folder.model.inherit")
        try await settle(editor) { ids(editor).contains("folder.model.localModel") }
        try snapshot(editor.view, root.appendingPathComponent("folder-model-settings.png"))
        try press(editor, "folder.save")
        try await settle(editor) { copied != nil }
        english = copied!
        try expect(english.overrides.localProvider == "lmstudio" && english.overrides.localModel == "local/qwen", "Native inheritance switch must copy configured non-secret model selection")
        app.settings.localModel = "local/changed"; app.saveSettings()
        try expect(app.effectiveSettings(for: meeting.id).localModel == "local/qwen", "Explicit folder model must remain stable when defaults change")
        english.overrides.inheritModel()
        guard let inherited = app.notes.saveFolder(english) else { throw AppError.message(app.notes.error ?? "Cannot inherit model") }
        english = inherited
        try expect(app.effectiveSettings(for: meeting.id).localModel == "local/changed", "Returning model to inheritance must follow defaults")
        print("PASS: native model override, persistence and return to inheritance preserve global settings")
        editor.close()

        var work = LibraryFolder(name: "Работа")
        work.overrides.features = FolderFeatureOverrides(); work.overrides.features?.cards = false; work.overrides.features?.tasks = true
        guard let savedWork = app.notes.saveFolder(work) else { throw AppError.message(app.notes.error ?? "Cannot create work folder") }
        try await settle(main) { ids(main).contains("folder.select." + savedWork.id) }
        var lessonNote = CapturedNote(text: "Повторить вежливые просьбы и подготовить три примера к следующему занятию.", title: "К следующему уроку", folderID: english.id)
        lessonNote.meetingID = meeting.id
        guard app.notes.save(lessonNote) != nil else { throw AppError.message(app.notes.error ?? "Cannot prepare synthetic lesson note") }
        app.librarySection = "meetings"; app.folderSelection = english.id; app.selection = meeting.id; app.tab = "notes"; app.loadSelection()
        try await settle(main) { ids(main).contains("meeting.folder") }
        try snapshot(main.view, root.appendingPathComponent("folders-workflow.png"))
        try press(main, "folder.select." + savedWork.id)
        try await settle(main) { app.folderSelection == savedWork.id && !ids(main).contains("library.cards") }
        try expect(!app.filteredMeetings.contains(where: { $0.id == meeting.id }), "Different folder must not show English meeting")
        try press(main, "folder.select.all")
        try await settle(main) { app.folderSelection == nil && ids(main).contains("library.cards") }
        try expect(app.filteredMeetings.contains(where: { $0.id == meeting.id }), "All folders returns full meeting library")
        print("PASS: switching folders applies independent capabilities; all folders includes both profiles")

        guard let englishTask = app.notes.createWorkspaceTask(title: "Повторить просьбы", folderID: english.id),
              let workTask = app.notes.createWorkspaceTask(title: "Подготовить план синка", folderID: savedWork.id) else {
            throw AppError.message(app.notes.error ?? "Cannot create scoped tasks")
        }
        app.notes.reload(); app.notes.loadTasks(); app.notes.loadTaskWorkspaces()
        app.folderSelection = english.id
        let tasks = Host(AnyView(TasksWorkspaceView(notes: app.notes).environmentObject(app)), width: 1040, height: 700)
        defer { tasks.close() }
        try await settle(tasks) { ids(tasks).contains("tasks.row." + englishTask.id) }
        try expect(!ids(tasks).contains("tasks.row." + workTask.id), "English task list must hide another folder's task")
        app.librarySection = "tasks"
        try press(main, "folder.select." + savedWork.id)
        try expect(app.librarySection == "tasks", "Switching folders with tasks enabled must preserve the tasks workspace")
        try await settle(tasks) { ids(tasks).contains("tasks.row." + workTask.id) && !ids(tasks).contains("tasks.row." + englishTask.id) }
        app.folderSelection = nil
        try await settle(tasks) { ids(tasks).contains("tasks.row." + workTask.id) && ids(tasks).contains("tasks.row." + englishTask.id) }
        tasks.close()
        print("PASS: manual task creation preserves folder membership and native task list scopes both directions")

        var linked = CapturedNote(text: "Мысли после рабочего синка", title: "Практика формулировок", folderID: savedWork.id)
        linked.meetingID = meeting.id
        guard let linkedNote = app.notes.save(linked) else { throw AppError.message(app.notes.error ?? "Cannot create cross-folder note") }
        app.folderSelection = english.id
        app.openCapturedNote(linkedNote)
        try expect(app.librarySection == "inbox" && app.folderSelection == savedWork.id && app.notes.selectedNoteID == linkedNote.id,
                   "A linked note with its own folder must open that note without losing selection to its meeting's folder")
        let noteLibrary = Host(AnyView(NotesLibraryView(notes: app.notes).environmentObject(app)), width: 1040, height: 700)
        defer { noteLibrary.close() }
        try await settle(noteLibrary) { app.notes.selectedNoteID == linkedNote.id }
        noteLibrary.close()
        print("PASS: cross-folder note navigation preserves its own profile and selected note")

        let before = app.notes.notes.first { $0.id == note.id }
        var stale = english; stale.name = "Устаревшая правка"
        english.name = "Английский · занятия"
        guard let renamed = app.notes.saveFolder(english) else { throw AppError.message(app.notes.error ?? "Cannot rename folder") }
        try expect(app.notes.saveFolder(stale) == nil, "Concurrent profile edit must reject stale revision")
        app.notes.error = nil
        try expect(app.notes.deleteFolder(renamed), "Folder deletion failed")
        try expect(app.notes.folder(renamed.id) == nil && app.notes.notes.contains(where: { $0.id == note.id && $0.text == before?.text && $0.folderID == nil }), "Folder deletion must unlink, preserve note contents")
        try expect(app.notes.context(for: meeting.id).folderID == nil && app.meetings.contains(where: { $0.id == meeting.id }), "Folder deletion must preserve meeting")
        try expect(app.effectiveSettings(for: meeting.id).localModel == app.settings.localModel && !app.effectiveSettings(for: meeting.id).features.cards, "Deleted profile must resolve current app defaults")
        try expect(!app.busy && !app.isRecording && app.jobs.activeCount == 0 && !app.calendar.connected, "Folder checks must not start inference, recording or calendar authorization")
        print("PASS: stale profile rejected; deleting folder preserves content and restores app inheritance")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
    private static func sheetsClosed(_ host: Host) -> Bool {
        host.window.attachedSheet == nil && host.window.sheets.isEmpty
    }
    private static func settle(_ host: Host, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try? snapshot(host.view, URL(fileURLWithPath: ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] ?? "/private/tmp").appendingPathComponent("folders-failure.png"))
        throw AppError.message("Folder UI did not reach expected state at line \(line); attached sheets: \(host.window.sheets.count). IDs: " + ids(host).sorted().joined(separator: ", "))
    }
    private static func roots(_ host: Host) -> [NSView] {
        var result: [NSView] = [host.view]
        func sheets(_ window: NSWindow) {
            for sheet in window.sheets { if let view = sheet.contentView { result.append(view) }; sheets(sheet) }
        }
        sheets(host.window); return result
    }
    private static func ids(_ host: Host) -> Set<String> { Set(roots(host).flatMap(nodes).compactMap(\.identifier)) }
    private static func editName(_ host: Host, text: String) throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = roots(host).reversed().flatMap(fields).first(where: { $0.placeholderString == "Название папки" }) else { throw AppError.message("Native folder name field missing") }
        field.window?.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Native folder name editor missing") }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: text) else { throw AppError.message("Native folder name change rejected") }
        editor.replaceCharacters(in: range, with: text); editor.didChangeText()
    }
    private static func doubleClick(_ host: Host, _ identifier: String) throws {
        guard let node = roots(host).flatMap(nodes).first(where: { $0.identifier == identifier }), let frame = node.frame else { throw AppError.message("Native folder row geometry missing") }
        host.window.makeKeyAndOrderFront(nil)
        let point = host.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for count in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) else { throw AppError.message("Native double-click event missing") }
                host.window.sendEvent(event)
            }
        }
    }
    private static func press(_ host: Host, _ identifier: String) throws {
        let matching = roots(host).flatMap(nodes).filter { $0.identifier == identifier }
        for node in matching { if node.press() { return } }
        if let node = matching.first, let frame = node.frame {
            let point = NSPoint(x: frame.midX, y: frame.midY)
            var windows = [host.window]
            func addSheets(_ window: NSWindow) { for sheet in window.sheets { windows.append(sheet); addSheets(sheet) } }
            addSheets(host.window)
            if let window = windows.reversed().first(where: { $0.frame.contains(point) }) {
                window.makeKeyAndOrderFront(nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(event) }
                }
                return
            }
        }
        throw AppError.message("Folder control cannot be pressed: " + identifier + " types: " + matching.map { String(describing: type(of: $0.object)) }.joined(separator: ", "))
    }
    private static func snapshot(_ view: NSView, _ url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Feature snapshot failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Feature PNG failed") }
        try data.write(to: url)
    }
    @MainActor private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ root: AnyView, width: CGFloat, height: CGFloat) {
            view = NSHostingView(rootView: root); view.sizingOptions = []
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil) }
    }
    @MainActor private struct Node {
        let object: NSObject
        private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func get(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        var identifier: String? { modern?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var frame: NSRect? {
            if let modern { return modern.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(method, to: Frame.self)(object, selector)
        }
        var children: [Any] { modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? [] }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let control = object as? NSControl, control.isEnabled { control.performClick(nil); return true }
            if let modern { return modern.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    private static func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
}
#endif
