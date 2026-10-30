import AppKit
import Carbon
import Combine
import PosleCore
import SwiftUI

/// Carbon hotkeys work while another app is active without Accessibility access.
@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    private weak var store: AppStore?
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var captureKey: EventHotKeyRef?
    private var bookmarkKey: EventHotKeyRef?
    private var voiceKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var settingsObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var started = false
    private let draft = QuickCaptureDraft()
    init(store: AppStore) { self.store = store; super.init() }
    var hasUnsavedDraft: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func start() {
        guard !started else { return }; started = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = BrandArtwork.menuBarImage()
        let menu = NSMenu()
        let capture = NSMenuItem(title: L("Быстрая заметка…"), action: #selector(showFromMenu), keyEquivalent: "")
        capture.target = self; menu.addItem(capture)
        let mark = NSMenuItem(title: L("Отметить важный момент"), action: #selector(markFromMenu), keyEquivalent: "")
        mark.target = self; menu.addItem(mark)
        let voice = NSMenuItem(title: L("Голосовое поручение…"), action: #selector(voiceFromMenu), keyEquivalent: "")
        voice.target = self; voice.isHidden = store?.isFeatureEnabled(.assistant) != true; menu.addItem(voice)
        menu.addItem(.separator())
        let library = NSMenuItem(title: L("Открыть After"), action: #selector(openMain), keyEquivalent: "")
        library.target = self; menu.addItem(library)
        item.menu = menu; statusItem = item
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr else { return status }
            let owner = Unmanaged<QuickCaptureController>.fromOpaque(data).takeUnretainedValue()
            let identifier = key.id
            Task { @MainActor in if identifier == 1 { owner.show() } else if identifier == 2 { owner.markImportant() } else if identifier == 3 { owner.showVoice() } }
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
        if result != noErr { store?.notes.hotkeyNotice = L("Горячие клавиши недоступны. Быстрая заметка работает из строки меню.") }
        registerShortcuts()
        settingsObserver = NotificationCenter.default.addObserver(forName: Notification.Name("PosleShortcutsChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.registerShortcuts() }
        }
        languageObserver = NotificationCenter.default.addObserver(forName: .posleUILanguageChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshLanguage() }
        }
    }
    func stop() {
        if let captureKey { UnregisterEventHotKey(captureKey) }; captureKey = nil
        if let bookmarkKey { UnregisterEventHotKey(bookmarkKey) }; bookmarkKey = nil
        if let voiceKey { UnregisterEventHotKey(voiceKey) }; voiceKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }; settingsObserver = nil
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }; languageObserver = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
        panel?.close(); panel = nil; started = false
    }
    /// Change chrome in place: a language switch must not recreate an editor or its draft.
    private func refreshLanguage() {
        panel?.title = L("Быстрая заметка")
        statusItem?.button?.image?.accessibilityDescription = L("After")
        for item in statusItem?.menu?.items ?? [] {
            switch item.action {
            case #selector(showFromMenu): item.title = L("Быстрая заметка…")
            case #selector(markFromMenu): item.title = L("Отметить важный момент")
            case #selector(voiceFromMenu): item.title = L("Голосовое поручение…")
            case #selector(openMain): item.title = L("Открыть After")
            default: break
            }
        }
    }
    private func registerShortcuts() {
        if let captureKey { UnregisterEventHotKey(captureKey) }; captureKey = nil
        if let bookmarkKey { UnregisterEventHotKey(bookmarkKey) }; bookmarkKey = nil
        if let voiceKey { UnregisterEventHotKey(voiceKey) }; voiceKey = nil
        guard let store, eventHandler != nil else { return }
        statusItem?.menu?.items.first(where: { $0.action == #selector(voiceFromMenu) })?.isHidden = !store.isFeatureEnabled(.assistant)
        store.notes.hotkeyNotice = nil
        if store.settings.quickCaptureEnabled {
            let alternate = store.settings.quickCaptureShortcut == "controlShiftSpace"
            let code = UInt32(alternate ? kVK_Space : kVK_ANSI_N)
            let modifiers = UInt32(alternate ? (controlKey | shiftKey) : (controlKey | optionKey))
            let result = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x50534C45, id: 1), GetApplicationEventTarget(), 0, &captureKey)
            if result != noErr { store.notes.hotkeyNotice = L("Сочетание быстрой заметки занято. Выберите другое в настройках или используйте строку меню.") }
        }
        if store.isFeatureEnabled(.assistant), store.settings.voiceShortcutEnabled {
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x50534C45, id: 3), GetApplicationEventTarget(), 0, &voiceKey)
            if result != noErr { store.notes.hotkeyNotice = L("Сочетание ⌃⌥M занято. Поручение можно открыть кнопкой микрофона.") }
        }
        if store.settings.bookmarkShortcutEnabled {
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x50534C45, id: 2), GetApplicationEventTarget(), 0, &bookmarkKey)
            if result != noErr { store.notes.hotkeyNotice = L("Сочетание ⌃⌥B занято. Отметить момент можно кнопкой во время записи.") }
        }
    }
    func show() {
        guard let store else { return }
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let candidate = store.settings.notesSaveToActiveMeeting ? (store.captureMeetingID ?? (store.isPlaying ? store.selection : nil)) : nil
        let target = candidate.flatMap { id in store.allNoteMeetings.contains(where: { $0.id == id }) ? id : nil }
        let timestamp: Double? = !store.settings.notesAutoTimestamp ? nil : target == store.captureMeetingID && store.isRecording
            ? max(0, Date().timeIntervalSince(store.recordingDate ?? Date())) : target != nil ? store.playbackTime : nil
        let view = QuickCaptureView(notes: store.notes, initialMeetingID: target, initialTimestamp: timestamp, initialFolderID: store.folderSelection, draft: draft) { [weak self] in self?.panel?.close() }.environmentObject(store)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 320), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = L("Быстрая заметка"); window.isFloatingPanel = true; window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false; window.delegate = self; window.contentView = NSHostingView(rootView: LocalizedInterfaceRoot(content: view))
        window.center(); panel = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSPanel, window === panel { panel = nil }
    }
    func markImportant() {
        guard let store else { return }
        let meetingID = store.captureMeetingID ?? (store.transcript != nil ? store.selection : nil)
        guard let meetingID, store.allNoteMeetings.contains(where: { $0.id == meetingID }) else { show(); return }
        let time = store.isRecording && meetingID == store.captureMeetingID
            ? max(0, Date().timeIntervalSince(store.recordingDate ?? Date())) : store.playbackTime
        if let note = store.notes.capture(text: L("Важный момент"), kind: "important", meetingID: meetingID, timestamp: time) {
            store.notes.highlightedNoteID = note.id; store.notice = LF("Отмечено · {0}", arguments: [String(describing: (Exporter.timestamp(time)))])
        }
    }
    func showVoice() {
        openMain(); store?.presentVoice()
    }
    @objc private func voiceFromMenu() { showVoice() }
    @objc private func showFromMenu() { show() }
    @objc private func markFromMenu() { markImportant() }
    @objc private func openMain() {
        panel?.orderOut(nil); NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) { window.makeKeyAndOrderFront(nil) }
    }
}

/// The controller keeps this draft while its panel is hidden or closed. The
/// destination and timestamp belong to the draft, so reopening during another
/// meeting cannot silently attach an unfinished thought to the wrong recording.
@MainActor
final class QuickCaptureDraft: ObservableObject {
    private let editorID = UUID()
    @Published var text = "" {
        didSet { UnsavedEditorRegistry.set(id: editorID, title: L("Быстрая заметка"), dirty: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
    @Published var kind = "note"
    @Published var meetingID = ""
    private(set) var folderID: String?
    private(set) var sourceMeetingID: String?
    private(set) var sourceTimestamp: Double?
    private var initialized = false
    deinit {
        let id = editorID
        Task { @MainActor in UnsavedEditorRegistry.remove(id: id) }
    }
    func prepare(meetingID: String?, timestamp: Double?, folderID: String? = nil) {
        guard !initialized || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.meetingID = meetingID ?? ""; self.folderID = folderID; sourceMeetingID = meetingID; sourceTimestamp = timestamp; initialized = true
    }
    var timestamp: Double? { meetingID == sourceMeetingID ? sourceTimestamp : nil }
    func destination(in meetings: [Meeting]) -> (meetingID: String?, timestamp: Double?) {
        guard let meeting = meetings.first(where: { $0.id == meetingID && $0.libraryKind != "cards" }) else { return (nil, nil) }
        return (meeting.id, timestamp)
    }
    func saved() { text = ""; kind = "note"; meetingID = ""; folderID = nil; sourceMeetingID = nil; sourceTimestamp = nil; initialized = false }
    func settings(in app: AppStore) -> AppSettings {
        app.effectiveSettings(for: meetingID.isEmpty ? nil : meetingID, folderID: folderID)
    }
    var hasMeeting: Bool { !meetingID.isEmpty }
    @discardableResult func save(in app: AppStore) -> CapturedNote? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if hasMeeting && !app.allNoteMeetings.contains(where: { $0.id == meetingID }) {
            app.notes.error = L("Встреча недоступна. Выберите другую встречу или сохранение без встречи."); return nil
        }
        if !hasMeeting, let folderID, app.notes.folder(folderID) == nil {
            app.notes.error = L("Папка удалена. Выберите папку для заметки."); return nil
        }
        let target = destination(in: app.allNoteMeetings)
        guard let note = app.notes.capture(text: text, kind: kind == "task" && !settings(in: app).features.tasks ? "note" : kind,
            meetingID: target.meetingID, timestamp: target.timestamp, folderID: target.meetingID == nil ? folderID : nil) else { return nil }
        saved(); return note
    }
    func selectFolder(_ id: String?) { folderID = id; meetingID = "" }
}

#if DEBUG
extension QuickCaptureController {
    /// Only invoked by the disposable native notes harness. No registration,
    /// recording, network or personal data access is started by this check.
    static func verifyDraftPreservation(store: AppStore) throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw AppError.message(message) }
        }
        let value = QuickCaptureDraft()
        value.prepare(meetingID: "original", timestamp: 0)
        value.text = "Несохранённая мысль"; value.kind = "question"
        value.prepare(meetingID: "another", timestamp: 90)
        try expect(value.text == "Несохранённая мысль" && value.kind == "question" && value.meetingID == "original" && value.timestamp == 0,
                   "Reopening must retain draft text, type and its original zero-second destination")
        value.meetingID = "another"
        try expect(value.timestamp == nil, "Changing destination must not carry another meeting's timestamp")
        value.saved(); value.prepare(meetingID: "another", timestamp: 90)
        try expect(value.text.isEmpty && value.kind == "note" && value.meetingID == "another" && value.timestamp == 90,
                   "Only a successful save resets the draft for the next capture")
        let controller = QuickCaptureController(store: store)
        controller.show()
        defer { controller.stop() }
        controller.draft.text = "Черновик после закрытия окна"
        guard let first = controller.panel else { throw AppError.message("Missing own quick-capture panel") }
        first.performClose(nil)
        try expect(controller.panel == nil && controller.draft.text == "Черновик после закрытия окна", "Native close must retain the draft")
        controller.show()
        try expect(controller.panel != nil && controller.panel !== first && controller.draft.text == "Черновик после закрытия окна", "A newly opened panel must reuse the retained draft")
        controller.panel?.close()
        try expect(controller.draft.text == "Черновик после закрытия окна", "Hide/Escape close path must retain the draft")
        try expect(UnsavedEditorRegistry.hasUnsaved, "A hidden quick capture must participate in the app's quit/update draft guard")
        controller.draft.saved()
        print("PASS: quick-capture draft retains text/type/destination/zero timestamp across native close and reopen; successful save resets it and releases quit protection")
    }
    static func verifyFolderScope(store app: AppStore) throws {
        func expect(_ condition: Bool, _ message: String) throws { if !condition { throw AppError.message(message) } }
        guard let english = app.notes.saveFolder(LibraryFolder(name: "Занятия · быстрые заметки")),
              let work = app.notes.saveFolder(LibraryFolder(name: "Работа · быстрые заметки")) else { throw AppError.message(app.notes.error ?? "Cannot create quick capture folders") }
        let value = QuickCaptureDraft()
        defer { value.saved() }
        value.prepare(meetingID: nil, timestamp: nil, folderID: english.id); value.text = "Повторить новые выражения"
        app.folderSelection = work.id
        value.prepare(meetingID: nil, timestamp: nil, folderID: work.id)
        guard let note = value.save(in: app) else { throw AppError.message(app.notes.error ?? "Cannot save pinned capture") }
        try expect(note.folderID == english.id, "Closing, switching folders and reopening must retain the draft's captured folder")
        value.prepare(meetingID: nil, timestamp: nil); value.text = "Мысль без папки"
        guard let base = value.save(in: app) else { throw AppError.message(app.notes.error ?? "Cannot save base capture") }
        try expect(base.folderID == nil, "An explicitly captured base draft must not inherit the current sidebar folder")
        value.prepare(meetingID: nil, timestamp: nil, folderID: english.id); value.text = "Не потерять после удаления папки"
        guard let current = app.notes.folder(english.id), app.notes.deleteFolder(current) else { throw AppError.message("Cannot remove quick capture folder") }
        try expect(value.save(in: app) == nil && !value.text.isEmpty, "A deleted folder must block silent redirection and preserve typed text")
        value.selectFolder(work.id)
        guard let recovered = value.save(in: app) else { throw AppError.message(app.notes.error ?? "Cannot select another destination") }
        try expect(recovered.folderID == work.id, "Explicit destination selection must recover the same draft")
        value.prepare(meetingID: "removed-meeting", timestamp: 7, folderID: work.id); value.text = "Мысль для удалённой встречи"
        try expect(value.save(in: app) == nil && value.meetingID == "removed-meeting" && !value.text.isEmpty,
                   "A missing meeting must preserve the draft and require an explicit destination")
        app.folderSelection = nil; app.notes.error = nil
        print("PASS: quick-capture folder stays pinned across sidebar changes; base scope, missing destinations and explicit recovery preserve drafts")
    }
}
#endif

struct QuickCaptureView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let initialMeetingID: String?
    let initialTimestamp: Double?
    let initialFolderID: String?
    let close: () -> Void
    @ObservedObject private var draft: QuickCaptureDraft
    private var destination: (meetingID: String?, timestamp: Double?) { draft.destination(in: app.allNoteMeetings) }
    @State private var showingError = false
    @State private var focused = false
    init(notes: NotesStore, initialMeetingID: String?, initialTimestamp: Double?, initialFolderID: String? = nil, draft: QuickCaptureDraft? = nil, close: @escaping () -> Void) {
        self.notes = notes; self.initialMeetingID = initialMeetingID; self.initialTimestamp = initialTimestamp; self.initialFolderID = initialFolderID
        self.draft = draft ?? QuickCaptureDraft(); self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlainNoteInput(text: $draft.text, placeholder: L("Новая заметка…"), isFocused: $focused, accessibilityLabel: L("Текст быстрой заметки"))
                .frame(height: 106).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Ink.accent.opacity(0.7) : Ink.line))
            HStack(spacing: 12) {
                Picker(L("Тип"), selection: Binding(get: {
                    draft.kind == "task" && !draft.settings(in: app).features.tasks ? "note" : draft.kind
                }, set: { draft.kind = $0 })) {
                    Text(L("Заметка")).tag("note"); Text(L("Важно")).tag("important"); Text(L("Вопрос")).tag("question")
                    if draft.settings(in: app).features.tasks { Text(L("Задача")).tag("task") }
                }
                    .labelsHidden().frame(width: 116).accessibilityLabel(L("Тип заметки"))
                Picker(L("Куда сохранить"), selection: $draft.meetingID) {
                    Text(L("Без встречи")).tag("")
                    if !draft.meetingID.isEmpty && !app.allNoteMeetings.contains(where: { $0.id == draft.meetingID }) { Text(L("Встреча недоступна · выберите другую")).tag(draft.meetingID) }
                    ForEach(app.allNoteMeetings) { Text($0.title).tag($0.id) }
                }.labelsHidden().accessibilityLabel(L("Куда сохранить заметку"))
                    .help(L("Куда сохранить заметку"))
            }
            if !draft.hasMeeting {
                Picker(L("Папка"), selection: Binding(get: { draft.folderID ?? "" }, set: { draft.selectFolder($0.isEmpty ? nil : $0) })) {
                    Text(L("Без папки")).tag("")
                    ForEach(app.notes.folders) { Text($0.name).tag($0.id) }
                    if let id = draft.folderID, app.notes.folder(id) == nil { Text(L("Удалённая папка · выберите другую")).tag(id) }
                }.font(AppTypography.caption).accessibilityLabel(L("Папка быстрой заметки"))
            }
            HStack(spacing: 10) {
                if let error = notes.error {
                    Button { showingError = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                            Text(L("Ошибка"))
                            Image(systemName: "chevron.right")
                        }
                    }.buttonStyle(.borderless).font(AppTypography.caption).foregroundStyle(Ink.warning).frame(maxWidth: 190, alignment: .leading)
                        .popover(isPresented: $showingError) { Text(error).font(AppTypography.body).textSelection(.enabled).padding(18).frame(width: 360) }
                        .help(error).accessibilityLabel(L("Ошибка заметок. Показать подробности")).accessibilityValue(error)
                } else if let time = destination.timestamp {
                    Label(Exporter.timestamp(time), systemImage: "clock").font(AppTypography.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button(L("Скрыть"), action: close).keyboardShortcut(.cancelAction)
                    .help(L("Закрыть окно и оставить черновик до выхода из приложения"))
                Button(L("Сохранить")) {
                    if draft.save(in: app) != nil { close() }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help(L("Сохранить · ⌘↩"))
            }
        }.padding(18).frame(width: 490).background(Ink.paper).appControlDefaults()
            .modifier(PosleThemeRoot(root: notes.root))
            .onAppear { draft.prepare(meetingID: initialMeetingID, timestamp: initialTimestamp, folderID: initialFolderID); focused = true }
    }
}
