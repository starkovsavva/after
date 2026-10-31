import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
import AfterLocalization
#if DEBUG
import AppKit
import Foundation
import AfterCore
import SwiftUI

@MainActor
enum SemanticUXNativeChecks {
    /// A controllable blocking request exercises the same coordinator path as
    /// FFI without a download, provider, credentials, or a model installation.
    private final class BlockingRequest: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func complete() { release.signal() }
        func request(_ root: URL, _ command: String, _ config: SemanticSearchConfiguration, _ key: String) throws -> Data {
            lock.lock(); count += 1; let current = count; lock.unlock()
            if current == 1 { _ = release.wait(timeout: .now() + 10) }
            if command == "semantic-check" { return try JSONEncoder().encode(Envelope(config: config)) }
            return Data("{\"ready\":true}".utf8)
        }
    }
    private struct Envelope: Codable { var config: SemanticSearchConfiguration }
    static func run(_ app: AppStore, root: URL) async throws {
        let bridge = try RustBridge.shared.get()
        let original = try JSONDecoder().decode(Envelope.self, from: bridge.request(root: root, command: "semantic-config")).config
        let oldFeatures = app.settings.features
        defer {
            _ = try? bridge.request(root: root, command: "semantic-config", arguments: ["config":original.arguments])
            app.settings.features = oldFeatures; _ = app.saveSettings()
            app.showingSettings = false; app.showingSearch = false
        }
        app.settings.features.semanticSearch = true
        guard app.saveSettings() else { throw AppError.message("Cannot enable search fixture") }
        let baseline = SemanticSearchConfiguration()
        _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config":baseline.arguments])
        guard app.notes.save(CapturedNote(id: "semantic-status-note", text: "Distinctive marigold search fixture", title: "Marigold")) != nil else {
            throw AppError.message("Cannot create semantic search fixture")
        }
        let search = KnowledgeSearchController()
        search.update(store: app, query: "marigold", scope: "notes", immediate: true)
        try await wait { !search.searching }
        try expect(search.semanticStatus == .disabled && !search.sources.isEmpty, "Disabled model must be explicit even when lexical results exist")
        search.update(store: app, query: "zxqvabsence", scope: "transcript", immediate: true)
        try await wait { !search.searching }
        try expect(search.semanticStatus == .disabled && search.sources.isEmpty, "Disabled status must survive empty results")
        var enabled = baseline; enabled.enabled = true
        _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config":enabled.arguments])
        search.update(store: app, query: "marigold", scope: "notes", immediate: true)
        try await wait { !search.searching }
        try expect(search.semanticStatus == .needsRefresh && !search.sources.isEmpty, "An enabled model without an index must report preparation, not success")
        try Data("invalid JSON".utf8).write(to: root.appendingPathComponent("semantic-settings.json"))
        search.update(store: app, query: "marigold", scope: "notes", immediate: true)
        try await wait { !search.searching }
        try expect(search.semanticStatus == .unavailable && !search.sources.isEmpty && search.error == nil,
                   "Unavailable semantic configuration must preserve lexical results with a distinct status")
        _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config":baseline.arguments])

        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let prior = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        defer { NSApp.accessibilitySetValue(prior, forAttribute: mode) }
        app.searchQuery = "marigold"; app.searchScope = "notes"
        let host = NSHostingView(rootView: SearchView().environmentObject(app))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 760, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await wait { host.layoutSubtreeIfNeeded(); return NativeTabNavigation.contains("search.mode.true", in: host) }
        try NativeTabNavigation.press("search.mode.true", in: host)
        try await wait { host.layoutSubtreeIfNeeded(); return NativeTabNavigation.contains("search.semantic-status.disabled", in: host) }
        app.searchScope = "transcript"; app.searchQuery = "zxqvabsence"
        try await wait { host.layoutSubtreeIfNeeded(); return NativeTabNavigation.contains("search.semantic-status.disabled", in: host) }
        try NativeTabNavigation.press("search.semantic-settings", in: host)
        try expect(app.showingSettings && app.settingsSection == "semantic", "Search status must offer the semantic settings route")
        window.contentView = nil

        let blocked = BlockingRequest()
        let preparation = SemanticPreparationController(request: { try blocked.request($0, $1, $2, $3) })
        preparation.start(app: app, draft: baseline, baseline: baseline, key: "")
        try await wait { blocked.calls == 1 }
        var admittedDuringDownload = false
        let localJob = Task {
            let lease = try await app.localRuntimeLease.acquire()
            admittedDuringDownload = true
            await app.localRuntimeLease.release(lease)
        }
        defer { localJob.cancel() }
        try await wait { admittedDuringDownload }
        try expect(preparation.running && blocked.calls == 1, "A local recording/model job must acquire its runtime while the download is blocked")
        preparation.cancelActivation()
        try expect(preparation.running && preparation.activationCancelled, "Cancelling activation must acknowledge the blocking transfer is still running")
        preparation.start(app: app, draft: baseline, baseline: baseline, key: "")
        try expect(blocked.calls == 1, "Retry must wait until the previous FFI call drains")
        blocked.complete()
        try await wait { !preparation.running }
        try expect(blocked.calls == 1, "Cancelled preparation must not check or enable the model")
        try expect(try JSONDecoder().decode(Envelope.self, from: bridge.request(root: root, command: "semantic-config")).config == baseline,
                   "Cancelled preparation changed saved settings")
        // A completed transfer may be reused. Changing saved configuration
        // while it runs must prevent its old consent from replacing new values.
        let second = BlockingRequest()
        let retry = SemanticPreparationController(request: { try second.request($0, $1, $2, $3) })
        retry.start(app: app, draft: baseline, baseline: baseline, key: "")
        try await wait { second.calls == 1 }
        var changed = baseline; changed.queryPrefix += "Changed "
        _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config":changed.arguments])
        let checkingLease = try await app.localRuntimeLease.acquire()
        defer { Task { await app.localRuntimeLease.release(checkingLease) } }
        second.complete()
        try await wait { retry.message == L("Загрузка завершена. Проверяем модель…") }
        try await Task.sleep(for:.milliseconds(100))
        try expect(second.calls == 1 && retry.running, "The model check must still wait for the inference lease")
        await app.localRuntimeLease.release(checkingLease)
        try await wait { !retry.running }
        try expect(second.calls == 2 && !retry.failed, "Retry must complete its model check")
        try expect(try JSONDecoder().decode(Envelope.self, from: bridge.request(root: root, command: "semantic-config")).config == changed,
                   "An older setup request replaced newer settings")
        _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config":baseline.arguments])

        // Edit a real key draft, switch providers and invoke the actual setup
        // button. Cancel edits must remain enabled while a fake FFI download
        // blocks, without silently discarding the key on provider selection.
        var external = baseline; external.provider = "ollama"; external.endpoint = "http://127.0.0.1:11434"
        _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config":external.arguments])
        let formRequest = BlockingRequest()
        let formPreparation = SemanticPreparationController(request: { try formRequest.request($0, $1, $2, $3) })
        let settings = NSHostingView(rootView: SemanticSearchSettings(preparationForDiagnostics: formPreparation,
            advancedExpandedForDiagnostics: true).environmentObject(app).padding(20))
        settings.sizingOptions = []; settings.frame = NSRect(x: 0, y: 0, width: 820, height: 1150)
        window.setContentSize(settings.frame.size); window.contentView = settings
        try await wait { settings.layoutSubtreeIfNeeded(); return descendants(settings, as:NSSecureTextField.self).first != nil }
        guard let field = descendants(settings, as:NSSecureTextField.self).first else { throw AppError.message("Semantic key field missing") }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Semantic key editor missing") }
        let range = NSRange(location:0, length:(editor.string as NSString).length)
        guard editor.shouldChangeText(in:range, replacementString:"fixture-key-preserved") else {throw AppError.message("Semantic key editor refused fixture")}
        editor.replaceCharacters(in:range, with:"fixture-key-preserved"); editor.didChangeText()
        try await wait { SettingsDraftRegistry.hasUnsaved }
        window.makeFirstResponder(nil)
        try await NativePickerChecks.select(title:L("Встроенная модель After"), identifier:"semantic.provider", in:[settings])
        try await wait { settings.layoutSubtreeIfNeeded(); return NativeTabNavigation.contains("semantic.prepare", in:settings) }
        try NativeTabNavigation.press("semantic.prepare", in:settings)
        try await wait { formRequest.calls == 1 }
        try expect(SettingsDraftRegistry.hasUnsaved && !SettingsDraftRegistry.isBusy,
                   "Setup must preserve the key draft without registering a blocking operation")
        try await wait { settings.layoutSubtreeIfNeeded(); return NativeTabNavigation.nodes(in:settings).contains { $0.identifier == "semantic.cancel" && $0.enabled } }
        try NativeTabNavigation.press("semantic.cancel", in:settings)
        try await wait { !SettingsDraftRegistry.hasUnsaved }
        try expect(formPreparation.running, "Discarding edits must not pretend to stop the blocking transfer")
        window.contentView = nil
        try expect(formPreparation.running, "Leaving settings must keep background preparation observable")
        formPreparation.cancelActivation(); formRequest.complete()
        try await wait { !formPreparation.running }
        try expect(try JSONDecoder().decode(Envelope.self, from:bridge.request(root:root,command:"semantic-config")).config == external,
                   "Cancelling preparation must preserve the saved configuration")
        print("PASS: search status survives lexical/empty results; preparation releases settings, drains cancellation, and rejects stale activation")
    }
    private static func descendants<T:NSView>(_ root:NSView, as type:T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, as:type) }
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppError.message(message) }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AppError.message("Semantic UX check timed out")
    }
}
#endif
