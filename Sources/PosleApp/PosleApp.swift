import AppKit
import SwiftUI
import PosleCore

@main
struct PosleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore(preview: ProcessInfo.processInfo.arguments.contains("--preview"))

    var body: some Scene {
        WindowGroup("После") {
            MainView().environmentObject(store)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .frame(minWidth: 1040, minHeight: 700)
                .onAppear { delegate.connect(store) }
                .onOpenURL { url in
                    if store.calendar.openLink(url) { store.librarySection = "calendar" }
                    else if url.isFileURL { store.importFile(url) }
                }
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForAppUpdates(updates: store.updates)
                OpenUpdateDraft(updates: store.updates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Добавить запись…") { store.chooseFile() }.keyboardShortcut("o")
                Button(store.librarySection == "inbox" ? "Новая заметка" : "Записать встречу…") {
                    if store.librarySection == "inbox" { store.notes.newLibraryNoteRequest = UUID() }
                    else { store.showingRecord = true }
                }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Голосовое поручение…") { store.presentVoice() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Быстрая заметка…") { store.quickCaptureAction?() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Отметить важный момент") { store.bookmarkAction?() }
                Button("Поиск по библиотеке…") { store.openGlobalSearch() }.keyboardShortcut("k")
            }
            CommandMenu("Встреча") {
                Button("Конспект") { store.librarySection = "meetings"; store.tab = "summary" }.keyboardShortcut("1")
                Button("Транскрипт") { store.librarySection = "meetings"; store.tab = "transcript" }.keyboardShortcut("2")
                Button("Карточки встречи") { store.librarySection = "meetings"; store.tab = "cards" }.keyboardShortcut("3")
                Button("Заметки встречи") { store.librarySection = "meetings"; store.tab = "notes" }.keyboardShortcut("4")
            }
            CommandGroup(replacing: .help) {
                Button("Начало работы с После") { GuidanceController.shared.presentGettingStarted() }
                Button("Что нового") { GuidanceController.shared.presentWhatsNew() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { store.openSettings() }.keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var capture: QuickCaptureController?
    func connect(_ store: AppStore) {
        self.store = store
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--preview") && !args.contains("--snapshot") && !args.contains(where: { $0.hasPrefix("--check-") }) else { return }
        if capture == nil {
            let controller = QuickCaptureController(store: store); capture = controller; controller.start()
            store.quickCaptureAction = { [weak controller] in controller?.show() }
            store.bookmarkAction = { [weak controller] in controller?.markImportant() }
            store.updates.start(store: store, hasQuickDraft: { [weak controller] in controller?.hasUnsavedDraft ?? false },
                                showQuickDraft: { [weak controller] in controller?.show() })
        }
    }
    func applicationWillTerminate(_ notification: Notification) { capture?.stop(); store?.localService.stop(); store?.calendar.stop() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-embedded-speech") {
            Task {
                do { try await EmbeddedSpeechNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Embedded NSApplication check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-pipeline") {
            Task {
                do { try await PipelineNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native pipeline check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-corrections") {
            Task {
                do { try await CorrectionsNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Corrections check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-recording-sessions") {
            Task {
                do { try await RecordingSessionNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Recording session check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-cards") {
            Task {
                do { try await CardsNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Cards check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-source-playback") {
            Task {
                do { try await SourcePlaybackNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Source playback check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-queue") {
            Task {
                do { try await QueueNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Queue check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-guidance") {
            do { try GuidanceNativeChecks.run(); NSApp.terminate(nil) }
            catch { fputs("Guidance check failed: \(error)\n", stderr); exit(1) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-recording") {
            Task {
                do { try await RecordingNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native recording check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-tasks") {
            Task {
                do { try await TasksNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native tasks check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-themes") {
            do { try ThemeNativeChecks.run(); NSApp.terminate(nil) }
            catch { fputs("Native theme check failed: \(error)\n", stderr); exit(1) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-voice") {
            Task {
                do { try await VoiceNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native voice check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-copy-transcript") {
            do { try TranscriptNativeChecks.run(); NSApp.terminate(nil) }
            catch { fputs("Clipboard check failed: \(error)\n", stderr); exit(1) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-updates") {
            Task {
                do { try await UpdateNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Updater check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-calendar-workspace") {
            Task {
                do { try await CalendarWorkspaceNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Calendar workspace check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-calendar") {
            Task {
                do { try await CalendarNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Calendar check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-ui-consistency") {
            Task {
                do { try await UIConsistencyChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native UI consistency check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-notes") {
            Task {
                do { try await NotesNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native notes check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-overview") {
            Task {
                do { try await OverviewNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native overview check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-jobs") {
            Task {
                do { try await JobNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native job check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-navigation") {
            Task {
                do { try await NativeNavigationChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native navigation check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        #endif
        // Own-view rendering for UI verification; never captures the user's screen.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--snapshot"),
           ProcessInfo.processInfo.arguments.count > index + 1 {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            let previewStore = AppStore(preview: true)
            let arguments = ProcessInfo.processInfo.arguments
            func option(_ name: String) -> String? {
                guard let i = arguments.firstIndex(of: name), arguments.count > i + 1 else { return nil }
                return arguments[i + 1]
            }
            if let tabIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--preview-tab"),
               ProcessInfo.processInfo.arguments.count > tabIndex + 1 { previewStore.tab = ProcessInfo.processInfo.arguments[tabIndex + 1] }
            let screen = option("--preview-screen") ?? "meeting"
            if arguments.contains("--preview-busy") { previewStore.busy = true; previewStore.canCancelJob = true; previewStore.progressText = "Проверяю установленные модели…" }
            if arguments.contains("--preview-error") { previewStore.error = "Не удалось подключиться к модели. Проверьте локальный сервер в настройках." }
            if arguments.contains("--preview-notes-error") { previewStore.notes.error = "Не удалось сохранить заметку. Ваш текст остался в редакторе." }
            if ["inbox", "tasks", "contexts", "cards-library", "calendar", "calendar-disconnected"].contains(screen) {
                previewStore.librarySection = screen == "cards-library" ? "cards" : screen.hasPrefix("calendar") ? "calendar" : screen
            }
            #if DEBUG
            if ["voice", "voice-result"].contains(screen) { previewStore.voice.seedPreview(screen) }
            #endif
            if screen == "notes" { previewStore.librarySection = "meetings"; previewStore.tab = "notes" }
            if screen == "welcome" { previewStore.selection = nil; previewStore.meetings = []; previewStore.loadSelection() }
            if screen == "processing" {
                previewStore.busy = true; previewStore.canCancelJob = true; previewStore.processingID = previewStore.selection
                previewStore.progressText = "Распознаю речь · часть 2 из 8"; previewStore.progress = 0.25
            }
            if screen == "recording" || screen == "saving" {
                previewStore.isRecording = true; previewStore.recordingDate = Date().addingTimeInterval(-125)
                previewStore.transcript = nil; previewStore.summary = nil
                if screen == "saving" {
                    previewStore.stoppingRecording = true; previewStore.busy = true; previewStore.canCancelJob = true
                    previewStore.progressText = "Сохраняю запись и готовлю MP3…"
                }
            }
            if screen == "cards-empty" { previewStore.tab = "cards"; previewStore.summary?.cards = [] }
            if screen == "empty-search" { previewStore.libraryFilter = "Нет такой встречи" }
            if screen == "error" { previewStore.error = "Модель не найдена. Загрузите её в настройках и повторите создание конспекта. Транскрипт сохранён." }
            let content: AnyView
            switch screen {
            case "getting-started", "whats-new":
                let guide = GuidanceController.shared
                guide.configure(root: previewStore.root, preview: true)
                if screen == "getting-started" { guide.presentGettingStarted() } else { guide.presentWhatsNew() }
                content = AnyView(GuidanceSheet(controller: guide))
            case "transcript-editor":
                content = AnyView(TranscriptSegmentEditor(meetingID: previewStore.selection ?? "", segmentID: previewStore.transcript?.segments.first?.id ?? 0).environmentObject(previewStore))
            case "insight-editor":
                content = AnyView(SummaryInsightEditor(meetingID: previewStore.selection ?? "", itemIndex: 0).environmentObject(previewStore))
            case "settings": content = AnyView(SettingsView(section: option("--settings-section") ?? "general").environmentObject(previewStore))
            case "note-editor":
                if let note = previewStore.notes.notes.first(where: { $0.meetingID == previewStore.selection }) { content = AnyView(NoteEditorView(notes: previewStore.notes, note: note).environmentObject(previewStore)) }
                else { content = AnyView(NotesInboxView(notes: previewStore.notes).environmentObject(previewStore)) }
            case "quick-note": content = AnyView(QuickCaptureView(notes: previewStore.notes, initialMeetingID: previewStore.selection, initialTimestamp: 65, close: {}).environmentObject(previewStore))
            case "record": content = AnyView(RecordView().environmentObject(previewStore))
            case "speakers": content = AnyView(SpeakerReviewView(meetingID: previewStore.selection ?? "").environmentObject(previewStore))
            case "sources", "sources-missing":
                let ids = (previewStore.transcript?.segments.map(\.id) ?? []) + (screen == "sources-missing" ? [999999] : [])
                content = AnyView(VStack(alignment: .leading, spacing: 14) {
                    Text("Источники").font(AppTypography.heading)
                    ScrollView { SourceQuotes(ids: ids, snapshot: previewStore.transcript?.segments, meetingID: previewStore.selection) { _, _ in } }
                }.padding(20).environmentObject(previewStore))
            case "search":
                previewStore.showingSearch = true; previewStore.searchQuery = option("--preview-query") ?? "доступ"
                content = AnyView(SearchView().environmentObject(previewStore))
            default: content = AnyView(MainView().environmentObject(previewStore))
            }
            #if DEBUG
            if screen == "calendar" {
                if let date = option("--calendar-date"), let value = ISO8601DateFormatter().date(from: date) { previewStore.calendar.selectedDate = value }
                previewStore.calendar.seedPreview()
                if let mode = option("--calendar-view").flatMap(CalendarDisplayMode.init(rawValue:)) { previewStore.calendar.displayMode = mode }
            }
            #endif
            if let provider = option("--cloud-provider") { previewStore.settings.mode = "cloud"; previewStore.settings.switchCloudProvider(provider) }
            if let speechMode = option("--speech-mode") { previewStore.settings.speechMode = speechMode }
            let dark = option("--appearance") == "dark"
            let defaultWidth: Double = screen == "note-editor" ? 700 : screen == "quick-note" ? 490 : screen == "search" ? 760 : screen == "settings" ? 900 : ["getting-started", "whats-new", "transcript-editor", "insight-editor"].contains(screen) ? 620 : screen == "record" ? 560 : screen == "speakers" ? 560 : screen.hasPrefix("sources") ? 470 : 1260
            let defaultHeight: Double = screen == "note-editor" ? 650 : screen == "quick-note" ? 280 : screen == "search" ? 650 : screen == "settings" ? 760 : ["getting-started", "whats-new", "transcript-editor", "insight-editor"].contains(screen) ? 480 : screen == "record" ? 660 : screen == "speakers" ? 430 : screen.hasPrefix("sources") ? 460 : 820
            let width = option("--width").flatMap(Double.init) ?? defaultWidth
            let height = option("--height").flatMap(Double.init) ?? defaultHeight
            let view = NSHostingView(rootView: content
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: width, height: height)
                .background(Ink.paper).clipped())
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.contentView = view; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.center(); window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                window.makeFirstResponder(nil)
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                // The snapshot window uses a transparent title bar. Exclude its
                // safe-area strip from the cached image, in either coordinate system.
                let bounds = view.bounds
                let top = max(0, view.safeAreaInsets.top)
                let snapshotRect = NSRect(x: bounds.minX,
                                          y: bounds.minY + (view.isFlipped ? top : 0),
                                          width: bounds.width, height: max(0, bounds.height - top))
                guard snapshotRect.height > 0,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: snapshotRect) else {
                    fputs("Could not render the app view\n", stderr); NSApp.terminate(nil); return
                }
                view.cacheDisplay(in: snapshotRect, to: bitmap)
                do { try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                catch { fputs("\(error)\n", stderr) }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isTerminating == true { return .terminateLater }
        if let store, store.updates.relaunchRequested && !store.updates.canSafelyRelaunch {
            store.notice = "Завершите работу и сохраните правки перед обновлением"
            return .terminateCancel
        }
        if UnsavedEditorRegistry.hasUnsaved {
            let alert = NSAlert()
            alert.messageText = "Есть несохранённые правки"
            alert.informativeText = UnsavedEditorRegistry.titles.joined(separator: "\n")
            alert.addButton(withTitle: "Вернуться к редактированию")
            alert.addButton(withTitle: "Выйти без сохранения")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        if store?.notes.flushCaptureDrafts() == false { store?.error = store?.notes.error; return .terminateCancel }
        if store?.voice.flushDraft() == false { store?.presentVoice(); return .terminateCancel }
        if store?.flushOverviewDrafts() == false { return .terminateCancel }
        if !NoteDraftPersistence.flushAll() {
            sender.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить заметку"
            alert.informativeText = "Ваши правки остались в редакторе. Повторите сохранение или сохраните копию перед выходом."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "К заметкам")
            alert.addButton(withTitle: "Выйти без сохранения")
            if alert.runModal() != .alertSecondButtonReturn {
                store?.librarySection = "inbox"
                return .terminateCancel
            }
        }
        guard let store, store.isRecording || store.startingRecording || store.stoppingRecording || store.busy || store.voice.isWorking || store.jobs.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = store.isRecording ? "Сохранить запись перед выходом?" : "Остановить обработку и выйти?"
        alert.informativeText = store.isRecording ? "Приложение завершит сохранение звуковых дорожек." : "Исходная запись останется на Mac. Обработку можно повторить."
        alert.addButton(withTitle: store.isRecording ? "Сохранить и выйти" : "Остановить и выйти")
        alert.addButton(withTitle: "Остаться")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await store.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
