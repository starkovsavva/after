#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Real native DTO/coordinator ↔ Rust C ABI contracts, without credentials,
/// external requests, recording, model inference or account access.
@MainActor
enum IntegrationNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable preview required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable root required")
        let app = AppStore(preview: true)
        let bridge = try RustBridge.shared.get()
        let empty = try JSONDecoder().decode(TrackerSyncState.self, from: bridge.request(root: root, command: "tracker-state"))
        try expect(empty.configurations.isEmpty && empty.pending.isEmpty && empty.linkedTasks.isEmpty, "Empty sync state must decode")
        var configuration = TrackerSyncConfiguration()
        configuration.id = "personal-check"; configuration.provider = "google"; configuration.account = "Личный"
        configuration.scopes = ["english"]; configuration.scopeTitles = ["english":"Английский"]
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
        let configured = try JSONDecoder().decode(TrackerSyncState.self, from: bridge.request(root: root, command: "tracker-configure", arguments: ["configuration":value,"expectedRevision":0]))
        try expect(configured.configurations.first?.scopeTitles["english"] == "Английский" && configured.configurations.first?.enabled == false, "Provider configuration must roundtrip titles and remain disabled")
        app.trackerSync.reload()
        try expect(app.trackerSync.error == nil && app.trackerSync.state.configurations.first?.scopeTitles["english"] == "Английский", "Actual native coordinator must decode configured Rust state")
        print("PASS: actual Rust tracker state/configuration decodes in Swift, persists list names and starts disabled")
        struct SemanticEnvelope: Decodable { var config: SemanticSearchConfiguration; var fingerprint: String }
        let semantic = try JSONDecoder().decode(SemanticEnvelope.self, from: bridge.request(root: root, command: "semantic-config"))
        try expect(!semantic.config.enabled && semantic.config.dimensions == 1024 && semantic.fingerprint.count == 64, "Semantic configuration/binding must decode in native UI")
        let index = try JSONSerialization.jsonObject(with: bridge.request(root: root, command: "semantic-status")) as? [String:Any]
        try expect(index != nil && !app.busy && app.jobs.activeCount == 0, "Reading new integration settings must not start work")
        print("PASS: semantic model configuration and credential binding decode without inference or network")
        try await optionalSearchChecks(app)
        let hosted = NSHostingView(rootView: IntegrationSettingsView().environmentObject(app))
        hosted.frame = NSRect(x:0,y:0,width:620,height:540); hosted.layoutSubtreeIfNeeded()
        try expect(hosted.fittingSize.height > 0, "Integration view must lay out with real persisted metadata")
        print("PASS: native integrations view lays out persisted provider configuration")
    }
    private static func optionalSearchChecks(_ app: AppStore) async throws {
        let original = app.settings.features
        let originalError = app.error
        defer { app.settings.features = original; app.error = originalError }
        app.settings.features = AppFeatures()
        let base = app.settings.features
        try expect(Set(base.knowledgeSearchKinds) == Set(["meeting", "transcript", "summary", "note"]), "Base retrieval must retain meetings, notes, summaries and transcripts only")
        for kind in ["title", "overview", "item", "manual", "summary"] {
            try expect(base.allowsKnowledgeKind(kind), "Base summary facts remain searchable with optional tools disabled")
        }
        for scope in ["cards", "tasks", "code", "unknown"] {
            try expect(base.normalizedSearchScope(scope, byMeaning: true) == "all", "Saved scopes cannot reopen disabled tools")
        }
        let controller = KnowledgeSearchController()
        controller.update(store: app, query: "доступ к сервису", scope: "all", immediate: true)
        try expect(!controller.searching && controller.sources.isEmpty && controller.error == nil, "Disabled semantic search must return before configuration, credentials or provider calls")
        let section = app.librarySection, selectedTask = app.notes.selectedTaskID
        app.openTask(id: "must-not-open-disabled-task")
        try expect(app.librarySection == section && app.notes.selectedTaskID == selectedTask && app.activeTaskProjectID == nil,
                   "Disabled task navigation must not switch section or select a task")
        try expect(app.error?.contains("Включите") == true, "Disabled task navigation explains how to enable the feature")
        for kind in ["task", "card", "code", "calendar"] {
            let source = KnowledgeSource(id: "disabled-" + kind, kind: kind, title: "Источник", excerpt: "Контекст", sourceFingerprint: "fixture")
            try expect(!app.permitsKnowledgeSource(source), "Disabled source kinds must be blocked before resolving paths, accounts or native calendar")
            do { try app.revealKnowledgeSource(source); throw AppError.message("Disabled source unexpectedly opened") }
            catch { try expect(error.localizedDescription.contains("выключен"), "Source route must fail on feature permission before missing IDs or provider access") }
        }
        let source = KnowledgeSource(id: "base-summary", kind: "summary", title: "Итоги", excerpt: "Подготовить отчёт.", sourceFingerprint: "fixture")
        try expect(app.permitsKnowledgeSource(source), "An action in the factual summary stays accessible without the task tracker")
        controller.seedPreview([source]); controller.open(source, store: app)
        try expect(controller.openingID == nil && controller.sources.isEmpty, "A stale semantic result cannot navigate after semantic search is disabled")
        app.settings.features.semanticSearch = true
        controller.update(store: app, query: "задача", scope: "tasks", immediate: true)
        try expect(!controller.searching && controller.error == nil, "A disabled task scope must not start a semantic provider request")
        controller.update(store: app, query: "доступ", scope: "all", immediate: false)
        app.settings.features.semanticSearch = false
        try await Task.sleep(for: .milliseconds(400))
        try expect(!controller.searching && controller.error == nil && controller.sources.isEmpty, "Feature revocation during debounce prevents inference and suppresses late results")
        controller.cancel()
        let all = AppFeatures.allEnabled
        try expect(["card", "task", "code", "calendar"].allSatisfy(all.allowsKnowledgeKind), "Explicitly enabled tools restore their source routes")
        try expect(all.normalizedSearchScope("cards", byMeaning: false) == "cards" && all.normalizedSearchScope("code", byMeaning: true) == "code", "Enabled scopes remain available")
        try expect(all.normalizedSearchScope("code", byMeaning: false) == "all" && !all.allowsKnowledgeKind("unknown"), "Unavailable modes and unknown source types fail closed")
        print("PASS: optional search scopes and source routes follow live feature permissions; disabled/debounced semantic work never starts")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}
#endif
