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
import PosleCore

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
        print("PASS: 24 native ChatGPT settings renders cover sign-in, account identity, permission loss, catalog loading/empty, reasoning, and long content in light/dark")
        print("ChatGPT settings screenshots: \(screenshots.path)")
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
