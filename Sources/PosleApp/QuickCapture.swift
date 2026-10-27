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
    private var started = false
    private let draft = QuickCaptureDraft()
    init(store: AppStore) { self.store = store; super.init() }
    var hasUnsavedDraft: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func start() {
        guard !started else { return }; started = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = SunsetArtwork.menuBarImage()
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Быстрая заметка…", action: #selector(showFromMenu), keyEquivalent: "")
        capture.target = self; menu.addItem(capture)
        let mark = NSMenuItem(title: "Отметить важный момент", action: #selector(markFromMenu), keyEquivalent: "")
        mark.target = self; menu.addItem(mark)
        let voice = NSMenuItem(title: "Голосовое поручение…", action: #selector(voiceFromMenu), keyEquivalent: "")
        voice.target = self; voice.isHidden = store?.settings.isEnabled(.assistant) != true; menu.addItem(voice)
        menu.addItem(.separator())
        let library = NSMenuItem(title: "Открыть После", action: #selector(openMain), keyEquivalent: "")
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
        if result != noErr { store?.notes.hotkeyNotice = "Горячие клавиши недоступны. Быстрая заметка работает из строки меню." }
        registerShortcuts()
        settingsObserver = NotificationCenter.default.addObserver(forName: Notification.Name("PosleShortcutsChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.registerShortcuts() }
        }
    }
    func stop() {
        if let captureKey { UnregisterEventHotKey(captureKey) }; captureKey = nil
        if let bookmarkKey { UnregisterEventHotKey(bookmarkKey) }; bookmarkKey = nil
        if let voiceKey { UnregisterEventHotKey(voiceKey) }; voiceKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }; settingsObserver = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
        panel?.close(); panel = nil; started = false
    }
    private func registerShortcuts() {
        if let captureKey { UnregisterEventHotKey(captureKey) }; captureKey = nil
        if let bookmarkKey { UnregisterEventHotKey(bookmarkKey) }; bookmarkKey = nil
        if let voiceKey { UnregisterEventHotKey(voiceKey) }; voiceKey = nil
        guard let store, eventHandler != nil else { return }
        statusItem?.menu?.items.first(where: { $0.action == #selector(voiceFromMenu) })?.isHidden = !store.settings.isEnabled(.assistant)
        store.notes.hotkeyNotice = nil
        if store.settings.quickCaptureEnabled {
            let alternate = store.settings.quickCaptureShortcut == "controlShiftSpace"
            let code = UInt32(alternate ? kVK_Space : kVK_ANSI_N)
            let modifiers = UInt32(alternate ? (controlKey | shiftKey) : (controlKey | optionKey))
            let result = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x50534C45, id: 1), GetApplicationEventTarget(), 0, &captureKey)
            if result != noErr { store.notes.hotkeyNotice = "Сочетание быстрой заметки занято. Выберите другое в настройках или используйте строку меню." }
        }
        if store.settings.isEnabled(.assistant), store.settings.voiceShortcutEnabled {
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x50534C45, id: 3), GetApplicationEventTarget(), 0, &voiceKey)
            if result != noErr { store.notes.hotkeyNotice = "Сочетание ⌃⌥M занято. Поручение можно открыть кнопкой микрофона." }
        }
        if store.settings.bookmarkShortcutEnabled {
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x50534C45, id: 2), GetApplicationEventTarget(), 0, &bookmarkKey)
            if result != noErr { store.notes.hotkeyNotice = "Сочетание ⌃⌥B занято. Отметить момент можно кнопкой во время записи." }
        }
    }
    func show() {
        guard let store else { return }
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let candidate = store.settings.notesSaveToActiveMeeting ? (store.captureMeetingID ?? (store.isPlaying ? store.selection : nil)) : nil
        let target = candidate.flatMap { id in store.noteMeetings.contains(where: { $0.id == id }) ? id : nil }
        let timestamp: Double? = !store.settings.notesAutoTimestamp ? nil : target == store.captureMeetingID && store.isRecording
            ? max(0, Date().timeIntervalSince(store.recordingDate ?? Date())) : target != nil ? store.playbackTime : nil
        let view = QuickCaptureView(notes: store.notes, initialMeetingID: target, initialTimestamp: timestamp, draft: draft) { [weak self] in self?.panel?.close() }.environmentObject(store)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 280), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Быстрая заметка"; window.isFloatingPanel = true; window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false; window.delegate = self; window.contentView = NSHostingView(rootView: view)
        window.center(); panel = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSPanel, window === panel { panel = nil }
    }
    func markImportant() {
        guard let store else { return }
        let meetingID = store.captureMeetingID ?? (store.transcript != nil ? store.selection : nil)
        guard let meetingID, store.noteMeetings.contains(where: { $0.id == meetingID }) else { show(); return }
        let time = store.isRecording && meetingID == store.captureMeetingID
            ? max(0, Date().timeIntervalSince(store.recordingDate ?? Date())) : store.playbackTime
        if let note = store.notes.capture(text: "Важный момент", kind: "important", meetingID: meetingID, timestamp: time) {
            store.notes.highlightedNoteID = note.id; store.notice = "Отмечено · \(Exporter.timestamp(time))"
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
    @Published var text = ""
    @Published var kind = "note"
    @Published var meetingID = ""
    private(set) var sourceMeetingID: String?
    private(set) var sourceTimestamp: Double?
    private var initialized = false
    func prepare(meetingID: String?, timestamp: Double?) {
        guard !initialized || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.meetingID = meetingID ?? ""; sourceMeetingID = meetingID; sourceTimestamp = timestamp; initialized = true
    }
    var timestamp: Double? { meetingID == sourceMeetingID ? sourceTimestamp : nil }
    func destination(in meetings: [Meeting]) -> (meetingID: String?, timestamp: Double?) {
        guard let meeting = meetings.first(where: { $0.id == meetingID && $0.libraryKind != "cards" }) else { return (nil, nil) }
        return (meeting.id, timestamp)
    }
    func saved() { text = ""; kind = "note"; meetingID = ""; sourceMeetingID = nil; sourceTimestamp = nil; initialized = false }
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
        print("PASS: quick-capture draft retains text/type/destination/zero timestamp across native close and reopen; successful save resets it")
    }
}
#endif

struct QuickCaptureView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let initialMeetingID: String?
    let initialTimestamp: Double?
    let close: () -> Void
    @ObservedObject private var draft: QuickCaptureDraft
    private var destination: (meetingID: String?, timestamp: Double?) { draft.destination(in: app.noteMeetings) }
    @State private var showingError = false
    @FocusState private var focused: Bool
    init(notes: NotesStore, initialMeetingID: String?, initialTimestamp: Double?, draft: QuickCaptureDraft? = nil, close: @escaping () -> Void) {
        self.notes = notes; self.initialMeetingID = initialMeetingID; self.initialTimestamp = initialTimestamp
        self.draft = draft ?? QuickCaptureDraft(); self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty { Text("Новая заметка…").font(AppTypography.body).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                TextEditor(text: $draft.text).font(AppTypography.body).scrollContentBackground(.hidden).focused($focused).frame(height: 106)
                    .accessibilityLabel("Текст быстрой заметки")
            }.padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Ink.accent.opacity(0.7) : Ink.line))
            HStack(spacing: 12) {
                Picker("Тип", selection: Binding(get: {
                    draft.kind == "task" && !app.settings.isEnabled(.tasks) ? "note" : draft.kind
                }, set: { draft.kind = $0 })) {
                    Text("Заметка").tag("note"); Text("Важно").tag("important"); Text("Вопрос").tag("question")
                    if app.settings.isEnabled(.tasks) { Text("Задача").tag("task") }
                }
                    .labelsHidden().frame(width: 116).accessibilityLabel("Тип заметки")
                Picker("Куда сохранить", selection: $draft.meetingID) {
                    Text("Входящие").tag("")
                    if !draft.meetingID.isEmpty && !app.noteMeetings.contains(where: { $0.id == draft.meetingID }) { Text("Входящие · встреча недоступна").tag(draft.meetingID) }
                    ForEach(app.noteMeetings) { Text($0.title).tag($0.id) }
                }.labelsHidden().accessibilityLabel("Куда сохранить заметку")
                    .help("Куда сохранить заметку")
            }
            HStack(spacing: 10) {
                if let error = notes.error {
                    Button { showingError = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                            Text("Ошибка")
                            Image(systemName: "chevron.right")
                        }
                    }.buttonStyle(.borderless).font(AppTypography.caption).foregroundStyle(Ink.warning).frame(maxWidth: 190, alignment: .leading)
                        .popover(isPresented: $showingError) { Text(error).font(AppTypography.body).textSelection(.enabled).padding(18).frame(width: 360) }
                        .help(error).accessibilityLabel("Ошибка заметок. Показать подробности").accessibilityValue(error)
                } else if let time = destination.timestamp {
                    Label(Exporter.timestamp(time), systemImage: "clock").font(AppTypography.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Скрыть", action: close).keyboardShortcut(.cancelAction)
                    .help("Закрыть окно и оставить черновик до выхода из приложения")
                Button("Сохранить") {
                    let target = destination
                    if notes.capture(text: draft.text, kind: draft.kind == "task" && !app.settings.isEnabled(.tasks) ? "note" : draft.kind, meetingID: target.meetingID, timestamp: target.timestamp) != nil { draft.saved(); close() }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("Сохранить · ⌘↩")
            }
        }.padding(18).frame(width: 490).background(Ink.paper).appControlDefaults()
            .modifier(PosleThemeRoot(root: notes.root))
            .onAppear { draft.prepare(meetingID: initialMeetingID, timestamp: initialTimestamp); focused = true }
    }
}
