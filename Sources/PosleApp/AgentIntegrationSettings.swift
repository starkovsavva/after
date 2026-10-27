import AppKit
import PosleCore
import SwiftUI

struct AgentIntegrationSettings: View {
    @EnvironmentObject private var app: AppStore
    @State private var enabled = false
    @State private var revision = 0
    @State private var loading = true
    @State private var message: String?
    @State private var failed = false

    private struct Access: Decodable { var enabled: Bool; var revision: Int }
    private var configuration: String {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/posle-engine").path
        return "[mcp_servers.posle]\ncommand = \(toml(executable))\nargs = [\"mcp\", \"--root\", \(toml(app.root.path))]\n"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Агенты").font(AppTypography.sectionTitle)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Разрешить подключение через MCP", isOn: Binding(get: { enabled }, set: save))
                    .disabled(loading).accessibilityIdentifier("integrations.mcp.enabled")
                Text("Выберите доступные задачи и материалы в меню «…» у задачи. Они попадут в контекст подключённого агента.")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if enabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Подключение Codex").font(AppTypography.controlStrong)
                    Text("Добавьте этот блок в настройки MCP вашего личного проекта.")
                        .font(AppTypography.control).foregroundStyle(.secondary)
                    Text(configuration).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityIdentifier("integrations.mcp.configuration")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration, forType: .string)
                        failed = false; message = "Настройки подключения скопированы"
                    } label: { Label("Скопировать настройки", systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered).accessibilityIdentifier("integrations.mcp.copy")
                    Text("Агент сможет брать задачи в работу, добавлять результаты и завершать их. Папки передаются как ссылки; доступ к файлам задаётся в среде агента.")
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
            }
            if let message {
                Label(message, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(AppTypography.caption).foregroundStyle(failed ? Ink.warning : .secondary)
                    .textSelection(.enabled).accessibilityIdentifier("integrations.mcp.status")
            }
        }.onAppear(perform: load)
    }
    private func load() {
        defer { loading = false }
        do {
            let data = try RustBridge.shared.get().request(root: app.root, command: "task-agent-settings")
            let value = try JSONDecoder().decode(Access.self, from: data)
            enabled = value.enabled; revision = value.revision
        } catch { failed = true; message = error.localizedDescription }
    }
    private func save(_ next: Bool) {
        do {
            let data = try RustBridge.shared.get().request(root: app.root, command: "task-agent-settings", arguments: [
                "enabled": next, "expectedRevision": revision, "operationID": UUID().uuidString.lowercased()
            ])
            let value = try JSONDecoder().decode(Access.self, from: data)
            enabled = value.enabled; revision = value.revision; failed = false
            message = next ? "MCP включён для разрешённых задач" : "MCP выключен"
        } catch { load(); failed = true; message = error.localizedDescription }
    }
    /// TOML basic strings accept literal Unicode, but their escapes differ from
    /// JSON and Swift. In particular JSON's optional escaped slash is invalid.
    private func toml(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 0...31, 127: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
