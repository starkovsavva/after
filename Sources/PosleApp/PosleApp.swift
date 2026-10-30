import AppKit
import SwiftUI
import PosleCore

@main
struct PosleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    @ObservedObject private var localization = UILocalization.shared

    var body: some Scene {
        WindowGroup(L("After")) {
            MainView().environmentObject(store)
                .environment(\.locale, localization.locale)
                .frame(minWidth: 1040, minHeight: 700)
                .onAppear { delegate.connect(store) }
                .onOpenURL { url in
                    if url.scheme == "posle", url.host == "calendar-task", !store.isFeatureEnabled(.calendar) {
                        store.librarySection = "calendar"
                    } else if store.calendar.openLink(url) { store.librarySection = "calendar" }
                    else if url.isFileURL { store.importFile(url) }
                }
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(LF("О программе {0}", arguments: [L("After")])) {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: L("After"), .applicationVersion: AppVersion.current ?? ""])
                }
            }
            CommandGroup(after: .appInfo) {
                CheckForAppUpdates(updates: store.updates)
                OpenUpdateDraft(updates: store.updates)
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Добавить запись…")) { store.chooseFile() }.keyboardShortcut("o")
                Button(store.librarySection == "inbox" ? L("Новая заметка") : L("Записать встречу…")) {
                    if store.librarySection == "inbox" { store.notes.newLibraryNoteRequest = UUID() }
                    else { store.showingRecord = true }
                }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                if store.isFeatureEnabled(.assistant) {
                    Button(L("Голосовое поручение…")) { store.presentVoice() }.keyboardShortcut("m", modifiers: [.command, .shift])
                }
                Button(L("Быстрая заметка…")) { store.quickCaptureAction?() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("Отметить важный момент")) { store.bookmarkAction?() }
                Button(L("Поиск по библиотеке…")) { store.openGlobalSearch() }.keyboardShortcut("k")
            }
            CommandMenu(L("Встреча")) {
                Button(L("Переименовать встречу…")) {
                    if let meeting = store.selected {
                        store.librarySection = "meetings"
                        store.meetingTitleEdits.begin(meeting)
                    }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.selected == nil || store.captureMeetingID == store.selection)
                Divider()
                Button(L("Конспект")) { store.librarySection = "meetings"; store.tab = "summary" }.keyboardShortcut("1")
                Button(L("Транскрипт")) { store.librarySection = "meetings"; store.tab = "transcript" }.keyboardShortcut("2")
                if store.isFeatureEnabled(.cards) {
                    Button(L("Карточки встречи")) { store.librarySection = "meetings"; store.tab = "cards" }.keyboardShortcut("3")
                }
                Button(L("Заметки встречи")) { store.librarySection = "meetings"; store.tab = "notes" }.keyboardShortcut("4")
            }
            CommandGroup(replacing: .help) {
                Button(L("Начало работы с After")) { GuidanceController.shared.presentGettingStarted() }
                Button(L("Что нового")) { GuidanceController.shared.presentWhatsNew() }
                Button(L("Поддержать After…")) { store.openSupport() }
                    .disabled(store.showingSettings || store.showingRecord || store.showingSearch || store.showingCaptureDrafts)
                Divider()
                Button {
                    let settings = store.librarySection == "meetings" ? store.effectiveSettings(for: store.selection, folderID: store.folderSelection) : store.activeSettings
                    let failure = store.jobs.jobs.filter { ["failed", "interrupted"].contains($0.state) }.max { $0.updatedAt < $1.updatedAt }
                    BugReportController.shared.present(settings: settings, lastFailure: failure)
                } label: { Label(L("Сообщить об ошибке…"), systemImage: "ladybug") }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("Настройки…")) { store.openSettings() }.keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var capture: QuickCaptureController?
    private var localizationObserver: NSObjectProtocol?
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
    func applicationWillTerminate(_ notification: Notification) { ChatGPTAccount.shared.cancelSignIn(); capture?.stop(); store?.localService.stop(); store?.calendar.stop() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        localizationObserver = NotificationCenter.default.addObserver(forName: .posleUILanguageChanged, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { refreshLocalizedApplicationMenu() }
        }
        DispatchQueue.main.async { refreshLocalizedApplicationMenu() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-localization") {
            Task { @MainActor in
                do { try await LocalizationNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Localization check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-embedded-speech") {
            Task {
                do { try await EmbeddedSpeechNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Embedded NSApplication check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-chatgpt-auth") {
            Task {
                do { try await ChatGPTAuthNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("ChatGPT auth check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-chatgpt-ui") {
            Task {
                do { try await ChatGPTUINativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("ChatGPT UI check failed: \(error)\n", stderr); exit(1) }
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
        if ProcessInfo.processInfo.arguments.contains("--check-recording-start") {
            Task {
                do { try await RecordingStartNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Recording start check failed: \(error)\n", stderr); exit(1) }
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
        if ProcessInfo.processInfo.arguments.contains("--check-release-notes") {
            Task {
                do {
                    guard let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable release notes root required") }
                    try await ReleaseNotesUINativeChecks.run(root: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                } catch { fputs("Release notes UI check failed: \(error)\n", stderr); exit(1) }
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
        if ProcessInfo.processInfo.arguments.contains("--check-responsiveness") {
            Task { @MainActor in
                do { try await ResponsivenessNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native responsiveness failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-bug-report") {
            Task { @MainActor in
                do { try await BugReportNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native bug report failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-contexts") {
            Task { @MainActor in
                do { try await ContextsNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native contexts failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-meeting-rename") {
            Task { @MainActor in
                do { try await MeetingRenameNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native meeting rename failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-folder-jobs") {
            Task { @MainActor in
                do { try await FolderJobNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Folder job check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-folders") {
            Task {
                do { try await FolderNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native folder check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-feature-ui") {
            Task {
                do { try await FeatureUINativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native feature UI check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-trash") {
            Task {
                do { try await TrashNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native trash check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-integrations") {
            Task {
                do { try await IntegrationNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native integrations check failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-task-workspace") {
            Task {
                do { try await TaskWorkspaceNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native task workspace check failed: \(error)\n", stderr); exit(1) }
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
        if ProcessInfo.processInfo.arguments.contains("--check-source-popover") {
            Task {
                do {
                    guard let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable source popover root required") }
                    try await SourcePopoverNativeChecks.run(root: URL(fileURLWithPath: path))
                    try await ClaimSourcesNativeChecks.run(root: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                } catch { fputs("Source popover check failed: \(error)\n", stderr); exit(1) }
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
        if ProcessInfo.processInfo.arguments.contains("--check-typography") {
            Task {
                do { try await TypographyNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native typography check failed: \(error)\n", stderr); exit(1) }
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
            ThemeController.shared.configure(root: previewStore.root)
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
            if ["voice", "voice-result", "voice-answer"].contains(screen) { previewStore.voice.seedPreview(screen) }
            ReleasePreviewFixtures.prepare(previewStore, screen: screen)
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
                let guide = GuidanceController(version: AppVersion.current ?? ReleaseNotesCatalog.latestVersion)
                guide.configure(root: previewStore.root, preview: true)
                if screen == "getting-started" { guide.presentGettingStarted() } else { guide.presentWhatsNew() }
                content = AnyView(GuidanceSheet(controller: guide))
            case "transcript-editor":
                content = AnyView(TranscriptSegmentEditor(meetingID: previewStore.selection ?? "", segmentID: previewStore.transcript?.segments.first?.id ?? 0).environmentObject(previewStore))
            case "insight-editor":
                content = AnyView(SummaryInsightEditor(meetingID: previewStore.selection ?? "", itemIndex: 0).environmentObject(previewStore))
            case "support": content = AnyView(SupportSheet(close: {}, feedback: {}))
            case "settings": content = AnyView(SettingsView(section: option("--settings-section") ?? "general").environmentObject(previewStore))
            case "tracker-sync": content = AnyView(SettingsView(section: "integrations").environmentObject(previewStore))
            case "note-editor":
                if let note = previewStore.notes.notes.first(where: { $0.meetingID == previewStore.selection }) { content = AnyView(NoteEditorView(notes: previewStore.notes, note: note).environmentObject(previewStore)) }
                else { content = AnyView(NotesInboxView(notes: previewStore.notes).environmentObject(previewStore)) }
            case "quick-note": content = AnyView(QuickCaptureView(notes: previewStore.notes, initialMeetingID: previewStore.selection, initialTimestamp: 65, close: {}).environmentObject(previewStore))
            case "record": content = AnyView(RecordView().environmentObject(previewStore))
            case "speakers": content = AnyView(SpeakerReviewView(meetingID: previewStore.selection ?? "").environmentObject(previewStore))
            case "sources", "sources-missing":
                let ids = (previewStore.transcript?.segments.map(\.id) ?? []) + (screen == "sources-missing" ? [999999] : [])
                content = AnyView(VStack(alignment: .leading, spacing: 14) {
                    Text(L("Источники")).font(AppTypography.heading)
                    ScrollView { SourceQuotes(ids: ids, snapshot: previewStore.transcript?.segments, meetingID: previewStore.selection) { _, _ in } }
                }.padding(20).environmentObject(previewStore))
            case "search", "search-semantic":
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
            let defaultWidth: Double = screen == "whats-new" ? 940 : screen == "support" ? 720 : screen == "note-editor" ? 700 : screen == "quick-note" ? 490 : ["search", "search-semantic"].contains(screen) ? 760 : ["settings", "tracker-sync"].contains(screen) ? 900 : ["getting-started", "whats-new", "transcript-editor", "insight-editor"].contains(screen) ? 620 : screen == "record" ? 560 : screen == "speakers" ? 560 : screen.hasPrefix("sources") ? 470 : 1260
            let defaultHeight: Double = screen == "whats-new" ? 680 : screen == "support" ? 400 : screen == "note-editor" ? 650 : screen == "quick-note" ? 280 : ["search", "search-semantic"].contains(screen) ? 650 : ["settings", "tracker-sync"].contains(screen) ? 760 : ["getting-started", "whats-new", "transcript-editor", "insight-editor"].contains(screen) ? 480 : screen == "record" ? 660 : screen == "speakers" ? 430 : screen.hasPrefix("sources") ? 460 : 820
            let width = option("--width").flatMap(Double.init) ?? defaultWidth
            let height = option("--height").flatMap(Double.init) ?? defaultHeight
            let view = NSHostingView(rootView: content
                .environment(\.locale, UILocalization.shared.locale)
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
            store.notice = L("Завершите работу и сохраните правки перед обновлением")
            return .terminateCancel
        }
        if UnsavedEditorRegistry.hasUnsaved {
            let alert = NSAlert()
            alert.messageText = L("Есть несохранённые правки")
            alert.informativeText = UnsavedEditorRegistry.titles.joined(separator: "\n")
            alert.addButton(withTitle: L("Вернуться к редактированию"))
            alert.addButton(withTitle: L("Выйти без сохранения"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        if store?.notes.flushCaptureDrafts() == false { store?.error = store?.notes.error; return .terminateCancel }
        if store?.voice.flushDraft() == false { store?.presentVoice(); return .terminateCancel }
        if store?.flushOverviewDrafts() == false { return .terminateCancel }
        if !NoteDraftPersistence.flushAll() {
            sender.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("Не удалось сохранить заметку")
            alert.informativeText = L("Ваши правки остались в редакторе. Повторите сохранение или сохраните копию перед выходом.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("К заметкам"))
            alert.addButton(withTitle: L("Выйти без сохранения"))
            if alert.runModal() != .alertSecondButtonReturn {
                store?.librarySection = "inbox"
                return .terminateCancel
            }
        }
        guard let store, store.isRecording || store.startingRecording || store.stoppingRecording || store.busy || store.voice.isWorking || store.jobs.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = store.isRecording ? L("Сохранить запись перед выходом?") : L("Остановить обработку и выйти?")
        alert.informativeText = store.isRecording ? L("Приложение завершит сохранение звуковых дорожек.") : L("Исходная запись останется на Mac. Обработку можно повторить.")
        alert.addButton(withTitle: store.isRecording ? L("Сохранить и выйти") : L("Остановить и выйти"))
        alert.addButton(withTitle: L("Остаться"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await store.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
