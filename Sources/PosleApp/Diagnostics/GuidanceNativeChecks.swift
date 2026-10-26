#if DEBUG
import Foundation

@MainActor
enum GuidanceNativeChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("posle-guidance-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw AppError.message(message) }
        }
        let controller = GuidanceController()
        controller.configure(root: root, preview: false)
        controller.considerStartup(hasMeetings: false)
        try expect(controller.presentation == .gettingStarted, "First empty library must offer optional getting started")
        controller.complete(with: .record)
        try expect(controller.presentation == nil, "An explicit action must close guidance before opening another sheet")
        try expect(controller.takeAction() == .record && controller.takeAction() == nil, "Guidance actions must be consumed once")
        let reopened = GuidanceController(); reopened.configure(root: root, preview: false)
        reopened.considerStartup(hasMeetings: true)
        try expect(reopened.presentation == nil, "Seen guidance must not interrupt reopening the app")
        reopened.presentWhatsNew(); reopened.finishPresentation()
        reopened.dismissHint("cards.create"); reopened.setHintsEnabled(false)
        let persisted = GuidanceController(); persisted.configure(root: root, preview: false)
        try expect(!persisted.hintsEnabled && !persisted.shouldShowHint("tasks.date"), "Hint preference must survive reopen")
        persisted.setHintsEnabled(true)
        try expect(!persisted.shouldShowHint("cards.create") && persisted.shouldShowHint("tasks.date"), "Only the dismissed context hint must remain hidden")
        let original = try Data(contentsOf: root.appendingPathComponent("guidance.json"))
        let preview = GuidanceController(); preview.configure(root: root, preview: true)
        preview.considerStartup(hasMeetings: false)
        try expect(preview.presentation == nil, "Preview must never start guidance automatically")
        preview.presentGettingStarted(); preview.complete(); preview.setHintsEnabled(false)
        try expect(try Data(contentsOf: root.appendingPathComponent("guidance.json")) == original, "Preview must never persist guidance changes")
        let preferencesURL = root.appendingPathComponent("guidance.json")
        var preferences = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        preferences["knownVersion"] = "0.11.0-previous-patch"
        try JSONSerialization.data(withJSONObject: preferences).write(to: preferencesURL, options: .atomic)
        let patch = GuidanceController(); patch.configure(root: root, preview: false)
        patch.considerStartup(hasMeetings: true)
        try expect(patch.presentation == nil, "A patch version must not repeat the same feature guide")
        preferences.removeValue(forKey: "knownFeatureRelease")
        try JSONSerialization.data(withJSONObject: preferences).write(to: preferencesURL, options: .atomic)
        let upgraded = GuidanceController(); upgraded.configure(root: root, preview: false)
        upgraded.considerStartup(hasMeetings: true)
        try expect(upgraded.presentation == .whatsNew, "Older preferences must migrate and offer the new feature guide once")
        upgraded.finishPresentation()
        let afterUpgrade = GuidanceController(); afterUpgrade.configure(root: root, preview: false)
        afterUpgrade.considerStartup(hasMeetings: true)
        try expect(afterUpgrade.presentation == nil, "Completing the migrated feature guide must persist across reopening")
        print("PASS: optional first run, one-shot actions, persisted hints, inert preview and one guide per feature release")
    }
}
#endif
