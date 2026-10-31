import AfterPlatformMacOS
import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

/// Client configuration is presentation only: every format starts the same
/// local stdio server with the same library and task permissions.
struct AgentMCPConfiguration {
    enum Client: String, CaseIterable, Identifiable {
        case codex, claude, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude"
            case .other: L("Другой клиент")
            }
        }
        var instructions: String {
            switch self {
            case .codex:
                L("Добавьте блок в .codex/config.toml личного проекта или в ~/.codex/config.toml.")
            case .claude:
                L("Добавьте сервер в mcpServers в настройках Claude Desktop или в .mcp.json личного проекта Claude Code.")
            case .other:
                L("Выберите локальный сервер (stdio). Укажите command и args из JSON ниже в настройках своего клиента.")
            }
        }
    }
    var executable: String
    var root: String
    var sharedMaterialSearch = false
    var arguments: [String] { ["mcp", "--root", root] + (sharedMaterialSearch ? ["--shared-material-search"] : []) }

    func text(for client: Client) -> String {
        if client == .codex {
            return "[mcp_servers.posle]\ncommand = \(Self.toml(executable))\nargs = [\(arguments.map(Self.toml).joined(separator: ", "))]\n"
        }
        let server: [String: Any] = ["type": "stdio", "command": executable, "args": arguments]
        let value: [String: Any] = client == .claude ? ["mcpServers": ["posle": server]] : server
        // All values are strings and arrays supplied by the app, not user JSON.
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// TOML basic strings accept literal Unicode, but their escapes differ from
    /// JSON and Swift. In particular JSON's optional escaped slash is invalid.
    private static func toml(_ text: String) -> String {
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

struct AgentIntegrationSettings: View {
    @EnvironmentObject private var app: AppStore
    @State private var enabled = false
    @State private var revision = 0
    @State private var loading = true
    @State private var message: String?
    @State private var failed = false
    @State private var client: AgentMCPConfiguration.Client = .codex
    @State private var sharedMaterialSearch = false

    private struct Access: Decodable { var enabled: Bool; var revision: Int }
    private var configuration: String {
        let current = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/After Engine")
        let legacy = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/posle-engine")
        return AgentMCPConfiguration(
            executable: FileManager.default.isExecutableFile(atPath: current.path) ? current.path : legacy.path,
            root: app.root.path,
            sharedMaterialSearch: sharedMaterialSearch
        ).text(for: client)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L("Внешние агенты")).font(AppTypography.sectionTitle)
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L("MCP для задач: разрешить подключение"), isOn: Binding(get: { enabled }, set: save))
                    .disabled(loading).accessibilityIdentifier("integrations.mcp.enabled")
                Text(L("Подходит любой агент с поддержкой локальных MCP-серверов (stdio). Выберите доступные задачи и материалы в меню «… → Доступ агентам» у задачи."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if enabled {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("Клиент"), selection: $client) {
                        ForEach(AgentMCPConfiguration.Client.allCases) { client in
                            Text(client.title).tag(client)
                        }
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    .accessibilityIdentifier("integrations.mcp.client")
                    Toggle(L("Поиск в материалах задачи"), isOn: $sharedMaterialSearch)
                    Text(L("Агент сможет искать только в материалах, которые вы явно открыли ему в закреплённой задаче. Поиск по всей базе знаний не включается."))
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                    Text(client.instructions)
                        .font(AppTypography.control).foregroundStyle(.secondary)
                    Text(configuration).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityIdentifier("integrations.mcp.configuration")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration, forType: .string)
                        failed = false; message = L("Настройки подключения скопированы")
                    } label: { Label(L("Скопировать настройки"), systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered).accessibilityIdentifier("integrations.mcp.copy")
                    Text(L("После добавления перезапустите подключение MCP в клиенте. Агент сможет брать разрешённые задачи в работу, добавлять результаты и завершать их. Папки передаются как ссылки; доступ к файлам задаётся в среде агента."))
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
                .onChange(of: client) { _, _ in message = nil; failed = false }
            }
            Divider()
            SnapshotAgentSettings(root: app.root).environmentObject(app)
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
            message = next ? L("MCP для разрешённых задач включён") : L("MCP для задач выключен")
        } catch { load(); failed = true; message = error.localizedDescription }
    }
}
