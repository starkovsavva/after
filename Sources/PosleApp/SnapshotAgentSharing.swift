import AppKit
import PosleCore
import SwiftUI

struct AgentShareSource: Codable, Identifiable { var id: String; var kind: String; var title: String; var text: String; var fingerprint: String; var revision: Int }
struct AgentSharePreview: Decodable, Identifiable { var id: String; var digest: String; var title: String; var createdAt: Double; var sources: [AgentShareSource] }
struct AgentShareSnapshot: Decodable, Identifiable { var id: String { shareID ?? (String(createdAt) + title) }; var shareID: String?; var title: String; var createdAt: Double; var sources: [AgentShareSource] }
struct AgentShareConnection: Decodable, Identifiable { var id: String; var code: String; var label: String; var createdAt: Double }
struct AgentShareAccess: Decodable { var enabled: Bool; var revision: Int }
struct AgentShareRecord: Decodable, Identifiable { var id: String; var title: String; var createdAt: Double; var expiresAt: Double; var revoked: Bool; var sourceCount: Int }
struct AgentShareArtifact: Decodable, Identifiable { var id: String { title + (url ?? "") + (text ?? "") }; var title: String; var text: String?; var url: String? }
struct AgentShareEvidence: Decodable, Identifiable { var id: String { sourceID }; var sourceID: String; var fingerprint: String; var title: String? }
struct AgentShareReport: Decodable, Identifiable { var id: String; var shareID: String; var createdAt: Double; var text: String; var artifacts: [AgentShareArtifact]; var evidence: [AgentShareEvidence]; var completed: Bool }
struct AgentShareHistory: Decodable { var shares: [AgentShareRecord]; var reports: [AgentShareReport]; var nextOffset: Int? }
struct AgentShareCompletion {
    var shareID: String
    var connection: AgentShareConnection
    var preview: AgentSharePreview
    var expiresAt: Double
}

enum AgentSharePresentation {
    static let noteLimit = 50
    static func date(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(.dateTime.day().month().year().hour().minute().second().locale(UILocale()))
    }
    static func reference(_ share: AgentShareRecord) -> String { date(share.createdAt) + " · " + String(share.id.prefix(8)) }
    static func status(_ share: AgentShareRecord) -> String {
        share.revoked ? L("Доступ отозван") : share.expiresAt <= Date().timeIntervalSince1970 ? L("Срок доступа истёк") : L("Доступ активен")
    }
}

@MainActor final class AgentShareController: ObservableObject {
    @Published var access = AgentShareAccess(enabled: false, revision: 0)
    @Published var connections: [AgentShareConnection] = []
    @Published var preview: AgentSharePreview?
    @Published var shares: [AgentShareRecord] = []
    @Published var reports: [AgentShareReport] = []
    @Published var nextOffset: Int?
    @Published var error: String?
    @Published var busy = false
    @Published var loaded = false
    @Published var completion: AgentShareCompletion?
    @Published var notice: String?
    private var historyLoading = false
    private var historyGeneration = 0
    private var mutationGeneration = 0
    let root: URL
    init(root: URL) { self.root = root }
    func request(_ command: String, _ arguments: [String: Any] = [:]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let root = root
        return try await Task.detached(priority: .userInitiated) {
            let args = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try RustBridge.shared.get().request(root: root, command: command, arguments: args)
        }.value
    }
    func load() async {
        guard !busy else { return }
        let generation = mutationGeneration
        do {
            let access = try JSONDecoder().decode(AgentShareAccess.self, from: await request("agent-share-settings"))
            struct Connections: Decodable { var connections: [AgentShareConnection] }
            let connections = try JSONDecoder().decode(Connections.self, from: await request("agent-share-connections")).connections
            guard !busy, generation == mutationGeneration else { return }
            self.access = access; self.connections = connections; loaded = true
            if !access.enabled { applyMasterRevocation() }
        } catch { self.error = error.localizedDescription }
    }
    func setEnabled(_ enabled: Bool, taskID: String? = nil) async {
        guard !busy else { return }
        mutationGeneration += 1
        busy = true; defer { busy = false }
        do {
            access = try JSONDecoder().decode(AgentShareAccess.self, from: await request("agent-share-settings", ["enabled": enabled, "expectedRevision": access.revision]))
            error = nil; notice = enabled ? nil : L("Доступ ко всем снимкам отозван.")
            if !enabled { applyMasterRevocation() }
            if let taskID { await history(taskID: taskID) }
        } catch { self.error = error.localizedDescription }
    }
    private func applyMasterRevocation() {
        completion = nil; preview = nil
        shares = shares.map { var share = $0; share.revoked = true; return share }
    }
    func hasPendingConnection(_ id: String) -> Bool {
        access.enabled && connections.contains { $0.id == id }
    }
    func prepare(taskID: String, notes: [CapturedNote]) async {
        guard !busy else { return }
        mutationGeneration += 1
        busy = true; defer { busy = false }
        do {
            preview = try JSONDecoder().decode(AgentSharePreview.self, from: await request("agent-share-preview", ["taskID": taskID, "sources": notes.map { ["noteID": $0.id, "revision": $0.revision] as [String: Any] }]))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func approve(connectionID: String) async -> Bool {
        guard !busy, let preview else { return false }
        guard hasPendingConnection(connectionID), let connection = connections.first(where: { $0.id == connectionID }) else {
            error = L("Выберите действующий код подключения. Для нового снимка попросите агента вызвать after_share_request_snapshot.")
            return false
        }
        mutationGeneration += 1
        busy = true; defer { busy = false }
        do {
            struct Approval: Decodable { var id: String; var expiresAt: Double }
            let result = try JSONDecoder().decode(Approval.self, from: await request("agent-share-approve", ["draftID": preview.id, "digest": preview.digest, "sessionID": connectionID]))
            completion = AgentShareCompletion(shareID: result.id, connection: connection, preview: preview, expiresAt: result.expiresAt)
            connections.removeAll { $0.id == connectionID }
            self.preview = nil; error = nil; notice = nil; return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    func history(taskID: String, more: Bool = false) async {
        guard !more || !historyLoading else { return }
        historyGeneration += 1
        let generation = historyGeneration
        historyLoading = true
        defer { if generation == historyGeneration { historyLoading = false } }
        do {
            let offset = more ? (nextOffset ?? 0) : 0
            let value = try JSONDecoder().decode(AgentShareHistory.self, from: await request("agent-share-history", ["taskID": taskID, "offset": offset]))
            guard !Task.isCancelled, generation == historyGeneration else { return }
            shares = value.shares
            if let completion, let share = shares.first(where: { $0.id == completion.shareID }), share.revoked || share.expiresAt <= Date().timeIntervalSince1970 {
                self.completion = nil
                notice = AgentSharePresentation.status(share)
            }
            if more {
                let existing = Set(reports.map(\.id))
                reports += value.reports.filter { !existing.contains($0.id) }
                nextOffset = value.nextOffset
            }
            else if reports.count > 10 {
                let ids = Set(value.reports.map(\.id))
                // Keep the expanded history stable during ordinary polling.
                // A burst larger than one page starts a fresh contiguous page;
                // never skip unseen reports by treating a gap as loaded.
                if reports.contains(where: { ids.contains($0.id) }) {
                    reports = value.reports + reports.filter { !ids.contains($0.id) }
                    if nextOffset != nil { nextOffset = reports.count }
                } else { reports = value.reports; nextOffset = value.nextOffset }
            } else { reports = value.reports; nextOffset = value.nextOffset }
        } catch { self.error = error.localizedDescription }
    }
    func revoke(_ id: String, taskID: String) async {
        guard !busy else { return }
        mutationGeneration += 1
        busy = true; defer { busy = false }
        do { _ = try await request("agent-share-revoke", ["shareID": id]); error = nil; await history(taskID: taskID) }
        catch { self.error = error.localizedDescription }
    }
    func snapshot(_ id: String) async throws -> AgentShareSnapshot {
        var snapshot = try JSONDecoder().decode(AgentShareSnapshot.self, from: await request("agent-share-snapshot", ["shareID": id]))
        snapshot.shareID = id
        return snapshot
    }
}

struct SnapshotAgentSettings: View {
    @EnvironmentObject private var app: AppStore
    @StateObject private var model: AgentShareController
    init(root: URL) { _model = StateObject(wrappedValue: AgentShareController(root: root)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Снимки для агентов")).font(AppTypography.heading)
            Toggle(L("Разрешить передачу снимков"), isOn: Binding(get: { model.access.enabled }, set: { value in Task { await model.setEnabled(value) } }))
                .disabled(model.busy || !model.loaded).accessibilityIdentifier("snapshot.settings.enabled")
            Text(L("Отдельное разрешение: агент получает только просмотренную и подтверждённую копию выбранных заметок. Изменение оригиналов и старые настройки MCP не меняют эту копию. Выключение отзывает все снимки; уже полученные данные отозвать нельзя."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            if let notice = model.notice { Text(notice).font(AppTypography.caption) }
            if let error = model.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.task { await model.load() }
    }
}

struct TaskSnapshotShareSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var notes: NotesStore
    let taskID: String
    @StateObject private var model: AgentShareController
    @State private var selected = Set<String>()
    @State private var connectionID = ""
    @State private var query = ""
    @State private var showConfiguration = false
    @State private var savedSnapshot: AgentShareSnapshot?
    init(root: URL, notes: NotesStore, taskID: String) {
        self.notes = notes; self.taskID = taskID
        _model = StateObject(wrappedValue: AgentShareController(root: root))
    }
    private var candidates: [CapturedNote] {
        notes.notes.filter { $0.kind == "note" && $0.trashedAt == nil && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    private var configuration: String {
        let executable = ProcessInfo.processInfo.environment["POSLE_RUST_ENGINE"] ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/After Engine").path
        let value: [String: Any] = ["mcpServers": ["after_snapshot": ["command": executable, "args": ["mcp-share", "--root", app.root.path]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppPageHeader(title: L("Снимок для агента"), modal: true)
            Text(L("Агент получит точную копию показанных материалов на 24 часа. Оригиналы не обновляют её автоматически. Доступ можно отозвать здесь; это не удаляет уже полученные агентом данные."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(L("Разрешить передачу снимков"), isOn: Binding(get: { model.access.enabled }, set: { value in Task { await model.setEnabled(value, taskID: taskID) } }))
                        .disabled(model.busy || !model.loaded).accessibilityIdentifier("snapshot.enabled")
                    Text(L("Это отдельное разрешение от прежнего доступа к задачам через MCP. Выключение отзывает все ранее выданные снимки."))
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                    if let completion = model.completion {
                        completed(completion)
                    } else if let preview = model.preview {
                        Text(L("Проверьте всё, что увидит агент")).font(AppTypography.heading)
                        Text(AgentSharePresentation.date(preview.createdAt)).font(AppTypography.caption).foregroundStyle(.secondary)
                        AgentShareSourcesView(sources: preview.sources)
                        if let connection = model.connections.first(where: { $0.id == connectionID }) {
                            Label(connection.code, systemImage: "link").font(.system(.body, design: .monospaced)).accessibilityIdentifier("snapshot.review-code")
                        }
                    } else {
                        selection
                    }
                    if !model.shares.isEmpty {
                        Divider()
                        Text(L("Предоставленные снимки")).font(AppTypography.heading)
                        ForEach(model.shares) { share in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(share.title).font(AppTypography.controlStrong)
                                AgentShareRecordDetails(share: share)
                                HStack {
                                    Button(L("Показать предоставленные материалы")) { openSnapshot(share.id) }
                                        .accessibilityIdentifier("snapshot.sources." + share.id)
                                    Spacer()
                                    if !share.revoked && share.expiresAt > Date().timeIntervalSince1970 {
                                        Button(L("Отозвать доступ")) { Task { await model.revoke(share.id, taskID: taskID) } }
                                            .disabled(model.busy).accessibilityIdentifier("snapshot.revoke." + share.id)
                                    }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = model.notice { Text(notice).font(AppTypography.caption).accessibilityIdentifier("snapshot.notice") }
            if let error = model.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning).accessibilityIdentifier("snapshot.error") }
            HStack {
                if model.preview != nil { Button(L("Назад")) { model.preview = nil } }
                Spacer()
                Button(L("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
                if model.preview != nil {
                    Button(L("Предоставить этот снимок")) { Task {
                        if await model.approve(connectionID: connectionID) {
                            connectionID = ""; selected.removeAll(); query = ""
                            await model.history(taskID: taskID)
                        }
                    } }.buttonStyle(.borderedProminent).disabled(model.busy || !model.hasPendingConnection(connectionID)).accessibilityIdentifier("snapshot.approve")
                } else if model.completion == nil {
                    Button(L("Посмотреть снимок")) { Task { await model.prepare(taskID: taskID, notes: notes.notes.filter { selected.contains($0.id) }) } }
                        .buttonStyle(.borderedProminent).disabled(model.busy || selected.isEmpty || !model.hasPendingConnection(connectionID)).accessibilityIdentifier("snapshot.preview")
                }
            }
        }.padding(24).frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 720).appControlDefaults()
            .task {
                await model.load(); await model.history(taskID: taskID)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2)); if Task.isCancelled { break }
                    await model.load(); await model.history(taskID: taskID)
                }
            }
            .onChange(of: model.connections.map(\.id)) { _, ids in
                if !connectionID.isEmpty && !ids.contains(connectionID) {
                    connectionID = ""; model.preview = nil
                }
            }
            .onChange(of: model.access.enabled) { _, enabled in if !enabled { connectionID = "" } }
            .sheet(item: $savedSnapshot) { AgentShareSnapshotSheet(snapshot: $0) }
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(L("Подключить агента"), isExpanded: $showConfiguration) {
                Text(L("Добавьте локальный MCP-сервер с этой конфигурацией. Агент должен вызвать after_share_status и показать код подключения."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                Text(configuration).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button(L("Скопировать настройки")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(configuration, forType: .string) }
            }
            newCodeInstructions
            Text(L("Подключение")).font(AppTypography.controlStrong)
            Text(L("Сравните код с кодом у агента. Имя клиента сообщается самим клиентом и не подтверждает его личность."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            if model.connections.isEmpty { Text(L("Ожидаем новый код подключения агента…")).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.waiting-connection") }
            ForEach(model.connections) { connection in
                Button { connectionID = connection.id } label: {
                    HStack { Image(systemName: connectionID == connection.id ? "largecircle.fill.circle" : "circle"); Text(connection.code).monospaced(); Text(connection.label).foregroundStyle(.secondary); Spacer() }
                }.buttonStyle(.plain).disabled(!model.access.enabled || model.busy).accessibilityIdentifier("snapshot.connection." + connection.id)
            }
            HStack {
                Text(LF("Выбрано {0} из 50 заметок", arguments: [String(selected.count)])).font(AppTypography.controlStrong).accessibilityIdentifier("snapshot.selection-count")
                Spacer()
                TextField(L("Поиск"), text: $query).frame(width: 220).accessibilityIdentifier("snapshot.note-search")
            }
            if selected.count >= AgentSharePresentation.noteLimit {
                Text(L("В одном снимке можно передать до 50 заметок. Снимите выбор с одной заметки, чтобы добавить другую."))
                    .font(AppTypography.caption).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.selection-limit")
            }
            if candidates.isEmpty {
                Text(query.isEmpty ? L("Пока нет заметок для снимка. Сначала создайте заметку в библиотеке.") : L("Заметки не найдены. Измените запрос или очистите поиск."))
                    .foregroundStyle(.secondary).accessibilityIdentifier("snapshot.empty-notes")
                if !query.isEmpty { Button(L("Очистить поиск")) { query = "" }.accessibilityIdentifier("snapshot.clear-search") }
            }
            ForEach(candidates) { note in
                Toggle(isOn: Binding(get: { selected.contains(note.id) }, set: { on in
                    if on { if selected.count < AgentSharePresentation.noteLimit { selected.insert(note.id) } }
                    else { selected.remove(note.id) }
                })) { Text(note.title.isEmpty ? String(note.text.prefix(90)) : note.title).lineLimit(2) }
                    .disabled(model.busy || (!selected.contains(note.id) && selected.count >= AgentSharePresentation.noteLimit))
                    .accessibilityIdentifier("snapshot.note." + note.id)
            }
        }
    }
    private var newCodeInstructions: some View {
        Text(L("Для нового снимка попросите агента вызвать after_share_request_snapshot и показать новый код. Перезапускать MCP-клиент не нужно. Прежний доступ этого подключения будет отозван; новую копию нужно подтвердить снова."))
            .font(AppTypography.caption).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.new-code-instructions")
    }
    private func completed(_ completion: AgentShareCompletion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Снимок предоставлен этому подключению"), systemImage: "checkmark.circle").font(AppTypography.heading).accessibilityIdentifier("snapshot.approved")
            Text(completion.connection.label + " · " + completion.connection.code).font(AppTypography.controlStrong)
            Text(LF("Материалов: {0} · Доступ до {1}", arguments: [String(completion.preview.sources.count), AgentSharePresentation.date(completion.expiresAt)]))
                .font(AppTypography.caption).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.approved-summary")
            ForEach(completion.preview.sources) { source in Label(source.title, systemImage: source.kind == "task" ? "checklist" : "note.text") }
            Button(L("Показать предоставленные материалы")) { openSnapshot(completion.shareID) }.accessibilityIdentifier("snapshot.approved-sources")
            Text(L("Агент может прочитать эту копию и прислать отчёт. Отчёт появится в истории задачи."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            newCodeInstructions
            Button(L("Подготовить новый снимок")) { model.completion = nil; connectionID = ""; selected.removeAll(); query = "" }
                .accessibilityIdentifier("snapshot.new")
        }
    }
    private func openSnapshot(_ id: String) {
        Task { do { savedSnapshot = try await model.snapshot(id) } catch { model.error = error.localizedDescription } }
    }
}

struct AgentShareRecordDetails: View {
    let share: AgentShareRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LF("Снимок от {0}", arguments: [AgentSharePresentation.reference(share)]))
            Text(LF("Материалов: {0} · Доступ до {1}", arguments: [String(share.sourceCount), AgentSharePresentation.date(share.expiresAt)]))
            Text(AgentSharePresentation.status(share)).accessibilityIdentifier("snapshot.status." + share.id)
        }.font(AppTypography.caption).foregroundStyle(.secondary)
    }
}

struct AgentShareSourcesView: View {
    let sources: [AgentShareSource]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 6) {
                    Label(source.title, systemImage: source.kind == "task" ? "checklist" : "note.text").font(AppTypography.controlStrong)
                    Text(L("Версия") + " " + String(source.revision)).font(AppTypography.caption).foregroundStyle(.secondary)
                    Text(source.text).font(AppTypography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("snapshot.source." + source.id)
            }
        }
    }
}
struct AgentShareSnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: AgentShareSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppPageHeader(title: snapshot.title, modal: true)
            Text(L("Сохранённая копия на момент предоставления доступа")).font(AppTypography.caption).foregroundStyle(.secondary)
            if let shareID = snapshot.shareID {
                Text(LF("Снимок {0}", arguments: [String(shareID.prefix(8))])).font(AppTypography.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("snapshot.saved." + shareID)
            }
            Text(Date(timeIntervalSince1970: snapshot.createdAt).formatted(.dateTime.day().month().hour().minute().second().locale(UILocale())))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            ScrollView { AgentShareSourcesView(sources: snapshot.sources).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer(); Button(L("Готово")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("snapshot.sources.close") }
        }.padding(24).frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 600)
    }
}
struct SnapshotShareHistoryView: View {
    let taskID: String
    @StateObject private var model: AgentShareController
    @State private var snapshot: AgentShareSnapshot?
    @State private var artifact: TaskArtifact?
    init(root: URL, taskID: String) { self.taskID = taskID; _model = StateObject(wrappedValue: AgentShareController(root: root)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.shares.isEmpty { Text(L("Работа агента со снимками")).font(AppTypography.heading) }
            ForEach(model.shares) { share in
                VStack(alignment: .leading, spacing: 8) {
                    AgentShareRecordDetails(share: share)
                    HStack {
                        Button { openSnapshot(share.id) } label: { Label(L("Показать предоставленные материалы"), systemImage: "shippingbox") }
                            .accessibilityIdentifier("snapshot.history.sources." + share.id)
                        Spacer()
                        if !share.revoked && share.expiresAt > Date().timeIntervalSince1970 {
                            Button(L("Отозвать доступ")) { Task { await model.revoke(share.id, taskID: taskID) } }
                                .disabled(model.busy).accessibilityIdentifier("snapshot.history.revoke." + share.id)
                        }
                    }
                }
            }
            ForEach(model.reports) { report in
                VStack(alignment: .leading, spacing: 8) {
                    Label(report.completed ? L("Агент завершил работу со снимком") : L("Отчёт агента"), systemImage: "doc.text").font(AppTypography.controlStrong)
                    Text(LF("Отчёт от {0}", arguments: [AgentSharePresentation.date(report.createdAt)]))
                        .font(AppTypography.caption).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.history.report-date." + report.id)
                    if let share = model.shares.first(where: { $0.id == report.shareID }) {
                        Button(LF("По снимку от {0}", arguments: [AgentSharePresentation.reference(share)])) { openSnapshot(report.shareID) }
                            .font(AppTypography.caption).accessibilityIdentifier("snapshot.history.report-snapshot." + report.id + "." + share.id)
                    }
                    Text(report.text).font(AppTypography.body).textSelection(.enabled)
                    Text(L("Сообщение агента; статус исходной задачи не изменён.")).font(AppTypography.caption).foregroundStyle(.secondary)
                    ForEach(report.evidence) { evidence in
                        Button { Task {
                            do {
                                var saved = try await model.snapshot(report.shareID)
                                saved.sources = saved.sources.filter { $0.id == evidence.sourceID && $0.fingerprint == evidence.fingerprint }
                                guard !saved.sources.isEmpty else { throw AppError.message(L("Источник отчёта недоступен")) }
                                snapshot = saved
                            } catch { model.error = error.localizedDescription }
                        } } label: { Label(evidence.title ?? L("Источник отчёта"), systemImage: "text.bubble") }
                            .accessibilityIdentifier("snapshot.history.evidence." + report.id + "." + evidence.sourceID)
                    }
                    ForEach(Array(report.artifacts.enumerated()), id: \.offset) { index, value in
                        Button(value.title) { let payload: [String: Any] = ["id": report.id + String(index), "kind": "report", "title": value.title, "text": value.text ?? "", "url": value.url as Any? ?? NSNull()]
                            if let data = try? JSONSerialization.data(withJSONObject: payload) { artifact = try? JSONDecoder().decode(TaskArtifact.self, from: data) } }
                            .accessibilityIdentifier("snapshot.history.artifact." + report.id + "." + String(index))
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("snapshot.history.report." + report.id)
            }
            if model.nextOffset != nil { Button(L("Показать ещё")) { Task { await model.history(taskID: taskID, more: true) } } }
            if let error = model.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.task(id: taskID) {
            model.reports = []; model.shares = []; model.nextOffset = nil
            await model.history(taskID: taskID)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3)); if Task.isCancelled { break }; await model.history(taskID: taskID) }
        }
            .sheet(item: $snapshot) { AgentShareSnapshotSheet(snapshot: $0) }
            .sheet(item: $artifact) { TaskArtifactSheet(artifact: $0) }
    }
    private func openSnapshot(_ id: String) {
        Task { do { snapshot = try await model.snapshot(id) } catch { model.error = error.localizedDescription } }
    }
}
