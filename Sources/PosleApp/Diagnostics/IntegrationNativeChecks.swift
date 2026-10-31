#if DEBUG
import AppKit
import Darwin
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
        try mcpConfigurationChecks()
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
        try await semanticSetupChecks(app, root: root)
        try await SemanticUXNativeChecks.run(app, root: root)
        try await semanticLeaseChecks(app, root: root)
        try await optionalSearchChecks(app)
        try await nativeTabChecks(app, root: root)
    }
    /// A real controller/FFI path must not reach its local provider while a
    /// recording preparation or model job holds the shared admission lease.
    private static func semanticLeaseChecks(_ app: AppStore, root: URL) async throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppError.message("Could not reserve fixture port") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw AppError.message("Could not reserve fixture port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw AppError.message("Could not inspect fixture port") }
        let port = UInt16(bigEndian: address.sin_port)
        // Bound but deliberately not listening: no real service or external
        // network receives the synthetic note, and connection fails promptly.
        let bridge = try RustBridge.shared.get()
        struct Envelope: Decodable { var config: SemanticSearchConfiguration }
        let original = try JSONDecoder().decode(Envelope.self, from: bridge.request(root: root, command: "semantic-config")).config
        let oldFeatures = app.settings.features
        defer {
            _ = try? bridge.request(root: root, command: "semantic-config", arguments: ["config":original.arguments])
            app.settings.features = oldFeatures
        }
        app.settings.features.semanticSearch = true
        guard app.saveSettings(), app.notes.save(CapturedNote(id:"semantic-lease-fixture", text:"Синтетический документ для проверки")) != nil else {
            throw AppError.message("Could not set up semantic lease fixture")
        }
        var config = original
        config.enabled = true; config.provider = "ollama"; config.endpoint = "http://127.0.0.1:\(port)"
        config.modelRevision = "fixture-revision"; config.allowCloud = false
        _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config":config.arguments])
        let held = try await app.localRuntimeLease.acquire()
        defer { Task { await app.localRuntimeLease.release(held) } }
        let controller = SemanticIndexController()
        defer { controller.stop() }
        controller.connectForDiagnostics(app)
        for _ in 0..<500 {
            if controller.running || controller.failed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(controller.running && !controller.failed, "Semantic controller did not wait for the held lease")
        try await Task.sleep(for: .milliseconds(150))
        try expect(!controller.failed, "Local embedding request started while the shared lease was held")
        // The user can start a recording after the first idle check while the
        // indexer is still waiting for admission. The post-acquire check must
        // release the lease and leave that recording unblocked.
        app.startingRecording = true
        defer { app.startingRecording = false }
        await app.localRuntimeLease.release(held)
        try await Task.sleep(for: .milliseconds(150))
        try expect(!controller.failed, "Embedding started after recording began while the lease was queued")
        app.startingRecording = false
        for _ in 0..<1500 {
            if controller.failed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(controller.failed, "Local embedding request did not continue after the lease was released: running=\(controller.running), paused=\(controller.paused), message=\(controller.message)")
        print("PASS: semantic batches wait for the shared local runtime lease and recheck recording before provider work")
    }
    /// Opening the real setup page must explain the optional local runtime and
    /// never install a model, enable indexing, or contact a provider by itself.
    private static func semanticSetupChecks(_ app: AppStore, root: URL) async throws {
        let oldFeatures = app.settings.features
        defer { app.settings.features = oldFeatures }
        app.settings.features.semanticSearch = true
        let bridge = try RustBridge.shared.get()
        let before = try bridge.request(root: root, command: "semantic-config")
        let controller = SemanticIndexController()
        controller.connectForDiagnostics(app)
        try expect(controller.hasDiagnosticConnection, "Fixture controller should connect")
        controller.pause()
        try expect(controller.paused && controller.hasDiagnosticConnection, "Pause must keep the index controller connected")
        controller.resume()
        try expect(!controller.paused && controller.hasDiagnosticConnection, "Resume must retain the same library connection")
        controller.stop()
        try expect(!controller.hasDiagnosticConnection, "Disconnect must release the library")
        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let prior = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        defer { NSApp.accessibilitySetValue(prior, forAttribute: mode) }
        let host = NSHostingView(rootView: ScrollView {
            SemanticSearchSettings().environmentObject(app).padding(20)
        }.frame(width: 820, height: 850).background(Ink.paper))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 820, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        do {
            try await settle(host, window) {
                NativeTabNavigation.contains("semantic.prepare", in: host) &&
                    !NativeTabNavigation.contains("semantic.check", in: host)
            }
        } catch {
            let found = NativeTabNavigation.nodes(in: host).compactMap(\.identifier).filter { $0.hasPrefix("semantic.") }
            throw AppError.message("Semantic setup controls unavailable: \(found)")
        }
        try expect(!NativeTabNavigation.contains("semantic.endpoint", in: host) &&
                   !NativeTabNavigation.contains("semantic.key", in: host), "Managed setup must not ask for a server or API key")
        try expect(try bridge.request(root: root, command: "semantic-config") == before,
                   "Opening setup must not enable indexing or change model settings")
        try expect(!app.busy && app.jobs.activeCount == 0, "Opening setup must not start provider work or a model job")
        try snapshot(host, at: root.appendingPathComponent("semantic-setup.png"))
        print("PASS: built-in semantic setup offers explicit preparation without a server/key or implicit jobs; pause and resume keep the connection")
    }
    /// Use the actual tab buttons in native windows; reading either setup page
    /// must not enable MCP, sync a tracker, or touch credentials.
    private static func nativeTabChecks(_ app: AppStore, root: URL) async throws {
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let bridge = try RustBridge.shared.get()
        let before = try bridge.request(root: root, command: "tracker-state")
        for dark in [false, true] {
            let view = NSHostingView(rootView: ScrollView {
                IntegrationSettingsView().environmentObject(app).padding(26)
            }.frame(width: 780, height: 620).background(Ink.paper)
                .environment(\.colorScheme, dark ? .dark : .light)
                .preferredColorScheme(dark ? .dark : .light))
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 780, height: 620)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            try await settle(view, window) {
                NativeTabNavigation.isSelected("integrations.section.trackers", in: view)
                    && NativeTabNavigation.contains("tracker.add", in: view)
            }
            try NativeTabNavigation.press("integrations.section.agents", in: view)
            try await settle(view, window) {
                NativeTabNavigation.isSelected("integrations.section.agents", in: view)
                    && !NativeTabNavigation.isSelected("integrations.section.trackers", in: view)
                    && NativeTabNavigation.contains("integrations.mcp.enabled", in: view)
                    && !NativeTabNavigation.contains("tracker.add", in: view)
            }
            try snapshot(view, at: root.appendingPathComponent(dark ? "integration-tabs-dark.png" : "integration-tabs-light.png"))
            try NativeTabNavigation.press("integrations.section.trackers", in: view)
            try await settle(view, window) {
                NativeTabNavigation.isSelected("integrations.section.trackers", in: view)
                    && !NativeTabNavigation.isSelected("integrations.section.agents", in: view)
                    && NativeTabNavigation.contains("tracker.add", in: view)
                    && !NativeTabNavigation.contains("integrations.mcp.enabled", in: view)
            }
            let accessHost = NSHostingView(rootView: TaskAgentAccessSheet(notes: app.notes, taskID: "missing-routing-fixture").environmentObject(app))
            accessHost.sizingOptions = []; accessHost.frame = view.frame; window.contentView = accessHost
            try await settle(accessHost, window) { NativeTabNavigation.contains("tasks.agent-settings", in: accessHost) }
            try NativeTabNavigation.press("tasks.agent-settings", in: accessHost)
            try expect(app.settingsSection == "integrations" && app.integrationSettingsSection == "agents", "Task access settings must route directly to Agents")
            window.contentView = view
            try await settle(view, window) {
                NativeTabNavigation.isSelected("integrations.section.agents", in: view) && NativeTabNavigation.contains("integrations.mcp.enabled", in: view)
            }
            app.openSettings("integrations")
            try expect(app.integrationSettingsSection == "agents", "Ordinary integration routing must preserve the selected subtab")
            try NativeTabNavigation.press("integrations.section.trackers", in: view)
            try await settle(view, window) { NativeTabNavigation.isSelected("integrations.section.trackers", in: view) }
        }
        try expect(try bridge.request(root: root, command: "tracker-state") == before,
                   "Switching integration tabs must preserve persisted tracker configuration")
        try expect(!app.busy && app.jobs.activeCount == 0 && !app.trackerSync.busy,
                   "Integration navigation must stay idle without provider requests or jobs")
        print("PASS: actual native Trackers/Agents tabs update selected AX state and their own content in light/dark windows, preserve configuration and stay offline")
    }
    private static func settle(_ view: NSView, _ window: NSWindow, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Native integration tabs did not reach the selected page or expected controls")
    }
    private static func snapshot(_ view: NSView, at url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Integration tab snapshot unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Integration tab PNG unavailable") }
        try data.write(to: url)
    }
    private static func mcpConfigurationChecks() throws {
        // Real macOS paths can contain spaces, Unicode, quotes and backslashes.
        // They must stay separate argv values instead of becoming a shell command.
        let configuration = AgentMCPConfiguration(
            executable: "/Applications/После \"личное\".app/Contents/MacOS/posle-engine",
            root: "/private/tmp/posle-native-check-MCP/Папка \"Английский\"\\Архив"
        )
        for client in [AgentMCPConfiguration.Client.claude, .other] {
            let object = try JSONSerialization.jsonObject(with: Data(configuration.text(for: client).utf8)) as! [String: Any]
            let server: [String: Any]
            if client == .claude {
                let servers = object["mcpServers"] as? [String: [String: Any]]
                try expect(servers?.count == 1 && servers?["posle"] != nil, "Claude configuration must wrap one named server")
                server = servers!["posle"]!
            } else { server = object }
            try expect(server["type"] as? String == "stdio" && server["command"] as? String == configuration.executable,
                       "MCP JSON configuration must preserve the executable path and stdio transport")
            try expect(server["args"] as? [String] == ["mcp", "--root", configuration.root],
                       "MCP JSON must roundtrip paths as separate arguments without shell escaping")
            try expect(server["env"] == nil && server["url"] == nil, "Local MCP must not require credentials or a remote service")
        }
        let codex = configuration.text(for: .codex)
        try expect(codex.hasPrefix("[mcp_servers.posle]\n") && !codex.contains("\\/"), "Codex needs TOML basic strings rather than JSON slash escapes")
        try expect(codex.contains("\\\"Английский\\\"\\\\Архив") && configuration.arguments.count == 3,
                   "Codex configuration must escape quote/backslash characters while preserving argument boundaries")
        print("PASS: Codex TOML and Claude/generic stdio JSON preserve Unicode paths and isolated argv without credentials")
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
