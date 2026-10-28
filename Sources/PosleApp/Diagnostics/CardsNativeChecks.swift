#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Exercises the shipped Rust ABI, view model and native list on an empty,
/// disposable fixture. No model, account, clipboard or capture permissions.
@MainActor
enum CardsNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Cards checks require an explicit disposable preview root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable cards root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let registration = UUID()
        UnsavedEditorRegistry.set(id: registration, title: "Новая карточка", dirty: true)
        try expect(UnsavedEditorRegistry.hasUnsaved && UnsavedEditorRegistry.titles.contains("Новая карточка"), "Unsaved editor was not registered")
        UnsavedEditorRegistry.set(id: registration, title: "Новая карточка", dirty: false)
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Saving a draft did not release the exit gate")
        UnsavedEditorRegistry.set(id: registration, title: "Карточка", dirty: true)
        UnsavedEditorRegistry.remove(id: registration)
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Closing an editor did not release the exit gate")
        let app = AppStore(preview: true)
        try expect(app.meetings.isEmpty, "Cards checks require an empty fixture")
        let bridge = try RustBridge.shared.get()
        let data = try bridge.request(root: root, command: "card-save", arguments: ["front": "circle back", "back": "Вернуться к вопросу", "newDeckTitle": "Рабочие фразы"])
        let created = try JSONDecoder().decode(CardSaveResult.self, from: data)
        let id = created.meeting.id
        for (front, back) in [("follow up", "Уточнить результат"), ("trade-off", "Компромисс")] {
            _ = try bridge.request(root: root, command: "card-save", arguments: ["meetingID": id, "front": front, "back": back])
        }
        app.reloadLibrary()
        let workspace = CardsWorkspace()
        await workspace.reload(root: root, meetingID: id)
        try expect(workspace.entries.count == 3 && workspace.errors.isEmpty && workspace.error == nil, "Native ABI could not load three manual cards")
        let original = workspace.entries[0]
        await workspace.preview(root: root, entry: original)
        try expect(workspace.options[1] == "1 мин" && workspace.options[2] == "5 мин 30 с" && workspace.options[3] == "10 мин", "FSRS preview intervals do not match the real learning steps")
        await workspace.rate(root: root, entry: original, rating: 3, meetingID: id)
        try expect(workspace.canUndo && workspace.entries[0].review?.count == 1, "Native grading failed")
        await workspace.undo(root: root, meetingID: id)
        try expect(!workspace.canUndo && workspace.entries[0].review == nil, "Native undo did not restore the unreviewed state")
        print("PASS: Swift → Rust card creation, loading, exact FSRS intervals, rating and undo")
        var edit = CardsWorkspace.arguments(original)
        edit["front"] = "circle back on"; edit["back"] = "Вернуться к обсуждению"
        _ = try bridge.request(root: root, command: "card-save", arguments: edit)
        do { _ = try bridge.request(root: root, command: "card-save", arguments: edit); throw AppError.message("Stale edit was accepted") }
        catch { try expect(error.localizedDescription != "Stale edit was accepted", "Stale card editor overwrote a newer version") }
        await workspace.reload(root: root, meetingID: id)
        let edited = workspace.entries[0]
        try expect(edited.card.front == "circle back on", "Edited text did not reload")
        await workspace.mutate(root: root, entry: edited, delete: false, meetingID: id)
        try expect(workspace.entries[0].suspended && !workspace.entries[0].isDue, "Paused card remained in the review queue")
        await workspace.mutate(root: root, entry: workspace.entries[0], delete: false, meetingID: id)
        await workspace.mutate(root: root, entry: workspace.entries[2], delete: true, meetingID: id)
        try expect(workspace.entries.count == 2, "Deleted card remained in the library")
        print("PASS: stale edit conflict, persistence, pause/resume and deletion")
        let host = NSHostingView(rootView: CardsWorkspaceView(meetingID: id).environmentObject(app).frame(width: 960, height: 660))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 960, height: 660)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await wait(host, window) { NativeTabNavigation.contains("cards.mode.all", in: host) }
        try expect(NativeTabNavigation.isSelected("cards.mode.study", in: host), "Cards must start in the selected review tab")
        try NativeTabNavigation.press("cards.mode.all", in: host)
        try await wait(host, window) { NativeTabNavigation.isSelected("cards.mode.all", in: host) && !NativeTabNavigation.isSelected("cards.mode.study", in: host) }
        try await wait(host, window) { descendants(host, as: NSTableView.self).contains { $0.numberOfRows >= 2 } }
        let table = descendants(host, as: NSTableView.self).first { $0.numberOfRows >= 2 }!
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await wait(host, window) { table.selectedRow == 1 }
        var summaryData = try bridge.read(root: root, url: app.meetingDirectory(id).appendingPathComponent("summary.json"))
        var summary = try JSONSerialization.jsonObject(with: summaryData) as! [String: Any]
        var cards = summary["cards"] as! [[String: Any]]
        for index in cards.indices { cards[index]["id"] = "replaced-\(index)" }
        summary["cards"] = cards
        _ = try bridge.request(root: root, command: "write", arguments: ["path": "meetings/\(id)/summary.json", "value": summary])
        NotificationCenter.default.post(name: .posleJobsChanged, object: nil)
        try await wait(host, window) { descendants(host, as: NSTableView.self).contains { $0.numberOfRows == 2 && $0.selectedRow == 0 } }
        summaryData = try bridge.read(root: root, url: app.meetingDirectory(id).appendingPathComponent("summary.json"))
        let intact = summaryData
        print("PASS: actual native All cards list selection survives replacement IDs with a real fallback card")
        let bad = app.meetingDirectory(id).appendingPathComponent("examples.json")
        try Data("malformed".utf8).write(to: bad)
        await workspace.reload(root: root, meetingID: id)
        try expect(!workspace.errors.isEmpty && workspace.error == nil, "Read failure masqueraded as an empty library")
        try FileManager.default.removeItem(at: bad)
        await workspace.reload(root: root, meetingID: id)
        try expect(workspace.errors.isEmpty && workspace.entries.count == 2, "Retry did not recover readable cards")
        let afterRetry = try bridge.read(root: root, url: app.meetingDirectory(id).appendingPathComponent("summary.json"))
        try expect(afterRetry == intact, "Load failure changed card data")
        print("PASS: visible per-deck errors and retry preserve the underlying cards")
        try await AppTabBarNativeChecks.run()
        print("5 native card workflow checks passed")
    }
    private static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }
    private static func wait(_ host: NSView, _ window: NSWindow, condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Native cards workflow timed out")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
}
#endif
