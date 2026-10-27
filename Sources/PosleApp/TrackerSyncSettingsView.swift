import SwiftUI

struct TrackerSyncSettingsView: View {
    @ObservedObject var coordinator: TrackerSyncCoordinator
    @State private var editor: TrackerSyncConfiguration?
    @State private var comparison: TrackerSyncConflict?
    @State private var disconnecting: TrackerSyncConfiguration?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Трекеры").font(AppTypography.sectionTitle)
                Spacer()
                Menu {
                    Button("Google Tasks") { editor = TrackerSyncConfiguration() }
                    Button("Яндекс Трекер") { var next = TrackerSyncConfiguration(); next.provider = "yandex"; editor = next }
                } label: { Label("Подключить", systemImage: "plus") }
                    .disabled(coordinator.busy).accessibilityIdentifier("tracker.add")
            }
            Text(coordinator.state.configurations.isEmpty
                 ? "Подключите Google Tasks или Яндекс Трекер и выберите списки задач."
                 : "Синхронизируются выбранные списки. Материалы задач остаются на Mac.")
                .font(AppTypography.control).foregroundStyle(.secondary)
            if coordinator.state.configurations.isEmpty {
                Text("Нет подключений").font(AppTypography.control).foregroundStyle(.secondary)
            }
            ForEach(coordinator.state.configurations) { config in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(config.account).font(AppTypography.controlStrong)
                            Text(config.providerTitle).font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if coordinator.busy { ProgressView().controlSize(.small) }
                        Menu {
                            Button("Настроить…") { editor = config }
                            Button("Синхронизировать") { Task { await coordinator.synchronize(config) } }
                                .disabled(!config.enabled || config.paused || config.scopes.isEmpty)
                            Divider()
                            Button("Отключить…", role: .destructive) { disconnecting = config }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Настройки подключения \(config.account)")
                    }
                    if !config.scopes.isEmpty {
                        Text(scopeDescription(config)).font(AppTypography.caption).foregroundStyle(.secondary)
                            .lineLimit(2).help(scopeDescription(config))
                    }
                    Text(status(config)).font(AppTypography.caption).foregroundStyle(config.requiresAuth || config.error != nil ? Ink.warning : .secondary)
                    if let message = config.error { Text(message).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
                }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if !coordinator.state.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Нужна сверка · \(coordinator.state.conflicts.count)").font(AppTypography.controlStrong)
                    ForEach(coordinator.state.conflicts) { conflict in
                        Button { comparison = conflict } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conflict.title).lineLimit(1)
                                    Text(conflict.reason).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("tracker.conflict.\(conflict.id)")
                    }
                }
            }
            if !coordinator.state.pending.isEmpty {
                Text("Ожидают отправки: \(coordinator.state.pending.count)").font(AppTypography.caption).foregroundStyle(.secondary)
                if coordinator.state.pending.contains(where: \.uncertain) {
                    Text("Проверяем результат последней отправки. Повторное создание остановлено до сверки, чтобы избежать дубликатов.")
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
            }
            if let error = coordinator.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
            else if let notice = coordinator.notice { Text(notice).font(AppTypography.caption).foregroundStyle(.secondary) }
        }
        .onAppear { coordinator.reload() }
        .sheet(item: $editor) { config in TrackerSyncConnectionEditor(coordinator: coordinator, initial: config) }
        .sheet(item: $comparison) { conflict in TrackerSyncConflictView(coordinator: coordinator, conflict: conflict) }
        .confirmationDialog("Отключить \(disconnecting?.account ?? "трекер")?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })) {
            Button("Отключить", role: .destructive) { if let config = disconnecting { coordinator.disconnect(config) }; disconnecting = nil }
        } message: { Text("Локальные задачи и материалы сохранятся. Токен будет удалён из Связки ключей.") }
    }
    private func scopeDescription(_ config: TrackerSyncConfiguration) -> String {
        let titles = config.scopes.compactMap { config.scopeTitles[$0] }.filter { !$0.isEmpty }
        if titles.count == config.scopes.count {
            return (config.provider == "google" ? "Списки: " : "Очереди: ") + titles.joined(separator: ", ")
        }
        return (config.provider == "google" ? "Выбрано списков: " : "Выбрано очередей: ") + String(config.scopes.count)
    }
    private func status(_ config: TrackerSyncConfiguration) -> String {
        if !config.enabled { return "Отключено" }
        if config.paused { return "На паузе" }
        if config.requiresAuth { return "Обновите доступ" }
        if config.scopes.isEmpty { return "Выберите списки задач" }
        if let date = config.retryAt, date > Date().timeIntervalSince1970 { return "Повтор после \(Date(timeIntervalSince1970: date).formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU"))))" }
        if let date = config.lastSync { return "Обновлено \(Date(timeIntervalSince1970: date).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))) · \(config.pushEnabled ? "В обе стороны" : "Только получение")" }
        return config.pushEnabled ? "Готово к синхронизации в обе стороны" : "Готово к получению задач"
    }
}

private struct TrackerSyncConnectionEditor: View {
    @ObservedObject var coordinator: TrackerSyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var config: TrackerSyncConfiguration
    @State private var token = ""
    @State private var refreshToken = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var expiry = Date().addingTimeInterval(3_600)
    @State private var scopes: [TrackerSyncScope] = []
    @State private var advanced = false
    @State private var savedOnce: Bool
    init(coordinator: TrackerSyncCoordinator, initial: TrackerSyncConfiguration) {
        self.coordinator = coordinator
        _config = State(initialValue: initial); _savedOnce = State(initialValue: !initial.id.isEmpty)
        _expiry = State(initialValue: initial.expiresAt.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3_600))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(config.providerTitle).font(AppTypography.sectionTitle)
            ScrollView {
                Form {
                    TextField("Название аккаунта", text: $config.account).disabled(savedOnce)
                        .help("Например, «Личный». Подключается только указанный вами аккаунт.")
                    if config.provider == "yandex" {
                        TextField("ID организации", text: $config.organizationId).disabled(savedOnce)
                        Toggle("Организация Yandex Identity Hub", isOn: $config.cloudOrganization).disabled(savedOnce)
                        Toggle("IAM-токен", isOn: $config.iamToken).disabled(!config.cloudOrganization)
                    }
                    SecureField(savedOnce ? "Новый токен (текущий сохранён)" : "Токен доступа", text: $token)
                        .accessibilityIdentifier("tracker.token")
                    if config.provider == "google" || config.iamToken {
                        DatePicker("Действует до", selection: $expiry, displayedComponents: [.date, .hourAndMinute])
                        if config.provider == "google" {
                            Text("Access token действует ограниченное время. Для автоматического продления добавьте refresh token своего OAuth-клиента.")
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                    }
                    if config.provider == "google" {
                        DisclosureGroup("Продление доступа Google", isExpanded: $advanced) {
                            TextField("OAuth Desktop client ID", text: $clientID)
                            SecureField("Client secret, если выдан", text: $clientSecret)
                            SecureField("Refresh token", text: $refreshToken)
                            Text("Нужен собственный OAuth-клиент с разрешением Google Tasks. Эти данные сохраняются только в Связке ключей.")
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                            Link("Как получить доступ", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
                        }
                    }
                    Section {
                        Toggle("Синхронизировать автоматически", isOn: $config.enabled)
                        Toggle("Отправлять изменения в трекер", isOn: $config.pushEnabled)
                        Toggle("Приостановить синхронизацию", isOn: $config.paused)
                        Text("Отправляются название, описание, статус и срок связанных задач. Материалы, записи встреч и заметки к задаче остаются в «После». Удаления автоматически не передаются.")
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        HStack {
                            Text(config.provider == "google" ? "Списки задач" : "Очереди").font(AppTypography.controlStrong)
                            Spacer()
                            Button("Загрузить списки") { Task { await loadScopes() } }.disabled(coordinator.busy)
                        }
                        ForEach(scopes) { scope in
                            Toggle(scope.title, isOn: Binding(get: { config.scopes.contains(scope.id) }, set: { selected in
                                if selected { if !config.scopes.contains(scope.id) { config.scopes.append(scope.id) } }
                                else { config.scopes.removeAll { $0 == scope.id } }
                            }))
                        }
                        if scopes.isEmpty && !config.scopes.isEmpty {
                            Text("Выбрано: \(config.scopes.joined(separator: ", "))").font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                    }
                    if config.provider == "yandex" {
                        DisclosureGroup("Соответствие статусов") {
                            statusField("К выполнению", key: "todo")
                            statusField("В работе", key: "doing")
                            statusField("Ожидает", key: "blocked")
                            statusField("Готово", key: "done")
                            Text("Укажите ключи статусов вашей очереди. Переходы выполняются по её рабочему процессу.")
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                    }
                }.formStyle(.grouped).disabled(coordinator.busy)
            }
            if let error = coordinator.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if coordinator.busy { ProgressView().controlSize(.small) }
                Button("Сохранить") { Task { if await save() { dismiss() } } }
                    .keyboardShortcut(.defaultAction).disabled(coordinator.busy || config.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 600, height: 700)
    }
    private func statusField(_ title: String, key: String) -> some View {
        TextField(title, text: Binding(get: { config.statusMapping[key] ?? "" }, set: { config.statusMapping[key] = $0 }))
    }
    private func save() async -> Bool {
        if config.provider == "google" || config.iamToken { config.expiresAt = expiry.timeIntervalSince1970 }
        let success = await coordinator.save(config, token: token, refreshToken: refreshToken, clientID: clientID, clientSecret: clientSecret)
        if success, let latest = coordinator.state.configurations.first(where: { $0.id == config.id || (!savedOnce && $0.account == config.account && $0.provider == config.provider) }) {
            config = latest; savedOnce = true; token = ""; refreshToken = ""; clientID = ""; clientSecret = ""
        }
        return success
    }
    private func loadScopes() async {
        guard await save() else { return }
        scopes = await coordinator.scopes(config)
        if let latest = coordinator.state.configurations.first(where: { $0.id == config.id }) { config = latest }
        config.scopeTitles.merge(Dictionary(uniqueKeysWithValues: scopes.map { ($0.id, $0.title) })) { _, new in new }
    }
}
private struct TrackerSyncConflictView: View {
    @ObservedObject var coordinator: TrackerSyncCoordinator
    let conflict: TrackerSyncConflict
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Сверка изменений").font(AppTypography.sectionTitle)
            Text(conflict.reason).font(AppTypography.control).foregroundStyle(.secondary)
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    version("В «После»", fields: conflict.local, unavailable: "Локальная задача удалена")
                    Divider()
                    version("В трекере", fields: conflict.remote.deleted ? nil : conflict.remote.fields, unavailable: "Внешняя задача удалена")
                }
            }
            if let error = coordinator.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
            HStack {
                Button("Позже") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Разорвать связь") { resolve("unlink") }
                if conflict.local != nil && !conflict.remote.deleted {
                    Button("Версия трекера") { resolve("remote") }
                    Button("Моя версия") { resolve("local") }
                }
            }.disabled(coordinator.busy)
        }.padding(24).frame(width: 760, height: 520)
    }
    private func version(_ title: String, fields: TrackerSyncFields?, unavailable: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppTypography.controlStrong)
            if let fields {
                Text(fields.title).font(AppTypography.body).textSelection(.enabled)
                Text(fields.text).font(AppTypography.control).textSelection(.enabled)
                Text("\(fields.status) · \(fields.due)").font(AppTypography.caption).foregroundStyle(.secondary)
            } else { Text(unavailable).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func resolve(_ value: String) {
        Task { await coordinator.resolve(conflict, resolution: value); if !coordinator.state.conflicts.contains(where: { $0.id == conflict.id }) { dismiss() } }
    }
}
