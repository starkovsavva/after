#if DEBUG
import Foundation
import PosleCore

@MainActor
enum ReleaseNotesNativeChecks {
    static func run() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("after-release-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !value() { throw AppError.message(message) }
        }
        func fixture(_ name: String, _ values: [String: Any]) throws -> URL {
            let root = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: values).write(to: root.appendingPathComponent("guidance.json"))
            return root
        }
        func preferences(_ root: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("guidance.json"))) as! [String: Any]
        }
        let knowledgeRoot = try fixture("knowledge-upgrade", ["introSeen": true, "knownVersion": "0.17.6.5", "lastLaunchedVersion": "0.17.6.5"])
        let knowledge = GuidanceController(version: "0.18.0")
        knowledge.configure(root: knowledgeRoot, preview: false)
        knowledge.updateFeatures(AppFeatures())
        knowledge.considerStartup(hasMeetings: true)
        let latestUpdates = knowledge.featureGroups.flatMap(\.updates)
        try expect(knowledge.presentation == .whatsNew && knowledge.previousVersion == "0.17.6.5", "Knowledge release preserves the previous installed version")
        try expect(Set(latestUpdates.map(\.id)).isSuperset(of: ["knowledgeBase", "semanticSearch", "tasks", "assistant", "recording"]), "The release explains each shipped workflow")
        try expect(knowledge.featureGroups.contains { $0.group == .disabled && $0.updates.contains { $0.id == "knowledgeBase" } }, "Announcing a new optional feature does not enable it")
        try expect(!latestUpdates.flatMap(\.changes).contains { $0.id == "recording.microphone-route" }, "Already installed release changes must not appear as new")
        knowledge.complete()
        let knowledgeReopen = GuidanceController(version: "0.18.0")
        knowledgeReopen.configure(root: knowledgeRoot, preview: false)
        knowledgeReopen.considerStartup(hasMeetings: true)
        try expect(knowledgeReopen.presentation == nil, "This release is announced once after completion")
        let root = try fixture("upgrade", ["introSeen": true, "knownVersion": "0.17.6.4", "lastLaunchedVersion": "0.17.6.4"])
        for (name, history) in [("empty-prior-guide", ["knownVersion": "0.17.6.4"]),
                                ("empty-prior-launch", ["lastLaunchedVersion": "0.17.6.4"])] {
            let existingRoot = try fixture(name, history)
            let existing = GuidanceController(version: "0.17.6.5")
            existing.configure(root: existingRoot, preview: false)
            existing.considerStartup(hasMeetings: false)
            try expect(existing.presentation == .whatsNew, "A previous guide or exact launch must take precedence over intro in an empty library")
        }
        let delayed = GuidanceController(version: "0.17.6.5")
        delayed.configure(root: root, preview: false)
        delayed.considerStartup(hasMeetings: true, canPresent: false)
        try expect(delayed.presentation == nil, "Busy or dirty editors must defer release notes")
        try expect(try preferences(root)["knownVersion"] as? String == "0.17.6.4", "Deferring must not accept an unseen update")
        let controller = GuidanceController(version: "0.17.6.5")
        controller.configure(root: root, preview: false)
        try expect(controller.previousVersion == "0.17.6.4" && controller.previousVersionIsExact,
                   "Pending release must keep its exact previous launch across restart")
        controller.seedUsage(["recording"])
        controller.considerStartup(hasMeetings: true)
        try expect(controller.presentation == .whatsNew, "A patch upgrade must present after the work/draft gate clears")
        try expect(controller.featureGroups.first?.group == .new, "New workflows must be discoverable before existing updates")
        try expect(controller.featureGroups.contains { $0.group == .used && $0.updates.contains { $0.id == "recording" } },
                   "Observed recording usage must personalize the used group")
        try expect(controller.featureGroups.contains { $0.group == .disabled && $0.updates.contains { $0.id == "calendar" } },
                   "Disabled optional workflows must remain distinct from used workflows")
        try expect(controller.changeCounts.added == 2 && controller.changeCounts.changed == 1 && controller.changeCounts.fixed == 6,
                   "Release counts must come from the exact current catalogue")
        controller.selectFeature("recording")
        try expect(!controller.isUnread("recording") && controller.isUnread("calendar"), "Only the viewed feature must become read")
        controller.finishPresentation()
        try expect(controller.isUnread("calendar"), "Closing release notes must not mark hidden features as read")
        let reopened = GuidanceController(version: "0.17.6.5")
        reopened.configure(root: root, preview: false)
        reopened.considerStartup(hasMeetings: true)
        try expect(reopened.presentation == nil, "An accepted version must not interrupt every launch")
        reopened.presentWhatsNew()
        try expect(!reopened.isUnread("recording") && reopened.isUnread("calendar"), "Per-feature read state must survive reopening")
        reopened.selectFeature("calendar")
        reopened.openFeatureSettings("calendar")
        try expect(reopened.presentation == nil && reopened.takeAction() == .settings("features") && reopened.takeAction() == nil,
                   "Disabled feature settings must queue once after the guide closes")
        reopened.presentWhatsNew(); reopened.selectFeature("sources"); reopened.openFeatureSettings("sources")
        try expect(reopened.takeAction() == .settings("ai"), "Each enabled workflow must route to its settings section")

        let legacyRoot = try fixture("legacy", ["introSeen": true, "knownVersion": "0.17.6.2", "knownFeatureRelease": "0.16"])
        let legacy = GuidanceController(version: "0.17.6.5")
        legacy.configure(root: legacyRoot, preview: false)
        try expect(legacy.previousVersion == "0.17.6.2" && !legacy.previousVersionIsExact,
                   "Legacy guide version must never be claimed as an exact previous app launch")
        legacy.considerStartup(hasMeetings: true)
        let historical = legacy.featureGroups.flatMap(\.updates).flatMap(\.changes).map(\.id)
        try expect(historical.contains("recording.video-pool") && historical.contains("appearance.icon") && !historical.contains("summary.profile-unicode"),
                   "Skipped versions must include actual later releases and exclude the baseline release")
        try expect(Set(historical).count == historical.count, "Merged feature notes must not repeat a change ID")
        legacy.finishPresentation()
        let downgrade = GuidanceController(version: "0.17.6.4")
        downgrade.configure(root: legacyRoot, preview: false)
        downgrade.considerStartup(hasMeetings: true)
        try expect(downgrade.presentation == nil, "A downgrade must not automatically show an upgrade announcement")
        downgrade.presentWhatsNew(); downgrade.finishPresentation()
        try expect(try preferences(legacyRoot)["knownVersion"] as? String == "0.17.6.5", "Manual viewing on a downgrade must not lower the accepted release")
        let returnToCurrent = GuidanceController(version: "0.17.6.5")
        returnToCurrent.configure(root: legacyRoot, preview: false)
        returnToCurrent.considerStartup(hasMeetings: true)
        try expect(returnToCurrent.presentation == nil, "Returning to an already accepted version must not repeat its announcement")

        let usageRoot = try fixture("usage", ["introSeen": true])
        let usage = GuidanceController(version: "0.17.6.5")
        usage.configure(root: usageRoot, preview: false)
        usage.seedUsage([])
        var features = AppFeatures(); features.calendar = true
        usage.updateFeatures(features)
        try expect(usage.featureGroups.contains { $0.group == .other && $0.updates.contains { $0.id == "calendar" } },
                   "An enabled feature without actual usage must remain Other")
        usage.recordUsage("calendar")
        try expect(usage.featureGroups.contains { $0.group == .used && $0.updates.contains { $0.id == "calendar" } },
                   "Observed navigation may promote an enabled feature to Used")
        usage.recordUsage("actual meeting text must never be stored")
        usage.recordUsage("import", root: parent.appendingPathComponent("foreign-library"))
        usage.recordUsage("cards"); usage.recordUsage("semanticSearch")
        let storedUsage = try preferences(usageRoot)["usedFeatureIDs"] as? [String] ?? []
        try expect(Set(storedUsage) == ["calendar", "cards", "semanticSearch"], "Only known feature IDs for this library may persist, even before they have release notes")
        let original = try Data(contentsOf: usageRoot.appendingPathComponent("guidance.json"))
        let preview = GuidanceController(version: "0.17.6.5")
        preview.configure(root: usageRoot, preview: true)
        preview.seedUsage(["import"]); preview.presentWhatsNew(); preview.selectFeature("recording"); preview.complete()
        try expect(try Data(contentsOf: usageRoot.appendingPathComponent("guidance.json")) == original, "Preview must not change release or usage preferences")
        print("PASS: release version migration, deferred startup, exact/legacy baselines, skipped releases, grouping, per-feature unread and settings routes")
    }
}
#endif
