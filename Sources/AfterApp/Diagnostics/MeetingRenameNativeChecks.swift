import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import Foundation
import AfterCore
import SwiftUI

/// Exercises real AppKit double-click, field editor and keyboard dispatch against
/// production views and Rust persistence. Never touches the user's library.
@MainActor
enum MeetingRenameNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable preview required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable title UI root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let app = AppStore(preview: true)
        var first = Meeting(title: "Первый синк", source: "source.mp3")
        first.duration = 420; first.speakerNames = ["speaker_1": "Анна"]
        let second = Meeting(title: "Урок английского", source: "source.mp3")
        for meeting in [first, second] {
            let directory = app.meetingDirectory(meeting.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try app.write(meeting, directory.appendingPathComponent("meta.json"))
        }
        app.reloadLibrary(); app.selection = first.id; app.loadSelection(); app.tab = "notes"
        let host = Host(AnyView(MainView().environmentObject(app)), width: 1260, height: 820)
        defer {
            for id in Array(app.meetingTitleEdits.drafts.keys) { app.meetingTitleEdits.cancel(id) }
            host.close()
        }
        try await settle(host) { titleNode(host) != nil }
        let initialHeight = titleNode(host)!.frame.height
        try await doubleClick(host)
        try await Task.sleep(for: .milliseconds(100))
        try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "  Синк с руководителем  ")
        try await key(host, "\r", code: 36)
        try await settle(host) { app.selected?.title == "Синк с руководителем" && app.meetingTitleEdits.drafts[first.id] == nil && field(host)?.stringValue == "Синк с руководителем" }
        let saved: Meeting? = app.read(app.meetingDirectory(first.id).appendingPathComponent("meta.json"))
        try expect(saved?.title == "Синк с руководителем" && saved?.duration == 420 && saved?.speakerNames == first.speakerNames,
                   "Double-click/Return must trim and persist title while preserving unrelated metadata")
        try expect(titleNode(host)?.frame.height == initialHeight, "Editing must not change title height")
        let reopened = AppStore(preview: true)
        try expect(reopened.meetings.contains { $0.id == first.id && $0.title == "Синк с руководителем" }, "Renamed title must survive library reopening")
        print("PASS: real double-click/Return persists a trimmed title, keeps layout and survives reopening"); fflush(stdout)

        try await doubleClick(host); try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "Не сохранять это имя")
        try await key(host, "\u{1b}", code: 53)
        try await settle(host) { app.meetingTitleEdits.drafts[first.id] == nil && field(host)?.stringValue == "Синк с руководителем" }
        try expect(app.selected?.title == "Синк с руководителем" && !UnsavedEditorRegistry.hasUnsaved, "Escape must restore saved title and release unsaved guard")
        print("PASS: Escape cancels inline rename without changing the saved meeting"); fflush(stdout)

        try await doubleClick(host); try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "Название после потери фокуса")
        try await focusNoteComposer(host)
        try await settle(host) { app.selected?.title == "Название после потери фокуса" && app.meetingTitleEdits.drafts[first.id] == nil }
        print("PASS: leaving a valid title field commits the edit"); fflush(stdout)

        try await doubleClick(host); try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "   "); try await key(host, "\r", code: 36)
        try await settle(host) { app.meetingTitleEdits.drafts[first.id]?.error != nil }
        try expect(app.selected?.title == "Название после потери фокуса" && UnsavedEditorRegistry.hasUnsaved, "Empty title must remain a protected draft without overwriting data")
        app.selection = second.id; app.loadSelection()
        try await settle(host) { titleNode(host)?.value == second.title }
        try expect(app.meetingTitleEdits.drafts[first.id]?.text == "   ", "Leaving a meeting must retain its invalid draft")
        app.selection = first.id; app.loadSelection()
        try await settle(host) { field(host)?.currentEditor() != nil && field(host)?.stringValue == "   " }
        try await replace(host, "Исправленное название"); try await key(host, "\r", code: 36)
        try await settle(host) { app.selected?.title == "Исправленное название" && app.meetingTitleEdits.drafts[first.id] == nil }
        try expect(app.meetings.first { $0.id == second.id }?.title == second.title, "A recovered draft must stay bound to its own meeting")
        print("PASS: empty title is rejected and retained across source switches, then saves to the correct meeting"); fflush(stdout)

        try await doubleClick(host); try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "Мой параллельный вариант")
        _ = try RustBridge.shared.get().request(root: app.root, command: "update", arguments: ["id": first.id, "patch": ["title": "Правка из другого окна", "duration": 900]])
        try await key(host, "\r", code: 36)
        try await settle(host) { app.meetingTitleEdits.drafts[first.id]?.error != nil }
        let concurrent: Meeting? = app.read(app.meetingDirectory(first.id).appendingPathComponent("meta.json"))
        try expect(concurrent?.title == "Правка из другого окна" && concurrent?.duration == 900 && app.meetingTitleEdits.drafts[first.id]?.text == "Мой параллельный вариант", "Stale rename must keep both the newer saved metadata and local draft")
        app.selection = second.id; app.loadSelection()
        try await settle(host) { titleNode(host)?.value == second.title }
        app.selection = first.id; app.loadSelection()
        try await settle(host) { field(host)?.stringValue == "Мой параллельный вариант" && field(host)?.currentEditor() != nil }
        try await key(host, "\u{1b}", code: 53)
        try await settle(host) { titleNode(host)?.value == "Правка из другого окна" }
        print("PASS: concurrent title edit cannot overwrite the newer value; draft stays recoverable"); fflush(stdout)

        // The existing context-menu notification must focus this same editor.
        NotificationCenter.default.post(name: Notification.Name("PosleRenameMeeting"), object: first.id)
        try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "Название после ошибки записи")
        let metadata = app.meetingDirectory(first.id).appendingPathComponent("meta.json")
        let originalBytes = try Data(contentsOf: metadata)
        try Data("{malformed fixture".utf8).write(to: metadata, options: .atomic)
        var restoreOriginal = true
        defer { if restoreOriginal { try? originalBytes.write(to: metadata, options: .atomic) } }
        try await key(host, "\r", code: 36)
        try await settle(host) { app.meetingTitleEdits.drafts[first.id]?.error != nil }
        try expect(app.meetingTitleEdits.drafts[first.id]?.text == "Название после ошибки записи" && UnsavedEditorRegistry.hasUnsaved, "Save failure must retain the complete draft and quit/update guard")
        try originalBytes.write(to: metadata, options: .atomic)
        try await key(host, "\r", code: 36)
        try await settle(host) { app.selected?.title == "Название после ошибки записи" && app.meetingTitleEdits.drafts[first.id] == nil }
        restoreOriginal = false
        try expect(!app.busy && !app.isRecording && app.jobs.activeCount == 0 && !app.calendar.connected, "Title checks must not start inference, recording or calendar access")
        print("PASS: menu rename uses the inline editor; failed persistence keeps draft and supports retry"); fflush(stdout)

        NotificationCenter.default.post(name: Notification.Name("PosleRenameMeeting"), object: first.id)
        try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "Сохранённое имя из меню")
        try await key(host, "\r", code: 36)
        try await settle(host) { app.selected?.title == "Сохранённое имя из меню" && app.meetingTitleEdits.drafts[first.id] == nil }
        try expect(app.meetingTitleEdits.focusRequest == nil, "Successful menu rename must clear its focus request")
        try await expectRemountKeepsNoteFocus(host, app: app, meetingID: first.id, other: second)

        NotificationCenter.default.post(name: Notification.Name("PosleRenameMeeting"), object: first.id)
        try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "Отменённое имя из меню")
        try await key(host, "\u{1b}", code: 53)
        try await settle(host) { app.meetingTitleEdits.drafts[first.id] == nil && field(host)?.stringValue == "Сохранённое имя из меню" }
        try expect(app.meetingTitleEdits.focusRequest == nil, "Escape must clear the matching menu focus request")
        try await expectRemountKeepsNoteFocus(host, app: app, meetingID: first.id, other: second)

        NotificationCenter.default.post(name: Notification.Name("PosleRenameMeeting"), object: first.id)
        try await settle(host) { field(host)?.currentEditor() != nil }
        try await replace(host, "Новое имя после возврата")
        try await key(host, "\r", code: 36)
        try await settle(host) { app.selected?.title == "Новое имя после возврата" && app.meetingTitleEdits.drafts[first.id] == nil && app.meetingTitleEdits.focusRequest == nil }
        print("PASS: completed or cancelled menu rename cannot steal focus after remount; a fresh request still focuses the title"); fflush(stdout)
    }
    @MainActor private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ root: AnyView, width: CGFloat, height: CGFloat) {
            view = NSHostingView(rootView: root); view.sizingOptions = []
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            if let visible = NSScreen.main?.visibleFrame { window.setFrameOrigin(NSPoint(x: visible.minX + 10, y: visible.maxY - window.frame.height)) }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil) }
    }
    private struct TitleNode { let frame: NSRect; let value: String }
    private static func titleNode(_ host: Host) -> TitleNode? {
        guard let field = field(host) else { return nil }
        return TitleNode(frame: field.accessibilityFrame(), value: field.stringValue)
    }
    private static func field(_ host: Host) -> NSTextField? {
        func visit(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Название встречи" { return field }
            for child in view.subviews { if let found = visit(child) { return found } }
            return nil
        }
        return visit(host.view)
    }
    private static func doubleClick(_ host: Host) async throws {
        guard let title = titleNode(host) else { throw AppError.message("Native meeting title missing") }
        host.window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(50))
        let point = host.window.convertPoint(fromScreen: NSPoint(x: title.frame.minX + min(30, title.frame.width / 2), y: title.frame.midY))
        for click in 1...2 { try sendClick(host, point: point, count: click) }
        try await Task.sleep(for: .milliseconds(50))
    }
    private static func sendClick(_ host: Host, point: NSPoint, count: Int) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: host.window.windowNumber, context: nil, eventNumber: count, clickCount: count,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { throw AppError.message("Cannot create native click") }
            return event
        }
        // Native controls track synchronously inside mouseDown. Queue mouseUp
        // first, then deliver down to the target window with exact coordinates.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        host.window.sendEvent(try event(.leftMouseDown))
    }

    private static func expectRemountKeepsNoteFocus(_ host: Host, app: AppStore, meetingID: String, other: Meeting) async throws {
        let savedTitle = app.meetings.first(where: { $0.id == meetingID })?.title
        try await focusNoteComposer(host)
        app.selection = other.id; app.loadSelection()
        try await settle(host) { titleNode(host)?.value == other.title }
        try await focusNoteComposer(host)
        app.selection = meetingID; app.loadSelection()
        try await settle(host) { titleNode(host)?.value == savedTitle }
        // Let any stale async request from the newly mounted native field run.
        try await Task.sleep(for: .milliseconds(100))
        try expect(field(host)?.currentEditor() == nil && host.window.firstResponder is PlainNoteTextView,
                   "Returning to a completed rename must preserve note focus rather than replay the old menu request")
        try expect(app.meetingTitleEdits.drafts[meetingID] == nil, "Remount must not recreate a finished title draft")
    }
    private static func focusNoteComposer(_ host: Host) async throws {
        func find(_ view: NSView) -> PlainNoteTextView? {
            if let editor = view as? PlainNoteTextView { return editor }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let editor = find(host.view) else { throw AppError.message("Production note composer missing") }
        try expect(host.window.makeFirstResponder(editor), "Native note focus request failed")
        try await Task.sleep(for: .milliseconds(50))
        try expect(host.window.firstResponder === editor, "Focus must transfer to the actual note editor")
    }
    private static func replace(_ host: Host, _ text: String) async throws {
        guard let editor = field(host)?.currentEditor() as? NSTextView else { throw AppError.message("Native title field editor not focused") }
        editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(30))
    }
    private static func key(_ host: Host, _ text: String, code: UInt16) async throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: host.window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                           isARepeat: false, keyCode: code) else { throw AppError.message("Cannot create key event") }
        host.window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
    private static func settle(_ host: Host, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Native meeting rename did not reach expected state. Title: " + (field(host)?.stringValue ?? "missing"))
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}
#endif
