import AppKit
import SwiftUI

@main
struct PosleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore(preview: ProcessInfo.processInfo.arguments.contains("--preview"))

    var body: some Scene {
        WindowGroup("После") {
            MainView().environmentObject(store)
                .frame(minWidth: 1040, minHeight: 700)
                .onAppear { delegate.connect(store) }
                .onOpenURL { store.importFile($0) }
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить запись…") { store.chooseFile() }.keyboardShortcut("o")
                Button("Записать встречу…") { store.showingRecord = true }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Быстрая заметка…") { store.quickCaptureAction?() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Отметить важный момент") { store.bookmarkAction?() }
                Button("Поиск по библиотеке…") { store.openGlobalSearch() }.keyboardShortcut("k")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { store.showingSettings = true }.keyboardShortcut(",")
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
        guard !args.contains("--preview") && !args.contains("--snapshot") && !args.contains("--check-navigation") else { return }
        if capture == nil {
            let controller = QuickCaptureController(store: store); capture = controller; controller.start()
            store.quickCaptureAction = { [weak controller] in controller?.show() }
            store.bookmarkAction = { [weak controller] in controller?.markImportant() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { capture?.stop(); store?.localService.stop() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-notes") {
            Task {
                do { try await NotesNativeChecks.run(); NSApp.terminate(nil) }
                catch { fputs("Native notes check failed: \(error)\n", stderr); exit(1) }
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
            if ["inbox", "tasks", "contexts", "cards-library"].contains(screen) {
                previewStore.librarySection = screen == "cards-library" ? "cards" : screen
            }
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
            case "settings": content = AnyView(SettingsView(section: option("--settings-section") ?? "general").environmentObject(previewStore))
            case "note-editor":
                if let note = previewStore.notes.notes.first(where: { $0.meetingID == previewStore.selection }) { content = AnyView(NoteEditorView(notes: previewStore.notes, note: note).environmentObject(previewStore)) }
                else { content = AnyView(NotesInboxView(notes: previewStore.notes).environmentObject(previewStore)) }
            case "quick-note": content = AnyView(QuickCaptureView(notes: previewStore.notes, initialMeetingID: previewStore.selection, initialTimestamp: 65, close: {}).environmentObject(previewStore))
            case "record": content = AnyView(RecordView().environmentObject(previewStore))
            case "search":
                previewStore.showingSearch = true; previewStore.searchQuery = option("--preview-query") ?? "доступ"
                content = AnyView(SearchView().environmentObject(previewStore))
            default: content = AnyView(MainView().environmentObject(previewStore))
            }
            let dark = option("--appearance") == "dark"
            let defaultWidth: Double = screen == "note-editor" ? 700 : screen == "quick-note" ? 490 : screen == "search" ? 760 : screen == "settings" ? 900 : screen == "record" ? 570 : 1260
            let defaultHeight: Double = screen == "note-editor" ? 700 : screen == "quick-note" ? 330 : screen == "search" ? 650 : screen == "settings" ? 690 : screen == "record" ? 620 : 820
            let width = option("--width").flatMap(Double.init) ?? defaultWidth
            let height = option("--height").flatMap(Double.init) ?? defaultHeight
            let view = NSHostingView(rootView: content
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
        guard let store, store.isRecording || store.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = store.isRecording ? "Сохранить запись перед выходом?" : "Остановить обработку и выйти?"
        alert.informativeText = store.isRecording ? "Приложение завершит сохранение звуковых дорожек." : "Исходная запись останется на Mac. Обработку можно повторить."
        alert.addButton(withTitle: store.isRecording ? "Сохранить и выйти" : "Остановить и выйти")
        alert.addButton(withTitle: "Остаться")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        if store.isRecording {
            Task {
                // Saving on exit must not start another transcription job.
                store.processAfterRecording = false
                if store.stoppingRecording {
                    while store.stoppingRecording { try? await Task.sleep(for: .milliseconds(100)) }
                } else { await store.stopRecording() }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        store.runner.cancel()
        return .terminateNow
    }
}
