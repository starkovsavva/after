import SwiftUI

struct TrackerSyncExportSheet: View {
    @ObservedObject var coordinator: TrackerSyncCoordinator
    let taskID: String
    let taskTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var connectionID = ""
    @State private var scopeID = ""
    @State private var scopes: [TrackerSyncScope] = []
    @State private var loading = false
    @State private var queued = false
    private var connections: [TrackerSyncConfiguration] {
        coordinator.state.configurations.filter { $0.enabled && $0.pushEnabled && !$0.paused && !$0.scopes.isEmpty }
    }
    private var connection: TrackerSyncConfiguration? { connections.first { $0.id == connectionID } }
    private var linked: Bool {
        let local = taskID.hasPrefix("manual:") ? String(taskID.dropFirst(7)) : taskID
        return coordinator.state.linkedTasks.contains { $0.localID == local } || coordinator.state.pending.contains { $0.localID == local }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Отправить в трекер")).font(AppTypography.sectionTitle)
            Text(taskTitle).font(AppTypography.body).lineLimit(3)
            if linked {
                Label(L("Задача уже связана с трекером или ожидает отправки"), systemImage: "link").foregroundStyle(.secondary)
            } else if connections.isEmpty {
                Text(L("В настройках подключите трекер, выберите списки и разрешите отправку изменений."))
                    .font(AppTypography.control).foregroundStyle(.secondary)
            } else {
                Picker(L("Аккаунт"), selection: $connectionID) {
                    ForEach(connections) { config in Text("\(config.account) · \(config.providerTitle)").tag(config.id) }
                }
                if loading { ProgressView(L("Загружаем списки…")).controlSize(.small) }
                else {
                    Picker(L("Список"), selection: $scopeID) {
                        Text(L("Выберите список")).tag("")
                        ForEach(scopes) { scope in Text(scope.title).tag(scope.id) }
                    }.disabled(scopes.isEmpty)
                }
                Text(L("Будут отправлены название, описание, статус и срок. Материалы и история останутся в «После»."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if let error = coordinator.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
            if queued { Label(L("Задача добавлена в очередь отправки"), systemImage: "checkmark.circle").font(AppTypography.control) }
            HStack {
                Button(queued ? L("Готово") : L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !queued && !linked && !connections.isEmpty {
                    Button(L("Отправить")) {
                        guard let connection else { return }
                        coordinator.export(taskID: taskID, connection: connection, scope: scopeID)
                        queued = coordinator.error == nil
                        if queued { Task { await coordinator.synchronize(connection) } }
                    }.keyboardShortcut(.defaultAction).disabled(loading || coordinator.busy || scopeID.isEmpty)
                }
            }
        }.padding(24).frame(width: 520)
        .onAppear { coordinator.reload(); connectionID = connections.first?.id ?? "" }
        .task(id: connectionID) { await loadScopes() }
    }
    private func loadScopes() async {
        scopeID = ""; scopes = []
        guard let connection else { return }
        loading = true; defer { loading = false }
        let selectedID = connection.id
        let all = await coordinator.scopes(connection)
        guard connectionID == selectedID else { return }
        scopes = all.filter { connection.scopes.contains($0.id) }
        if scopes.count == 1 { scopeID = scopes[0].id }
    }
}

struct TrackerSyncTaskStatus: View {
    @ObservedObject var coordinator: TrackerSyncCoordinator
    let taskID: String
    let hasExternalLink: Bool
    private var localID: String { taskID.hasPrefix("manual:") ? String(taskID.dropFirst(7)) : taskID }
    var body: some View {
        Group {
            if let link = coordinator.state.linkedTasks.first(where: { $0.localID == localID }),
               let config = coordinator.state.configurations.first(where: { $0.id == link.connection }) {
                Label(config.enabled && !config.paused ? LF("Синхронизация · {0}", arguments: [String(describing: (config.account))]) : LF("Синхронизация приостановлена · {0}", arguments: [String(describing: (config.account))]), systemImage: "arrow.triangle.2.circlepath")
            } else if coordinator.state.pending.contains(where: { $0.localID == localID }) {
                Label(L("Ожидает отправки в трекер"), systemImage: "clock")
            } else if hasExternalLink {
                Text(L("Ссылка на оригинал. Автоматическая синхронизация не подключена."))
            }
        }.font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
