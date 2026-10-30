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
        try await featureDefaultsWorkflow(app, main: main, root: root)
    }
    /// Follow the visible scope shortcut and native controls, then reopen the real stored profiles.
    private static func featureDefaultsWorkflow(_ app: AppStore, main: Host, root: URL) async throws {
        app.settings.features = AppFeatures(); app.saveSettings()
        var english = LibraryFolder(name: "Английский")
        english.overrides.features = FolderFeatureOverrides()
        english.overrides.features?.cards = true; english.overrides.features?.calendar = false
        english.overrides.language = "en"; english.overrides.localModel = "fixture/english"
        var work = LibraryFolder(name: "Работа · профиль")
        work.overrides.features = FolderFeatureOverrides()
        work.overrides.features?.cards = false; work.overrides.features?.calendar = true
        var inherited = LibraryFolder(name: "Общие настройки")
        guard let savedEnglish = app.notes.saveFolder(english), let savedWork = app.notes.saveFolder(work),
              let savedInherited = app.notes.saveFolder(inherited) else { throw AppError.message(app.notes.error ?? "Cannot prepare feature scopes") }
        english = savedEnglish; work = savedWork; inherited = savedInherited
        let bridge = try RustBridge.shared.get()
        func deck(_ title: String, folder: LibraryFolder) throws -> CardSaveResult {
            let data = try bridge.request(root: root, command: "card-save", arguments: ["front": "Согласовать", "back": "To agree", "newDeckTitle": title])
            let result = try JSONDecoder().decode(CardSaveResult.self, from: data)
            // Keep a real saved card, but exercise ordinary meeting navigation.
            // A standalone libraryKind=cards deck is intentionally absent from meetings.
            var meeting = result.meeting; meeting.libraryKind = nil; meeting.source = "synthetic.mp3"
            try app.write(meeting, app.meetingDirectory(meeting.id).appendingPathComponent("meta.json"))
            try expect(app.notes.assignMeetingFolder(result.meeting.id, folderID: folder.id), "Synthetic deck folder assignment failed")
            return result
        }
        let lesson = try deck("Английский · практика", folder: english)
        let sync = try deck("Рабочий синк", folder: work)
        let inheritedMeeting = Meeting(title: "Общий календарь", source: "synthetic.mp3")
        try FileManager.default.createDirectory(at: app.meetingDirectory(inheritedMeeting.id), withIntermediateDirectories: true)
        try app.write(inheritedMeeting, app.meetingDirectory(inheritedMeeting.id).appendingPathComponent("meta.json"))
        try expect(app.notes.assignMeetingFolder(inheritedMeeting.id, folderID: inherited.id), "Synthetic calendar meeting folder assignment failed")
        let lessonSummary = app.meetingDirectory(lesson.meeting.id).appendingPathComponent("summary.json")
        let workSummary = app.meetingDirectory(sync.meeting.id).appendingPathComponent("summary.json")
        let lessonBefore = try Data(contentsOf: lessonSummary), workBefore = try Data(contentsOf: workSummary)
        app.reloadLibrary(); app.librarySection = "meetings"
        try await settle(main) { ids(main).contains("folder.select." + english.id) }
        try press(main, "folder.select." + english.id)
        try await settle(main) { ids(main).contains("library.cards") && !ids(main).contains("library.calendar") && ids(main).contains("folder.features.open") }
        try snapshot(main.view, root.appendingPathComponent("folder-features-english.png"))
        try await folderListWorkflow(app, main: main, root: root, english: english, work: work)
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("folder.feature.calendar") && ids(main).contains("folder.features.defaults") }
        try expect(selectedFeature(main, .cards) == "Включено" && selectedFeature(main, .calendar) == "Выключено",
                   "The visible folder shortcut must open the selected folder's actual override controls")
        try snapshot(main.window.attachedSheet?.contentView ?? main.view, root.appendingPathComponent("folder-features-clean.png"))
        try await chooseFeature(main, .calendar, title: "Включено")
        try await settle(main) { UnsavedEditorRegistry.hasUnsaved }
        try snapshot(main.window.attachedSheet?.contentView ?? main.view, root.appendingPathComponent("folder-features-customize.png"))
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) && ids(main).contains("library.calendar") && !UnsavedEditorRegistry.hasUnsaved }
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("folder.feature.calendar") }
        try expect(selectedFeature(main, .calendar) == "Включено", "A saved native override must survive reopening the folder editor")
        try await chooseFeature(main, .calendar, title: "Выключено")
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) && !ids(main).contains("library.calendar") }
        guard let darkFolder = app.notes.folder(english.id) else { throw AppError.message("Saved feature profile missing") }
        let dark = Host(AnyView(FolderSettingsView(folder: darkFolder, section: "features").environmentObject(app).preferredColorScheme(.dark)), width: 840, height: 650)
        try await settle(dark) { ids(dark).contains("folder.feature.calendar") && selectedFeature(dark, .cards) == "Включено" }
        try snapshot(dark.view, root.appendingPathComponent("folder-features-dark.png"))
        dark.close()
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Taking a dark appearance preview must not change the folder or create a draft")
        print("PASS: visible scoped shortcut opens real tri-state controls; saving on/off updates the selected sidebar immediately and survives reopen")

        try press(main, "library.cards")
        try await settle(main) { app.librarySection == "cards" }
        try press(main, "folder.select." + work.id)
        try await settle(main) { app.librarySection == "meetings" && !ids(main).contains("library.cards") && ids(main).contains("library.calendar") }
        try snapshot(main.view, root.appendingPathComponent("folder-features-work.png"))
        try press(main, "folder.select." + english.id)
        app.selection = lesson.meeting.id; app.loadSelection(); app.tab = "cards"
        try await settle(main) { app.tab == "cards" && app.selection == lesson.meeting.id }
        try press(main, "folder.select." + work.id)
        try await settle(main) { app.selection == sync.meeting.id && app.tab == "summary" }
        try expect(app.folderSelection == work.id && !app.isFeatureEnabled(.cards),
                   "A destination without cards must select its meeting's summary rather than retaining the previous meeting's cards tab")
        print("PASS: English and Work show independent sidebars; switching away from hidden library and meeting tabs selects an available destination")

        app.settings.features.calendar = true; app.saveSettings()
        try press(main, "library.calendar")
        try await settle(main) { app.librarySection == "calendar" && app.selection == sync.meeting.id }
        try press(main, "folder.select." + inherited.id)
        try await settle(main) { app.librarySection == "calendar" && app.selection == inheritedMeeting.id }
        try press(main, "library.meetings")
        try await settle(main) { app.librarySection == "meetings" && app.selection == inheritedMeeting.id && app.selected?.id == inheritedMeeting.id }
        try expect(app.filteredMeetings.contains(where: { $0.id == inheritedMeeting.id }) && app.folderSelection == inherited.id,
                   "Changing folders while Calendar stays open must not retain another folder's stale meeting when returning to Meetings")
        app.settings.features.calendar = false; app.saveSettings()
        print("PASS: changing folders inside Calendar normalizes the selected meeting before returning to the meetings view")

        try press(main, "folder.select." + inherited.id)
        try await settle(main) { !ids(main).contains("library.cards") }
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("folder.features.defaults") }
        try expect(selectedFeature(main, .cards)?.hasPrefix("Как в приложении") == true, "New folders must start with live inheritance")
        try press(main, "folder.features.defaults")
        try await settle(main) { ids(main).contains("features.cards") && ids(main).contains("features.defaults.close") }
        try press(main, "features.cards")
        try await settle(main) { app.settings.features.cards && ids(main).contains("library.cards") }
        try expect(app.effectiveSettings(folderID: english.id).features.cards && !app.effectiveSettings(folderID: work.id).features.cards,
                   "Changing global defaults must follow inheritance without rewriting explicit folder on/off choices")
        try press(main, "features.defaults.close")
        try await settle(main) { ids(main).contains("folder.save") && !ids(main).contains("features.defaults.close") }
        try expect(selectedFeature(main, .cards)?.contains("вкл.") == true && !UnsavedEditorRegistry.hasUnsaved,
                   "The inherited picker must refresh from global defaults without inventing a folder draft")
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) }
        try press(main, "library.cards")
        try await settle(main) { app.librarySection == "cards" }
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("folder.features.defaults") }
        try press(main, "folder.features.defaults")
        try await settle(main) { ids(main).contains("features.cards") }
        try press(main, "features.cards")
        try await settle(main) { !app.settings.features.cards && app.librarySection == "meetings" && !ids(main).contains("library.cards") }
        try press(main, "features.defaults.close")
        try await settle(main) { ids(main).contains("folder.save") && !ids(main).contains("features.defaults.close") }
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) }
        try expect(app.notes.folder(inherited.id)?.overrides.features == nil,
                   "Editing global defaults must not copy a feature snapshot into an inherited folder")
        try press(main, "folder.select.all")
        try await settle(main) { ids(main).contains("library.cards") && ids(main).contains("library.calendar") }
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("features.cards") && ids(main).contains("features.defaults.close") }
        try expect(!app.settings.features.cards && app.visibleFeatures.cards && app.visibleFeatures.calendar,
                   "All folders must include explicitly enabled folder content while global defaults remain off")
        try snapshot(main.window.attachedSheet?.contentView ?? main.view, root.appendingPathComponent("folder-features-defaults.png"))
        try press(main, "features.defaults.close")
        try await settle(main) { sheetsClosed(main) }
        print("PASS: global controls reached from both scopes update inheriting folders, preserve explicit choices and keep All folders' content discoverable")

        try press(main, "folder.select." + english.id)
        try await settle(main) { ids(main).contains("library.cards") }
        try press(main, "library.cards")
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("folder.features.inheritAll") }
        try press(main, "folder.features.inheritAll")
        try await settle(main) { selectedFeature(main, .cards)?.hasPrefix("Как в приложении") == true && UnsavedEditorRegistry.hasUnsaved }
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) && app.librarySection == "meetings" && !ids(main).contains("library.cards") }
        guard let reset = app.notes.folder(english.id) else { throw AppError.message("Reset folder missing") }
        try expect(reset.overrides.features == nil && reset.overrides.localModel == "fixture/english" && reset.overrides.language == "en",
                   "Resetting feature inheritance must preserve separate model and summary-language overrides")
        let reopened = AppStore(preview: true)
        try expect(reopened.notes.folder(english.id)?.overrides == reset.overrides
                   && reopened.notes.folder(inherited.id)?.overrides.features == nil
                   && reopened.effectiveSettings(folderID: work.id).features.calendar
                   && !reopened.effectiveSettings(folderID: work.id).features.cards
                   && !reopened.settings.features.cards,
                   "Global defaults, sparse overrides and reset must survive a fresh store load")
        try expect(try Data(contentsOf: lessonSummary) == lessonBefore && Data(contentsOf: workSummary) == workBefore,
                   "Hiding cards, changing defaults and resetting folder features must preserve existing card bytes")
        try expect(!app.busy && !app.isRecording && app.jobs.activeCount == 0 && !app.calendar.connected && !app.calendar.requesting,
                   "Folder feature navigation must not start model inference, recording or calendar authorization")
        print("PASS: reset returns only feature choices to inheritance, preserves model/language and existing cards, and persists through a fresh store load")
    }
    private static func folderListWorkflow(_ app: AppStore, main: Host, root: URL, english: LibraryFolder, work: LibraryFolder) async throws {
        let settingsURL = root.appendingPathComponent("settings.json")
        let settingsBefore = try Data(contentsOf: settingsURL)
        let englishBefore = app.notes.folder(english.id), workBefore = app.notes.folder(work.id)
        try expect(app.foldersExpanded && app.folderSelection == english.id, "Folder-list fixture must start expanded in English")
        try await toggleFolders(main, app: app, expanded: false)
        try await settle(main) {
            !ids(main).contains("folder.select." + english.id) && !ids(main).contains("folder.new")
                && ids(main).contains("folder.scope.menu") && ids(main).contains("folder.features.open")
        }
        try expect(app.folderSelection == english.id && ids(main).contains("library.cards") && !ids(main).contains("library.calendar"),
                   "Collapsing folders must preserve the selected scope and its visible features")
        try snapshot(main.view, root.appendingPathComponent("folder-sidebar-collapsed.png"))
        let collapsed = AppStore(preview: true)
        try expect(!collapsed.foldersExpanded, "Collapsed folder list must survive a fresh application store")
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("folder.feature.cards") }
        try expect(selectedFeature(main, .cards) == "Включено" && selectedFeature(main, .calendar) == "Выключено",
                   "The persistent header must open the selected folder's feature controls while its list is hidden; cards=\(selectedFeature(main, .cards) ?? "missing"), calendar=\(selectedFeature(main, .calendar) ?? "missing")")
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) && !app.foldersExpanded }
        try await choosePublishedScope(main, folder: work, app: app)
        try await settle(main) { app.folderSelection == work.id && ids(main).contains("library.calendar") && !ids(main).contains("library.cards") }
        try expect(!app.foldersExpanded && !ids(main).contains("folder.select." + work.id) && ids(main).contains("folder.scope.menu"),
                   "Changing the active scope must preserve the collapsed list and expose the new folder's capabilities")
        print("PASS: actual native scope menu changes the active folder while the folder list stays collapsed")
        try press(main, "folder.features.open")
        try await settle(main) { ids(main).contains("folder.feature.cards") }
        try expect(selectedFeature(main, .cards) == "Выключено" && selectedFeature(main, .calendar) == "Включено",
                   "Collapsed-scope settings must follow the new selection instead of the previous folder")
        try press(main, "folder.save")
        try await settle(main) { sheetsClosed(main) }
        try await toggleFolders(main, app: app, expanded: true)
        try await settle(main) { ids(main).contains("folder.select." + english.id) && ids(main).contains("folder.new") }
        try expect(AppStore(preview: true).foldersExpanded && app.notes.folder(english.id) == englishBefore && app.notes.folder(work.id) == workBefore,
                   "Expanding the folder list must persist its layout without changing either folder profile")
        try expect(try Data(contentsOf: settingsURL) == settingsBefore, "Changing folder-list layout must not alter AI processing settings")
        try press(main, "folder.select." + english.id)
        try await settle(main) { app.folderSelection == english.id && ids(main).contains("library.cards") && !ids(main).contains("library.calendar") }
        print("PASS: native collapse/expand persists across reopening, keeps scope and feature access usable, and never changes processing profiles")

        let stateURL = root.appendingPathComponent("sidebar-state.json")
        let backupURL = root.appendingPathComponent("sidebar-state-check-backup.json")
        let persistedState = try Data(contentsOf: stateURL)
        try FileManager.default.moveItem(at: stateURL, to: backupURL)
        do {
            defer {
                try? FileManager.default.removeItem(at: stateURL)
                try? FileManager.default.moveItem(at: backupURL, to: stateURL)
            }
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
            try expect(!app.setFoldersExpanded(false) && app.foldersExpanded && app.error != nil,
                       "A failed sidebar-preference write must retain the currently displayed layout")
            try expect(try Data(contentsOf: backupURL) == persistedState && Data(contentsOf: settingsURL) == settingsBefore,
                       "A failed layout save must preserve the last state and existing processing-settings bytes")
        }
        app.error = nil
        try expect(try Data(contentsOf: stateURL) == persistedState && AppStore(preview: true).foldersExpanded,
                   "Restoring the fixture must preserve the last successful expanded preference")
        print("PASS: sidebar save failure preserves the live layout, prior preference and all processing settings")
    }
    private static func toggleFolders(_ host: Host, app: AppStore, expanded: Bool) async throws {
        guard app.foldersExpanded != expanded else { return }
        let candidates = roots(host).flatMap(nodes).filter { $0.identifier == "folder.list.toggle" }
        for node in candidates { if node.press() { break } }
        for _ in 0..<5 {
            if app.foldersExpanded == expanded { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let frame = roots(host).flatMap(nodes).first(where: { $0.identifier == "folder.list.label" })?.frame else {
            throw AppError.message("Native folder disclosure label missing")
        }
        // Standard DisclosureGroup has a real arrow at the sidebar's leading
        // inset. Its virtual AX group can include all expanded child rows.
        let bounds = host.window.convertToScreen(host.view.convert(host.view.bounds, to: nil))
        let point = host.window.convertPoint(fromScreen: NSPoint(x: bounds.minX + 18, y: frame.midY))
        host.window.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                host.window.sendEvent(event)
            }
        }
        try await settle(host) { app.foldersExpanded == expanded }
    }
    private static func choosePublishedScope(_ host: Host, folder: LibraryFolder, app: AppStore) async throws {
        do {
            // The shared driver materializes lazy NSMenus and waits for modern
            // SwiftUI menu windows before sending a complete keyboard sequence.
            try await NativePickerChecks.select(title: folder.name, identifier: "folder.scope.menu", in: roots(host))
        } catch {
            // A pull-down Menu may keep its label/placeholder as its AX value.
            // Its exact published destination is the authoritative action result.
            guard app.folderSelection == folder.id else { throw error }
        }
        try await settle(host) { app.folderSelection == folder.id }
    }
    private static func featurePopup(_ host: Host, _ feature: AppFeature) -> NSPopUpButton? {
        func popups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups) }
        let controls = roots(host).reversed().flatMap(popups).filter {
            $0.itemTitles.contains("Включено") && $0.itemTitles.contains("Выключено") && $0.itemTitles.contains(where: { $0.hasPrefix("Как в приложении") })
        }
        let identifier = "folder.feature." + feature.rawValue
        if let control = controls.first(where: { $0.accessibilityIdentifier() == identifier }) { return control }
        if let frame = roots(host).flatMap(nodes).first(where: { $0.identifier == identifier })?.frame,
           let control = controls.first(where: { frame.intersects($0.accessibilityFrame()) }) { return control }
        // SwiftUI may expose the identifier on its virtual accessibility wrapper.
        // The native controls retain the feature order from the real form.
        let ordered: [AppFeature] = [.tasks, .cards, .calendar, .assistant, .semanticSearch]
        guard let index = ordered.firstIndex(of: feature), controls.indices.contains(index) else { return nil }
        return controls[index]
    }
    private static func selectedFeature(_ host: Host, _ feature: AppFeature) -> String? {
        featurePopup(host, feature)?.titleOfSelectedItem ?? NativePickerChecks.value("folder.feature." + feature.rawValue, in: roots(host))
    }
    private static func chooseFeature(_ host: Host, _ feature: AppFeature, title: String) async throws {
        if featurePopup(host, feature) == nil {
            try await NativePickerChecks.select(title: title, identifier: "folder.feature." + feature.rawValue, in: roots(host))
            return
        }
        guard let popup = featurePopup(host, feature), let menu = popup.menu,
              let item = menu.items.first(where: { $0.title == title }) else { throw AppError.message("Native feature popup option missing: " + feature.rawValue + " / " + title) }
        popup.select(item); menu.performActionForItem(at: popup.indexOfSelectedItem)
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
        var children: [Any] {
            let children = modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? []
            let visible = get("accessibilityVisibleChildren") as? [Any] ?? []
            let contents = get("accessibilityContents") as? [Any] ?? []
            let navigation = get("accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            return children + visible + contents + navigation
        }
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
