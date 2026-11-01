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

/// Disposable end-to-end check of the native controller and the Rust boundary.
@MainActor
enum AssistantReadNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = env["POSLE_DATA_DIR"], let library = env["POSLE_RUST_LIBRARY"],
              FileManager.default.fileExists(atPath: library) else {
            throw AppError.message("Disposable preview and Rust library required")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Disposable root required")
        }
        let store = AppStore(preview: true)
        store.settings.features.assistant = true
        store.settings.features.tasks = true
        guard store.saveSettings() else { throw AppError.message("Could not save fixture settings") }
        let bridge = try RustBridge.shared.get()
        func object(_ data: Data) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppError.message("Expected JSON object")
            }
            return value
        }
        let created = try object(bridge.request(root: root, command: "task-create",
            arguments: ["title":"Пилот локальный", "text":"Согласовать детали",
                        "operationID":UUID().uuidString.lowercased()]))
        guard let id = created["id"] as? String, let revision = created["revision"],
              let fingerprint = created["sourceFingerprint"] as? String else {
            throw AppError.message("Missing fixture task")
        }
        let voice = store.voice
        let host = NSHostingView(rootView: AssistantReadNativeRoot(store: store))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 430, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let axMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(axMode)
        NSApp.accessibilitySetValue(true, forAttribute: axMode)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; NSApp.accessibilitySetValue(previousAX, forAttribute: axMode) }
        let jobsBefore = store.jobs.jobs.count
        voice.present()
        voice.text = "Найди задачу пилот"
        voice.perform()
        try await wait { !voice.isWorking }
        guard let result = voice.assistantRead, result.targets.count == 1,
              result.targets[0].taskID == id else {
            throw AppError.message("Local search failed: \(voice.message ?? "no result")")
        }
        let targetID = "assistant-read-target-\(id)"
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(targetID, in: host) != nil }
        guard store.jobs.jobs.count == jobsBefore else { throw AppError.message("Read created a model job") }
        _ = try bridge.request(root: root, command: "task-details-update",
            arguments: ["taskID":id, "expectedRevision":revision, "expectedSourceFingerprint":fingerprint,
                        "operationID":UUID().uuidString.lowercased(), "patch":["title":"Пилот обновлён"]])
        guard let button = find(targetID, in: host), press(button) else {
            throw AppError.message("Actual task result button was unavailable")
        }
        try await wait { !voice.isWorking }
        guard voice.phase == .editing, voice.message != nil, store.librarySection != "tasks" else {
            throw AppError.message("Stale task was opened instead of rejected")
        }
        voice.reset(); voice.present(); voice.text = "Что в последней таске?"
        voice.perform()
        try await wait { !voice.isWorking }
        guard let inspected = voice.assistantRead, inspected.plan.intent == .inspect,
              inspected.targets.first?.taskID == id,
              inspected.targets.first?.recentHistory?.isEmpty == false,
              store.jobs.jobs.count == jobsBefore else {
            throw AppError.message("Latest task and history did not appear locally: \(voice.message ?? "")")
        }

        // Exercise a real task/claim/report lifecycle and use the actual
        // assistant button to open the artifact from the latest report.
        _ = try bridge.request(root: root, command: "task-agent-settings",
            arguments: ["enabled":true, "expectedRevision":0, "operationID":UUID().uuidString.lowercased()])
        let current = try object(bridge.request(root: root, command: "task-get", arguments: ["taskID":id]))
        let shared = try object(bridge.request(root: root, command: "task-details-update",
            arguments: ["taskID":id, "expectedRevision":current["revision"]!, "expectedSourceFingerprint":current["sourceFingerprint"]!,
                        "operationID":UUID().uuidString.lowercased(), "patch":["agentAccess":["enabled":true]]]))
        let context = try object(bridge.request(root: root, command: "task-context", arguments: ["taskID":id]))
        let claimed = try object(bridge.request(root: root, command: "task-agent-claim",
            arguments: ["taskID":id, "expectedRevision":shared["revision"]!, "expectedContextVersion":context["contextVersion"]!,
                        "operationID":UUID().uuidString.lowercased(), "agentID":"Test Agent"]))
        guard let claim = claimed["claim"] as? [String: Any], let claimID = claim["id"] as? String else {
            throw AppError.message("Missing fixture claim")
        }
        func report(_ revision: Any, _ text: String, _ artifactID: String) throws -> [String: Any] {
            try object(bridge.request(root: root, command: "task-agent-report", arguments: [
                "taskID":id, "expectedRevision":revision, "claimID":claimID, "agentID":"Test Agent",
                "operationID":UUID().uuidString.lowercased(), "text":text,
                "artifacts":[["id":artifactID, "title":"Результат проверки", "kind":"checks", "text":"Результат только из этого отчёта"]]
            ]))
        }
        let firstReport = try report(claimed["revision"]!, "Старый отчёт", "old-artifact")
        voice.reset(); voice.present(); voice.text = "Что в последней таске?"; voice.perform()
        try await wait { !voice.isWorking }
        guard let firstTarget = voice.assistantRead?.targets.first,
              firstTarget.latestReport?.actor == "Test Agent", firstTarget.latestReport?.text == "Старый отчёт",
              firstTarget.latestReport?.artifacts.first?.id == "old-artifact" else {
            throw AppError.message("Agent attribution or report artifact missing")
        }
        let oldButtonID = "assistant-read-artifact-old-artifact"
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(oldButtonID, in: host) != nil }
        _ = try report(firstReport["revision"]!, "Свежий отчёт", "new-artifact")
        guard let oldButton = find(oldButtonID, in: host), press(oldButton) else { throw AppError.message("Old artifact button unavailable") }
        try await wait { !voice.isWorking }
        guard voice.phase == .editing, voice.message != nil, store.librarySection != "tasks", store.taskHistoryRoute == nil else {
            throw AppError.message("Stale artifact was opened")
        }
        voice.reset(); voice.present(); voice.text = "Что в последней таске?"; voice.perform()
        try await wait { !voice.isWorking }
        guard let latest = voice.assistantRead?.targets.first?.latestReport,
              latest.actor == "Test Agent", latest.text == "Свежий отчёт",
              latest.artifacts.first?.id == "new-artifact" else { throw AppError.message("Latest report selection is incorrect") }
        let newButtonID = "assistant-read-artifact-new-artifact"
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(newButtonID, in: host) != nil }
        // The app may still display the cached result when policy is changed
        // by another process. Revalidate on click before navigating.
        let settingsURL = root.appendingPathComponent("settings.json")
        let savedSettings = try Data(contentsOf: settingsURL)
        guard var settings = try JSONSerialization.jsonObject(with: savedSettings) as? [String: Any],
              var features = settings["features"] as? [String: Any] else { throw AppError.message("Missing fixture settings") }
        features["assistant"] = false; settings["features"] = features
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL, options: .atomic)
        guard let revokedButton = find(newButtonID, in: host), press(revokedButton) else { throw AppError.message("Artifact button unavailable for revocation test") }
        try await wait { !voice.isWorking }
        guard voice.message != nil, store.librarySection != "tasks", store.taskHistoryRoute == nil else {
            throw AppError.message("Artifact opened after assistant access was revoked")
        }
        try savedSettings.write(to: settingsURL, options: .atomic)
        voice.reset(); voice.present(); voice.text = "Что в последней таске?"; voice.perform()
        try await wait { !voice.isWorking }
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(newButtonID, in: host) != nil }
        guard let newButton = find(newButtonID, in: host), press(newButton) else { throw AppError.message("New artifact button unavailable") }
        try await wait { !voice.isWorking && !voice.isPresented }
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return window.attachedSheet?.contentView.flatMap { find("tasks.artifact.contents.new-artifact", in: $0) } != nil
        }
        guard store.librarySection == "tasks", store.notes.selectedTaskID == id, store.error == nil else {
            throw AppError.message("Artifact did not open in task history: \(store.error ?? "")")
        }
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
        voice.reset(); voice.present(); voice.text = "Что в последней таске?"; voice.perform()
        try await wait { !voice.isWorking }
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("assistant-read-followup", in: host) != nil }
        guard let followup = find("assistant-read-followup", in: host), press(followup) else {
            throw AppError.message("Follow-up button unavailable")
        }
        let beforeFollowup = try object(bridge.request(root: root, command: "task-get", arguments: ["taskID":id]))
        _ = try bridge.request(root: root, command: "task-details-update", arguments: ["taskID":id,
            "expectedRevision":beforeFollowup["revision"]!, "expectedSourceFingerprint":beforeFollowup["sourceFingerprint"]!,
            "operationID":UUID().uuidString.lowercased(), "patch":["title":"Обновлённая задача"]])
        voice.text = "Открой её"; voice.perform()
        try await wait { !voice.isWorking }
        guard voice.phase == .editing, voice.isPresented, voice.message != nil else {
            throw AppError.message("A changed follow-up target was opened")
        }
        voice.reset(); voice.present(); voice.text = "Что в последней таске?"; voice.perform()
        try await wait { !voice.isWorking }
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("assistant-read-followup", in: host) != nil }
        guard let currentFollowup = find("assistant-read-followup", in: host), press(currentFollowup) else {
            throw AppError.message("Current follow-up unavailable")
        }
        voice.text = "Открой её"; voice.perform()
        try await wait { !voice.isWorking && !voice.isPresented }
        guard store.librarySection == "tasks", store.notes.selectedTaskID == id else {
            throw AppError.message("Follow-up did not open the current task")
        }
        voice.reset(); voice.present(); voice.text = "Открой последнюю задачу"
        voice.perform()
        try await wait { !voice.isWorking && !voice.isPresented }
        guard store.librarySection == "tasks", store.notes.selectedTaskID == id,
              store.jobs.jobs.count == jobsBefore else {
            throw AppError.message("Latest task did not open locally")
        }
        guard let initialNote = store.notes.save(CapturedNote(id:"assistant-note-fixture",
            text:"Квантовый запас оборудования для пилота", title:"Квантовый запас")) else {
            throw AppError.message("Could not create note fixture")
        }
        voice.reset(); voice.present(); voice.text = "Найди заметку про квантовый запас"; voice.perform()
        try await wait { !voice.isWorking }
        guard voice.assistantNotes?.targets.first?.noteID == initialNote.id else {
            throw AppError.message("Assistant did not find the note locally: \(voice.message ?? "")")
        }
        let noteButtonID = "assistant-note-target-" + initialNote.id
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(noteButtonID, in: host) != nil }
        var editedNote = initialNote; editedNote.text += " — новые данные"
        guard let savedNote = store.notes.save(editedNote), let staleNoteButton = find(noteButtonID, in: host), press(staleNoteButton) else {
            throw AppError.message("Could not change or select note fixture")
        }
        try await wait { !voice.isWorking }
        guard voice.phase == .editing, voice.message != nil else {
            throw AppError.message("Changed note was opened instead of rejected")
        }
        voice.reset(); voice.present(); voice.text = "Найди заметку про квантовый запас"; voice.perform()
        try await wait { !voice.isWorking }
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("assistant-note-followup", in: host) != nil }
        guard let noteFollowup = find("assistant-note-followup", in: host), press(noteFollowup) else { throw AppError.message("Note follow-up unavailable") }
        var changedAgain = savedNote; changedAgain.text += " — ещё правка"
        guard store.notes.save(changedAgain) != nil else { throw AppError.message("Could not change note twice") }
        voice.text = "Открой её"; voice.perform()
        try await wait { !voice.isWorking }
        guard voice.phase == .editing, voice.message != nil, voice.isPresented else {
            throw AppError.message("Changed note list was reused")
        }
        voice.reset(); voice.present(); voice.text = "Найди заметку про квантовый запас"; voice.perform()
        try await wait { !voice.isWorking }
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("assistant-note-followup", in: host) != nil }
        guard let currentNoteFollowup = find("assistant-note-followup", in: host), press(currentNoteFollowup) else { throw AppError.message("Current note follow-up unavailable") }
        voice.text = "Открой её"; voice.perform()
        try await wait { !voice.isWorking && !voice.isPresented }
        guard store.notes.selectedNoteID == initialNote.id, store.jobs.jobs.count == jobsBefore else {
            throw AppError.message("Assistant did not open the exact note locally")
        }
        print("PASS: task follow-up, attributed report, exact artifact and note navigation; stale/revoked results rejected without model jobs")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Assistant read check timed out")
    }
    private static func find(_ id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func attr(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func visit(_ object: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if attr(object, "accessibilityIdentifier") as? String == id { return object }
            let children = (attr(object, "accessibilityChildren") as? [NSObject] ?? []) +
                ((object as? NSView)?.subviews.map { $0 as NSObject } ?? [])
            for child in children { if let found = visit(child) { return found } }
            return nil
        }
        return visit(root)
    }
    private static func press(_ object: NSObject) -> Bool {
        if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Press.self)(object, selector)
    }
}

private struct AssistantReadNativeRoot: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if store.librarySection == "tasks" { TasksWorkspaceView(notes: store.notes) }
            if store.voice.isPresented { VoiceCommandPanel(controller: store.voice) }
        }.environmentObject(store)
    }
}
#endif
