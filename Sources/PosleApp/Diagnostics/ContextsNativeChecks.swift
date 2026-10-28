#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Disposable metadata and actual native controls; no account or model access.
@MainActor
enum ContextsNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable context preview required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable context root required")
        let app = AppStore(preview: true); app.settings.features.tasks = true
        guard let english = app.notes.saveFolder(LibraryFolder(name: "Английский")), let work = app.notes.saveFolder(LibraryFolder(name: "Работа")) else { throw AppError.message("Context folders fixture failed") }
        let lesson = Meeting(title: "Практика разговорного английского", source: "synthetic.mp3")
        let planning = Meeting(title: "Планирование запуска", source: "synthetic.mp3")
        for meeting in [lesson, planning] {
            try FileManager.default.createDirectory(at: app.meetingDirectory(meeting.id), withIntermediateDirectories: true)
            try app.write(meeting, app.meetingDirectory(meeting.id).appendingPathComponent("meta.json"))
        }
        app.reloadLibrary()
        try expect(app.notes.assignMeetingFolder(lesson.id, folderID: english.id) && app.notes.assignMeetingFolder(planning.id, folderID: work.id), "Folder assignment fixture failed")
        var original = app.notes.context(for: lesson.id); original.person = "Анна"; original.templateID = app.notes.templates.first?.id
        try expect(app.notes.saveContext(original), "Context fixture save failed")
        let summary = Summary(overview: "Повторили вежливые просьбы и разобрали фразы для рабочего созвона.", items: [], cards: [], provider: "fixture", model: "fixture", generatedAt: 1, warnings: [])
        try app.write(summary, app.meetingDirectory(lesson.id).appendingPathComponent("summary.json"))
        try expect(app.notes.capture(text: "Подготовить три примера вежливых просьб к следующему занятию.", meetingID: lesson.id) != nil, "Context note fixture failed")
        app.notes.notice = nil
        app.folderSelection = english.id
        let view = NSHostingView(rootView: NotesContextsView(notes: app.notes).environmentObject(app).appControlDefaults().preferredColorScheme(.light).background(Ink.paper))
        view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 1050, height: 760)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = view; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let priorAX = NSApp.accessibilityAttributeValue(ax); NSApp.accessibilitySetValue(true, forAttribute: ax)
        defer { NSApp.accessibilitySetValue(priorAX, forAttribute: ax) }
        try await wait(window) { ids(window).contains("contexts.add") }
        try expect(!ids(window).contains("contexts.selection"), "Empty project list must show an action rather than an unusable picker")
        try snapshot(view, root.appendingPathComponent("contexts-empty.png"))
        try press(window, "contexts.add")
        try await wait(window) { ids(window).contains("contexts.link.label") }
        try edit(window, placeholder: "Название проекта", value: "  Разговорная практика  ")
        try await wait(window) { UnsavedEditorRegistry.hasUnsaved }
        if let sheet = window.attachedSheet?.contentView { try snapshot(sheet, root.appendingPathComponent("contexts-link.png")) }
        try press(window, "contexts.link.save")
        try await wait(window) { app.notes.context(for: lesson.id).project == "Разговорная практика" && !ids(window).contains("contexts.link.save") }
        let saved = app.notes.context(for: lesson.id)
        try expect(saved.folderID == english.id && saved.person == "Анна" && saved.templateID == original.templateID && !UnsavedEditorRegistry.hasUnsaved,
                   "Native linking must preserve the folder, person, template and clean up the draft")
        try expect(app.notes.context(for: planning.id).project.isEmpty, "Linking must never affect another folder's meeting")
        try await wait(window) { ids(window).contains("contexts.edit." + lesson.id) }
        try snapshot(view, root.appendingPathComponent("contexts-project.png"))
        print("PASS: empty context action creates a project link through native fields and preserves the existing folder/person/template")

        // A second editor snapshots the whole context revision: moving the
        // meeting in another window must not be undone by this older label.
        var stale = ContextLinkDraft(baseline: saved, mode: "person", label: "Анна · преподаватель")
        try expect(app.notes.assignMeetingFolder(lesson.id, folderID: work.id), "Concurrent context move fixture failed")
        try expect(!app.notes.saveContext(stale.updated), "A stale context label must not overwrite a concurrent folder change")
        app.notes.error = nil; app.notes.reload()
        try expect(app.notes.context(for: lesson.id).folderID == work.id && app.notes.context(for: lesson.id).person == "Анна", "Revision conflict must preserve both the current folder and original person")
        stale = ContextLinkDraft(baseline: app.notes.context(for: lesson.id), mode: "person", label: stale.label)
        try expect(app.notes.saveContext(stale.updated), "An explicit fresh retry should save the label")
        try await wait(window) { ids(window).contains("contexts.openMeetings") }
        try expect(!ids(window).contains("contexts.edit." + lesson.id), "A meeting moved out of the selected folder cannot remain in its project view")
        let englishIndex = ContextLibraryIndex(meetings: app.noteMeetings, contexts: app.notes.workspace.contexts, mode: "project")
        try expect(englishIndex.labels.isEmpty, "Folder-scoped context index must not expose labels from another folder")
        app.folderSelection = nil
        try await wait(window) { ids(window).contains("contexts.edit." + lesson.id) }
        print("PASS: folder-scoped context navigation updates after moves; stale revision cannot undo concurrent metadata")

        let index = ContextLibraryIndex(meetings: [lesson, planning], contexts: [
            MeetingContext(meetingID: lesson.id, project: "Пилот", person: "Анна"),
            MeetingContext(meetingID: planning.id, project: "  пилот  ", person: "Борис"),
            MeetingContext(meetingID: "missing", project: "Скрытый проект")
        ], mode: "project")
        try expect(index.labels.count == 1 && index.meetings(for: "ПИЛОТ").count == 2 && index.meetings(for: "").isEmpty,
                   "Context labels must match case-insensitively, deduplicate and exclude unavailable meetings")
        let briefStore = ContextBriefStore()
        let load = Task { await briefStore.load(root: root, request: ContextBriefRequest(folderID: work.id, mode: "project", label: saved.project, meetings: [lesson])) }
        // Wait for the async loader to actually begin before cancelling its scope.
        for _ in 0..<100 where !briefStore.loading && briefStore.summaries.isEmpty { await Task.yield() }
        briefStore.cancel(); load.cancel(); await load.value
        try expect(briefStore.summaries.isEmpty && !briefStore.loading, "Cancelled scope loads cannot repopulate the old folder")
        print("PASS: context index handles labels and deleted meetings; cancelled summary loads do not refill a closed scope")
        print("3 native context checks passed")
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw AppError.message(message) } }
    private static func roots(_ window: NSWindow) -> [NSView] { [window.contentView, window.attachedSheet?.contentView].compactMap { $0 } }
    private static func ids(_ window: NSWindow) -> Set<String> { Set(roots(window).flatMap(nodes).compactMap(\.identifier)) }
    private static func wait(_ window: NSWindow, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { throw AppError.message("Context native control timeout: " + ids(window).sorted().joined(separator: ", ")) }
            window.contentView?.layoutSubtreeIfNeeded(); window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        window.contentView?.layoutSubtreeIfNeeded(); window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
    }
    private static func edit(_ window: NSWindow, placeholder: String, value: String) throws {
        func fields(_ root: NSView) -> [NSTextField] { (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields) }
        guard let field = roots(window).flatMap(fields).first(where: { $0.placeholderString == placeholder }) else { throw AppError.message("Context field missing: " + placeholder) }
        let target = window.attachedSheet ?? window; target.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Context field editor missing") }
        editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange())
    }
    private static func press(_ window: NSWindow, _ id: String) throws {
        let matching = roots(window).flatMap(nodes).filter { $0.identifier == id }
        for node in matching { if node.press() { return } }
        if let frame = matching.compactMap(\.frame).first(where: { $0.width > 0 && $0.height > 0 }) {
            let target = window.attachedSheet ?? window; target.makeKeyAndOrderFront(nil)
            let point = target.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            // Post the complete pair before yielding: AppKit's mouse tracking
            // may require the matching mouse-up inside its nested event loop.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
            }
            return
        }
        throw AppError.message("Context native action missing: " + id + " " + matching.map { String(describing: type(of: $0.object)) }.joined(separator: ", "))
    }
    private static func snapshot(_ view: NSView, _ url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Context snapshot failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Context PNG failed") }; try data.write(to: url)
    }
    private static func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, _ depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth + 1) } }
        }
        visit(root, 0); return result
    }
    @MainActor private struct Node {
        let object: NSObject
        private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func get(_ name: String) -> Any? { let selector = NSSelectorFromString(name); return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil }
        var identifier: String? { modern?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var children: [Any] { modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? [] }
        var frame: NSRect? {
            if let modern { return modern.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(method, to: Frame.self)(object, selector)
        }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let control = cell.controlView as? NSButton, control.isEnabled { control.performClick(nil); return true }
            if let control = object as? NSControl, control.isEnabled { control.performClick(nil); return true }
            return modern?.accessibilityPerformPress() ?? false
        }
    }
}
#endif
