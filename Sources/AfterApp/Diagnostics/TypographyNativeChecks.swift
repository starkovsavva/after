import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import AfterCore
import SwiftUI

/// Own windows and a disposable library only: no capture devices, accounts,
/// provider requests or application routes are involved in this layout check.
@MainActor
enum TypographyNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Typography checks require a disposable preview library")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable typography root required")
        let app = AppStore(preview: true)
        let theme = ThemeController.shared
        theme.configure(root: root); theme.change { $0.textSize = 14 }
        let draft = "Не потерять уточнение: проверить условия первого запуска и сохранить отдельный список вопросов к пятнице."
        app.voice.text = draft
        let paragraph = "К первому запуску подготовим условия оплаты, доступы к стенду и короткую инструкцию. Первые результаты обсудим в пятницу."
        let materialBody = "В материале сохранены важные детали: участники пилота, сроки подготовки, ответственный за доступы и вопросы для следующей встречи."
        let source = KnowledgeSource(id: "typography-source", kind: "note", title: "Материалы к первому запуску: условия оплаты, доступы и вопросы участников", excerpt: paragraph, noteID: "synthetic-note", sourceFingerprint: "synthetic")
        let answer = KnowledgeAnswer(title: "Подготовка первого запуска", paragraphs: [KnowledgeParagraph(text: paragraph, sourceIDs: [source.id])], sources: [source])
        let task = TaskWorkspace(id: "manual:typography-task", title: "Подготовить первый запуск", text: "Согласовать план и детали с участниками.", materials: [TaskMaterial(id: "typography-material", kind: "note", title: "Условия пилота", text: materialBody, available: true)])
        app.notes.setTaskThought(draft, task: task)
        var openedID: String?
        let answerHost = host(KnowledgeAnswerView(answer: answer, openingID: nil, open: { openedID = $0.id }).padding(18), size: NSSize(width: 430, height: 480))
        let voiceHost = host(VoiceCommandPanel(controller: app.voice).environmentObject(app), size: NSSize(width: 466, height: 440))
        let taskHost = host(TaskDetailView(notes: app.notes, task: task).environmentObject(app), size: NSSize(width: 620, height: 760))
        let windows = [answerHost, voiceHost, taskHost].map { view -> NSWindow in
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = view; window.appearance = NSAppearance(named: .aqua); window.makeKeyAndOrderFront(nil)
            return window
        }
        defer { windows.forEach { $0.orderOut(nil); $0.contentView = nil } }
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(true, forAttribute: ax)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: ax) }
        try await wait(windows) {
            frame(answerHost, text: paragraph) != nil && frame(voiceHost, identifier: "voice-command-text") != nil
                && frame(taskHost, text: materialBody) != nil && frame(taskHost, identifier: "tasks.append-text") != nil
        }
        let before = try metrics(answerHost, voiceHost, taskHost, paragraph: paragraph, materialBody: materialBody)
        try capture(answerHost, at: root.appendingPathComponent("answer-14pt.png"))
        theme.change { $0.textSize = 18 }
        try await wait(windows) {
            guard let after = try? metrics(answerHost, voiceHost, taskHost, paragraph: paragraph, materialBody: materialBody) else { return false }
            return zip(before, after).allSatisfy { $1 > $0 + 2 }
        }
        let after = try metrics(answerHost, voiceHost, taskHost, paragraph: paragraph, materialBody: materialBody)
        try expect(app.voice.text == draft && app.notes.taskThought(for: task) == draft, "Changing the text size cannot reset command or task drafts")
        try capture(answerHost, at: root.appendingPathComponent("answer-18pt.png"))
        guard let sourceNode = nodes(answerHost).first(where: { $0.identifier == "knowledge.source." + source.id }), sourceNode.press() else {
            for node in nodes(answerHost) {
                print("TYPOGRAPHY AX type=\(type(of: node.object)) id=\(node.identifier ?? "nil") label=\(node.label ?? "nil") value=\(node.value ?? "nil") frame=\(node.frame)")
            }
            throw AppError.message("The source action must stay accessible at 18 pt")
        }
        try expect(openedID == source.id, "The visible source must preserve its actual callback")
        try capture(answerHost, at: root.appendingPathComponent("answer-18pt.png"))
        try capture(voiceHost, at: root.appendingPathComponent("voice-18pt.png"))
        try capture(taskHost, at: root.appendingPathComponent("task-18pt.png"))
        guard let history = nodes(taskHost).first(where: { $0.identifier == "tasks.tab.history" }), history.press() else { throw AppError.message("Task history tab missing") }
        try await wait(windows) { nodes(taskHost).contains { $0.identifier == "tasks.tab.history" && $0.value == "Выбрана" } }
        theme.change { $0.textSize = 14 }
        try await wait(windows) { (frame(answerHost, text: paragraph)?.height ?? .greatestFiniteMagnitude) < after[0] - 2 }
        try expect(nodes(taskHost).contains { $0.identifier == "tasks.tab.history" && $0.value == "Выбрана" }, "Theme changes must retain local task detail state")
        try expect(app.voice.text == draft && app.notes.taskThought(for: task) == draft, "A second theme change cannot reset drafts")
        app.notes.captureDrafts.removeAll(); _ = app.notes.flushCaptureDrafts()
        print("PASS: live 14→18 pt grows answer, command editor, task material and thought geometry: \(before) → \(after)")
        print("PASS: source action remains accessible; command/thought drafts and selected detail tab survive theme updates")
        print("2 native typography E2E groups passed")
    }
    private static func host<V: View>(_ content: V, size: NSSize) -> NSView {
        let view = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: "ru_RU")).environment(\.colorScheme, .light).frame(width: size.width, height: size.height).background(Ink.paper).tint(Ink.accent))
        view.sizingOptions = []; view.frame = NSRect(origin: .zero, size: size); return view
    }
    private static func metrics(_ answer: NSView, _ voice: NSView, _ task: NSView, paragraph: String, materialBody: String) throws -> [CGFloat] {
        let values = [frame(answer, text: paragraph), frame(voice, identifier: "voice-command-text"), frame(task, text: materialBody), frame(task, identifier: "tasks.append-text")]
        guard values.allSatisfy({ ($0?.height ?? 0) > 0 }) else { throw AppError.message("Native typography geometry missing") }
        return values.compactMap { $0?.height }
    }
    private static func frame(_ root: NSView, text: String? = nil, identifier: String? = nil) -> NSRect? {
        nodes(root).first { node in
            (identifier.map { node.identifier == $0 } ?? (node.label == text || node.value == text)) && node.frame.height > 0
        }?.frame
    }
    private static func wait(_ windows: [NSWindow], _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded(); $0.displayIfNeeded() }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Live typography geometry did not update")
    }
    private static func capture(_ view: NSView, at url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Typography fixture capture failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Typography fixture PNG failed") }
        try data.write(to: url)
    }
    private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw AppError.message(message) } }
    private struct Node {
        let object: NSObject
        private var ax: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func get(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        var identifier: String? { ax?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var label: String? { ax?.accessibilityLabel() ?? get("accessibilityLabel") as? String }
        var value: String? { ax?.accessibilityValue() as? String ?? get("accessibilityValue") as? String }
        var frame: NSRect { ax?.accessibilityFrame() ?? .zero }
        var children: [Any] { ax?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? [] }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let ax { return ax.accessibilityPerformPress() }
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
            result.append(Node(object: object))
            for child in Node(object: object).children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
}
#endif
