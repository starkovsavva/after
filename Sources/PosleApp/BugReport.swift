import AppKit
import Combine
import Foundation
import PosleCore

/// Explicitly written user text is separate from the allowlisted machine data.
/// This boundary never serializes settings, jobs, errors, logs or account objects.
struct BugReportDraft: Codable, Equatable {
    var actual = ""
    var expected = ""
    var isEmpty: Bool { [actual, expected].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var isValid: Bool { !actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && [actual, expected].allSatisfy { $0.count <= 8_000 } }
    var tooLong: Bool { [actual, expected].contains { $0.count > 8_000 } }
}

struct BugReportDiagnostics: Encodable, Equatable {
    /// Static bundle metadata only: no paths, account IDs, logs or TCC changes.
    struct Installation: Encodable, Equatable {
        let location: String
        let sourceRevision: String
        let helperVersions: String
        let captureAuthorization = "system_picker"

        init(bundleURL: URL = Bundle.main.bundleURL) {
            let bundled = bundleURL.pathExtension == "app"
            let parent = bundleURL.deletingLastPathComponent().standardizedFileURL
            let applications = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            location = !bundled ? "unbundled" : applications.contains(parent) ? "applications" : "other"
            let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
            let info = (try? Data(contentsOf: infoURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            let revision = info["PosleSourceRevision"] as? String ?? ""
            sourceRevision = revision.range(of: #"^[a-f0-9]{40}([a-f0-9]{24})?$"#, options: .regularExpression) != nil ? revision : "unknown"
            guard bundled else { helperVersions = "not_bundled"; return }
            let keys = ["CFBundleShortVersionString", "CFBundleVersion"]
            guard keys.allSatisfy({ (info[$0] as? String)?.isEmpty == false }) else { helperVersions = "unknown"; return }
            var matches = true
            for name in ["После Обработка", "После Распознавание"] {
                let childURL = bundleURL.appendingPathComponent("Contents/Helpers/" + name + ".app/Contents/Info.plist")
                guard let data = try? Data(contentsOf: childURL),
                      let child = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    helperVersions = "missing"; return
                }
                matches = matches && keys.allSatisfy { child[$0] as? String == info[$0] as? String }
            }
            helperVersions = matches ? "match" : "mismatch"
        }
    }
    struct Route: Encodable, Equatable {
        let mode: String
        let provider: String
        init(settings: AppSettings, speech: Bool = false) {
            mode = Self.allowed(speech ? settings.speechMode : settings.mode, ["local", "cloud"])
            let raw = mode == "local" ? (speech ? "parakeet" : settings.localProvider) : (speech ? settings.speechCloudProvider : settings.cloudProvider)
            provider = Self.allowed(raw, ["parakeet", "managed", "ollama", "lmstudio", "openai", "chatgpt", "openrouter", "polza", "custom"])
        }
        private static func allowed(_ value: String, _ choices: Set<String>) -> String { choices.contains(value) ? value : "other" }
    }
    struct Failure: Encodable, Equatable {
        let operation: String
        let state: String
        let code: String
        let route: Route
        init(job: BackgroundJob) {
            operation = ["transcribe", "diarize", "finalize", "summarize", "dictate", "example", "expand-notes", "voice-plan"].contains(job.kind) ? job.kind : "other"
            state = ["failed", "interrupted"].contains(job.state) ? job.state : "other"
            // Raw messages can contain file paths or user content. Only fixed
            // classifications survive, including the fallback.
            let message = job.message
            if message.hasPrefix("Настройки модели не совпадают") { code = "operation_profile_mismatch" }
            else if message.hasPrefix("Профиль папки изменился") || message.hasPrefix("Папка или её настройки изменились") { code = "folder_profile_changed" }
            else if message.hasPrefix("Добавьте ключ распознавания") { code = "speech_credentials_missing" }
            else if message.hasPrefix("Целостность компонентов Python не подтверждена") { code = "runtime_integrity_failed" }
            else if message.hasPrefix("ChatGPT завершил запрос без текста ответа") || message.hasPrefix("ChatGPT: HTTP 200") { code = "empty_model_response" }
            else { code = "unclassified" }
            route = Route(settings: job.config.settings, speech: ["transcribe", "dictate"].contains(job.kind))
        }
    }
    let appVersion: String
    let appBuild: String
    let installation: Installation
    let macOS: String
    let architecture: String
    let currentRoute: Route
    let speechRoute: Route
    let lastFailure: Failure?

    init(settings: AppSettings, lastFailure: BackgroundJob? = nil,
         appVersion: String? = AppVersion.current,
         appBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        installation = Installation()
        self.appVersion = Self.numeric(appVersion, pattern: #"^[0-9]{1,4}(\.[0-9]{1,4}){1,3}$"#)
        self.appBuild = Self.numeric(appBuild, pattern: #"^[0-9]{1,12}$"#)
        let system = ProcessInfo.processInfo.operatingSystemVersion
        macOS = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "other"
        #endif
        currentRoute = Route(settings: settings); speechRoute = Route(settings: settings, speech: true)
        self.lastFailure = lastFailure.map(Failure.init)
    }
    private static func numeric(_ value: String?, pattern: String) -> String {
        guard let value, value.utf8.count <= 24, value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex else { return "unknown" }
        return value
    }
}

struct BugReportDocument: Encodable, Equatable {
    let schemaVersion = 1
    let description: BugReportDraft
    let diagnostics: BugReportDiagnostics
    var text: String {
        LF("После · отчёт об ошибке\n\nЧто произошло\n{0}\n\nЧто ожидалось\n{1}\n\nТехническая информация\n{2}\n", arguments: [description.actual, description.expected, String(decoding: (try? Self.encoder.encode(diagnostics)) ?? Data(), as: UTF8.self)])
    }
    var json: Data { (try? Self.encoder.encode(self)) ?? Data() }
    private static var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
    func write(to url: URL) throws {
        let data = url.pathExtension.lowercased() == "json" ? json : Data(text.utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class BugReportSession: ObservableObject {
    let id = UUID()
    let diagnostics: BugReportDiagnostics
    @Published var draft = BugReportDraft() { didSet { status = nil; failure = nil; updateRegistration() } }
    @Published var status: String?
    @Published var failure: String?
    @Published var previewExpanded = false
    private var checkpoint = BugReportDraft()
    private var reveal: (() -> Void)?
    init(diagnostics: BugReportDiagnostics) { self.diagnostics = diagnostics }
    var document: BugReportDocument { BugReportDocument(description: draft, diagnostics: diagnostics) }
    var hasUnsaved: Bool { !draft.isEmpty && draft != checkpoint }
    func didShare(_ saved: BugReportDraft, status: String) { checkpoint = saved; self.status = status; failure = nil; updateRegistration() }
    func setReveal(_ action: @escaping () -> Void) { reveal = action; updateRegistration() }
    func dispose() { UnsavedEditorRegistry.remove(id: id); reveal = nil }
    private func updateRegistration() { UnsavedEditorRegistry.set(id: id, title: L("Отчёт об ошибке"), dirty: hasUnsaved, reveal: reveal) }
}
