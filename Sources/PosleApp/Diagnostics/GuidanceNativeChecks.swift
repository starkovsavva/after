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
        let controller = GuidanceController(version: "0.17.6.5")
        controller.configure(root: root, preview: false)
        controller.considerStartup(hasMeetings: false)
        try expect(controller.presentation == .gettingStarted, "First empty library must offer optional getting started")
        controller.complete(with: .record)
        try expect(controller.presentation == nil, "An explicit action must close guidance before opening another sheet")
        try expect(controller.takeAction() == .record && controller.takeAction() == nil, "Guidance actions must be consumed once")
        let reopened = GuidanceController(version: "0.17.6.5"); reopened.configure(root: root, preview: false)
        reopened.considerStartup(hasMeetings: true)
        try expect(reopened.presentation == nil, "Seen guidance must not interrupt reopening the app")
        reopened.presentWhatsNew(); reopened.finishPresentation()
        reopened.dismissHint("cards.create"); reopened.setHintsEnabled(false)
        let persisted = GuidanceController(version: "0.17.6.5"); persisted.configure(root: root, preview: false)
        try expect(!persisted.hintsEnabled && !persisted.shouldShowHint("tasks.date"), "Hint preference must survive reopen")
        persisted.setHintsEnabled(true)
        try expect(!persisted.shouldShowHint("cards.create") && persisted.shouldShowHint("tasks.date"), "Only the dismissed context hint must remain hidden")
        let original = try Data(contentsOf: root.appendingPathComponent("guidance.json"))
        let preview = GuidanceController(version: "0.17.6.5"); preview.configure(root: root, preview: true)
        preview.considerStartup(hasMeetings: false)
        try expect(preview.presentation == nil, "Preview must never start guidance automatically")
        preview.presentGettingStarted(); preview.complete(); preview.setHintsEnabled(false)
        try expect(try Data(contentsOf: root.appendingPathComponent("guidance.json")) == original, "Preview must never persist guidance changes")
        let preferencesURL = root.appendingPathComponent("guidance.json")
        var preferences = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        preferences["knownVersion"] = "0.17.6.4"
        preferences["lastLaunchedVersion"] = "0.17.6.4"
        try JSONSerialization.data(withJSONObject: preferences).write(to: preferencesURL, options: .atomic)
        let patch = GuidanceController(version: "0.17.6.5"); patch.configure(root: root, preview: false)
        patch.considerStartup(hasMeetings: true)
        try expect(patch.presentation == .whatsNew, "Each patch upgrade must offer its own release notes")
        try expect(patch.previousVersion == "0.17.6.4" && patch.previousVersionIsExact, "New launch history must preserve the actual previous patch")
        patch.finishPresentation()
        let afterUpgrade = GuidanceController(version: "0.17.6.5"); afterUpgrade.configure(root: root, preview: false)
        afterUpgrade.considerStartup(hasMeetings: true)
        try expect(afterUpgrade.presentation == nil, "Completing this version must persist across reopening")
        try ReleaseNotesNativeChecks.run()
        print("PASS: optional first run, one-shot actions, persisted hints, inert preview and one presentation per product version")
    }
}
#endif
