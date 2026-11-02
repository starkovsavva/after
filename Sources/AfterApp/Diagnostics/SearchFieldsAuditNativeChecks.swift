#if DEBUG
import AfterCore
import AfterLocalization
import AfterPlatform
import AfterPlatformMacOS
import AppKit
import Foundation
import SwiftUI

/// Captures real product views and their own popovers, never the system screen.
/// The same fixture and manifest serve the before/after search-field audit.
@MainActor
enum SearchFieldsAuditNativeChecks {
    private struct Fixture {
        let app: AppStore
        let meeting: Meeting
        let source: CapturedNote
        let folder: LibraryFolder
        let task: TaskWorkspace
    }
    private struct Capture: Codable {
        struct Field: Codable {
            struct Frame: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
            let placeholder: String
            let identifier: String?
            let frame: Frame
        }
        let id: String
        let title: String
        let source: String
        let appearance: String
        let png: String
        let crop: String
        let width: Int
        let height: Int
        let fields: [Field]
    }
    private struct Manifest: Codable { let items: [Capture] }
    @MainActor private struct Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        func close() { window.orderOut(nil); window.contentView = nil }
    }
    @MainActor private final class Audit {
        let output: URL
        let app: AppStore
        var captures: [Capture] = []
        init(output: URL, app: AppStore) { self.output = output; self.app = app }

        func host(_ content: AnyView, width: CGFloat, height: CGFloat, dark: Bool) -> Host {
            let view = NSHostingView(rootView: AnyView(content.environmentObject(app)
                .environment(\.locale, UILocalization.shared.locale)
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: width, height: height).background(Ink.paper).tint(Ink.accent).appControlDefaults()))
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.makeKeyAndOrderFront(nil)
            return Host(view: view, window: window)
        }

        func surface(_ name: String, source: String, placeholder: String, width: CGFloat, height: CGFloat,
                     dark: Bool, view: AnyView, prepare: ((Host) async throws -> Void)? = nil) async throws {
            let host = host(view, width: width, height: height, dark: dark)
            defer { host.close() }
            if let prepare { try await prepare(host) }
            let field = try await waitForField(placeholder, in: host.view)
            field.scrollToVisible(field.bounds.insetBy(dx: -12, dy: -24))
            host.window.makeFirstResponder(nil)
            try await Task.sleep(for: .milliseconds(180))
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            try record(name, source: source, placeholder: placeholder, dark: dark, view: host.view)
        }

        func record(_ name: String, source: String, placeholder: String, dark: Bool, view: NSView) throws {
            view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
            guard let field = SearchFieldsAuditNativeChecks.descendants(view).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == placeholder }),
                  !field.visibleRect.isEmpty, !field.isHiddenOrHasHiddenAncestor else {
                throw AppError.message("Search audit field is not visible: " + name)
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw AppError.message("Search audit bitmap unavailable: " + name)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw AppError.message("Search audit PNG unavailable: " + name)
            }
            let appearance = dark ? "dark" : "light"
            let filename = name + "-" + appearance + ".png"
            try png.write(to: output.appendingPathComponent(filename), options: .atomic)
            let fieldRect = view.convert(field.bounds, from: field)
            let cropRect = fieldRect.insetBy(dx: -16, dy: -14).intersection(view.bounds)
            guard !cropRect.isEmpty, let cropBitmap = view.bitmapImageRepForCachingDisplay(in: cropRect) else {
                throw AppError.message("Search audit field crop unavailable: " + name)
            }
            view.cacheDisplay(in: cropRect, to: cropBitmap)
            guard let cropPNG = cropBitmap.representation(using: .png, properties: [:]) else {
                throw AppError.message("Search audit field crop PNG unavailable: " + name)
            }
            let crop = name + "-" + appearance + "-search.png"
            try cropPNG.write(to: output.appendingPathComponent(crop), options: .atomic)
            let sx = Double(bitmap.pixelsWide) / Double(view.bounds.width)
            let sy = Double(bitmap.pixelsHigh) / Double(view.bounds.height)
            let top = view.isFlipped ? fieldRect.minY - view.bounds.minY : view.bounds.maxY - fieldRect.maxY
            let frame = Capture.Field.Frame(x: Double(fieldRect.minX - view.bounds.minX) * sx,
                y: Double(top) * sy, width: Double(fieldRect.width) * sx, height: Double(fieldRect.height) * sy)
            captures.append(Capture(id: name + "-" + appearance, title: SearchFieldsAuditNativeChecks.title(name),
                source: source, appearance: appearance, png: filename, crop: crop,
                width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                fields: [Capture.Field(placeholder: placeholder, identifier: field.accessibilityIdentifier(), frame: frame)]))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Manifest(items: captures)).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
            print("SEARCH AUDIT: " + output.appendingPathComponent(filename).path)
        }
    }

    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Search audit requires --preview and an explicit disposable data root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Search audit requires /private/tmp/posle-native-check-*")
        }
        let output = environment["POSLE_SEARCH_FIELDS_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("search-fields-audit")
        guard output.path.hasPrefix("/") else { throw AppError.message("Search audit output must be absolute") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = try seed(root: root)
        let app = fixture.app
        let audit = Audit(output: output, app: app)
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousMode, forAttribute: accessibilityMode) }

        for dark in [false, true] {
            app.folderSelection = nil; app.librarySection = "meetings"; app.libraryFilter = "Пилот"
            try await audit.surface("meeting-title-filter", source: "Sources/AfterApp/MainView.swift", placeholder: L("Название встречи"),
                width: 1260, height: 820, dark: dark, view: AnyView(MainView()))
            app.libraryFilter = ""; app.searchQuery = ""; app.showingSearch = true
            try await audit.surface("global-search", source: "Sources/AfterApp/SearchView.swift", placeholder: L("Слово или фраза"),
                width: 760, height: 650, dark: dark, view: AnyView(SearchView()))
            app.showingSearch = false
            try await audit.surface("notes-library", source: "Sources/AfterApp/NotesLibraryView.swift", placeholder: L("Поиск заметок"),
                width: 1040, height: 760, dark: dark, view: AnyView(NotesLibraryView(notes: app.notes)))
            try await audit.surface("notes-inbox", source: "Sources/AfterApp/NotesViews.swift:NotesInboxView", placeholder: L("Поиск в заметках"),
                width: 920, height: 720, dark: dark, view: AnyView(NotesInboxView(notes: app.notes)))
            try await audit.surface("tasks", source: "Sources/AfterApp/TaskListBoardViews.swift", placeholder: L("Найти задачу…"),
                width: 1120, height: 820, dark: dark, view: AnyView(TasksWorkspaceView(notes: app.notes)))
            app.transcriptSearch = ""
            try await audit.surface("transcript", source: "Sources/AfterApp/TranscriptView.swift", placeholder: L("Поиск по словам встречи"),
                width: 1040, height: 740, dark: dark, view: AnyView(TranscriptView()))
            try await audit.surface("cards", source: "Sources/AfterApp/CardsLibraryView.swift", placeholder: L("Найти карточку"),
                width: 1040, height: 740, dark: dark, view: AnyView(CardsWorkspaceView()))
            try await audit.surface("knowledge", source: "Sources/AfterApp/KnowledgeBaseView.swift", placeholder: L("Найти заметку или встречу"),
                width: 1040, height: 760, dark: dark, view: AnyView(KnowledgeBaseView()))
            try await audit.surface("trash", source: "Sources/AfterApp/TrashView.swift", placeholder: L("Найти в Корзине"),
                width: 960, height: 720, dark: dark, view: AnyView(TrashView()))
            for person in [false, true] {
                try await audit.surface(person ? "contexts-person" : "contexts-project", source: "Sources/AfterApp/NotesViews.swift:NotesContextsView",
                    placeholder: L("Фильтр"), width: 1040, height: 760, dark: dark,
                    view: AnyView(NotesContextsView(notes: app.notes)), prepare: { host in
                        if person {
                            try await wait { host.view.layoutSubtreeIfNeeded(); return NativeTabNavigation.contains("contexts.mode.person", in: host.view) }
                            try NativeTabNavigation.press("contexts.mode.person", in: host.view)
                        }
                    })
            }
            try await audit.surface("knowledge-collection", source: "Sources/AfterApp/KnowledgeCollectionPicker.swift", placeholder: L("Найти по названию или тексту"),
                width: 820, height: 720, dark: dark, view: AnyView(KnowledgeCollectionPicker(excluded: [], capacity: 200, scopeFolderID: nil, onAdd: { _ in })))
            try await audit.surface("knowledge-links", source: "Sources/AfterApp/KnowledgeLinksSheet.swift", placeholder: L("Найти заметку"),
                width: 500, height: 620, dark: dark, view: AnyView(KnowledgeLinksSheet(notes: app.notes, source: fixture.source)))
            try await audit.surface("knowledge-rebuild", source: "Sources/AfterApp/KnowledgeRebuildSheet.swift", placeholder: L("Поиск заметок"),
                width: 820, height: 660, dark: dark, view: AnyView(KnowledgeRebuildSheet(store: app)))
            try await audit.surface("task-attach-note", source: "Sources/AfterApp/TaskAttachmentSheet.swift:notePicker", placeholder: L("Найти заметку"),
                width: 580, height: 620, dark: dark, view: AnyView(TaskAttachmentSheet(notes: app.notes, task: fixture.task, kind: .note)))
            try await audit.surface("task-attach-transcript", source: "Sources/AfterApp/TaskAttachmentSheet.swift:meetingPicker", placeholder: L("Найти реплику"),
                width: 580, height: 620, dark: dark, view: AnyView(TaskAttachmentSheet(notes: app.notes, task: fixture.task, kind: .meeting)))
            try await audit.surface("folder-add-meeting", source: "Sources/AfterApp/FolderQuickActions.swift:FolderMeetingPicker", placeholder: L("Найти встречу"),
                width: 580, height: 620, dark: dark, view: AnyView(FolderMeetingPicker(folder: fixture.folder)))
            try await audit.surface("agent-snapshot-notes", source: "Sources/AfterApp/SnapshotAgentSharing.swift:TaskSnapshotShareSheet", placeholder: L("Поиск"),
                width: 720, height: 760, dark: dark, view: AnyView(TaskSnapshotShareSheet(root: root, notes: app.notes, taskID: fixture.task.id)))
            try await captureProductPopovers(audit: audit, dark: dark)
        }
        guard audit.captures.count == 40 else { throw AppError.message("Search audit did not capture every surface in both appearances") }
        print("PASS: 20 real search surfaces captured in light/dark; manifest " + output.appendingPathComponent("manifest.json").path)
    }

    private static func seed(root: URL) throws -> Fixture {
        let app = AppStore(preview: true)
        guard app.root.standardizedFileURL.resolvingSymlinksInPath() == root else { throw AppError.message("Search fixture root mismatch") }
        app.settings.features = .allEnabled; app.settings.features.semanticSearch = false
        guard app.saveSettings() else { throw AppError.message(app.error ?? "Cannot save search-audit fixture settings") }
        ThemeController.shared.configure(root: root)
        var folders: [LibraryFolder] = []
        for index in 1...9 {
            guard let folder = app.notes.saveFolder(LibraryFolder(name: "Проект \(index)")) else { throw AppError.message(app.notes.error ?? "Cannot seed audit folders") }
            folders.append(folder)
        }
        var meetings: [Meeting] = []
        for index in 1...9 {
            let meeting = Meeting(title: "Пилот \(index) · план команды", source: "fixture.mp3")
            let directory = app.meetingDirectory(meeting.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try app.write(meeting, directory.appendingPathComponent("meta.json"))
            let transcript = Transcript(duration: 120, segments: [
                Segment(id: 1, start: 0, end: 16, speaker: "speaker_1", text: "Обсудим план пилота и доступ для команды."),
                Segment(id: 2, start: 17, end: 35, speaker: "speaker_2", text: "Проверим договор и сроки запуска проекта."),
                Segment(id: 3, start: 36, end: 56, speaker: "speaker_1", text: "Следующая встреча — в пятницу; подготовим список вопросов.")
            ], warnings: [], model: "native-search-fixture")
            try app.write(transcript, directory.appendingPathComponent("transcript.json"))
            meetings.append(meeting)
        }
        app.reloadLibrary()
        for (index, meeting) in meetings.enumerated() {
            var context = app.notes.context(for: meeting.id)
            context.project = "Проект \(index + 1)"; context.person = "Участник \(index + 1)"
            guard app.notes.saveContext(context) else { throw AppError.message(app.notes.error ?? "Cannot seed audit contexts") }
        }
        for index in 1...6 {
            var note = CapturedNote(text: "План пилота \(index): проверить доступ, согласовать договор и подготовить вопросы к запуску.", title: "Материал команды \(index)")
            note.tags = ["пилот", "команда"]
            guard app.notes.save(note) != nil else { throw AppError.message(app.notes.error ?? "Cannot seed audit notes") }
        }
        guard let meeting = meetings.first, let folder = folders.first,
              let taskNote = app.notes.capture(text: "Подготовить материалы пилота", kind: "task", meetingID: meeting.id) else {
            throw AppError.message(app.notes.error ?? "Cannot seed audit task")
        }
        app.notes.loadTasks(); app.notes.loadTaskWorkspaces()
        guard let task = app.notes.loadTaskWorkspace("manual:" + taskNote.id), let source = app.notes.notes.first(where: { $0.kind == "note" }) else {
            throw AppError.message(app.notes.error ?? "Cannot read audit task")
        }
        let bridge = try RustBridge.shared.get()
        for index in 1...3 {
            _ = try bridge.request(root: root, command: "card-save", arguments: ["meetingID": meeting.id, "front": "Pilot phrase \(index)", "back": "Выражение для пилота \(index)", "kind": index == 3 ? "concept" : "phrase"])
        }
        app.folderSelection = nil; app.selection = meeting.id; app.loadSelection()
        return Fixture(app: app, meeting: meeting, source: source, folder: folder, task: task)
    }

    private static func captureProductPopovers(audit: Audit, dark: Bool) async throws {
        let controller = MaterialFilterController()
        let host = audit.host(AnyView(NotesLibraryView(notes: audit.app.notes, filterController: controller)), width: 1040, height: 760, dark: dark)
        defer { controller.cancel(); host.close() }
        try await wait { host.view.layoutSubtreeIfNeeded(); return NativeTabNavigation.contains("notes.folder", in: host.view) }
        try NativeTabNavigation.press("notes.folder", in: host.view)
        try await wait { MaterialFilterNativeNavigation.contains("notes.folder.search", host: host.view) }
        guard let picker = MaterialFilterNativeNavigation.roots(host.view).first(where: { $0 !== host.view && NativeTabNavigation.contains("notes.folder.search", in: $0) }) else {
            throw AppError.message("Product searchable-picker popover not found")
        }
        _ = try await waitForField(L("Поиск"), in: picker)
        picker.window?.makeFirstResponder(nil)
        try audit.record("searchable-picker", source: "Sources/AfterApp/AppControls.swift:AfterPickerSearch", placeholder: L("Поиск"), dark: dark, view: picker)
        picker.window?.performClose(nil)
        host.close()

        let topicsController = MaterialFilterController()
        let topicsHost = audit.host(AnyView(NotesLibraryView(notes: audit.app.notes, filterController: topicsController)), width: 1040, height: 760, dark: dark)
        defer { topicsController.cancel(); topicsHost.close() }
        try await wait { topicsHost.view.layoutSubtreeIfNeeded(); return NativeTabNavigation.contains("notes.filters.button", in: topicsHost.view) }
        try MaterialFilterNativeNavigation.press("notes.filters.button", host: topicsHost.view)
        try await wait { MaterialFilterNativeNavigation.contains("notes.filters.popover", host: topicsHost.view) }
        try await MaterialFilterNativeNavigation.add(L("Тема"), prefix: "notes.filters", host: topicsHost.view)
        try await wait { MaterialFilterNativeNavigation.contains("notes.filters.topic.search", host: topicsHost.view) && !topicsController.topicsLoading }
        guard let topic = MaterialFilterNativeNavigation.roots(topicsHost.view).first(where: { $0 !== topicsHost.view && NativeTabNavigation.contains("notes.filters.topic.search", in: $0) }) else {
            throw AppError.message("Product topic-filter popover not found")
        }
        _ = try await waitForField(L("Найти тему"), in: topic)
        topic.window?.makeFirstResponder(nil)
        try audit.record("filter-topic", source: "Sources/AfterApp/MaterialFiltersControl.swift:topic", placeholder: L("Найти тему"), dark: dark, view: topic)
        try MaterialFilterNativeNavigation.press("notes.filters.cancel", host: topicsHost.view)
    }

    private static func waitForField(_ placeholder: String, in view: NSView) async throws -> NSTextField {
        var field: NSTextField?
        try await wait {
            view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
            field = descendants(view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder }
            return field != nil
        }
        guard let field else { throw AppError.message("Search field missing: " + placeholder) }
        return field
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func title(_ name: String) -> String {
        ["meeting-title-filter": "Фильтр встреч", "global-search": "Глобальный поиск", "notes-library": "Библиотека заметок",
         "notes-inbox": "Входящие заметки", "tasks": "Задачи", "transcript": "Транскрипт", "cards": "Карточки",
         "knowledge": "База знаний", "trash": "Корзина", "contexts-project": "Проекты", "contexts-person": "Люди",
         "knowledge-collection": "Заметки для подборки", "knowledge-links": "Связи заметки", "knowledge-rebuild": "Пересборка заметок",
         "task-attach-note": "Прикрепить заметку к задаче", "task-attach-transcript": "Прикрепить реплику к задаче",
         "folder-add-meeting": "Добавить встречу в папку", "agent-snapshot-notes": "Заметки для снимка агента",
         "searchable-picker": "Поиск в списке выбора", "filter-topic": "Выбор темы в фильтрах"][name] ?? name
    }
    private static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<300 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Search-field audit view did not become ready")
    }
}
#endif
