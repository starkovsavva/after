import PosleCore
import SwiftUI

/// Subscription sign-in has its own account and model controls. API credentials
/// never appear in this view, and model availability comes from the account.
@MainActor
struct ChatGPTSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var account: ChatGPTAccount
    @State private var signInTask: Task<Void, Never>?
    @State private var signInGeneration = UUID()
    @State private var catalogWasLoaded = false
    @State private var isDisconnecting = false
    private static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    init(account: ChatGPTAccount? = nil) { self.account = account ?? .shared }

    private var selectedProfile: ChatGPTProfile? {
        if let profile = account.profile, profile.id == store.settings.chatGPTAccountID { return profile }
        return account.savedProfiles.first { $0.id == store.settings.chatGPTAccountID }
    }
    private var isActiveAccount: Bool {
        guard let profile = account.profile else { return false }
        return profile.id == store.settings.chatGPTAccountID
    }
    private var usesPlan: Bool { isActiveAccount && account.profile?.planEnabled == true }
    private var selectedModel: ChatGPTModel? { account.models.first { $0.id == store.settings.cloudModel } }
    private var reasoningChoices: [String] { selectedModel?.reasoningChoices ?? [] }
    private var knownProfiles: [ChatGPTProfile] {
        var profiles = account.savedProfiles
        if let profile = account.profile, !profiles.contains(where: { $0.id == profile.id }) { profiles.append(profile) }
        return profiles
    }
    private var selectedAccount: Binding<String> {
        Binding(get: { store.settings.chatGPTAccountID }, set: { id in
            guard id != store.settings.chatGPTAccountID else { return }
            store.settings.chatGPTAccountID = id
            store.settings.cloudModel = ""
            store.clearCloudConnectionResult()
            startSignIn(accountID: id)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountCard
            if let message = account.message, !message.isEmpty, account.isError || !usesPlan {
                Label(message, systemImage: account.isError ? "exclamationmark.triangle" : "info.circle")
                    .font(AppTypography.caption)
                    .foregroundStyle(account.isError ? Ink.warning : Ink.secondaryText)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("chatgpt.account.message").chatGPTUIAnchor("chatgpt.account.message")
                if account.isError, usesPlan, account.models.isEmpty {
                    Button(L("Войти заново")) { startSignIn(accountID: store.settings.chatGPTAccountID) }
                        .buttonStyle(.bordered).disabled(account.isConnecting || account.isSigningOut)
                        .accessibilityIdentifier("chatgpt.account.reconnect").chatGPTUIAnchor("chatgpt.account.reconnect")
                }
            }
            if usesPlan {
                modelSettings
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button(L("Проверить подключение")) { store.checkCloudConnection() }
                        .buttonStyle(.bordered).chatGPTUIAnchor("chatgpt.connection.check")
                        .disabled(selectedModel == nil || account.isLoadingModels || account.isConnecting || store.busy)
                        .help(L("Короткий запрос без текста и записей встреч. Использует лимиты ChatGPT."))
                        .accessibilityIdentifier("chatgpt.connection.check")
                    if let status = store.cloudConnectionStatus {
                        Text(status).font(AppTypography.caption)
                            .foregroundStyle(store.cloudConnectionError ? Ink.warning : Ink.green)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if store.cloudConnectionError, store.cloudConnectionDiagnostic != nil {
                        Button { store.copyCloudConnectionDiagnostic() } label: {
                            Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                        }.buttonStyle(.plain)
                            .help(L("Скопировать диагностику подключения без текста встреч и данных аккаунта"))
                            .accessibilityLabel(L("Скопировать диагностику"))
                            .accessibilityIdentifier("chatgpt.connection.copy-diagnostics")
                            .chatGPTUIAnchor("chatgpt.connection.copy-diagnostics")
                    }
                }
                Text(L("Для конспекта и карточек OpenAI получает текст встречи."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            catalogWasLoaded = !account.models.isEmpty
            if store.settings.chatGPTAccountID.isEmpty || isActiveAccount { adoptActiveProfile() }
            guard !store.isPreview, usesPlan, account.models.isEmpty, !account.isLoadingModels,
                  account.message == nil else { return }
            await account.refreshModels()
        }
        .onChange(of: account.profile?.id) { _, _ in
            // An asynchronously restored account must not replace a different
            // saved selection. Explicit sign-in adopts its verified result.
            if store.settings.chatGPTAccountID.isEmpty || isActiveAccount { adoptActiveProfile() }
        }
        .onChange(of: account.models) { _, models in
            if !models.isEmpty { catalogWasLoaded = true }
            validateModelSelection()
        }
        .onChange(of: account.isLoadingModels) { _, loading in
            if !loading { catalogWasLoaded = true; validateModelSelection() }
        }
        .onChange(of: store.settings.cloudModel) { _, _ in validateReasoningSelection() }
        .onDisappear {
            if signInTask != nil, account.isConnecting { account.cancelSignIn() }
            signInTask?.cancel()
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChatGPT").font(AppTypography.controlStrong)
                    if let profile = selectedProfile {
                        Text(profile.displayName).font(AppTypography.control)
                            .lineLimit(2).textSelection(.enabled)
                        if let email = profile.email, !email.isEmpty, email != profile.displayName {
                            Text(email).font(AppTypography.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        if let label = ChatGPTConnectionLabels.connection(for: profile, among: knownProfiles) {
                            Text(label).font(AppTypography.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("chatgpt.account.connection").chatGPTUIAnchor("chatgpt.account.connection")
                        }
                    } else {
                        Text(L("Используйте свою подписку для конспектов и карточек."))
                            .font(AppTypography.control).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isActiveAccount && !account.isConnecting {
                    Menu {
                        Button(L("Сменить аккаунт…")) { startSignIn(useDifferentAccount: true) }
                        Button(L("Выйти"), role: .destructive, action: disconnectAccount)
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(L("Действия с аккаунтом ChatGPT"))
                }
            }
            if account.savedProfiles.count > 1 {
                Picker(L("Аккаунт"), selection: selectedAccount) {
                    if !account.savedProfiles.contains(where: { $0.id == store.settings.chatGPTAccountID }) {
                        Text(L("Выберите аккаунт")).tag(store.settings.chatGPTAccountID)
                    }
                    ForEach(account.savedProfiles) { profile in
                        Text(ChatGPTConnectionLabels.title(for: profile, among: knownProfiles)).tag(profile.id)
                    }
                }.disabled(account.isConnecting)
                    .accessibilityIdentifier("chatgpt.account.picker").chatGPTUIAnchor("chatgpt.account.picker")
            }
            if account.isConnecting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(L("Завершите вход в браузере")).font(AppTypography.control)
                    Spacer(minLength: 8)
                    Button(L("Отменить")) { account.cancelSignIn(); signInTask?.cancel() }
                        .buttonStyle(.bordered)
                }.accessibilityIdentifier("chatgpt.account.connecting").chatGPTUIAnchor("chatgpt.account.connecting")
            } else if account.isSigningOut || isDisconnecting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(L("Выход из аккаунта…")).font(AppTypography.control)
                }
            } else if usesPlan {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(L("Используется подписка ChatGPT"), systemImage: "checkmark.circle")
                        .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                    Spacer(minLength: 0)
                    usageLink
                }.accessibilityIdentifier("chatgpt.account.plan").chatGPTUIAnchor("chatgpt.account.plan")
            } else {
                Text(L("В браузере выберите личный аккаунт и разрешите «После» использовать подписку."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Continue with ChatGPT") {
                        if let profile = selectedProfile { startSignIn(accountID: profile.id) }
                        else { startSignIn(useDifferentAccount: true) }
                    }
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .accessibilityLabel(L("Continue with ChatGPT — продолжить вход через ChatGPT"))
                    .accessibilityIdentifier("chatgpt.account.sign-in").chatGPTUIAnchor("chatgpt.account.sign-in")
                    if isActiveAccount { usageLink }
                }
            }
        }
        .disabled(account.isSigningOut || isDisconnecting)
        .padding(16).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt.account.card").chatGPTUIAnchor("chatgpt.account.card")
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker(L("Модель"), selection: $store.settings.cloudModel) {
                    if !store.settings.cloudModel.isEmpty, selectedModel == nil {
                        Text(L("Проверяем выбранную модель…")).tag(store.settings.cloudModel)
                    }
                    Text(account.isLoadingModels ? L("Загрузка моделей…") : L("Выберите модель")).tag("")
                    ForEach(account.models) { model in Text(model.name).tag(model.id) }
                }
                .chatGPTUIAnchor("chatgpt.model.picker")
                .disabled(account.models.isEmpty || account.isLoadingModels)
                .accessibilityLabel(L("Модель по подписке ChatGPT для конспекта и карточек"))
                .accessibilityIdentifier("chatgpt.model.picker")
                if account.isLoadingModels {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24)
                        .accessibilityLabel(L("Загрузка доступных моделей ChatGPT"))
                } else {
                    Button { Task { await account.refreshModels() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                    }.buttonStyle(.plain).help(L("Обновить доступные модели"))
                        .accessibilityLabel(L("Обновить доступные модели ChatGPT"))
                        .accessibilityIdentifier("chatgpt.models.refresh").chatGPTUIAnchor("chatgpt.models.refresh")
                }
            }
            if account.models.isEmpty && !account.isLoadingModels && !account.isError {
                Text(L("Модели пока недоступны. Обновите список или проверьте доступ в ChatGPT."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chatgpt.models.empty").chatGPTUIAnchor("chatgpt.models.empty")
            }
            if selectedModel != nil {
                if reasoningChoices.isEmpty {
                    LabeledContent(L("Рассуждения"), value: L("Как у модели"))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(L("Рассуждения"), selection: $store.settings.cloudReasoning) {
                        Text(L("Как у модели")).tag("auto")
                        ForEach(reasoningChoices, id: \.self) { effort in
                            Text(Self.reasoningTitle(effort)).tag(effort)
                        }
                    }.accessibilityIdentifier("chatgpt.reasoning.picker").chatGPTUIAnchor("chatgpt.reasoning.picker")
                        .help(L("Более глубокие рассуждения могут увеличить время ответа и расход лимитов подписки."))
                }
            }
            DisclosureGroup(L("Дополнительно")) {
                Picker(L("Формат ответа"), selection: $store.settings.cloudOutput) {
                    Text("JSON Schema").tag("schema")
                    Text("JSON").tag("json")
                    Text(L("JSON по инструкции")).tag("prompt")
                }
                .padding(.top, 8)
                .help(L("Если модель не поддерживает JSON Schema, выберите JSON или JSON по инструкции. «После» проверит структуру и ссылки на источники."))
            }
        }
    }

    private var usageLink: some View {
        Link(L("Управлять использованием"), destination: Self.usageURL)
            .font(AppTypography.caption)
            .accessibilityHint(L("Открыть лимиты и настройки подписки на сайте ChatGPT"))
    }

    private func startSignIn(accountID: String? = nil, useDifferentAccount: Bool = false) {
        guard !store.isPreview, !isDisconnecting, !account.isSigningOut else { return }
        signInTask?.cancel()
        let generation = UUID(); signInGeneration = generation
        store.clearCloudConnectionResult()
        signInTask = Task {
            defer {
                if signInGeneration == generation { signInTask = nil }
            }
            let previousID = account.profile?.id
            if let accountID { await account.signIn(accountID: accountID) }
            else { await account.signIn(useDifferentAccount: useDifferentAccount) }
            guard !Task.isCancelled, let profile = account.profile,
                  !useDifferentAccount || profile.id != previousID,
                  accountID == nil || profile.id == accountID else { return }
            adoptActiveProfile()
        }
    }

    private func disconnectAccount() {
        guard !store.isPreview, !isDisconnecting else { return }
        signInTask?.cancel()
        isDisconnecting = true
        // Logout continues if settings close: matching jobs must stop before
        // their account credentials are removed.
        Task {
            defer { isDisconnecting = false }
            await store.disconnectChatGPTAccount(account)
            store.clearCloudConnectionResult()
        }
    }

    private func adoptActiveProfile() {
        guard let profile = account.profile else { return }
        if store.settings.chatGPTAccountID != profile.id {
            store.settings.chatGPTAccountID = profile.id
            store.settings.cloudModel = ""
            store.clearCloudConnectionResult()
        }
        validateModelSelection()
    }

    private func validateModelSelection() {
        guard usesPlan, !account.isLoadingModels else { return }
        if catalogWasLoaded, !store.settings.cloudModel.isEmpty, selectedModel == nil { store.settings.cloudModel = "" }
        validateReasoningSelection()
    }

    private func validateReasoningSelection() {
        guard selectedModel != nil else { return }
        if reasoningChoices.isEmpty {
            store.settings.cloudReasoning = "auto"
        } else if store.settings.cloudReasoning != "auto", !reasoningChoices.contains(store.settings.cloudReasoning) {
            store.settings.cloudReasoning = reasoningChoices.contains("none") ? "none" : "auto"
        }
    }

    private static func reasoningTitle(_ effort: String) -> String {
        switch effort {
        case "none": L("Без рассуждений")
        case "minimal": L("Минимальные")
        case "low": L("Неглубокие")
        case "medium": L("Средние")
        case "high": L("Глубокие")
        case "xhigh": L("Очень глубокие")
        case "max": L("Максимальные")
        default: effort
        }
    }
}

/// Registrations may share an email without representing the same connection.
/// Add a local, stable label only when their visible identities collide.
enum ChatGPTConnectionLabels {
    static func title(for profile: ChatGPTProfile, among profiles: [ChatGPTProfile]) -> String {
        let base = identity(profile)
        guard let connection = connection(for: profile, among: profiles) else { return base }
        return base + " · " + connection
    }
    static func connection(for profile: ChatGPTProfile, among profiles: [ChatGPTProfile]) -> String? {
        let visibleIdentity = identity(profile).lowercased()
        let peers = Set(profiles.filter { identity($0).lowercased() == visibleIdentity }.map(\.id))
        guard peers.count > 1 else { return nil }
        var length = min(6, profile.id.count)
        while length < profile.id.count && peers.filter({ $0.prefix(length) == profile.id.prefix(length) }).count > 1 { length += 1 }
        return L("Подключение ") + profile.id.prefix(length)
    }
    private static func identity(_ profile: ChatGPTProfile) -> String {
        let email = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? profile.displayName : email
    }
}
