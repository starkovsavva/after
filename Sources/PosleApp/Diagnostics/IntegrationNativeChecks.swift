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
        let hosted = NSHostingView(rootView: IntegrationSettingsView().environmentObject(app))
        hosted.frame = NSRect(x:0,y:0,width:620,height:540); hosted.layoutSubtreeIfNeeded()
        try expect(hosted.fittingSize.height > 0, "Integration view must lay out with real persisted metadata")
        print("PASS: native integrations view lays out persisted provider configuration")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}
#endif
