import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
import SwiftUI

extension View {
    /// Inert in shipping builds. Native diagnostics measure this exact view's
    /// enabled environment and geometry without opening the account browser.
    @ViewBuilder func chatGPTUIAnchor(_ identifier: String) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-chatgpt-ui") {
            self.background(ChatGPTUIProbe(identifier: identifier))
        } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
import AppKit
import Foundation
import AfterCore

private struct ChatGPTUIBounds: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}
private struct ChatGPTUIEnabled: PreferenceKey {
    static var defaultValue: [String: Bool] = [:]
    static func reduce(value: inout [String: Bool], nextValue: () -> [String: Bool]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}
private struct ChatGPTUIProbe: View {
    let identifier: String
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ChatGPTUIBounds.self, value: [identifier: geometry.frame(in: .global)])
                .preference(key: ChatGPTUIEnabled.self, value: [identifier: isEnabled])
        }
        .onPreferenceChange(ChatGPTUIBounds.self) { ChatGPTUINativeChecks.record($0) }
        .onPreferenceChange(ChatGPTUIEnabled.self) { ChatGPTUINativeChecks.recordEnabled($0) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Render fixtures use the real cloud settings and only inert account objects.
/// No production credential, browser, capture API, or remote request is used.
@MainActor
enum ChatGPTUINativeChecks {
    private static var frames: [String: CGRect] = [:]
    private static var enabled: [String: Bool] = [:]
    fileprivate static func record(_ values: [String: CGRect]) { frames.merge(values, uniquingKeysWith: { _, last in last }) }
    fileprivate static func recordEnabled(_ values: [String: Bool]) { enabled.merge(values, uniquingKeysWith: { _, last in last }) }

    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("ChatGPT UI checks require --preview and a disposable POSLE_DATA_DIR")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("ChatGPT UI checks require /private/tmp/posle-native-check-*")
        }
        let fixtureDiagnostic = try await verifyDiagnostics(root: root)
        let screenshots = root.appendingPathComponent("chatgpt-screenshots")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        let profile = ChatGPTProfile(id: "fixture-personal", displayName: "Мария Петрова", email: "maria@example.org", planEnabled: true)
        let compact = ChatGPTModel(id: "fixture-compact", name: "Быстрая модель", supportedReasoning: ["none", "low", "medium"])
        let duplicate = ChatGPTProfile(id: "fixture-duplicate", displayName: profile.displayName, email: profile.email, planEnabled: true)
        try expect(ChatGPTConnectionLabels.title(for: profile, among: [profile, duplicate]) != ChatGPTConnectionLabels.title(for: duplicate, among: [profile, duplicate]), "Same-email registrations must have distinct visible titles")
        try expect(ChatGPTConnectionLabels.connection(for: profile, among: [profile]) == nil, "Unique account identities must not gain extra labels")
        let other = ChatGPTProfile(id: "fixture-other", displayName: "Алексей Иванов", email: "alexey@example.org", planEnabled: true)
        let unknown = ChatGPTModel(id: "fixture-catalog-model", name: "Модель из каталога", supportedReasoning: nil)
        for appearance in [ColorScheme.light, .dark] {
            let scenarios: [(String, ChatGPTAccount, String, String, [String], [String])] = [
                ("signed-out", .fixture(), "", "", ["account.sign-in"], ["model.picker", "connection.check", "account.plan"]),
                ("connected", .fixture(profile: profile, savedProfiles: [profile], models: [compact]), profile.id, compact.id,
                 ["account.plan", "model.picker", "connection.check", "reasoning.picker"], ["account.sign-in"]),
                ("empty-catalog", .fixture(profile: profile, savedProfiles: [profile]), profile.id, "",
                 ["account.plan", "models.empty", "models.refresh", "connection.check"], ["account.sign-in"]),
                ("loading-catalog", .fixture(profile: profile, savedProfiles: [profile], loading: true), profile.id, "",
                 ["account.plan", "model.picker", "connection.check"], ["models.refresh", "models.empty"]),
                ("connecting", .fixture(connecting: true), "", "", ["account.connecting"], ["account.sign-in", "model.picker"]),
                ("model-default", .fixture(profile: profile, savedProfiles: [profile], models: [unknown]), profile.id, unknown.id,
                 ["account.plan", "model.picker", "connection.check"], ["reasoning.picker"]),
                ("permission-lost", .fixture(profile: ChatGPTProfile(id: profile.id, displayName: profile.displayName, email: profile.email, planEnabled: false)), profile.id, compact.id,
                 ["account.sign-in"], ["account.plan", "model.picker", "connection.check"]),
                ("catalog-error", .fixture(profile: profile, savedProfiles: [profile], message: "Не удалось загрузить модели. Проверьте сеть и обновите список.", isError: true), profile.id, "",
                 ["account.message", "account.reconnect", "models.refresh"], ["account.sign-in", "models.empty"]),
                ("saved-model-loading", .fixture(profile: profile, savedProfiles: [profile], loading: true), profile.id, compact.id,
                 ["account.plan", "model.picker"], ["models.empty", "account.sign-in"]),
                ("different-restored-account", .fixture(profile: profile, savedProfiles: [profile, other], models: [compact]), other.id, "",
                 ["account.sign-in", "account.picker"], ["account.plan", "model.picker", "connection.check"]),
                ("same-email-connections", .fixture(profile: duplicate, savedProfiles: [profile, duplicate], models: [compact]), duplicate.id, compact.id,
                 ["account.connection", "account.picker", "account.plan", "model.picker"], ["account.sign-in"])
            ]
            for (name, account, accountID, modelID, present, absent) in scenarios {
                let store = AppStore(preview: true)
                store.settings.mode = "cloud"; store.settings.cloudProvider = "chatgpt"
                store.settings.chatGPTAccountID = accountID; store.settings.cloudModel = modelID
                store.settings.cloudReasoning = "none"
                try await render(name: name, account: account, store: store, appearance: appearance, screenshots: screenshots) {
                    for identifier in ["account.card"] + present { try require(identifier) }
                    for identifier in absent {
                        try expect(frames["chatgpt." + identifier] == nil, "Unexpected control in \(name): \(identifier)")
                    }
                    if ["connected", "model-default"].contains(name) {
                        try expect(enabled["chatgpt.connection.check"] == true, "Ready account must allow a connection check")
                    } else if ["empty-catalog", "loading-catalog"].contains(name) {
                        try expect(enabled["chatgpt.connection.check"] == false, "Missing catalog must block requests")
                    }
                    if name == "different-restored-account" {
                        try expect(store.settings.chatGPTAccountID == other.id, "A restored active account must not silently replace another saved selection")
                    }
                    if name == "saved-model-loading" {
                        try expect(store.settings.cloudModel == compact.id, "Opening settings must retain the saved model until catalog loading finishes")
                    }
                    if name == "model-default" {
                        try expect(store.settings.cloudReasoning == "auto", "Unknown capabilities must use the model's default reasoning")
                    }
                }
            }
            let failedStore = AppStore(preview: true)
            failedStore.settings.mode = "cloud"; failedStore.settings.cloudProvider = "chatgpt"
            failedStore.settings.chatGPTAccountID = profile.id; failedStore.settings.cloudModel = compact.id
            failedStore.settings.cloudReasoning = "none"
            failedStore.recordCloudConnectionFailure(WorkerFailure(message: "ChatGPT завершил запрос без текста ответа.", chatGPTDiagnostics: fixtureDiagnostic), configuration: failedStore.settings)
            try await render(name: "failed-probe", account: .fixture(profile: profile, savedProfiles: [profile], models: [compact]),
                             store: failedStore, appearance: appearance, screenshots: screenshots) {
                try require("connection.copy-diagnostics")
                try expect(enabled["chatgpt.connection.copy-diagnostics"] == true, "Failed probe must offer diagnostic copying")
            }
            let long = ChatGPTProfile(id: "fixture-long", displayName: "Александра Константинопольская — личный аккаунт", email: "alexandra.konstantinopolskaya.personal.account@example.org", planEnabled: true)
            let longModel = ChatGPTModel(id: "fixture-long-model", name: "Модель для подробных конспектов, решений, карточек и важных деталей встречи", supportedReasoning: ["none", "medium"])
            let longStore = AppStore(preview: true)
            longStore.settings.cloudProvider = "chatgpt"; longStore.settings.chatGPTAccountID = long.id
            longStore.settings.cloudModel = longModel.id
            try await render(name: "long-account", account: .fixture(profile: long, savedProfiles: [profile, long], models: [longModel]),
                             store: longStore, appearance: appearance, screenshots: screenshots) {
                try require("account.picker"); try require("account.plan"); try require("model.picker")
            }
        }
        print("PASS: 26 native ChatGPT settings renders cover sign-in, account identity, permission loss, catalog loading/empty, reasoning, and long content in light/dark")
        print("ChatGPT settings screenshots: \(screenshots.path)")
    }

    /// The actual process/event/error boundary runs against one disposable script.
    /// It contains only synthetic canaries and never invokes an API or Keychain.
    private static func verifyDiagnostics(root: URL) async throws -> ChatGPTDiagnostics {
        let canary = "PRIVATE_CANARY_NEVER_COPY"
        var fields: [String: Any] = [
            "http_status": 200, "content_type": "missing", "wire": "sse", "response_bytes": 480,
            "events": 4, "output_text_delta": 0, "output_text_done": 1, "content_part_done": 1,
            "output_item_done": 1, "completed": 1, "other_events": 0,
            "terminal_status": "completed", "terminal_output": "array", "terminal_output_items": 0,
            "terminal_text_parts": 0, "terminal_refusal_parts": 0, "terminal_other_parts": 0,
            "accumulated_text_bytes": 11,
            "raw_body": canary, "request_id": canary, "account_id": canary, "model": canary,
            "arbitrary_event_type": canary, "headers": ["Authorization": canary]
        ]
        func event(_ diagnostic: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["event": "error", "message": canary, "chatGPTDiagnostics": diagnostic], options: [.sortedKeys])
        }
        let validEvent = try event(fields)
        let script = root.appendingPathComponent("chatgpt-diagnostic-error.sh")
        let encoded = String(decoding: validEvent, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
        try Data("printf '%s\\n' '\(encoded)'\nexit 1\n".utf8).write(to: script)
        let failure: WorkerFailure
        do {
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: [script.path], event: { _ in })
            throw AppError.message("Synthetic error process unexpectedly succeeded")
        } catch let error as WorkerFailure { failure = error }
        try expect(failure.localizedDescription == canary, "Typed worker error changed the human message")
        guard let diagnostic = failure.chatGPTDiagnostics else { throw AppError.message("Typed worker diagnostics lost across the actual process boundary") }
        var settings = AppSettings()
        settings.mode = "cloud"; settings.cloudProvider = "chatgpt"; settings.chatGPTAccountID = canary
        settings.cloudModel = canary; settings.cloudEndpoint = "https://" + canary + ".example.org"
        settings.cloudOutput = "schema"; settings.cloudReasoning = "none"
        let report = ChatGPTDiagnosticReport(diagnostics: diagnostic, settings: settings, appVersion: "0.12.2", appBuild: "17")
        let expectedFields = ["app_version=0.12.2", "app_build=17", "content_type=missing", "wire=sse", "output_text_done=1", "terminal_output_items=0"]
        for field in expectedFields { try expect(report.text.contains(field), "Missing safe diagnostic field: " + field) }
        try expect(!report.text.contains(canary), "Report copied an unallowlisted body/header/identity/model value")
        settings.cloudOutput = canary; settings.cloudReasoning = canary
        let hostileReport = ChatGPTDiagnosticReport(diagnostics: diagnostic, settings: settings, appVersion: canary, appBuild: canary)
        try expect(!hostileReport.text.contains(canary) && hostileReport.text.contains("reasoning=other") && hostileReport.text.contains("app_version=unknown"), "Report did not constrain settings/version metadata")
        let pasteboard = NSPasteboard(name: .init("app.posle.chatgpt-diagnostic-check.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try expect(report.copy(to: pasteboard) && pasteboard.string(forType: .string) == report.text,
                   "Diagnostic copy failed on an isolated pasteboard")
        let store = AppStore(preview: true)
        store.settings = settings
        store.recordCloudConnectionFailure(failure, configuration: settings)
        try expect(store.cloudConnectionError && store.cloudConnectionDiagnostic != nil && store.copyCloudConnectionDiagnostic(to: pasteboard),
                   "Failed subscription check did not retain an explicitly copyable safe report")
        let mutations: [(inout AppSettings) -> Void] = [
            { $0.cloudModel += "changed" }, { $0.chatGPTAccountID += "changed" },
            { $0.cloudReasoning = "low" }, { $0.cloudOutput = "json" }, { $0.cloudAPI = "chat" },
            { $0.mode = "local" }, { $0.switchCloudProvider("openai") }
        ]
        for mutate in mutations {
            store.settings = settings
            store.recordCloudConnectionFailure(failure, configuration: settings)
            mutate(&store.settings)
            try expect(store.cloudConnectionDiagnostic == nil && store.cloudConnectionStatus == nil && !store.copyCloudConnectionDiagnostic(to: pasteboard),
                       "Changed connection retained a stale diagnostic report")
        }
        store.settings = settings
        store.recordCloudConnectionFailure(failure, configuration: settings)
        store.clearCloudConnectionResult()
        try expect(store.cloudConnectionDiagnostic == nil && !store.cloudConnectionError, "Starting a fresh check retained prior diagnostic state")
        store.recordCloudConnectionFailure(AppError.message(canary), configuration: settings)
        try expect(store.cloudConnectionDiagnostic == nil && !store.copyCloudConnectionDiagnostic(to: pasteboard), "Untyped error was exported as a diagnostic report")
        for key in fields.keys.filter({ !["raw_body", "request_id", "account_id", "model", "arbitrary_event_type", "headers"].contains($0) }) {
            var incomplete = fields; incomplete.removeValue(forKey: key)
            let decoded = try JSONDecoder().decode(WorkerEvent.self, from: event(incomplete))
            try expect(decoded.chatGPTDiagnostics == nil && decoded.message == canary, "Missing diagnostic field must fail closed without losing human error")
        }
        for responseBytes in [8 * 1024 * 1024 + 1, 8 * 1024 * 1024 + 16 * 1024] {
            var overrun = fields; overrun["response_bytes"] = responseBytes
            let decoded = try JSONDecoder().decode(WorkerEvent.self, from: event(overrun))
            try expect(decoded.chatGPTDiagnostics?.responseBytes == UInt64(responseBytes), "Rust bounded read overrun lost its diagnostic report")
        }
        let invalidValues: [(String, Any)] = [("content_type", canary), ("wire", canary), ("terminal_status", canary),
                                              ("terminal_output", canary), ("events", -1), ("events", 8 * 1024 * 1024 + 1),
                                              ("response_bytes", 8 * 1024 * 1024 + 16 * 1024 + 1),
                                              ("http_status", 99), ("http_status", 600)]
        for (key, value) in invalidValues {
            var invalid = fields; invalid[key] = value
            let decoded = try JSONDecoder().decode(WorkerEvent.self, from: event(invalid))
            try expect(decoded.chatGPTDiagnostics == nil, "Unsafe diagnostic field was accepted: " + key)
        }
        fields.removeAll()
        print("PASS: real worker failure preserves typed diagnostics; private clipboard excludes body/header/model/account canaries; settings changes clear stale reports; malformed metadata fails closed")
        return diagnostic
    }

    private static func render(name: String, account: ChatGPTAccount, store: AppStore, appearance: ColorScheme,
                               screenshots: URL, checks: () throws -> Void) async throws {
        frames = [:]; enabled = [:]
        // 632 pt is the usable content width inside the existing 900 pt settings
        // window after its 215 pt sidebar and padding. Test the shipped form.
        let view = VStack(alignment: .leading, spacing: 20) {
            Text("Конспект и карточки").font(AppTypography.heading)
            CloudSettingsView(chatGPTAccount: account).environmentObject(store)
            Spacer(minLength: 0)
        }.appControlDefaults().padding(26).frame(width: 684, height: 600, alignment: .topLeading)
            .background(Ink.paper).tint(Ink.accent).environment(\.colorScheme, appearance)
            .environment(\.locale, Locale(identifier: "ru_RU"))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        for (identifier, frame) in frames {
            try expect(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width > 0 && frame.height > 0,
                       "Invalid geometry for " + identifier)
            try expect(frame.minX >= -1 && frame.maxX <= 685, "Horizontal clipping in \(name): \(identifier)")
            try expect(frame.minY >= -1 && frame.maxY <= 601, "Essential content outside settings viewport in \(name): \(identifier)")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("ChatGPT UI bitmap unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("ChatGPT UI PNG unavailable") }
        try data.write(to: screenshots.appendingPathComponent(name + (appearance == .dark ? "-dark.png" : "-light.png")))
        try checks()
    }
    private static func require(_ identifier: String) throws {
        try expect(frames["chatgpt." + identifier] != nil, "Missing ChatGPT control: " + identifier)
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw AppError.message(message) }
    }
}
#endif
