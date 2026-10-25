import AppKit
import Carbon
import Combine
import PosleCore
import SwiftUI

/// Carbon hotkeys work while another app is active without Accessibility access.
@MainActor
final class QuickCaptureController: NSObject {
    private weak var store: AppStore?
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var captureKey: EventHotKeyRef?
    private var bookmarkKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var settingsObserver: NSObjectProtocol?
    private var started = false
    init(store: AppStore) { self.store = store; super.init() }
    func start() {
        guard !started else { return }; started = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "После — заметки")
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Быстрая заметка…", action: #selector(showFromMenu), keyEquivalent: "")
        capture.target = self; menu.addItem(capture)
        let mark = NSMenuItem(title: "Отметить важный момент", action: #selector(markFromMenu), keyEquivalent: "")
        mark.target = self; menu.addItem(mark)
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
            Task { @MainActor in if identifier == 1 { owner.show() } else if identifier == 2 { owner.markImportant() } }
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
        if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }; settingsObserver = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
        panel?.close(); panel = nil; started = false
    }
    private func registerShortcuts() {
        if let captureKey { UnregisterEventHotKey(captureKey) }; captureKey = nil
        if let bookmarkKey { UnregisterEventHotKey(bookmarkKey) }; bookmarkKey = nil
        guard let store, eventHandler != nil else { return }
        store.notes.hotkeyNotice = nil
        if store.settings.quickCaptureEnabled {
            let alternate = store.settings.quickCaptureShortcut == "controlShiftSpace"
            let code = UInt32(alternate ? kVK_Space : kVK_ANSI_N)
            let modifiers = UInt32(alternate ? (controlKey | shiftKey) : (controlKey | optionKey))
            let result = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x50534C45, id: 1), GetApplicationEventTarget(), 0, &captureKey)
            if result != noErr { store.notes.hotkeyNotice = "Сочетание быстрой заметки занято. Выберите другое в настройках или используйте строку меню." }
        }
        if store.settings.bookmarkShortcutEnabled {
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x50534C45, id: 2), GetApplicationEventTarget(), 0, &bookmarkKey)
            if result != noErr { store.notes.hotkeyNotice = "Сочетание ⌃⌥B занято. Отметить момент можно кнопкой во время записи." }
        }
    }
    func show() {
        guard let store else { return }
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let target: String? = store.settings.notesSaveToActiveMeeting ? (store.captureMeetingID ?? (store.isPlaying ? store.selection : nil)) : nil
        let timestamp: Double? = !store.settings.notesAutoTimestamp ? nil : target == store.captureMeetingID && store.isRecording
            ? max(0, Date().timeIntervalSince(store.recordingDate ?? Date())) : target != nil ? store.playbackTime : nil
        let view = QuickCaptureView(notes: store.notes, initialMeetingID: target, initialTimestamp: timestamp) { [weak self] in self?.panel?.orderOut(nil); self?.panel = nil }.environmentObject(store)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 330), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Быстрая заметка"; window.isFloatingPanel = true; window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view)
        window.center(); panel = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func markImportant() {
        guard let store else { return }
        let meetingID = store.captureMeetingID ?? (store.transcript != nil ? store.selection : nil)
        guard let meetingID else { show(); return }
        let time = store.isRecording && meetingID == store.captureMeetingID
            ? max(0, Date().timeIntervalSince(store.recordingDate ?? Date())) : store.playbackTime
        if let note = store.notes.capture(text: "Важный момент", kind: "important", meetingID: meetingID, timestamp: time) {
            store.notes.highlightedNoteID = note.id; store.notice = "Отмечено · \(Exporter.timestamp(time))"
        }
    }
    @objc private func showFromMenu() { show() }
    @objc private func markFromMenu() { markImportant() }
    @objc private func openMain() {
        panel?.orderOut(nil); NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) { window.makeKeyAndOrderFront(nil) }
    }
}

struct QuickCaptureView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let initialMeetingID: String?
    let initialTimestamp: Double?
    let close: () -> Void
    @State private var text = ""
    @State private var kind = "note"
    @State private var meetingID = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Поймать мысль", systemImage: "pencil.line").font(AppTypography.heading)
                Spacer()
                if let time = initialTimestamp, meetingID == initialMeetingID { Text(Exporter.timestamp(time)).font(AppTypography.control).foregroundStyle(Ink.accent).monospacedDigit() }
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text("Мысль, вопрос или обещание…").font(AppTypography.body).foregroundStyle(.tertiary).padding(.top, 9).padding(.leading, 5).allowsHitTesting(false) }
                TextEditor(text: $text).font(AppTypography.body).scrollContentBackground(.hidden).focused($focused).frame(minHeight: 100)
                    .accessibilityLabel("Текст быстрой заметки")
            }.padding(7).background(Ink.soft, in: RoundedRectangle(cornerRadius: 9))
            HStack {
                Picker("Тип", selection: $kind) { Text("Заметка").tag("note"); Text("Важно").tag("important"); Text("Вопрос").tag("question"); Text("Задача").tag("task") }.labelsHidden().frame(width: 120)
                Picker("Куда сохранить", selection: $meetingID) { Text("Входящие").tag(""); ForEach(app.meetings) { Text($0.title).tag($0.id) } }.labelsHidden()
            }
            if let error = notes.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning).lineLimit(3) }
            HStack {
                Text("⌘↩ сохранить").font(AppTypography.caption).foregroundStyle(.secondary)
                Spacer(); Button("Отмена", action: close).keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    let target = meetingID.isEmpty ? nil : meetingID
                    let time = target == initialMeetingID ? initialTimestamp : nil
                    if notes.capture(text: text, kind: kind, meetingID: target, timestamp: time) != nil { text = ""; close() }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 490).background(Ink.paper).appControlDefaults()
            .onAppear { meetingID = initialMeetingID ?? ""; focused = true }
    }
}
