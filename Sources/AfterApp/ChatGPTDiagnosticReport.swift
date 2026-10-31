import AfterPlatform
import AppKit
import Foundation
import AfterCore

/// A report is rebuilt from allowlisted values, never from an error description,
/// settings dump, account identity, response body or log. It lives only in memory.
struct ChatGPTDiagnosticReport: Equatable, Sendable {
    let text: String

    init(diagnostics: ChatGPTDiagnostics, settings: AppSettings,
         appVersion: String? = AppVersion.current,
         appBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        let version = Self.numeric(appVersion, pattern: #"^[0-9]{1,4}(\.[0-9]{1,4}){1,3}$"#)
        let build = Self.numeric(appBuild, pattern: #"^[0-9]{1,12}$"#)
        let output = ["schema", "json", "prompt"].contains(settings.cloudOutput) ? settings.cloudOutput : "other"
        let reasoning = ["auto", "none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(settings.cloudReasoning) ? settings.cloudReasoning : "other"
        let fields = [("report_version", "1"), ("app_version", version), ("app_build", build),
                      ("provider", "chatgpt"), ("probe", "check-cloud"),
                      ("output_mode", output), ("reasoning", reasoning)] + diagnostics.fields
        text = "After ChatGPT diagnostics\n" + fields.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
    }

    private static func numeric(_ value: String?, pattern: String) -> String {
        guard let value, value.utf8.count <= 24,
              value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex else { return "unknown" }
        return value
    }

    @MainActor @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
