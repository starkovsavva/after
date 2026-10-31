import AfterPlatformMacOS
import AfterLocalization
import AfterCore
import SwiftUI

/// A key draft belongs to its exact endpoint account, including while the URL
/// is being edited. Changing providers never silently forwards another key.
struct CloudSettingsView: View {
    @EnvironmentObject private var store: AppStore
    var chatGPTAccount: ChatGPTAccount = .shared
    @State private var editorID = UUID()
    @State private var mounted = false
    @State private var drafts: [String: String] = [:]
    @State private var savedKeys: [String: String] = [:]
    @State private var loadedAccounts: Set<String> = []
    @State private var keyMessage = ""
    @State private var keyError = false

    private var account: String? {
        guard store.settings.cloudProvider != "chatgpt",
              store.settings.validatedCloudEndpoint() != nil else { return nil }
        return Keychain.account(for: store.settings)
    }
    private var key: String { account.flatMap { drafts[$0] } ?? "" }
    private var savedKey: String { account.flatMap { savedKeys[$0] } ?? "" }
    private var keyIsDirty: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines) != savedKey }
    private var hasPendingKeys: Bool {
        drafts.contains { account, value in value.trimmingCharacters(in: .whitespacesAndNewlines) != (savedKeys[account] ?? "") }
    }
    private func registerDrafts() {
        guard mounted else { return }
        SettingsDraftRegistry.set(id: editorID, title: L("API-ключи конспекта"), dirty: hasPendingKeys)
    }
    private var keyBinding: Binding<String> {
        Binding(get: { key }, set: { value in
            if let account { drafts[account] = value; keyMessage = ""; store.clearCloudConnectionResult(); registerDrafts() }
        })
    }
    private var configuration: String {
        [store.settings.cloudProvider, store.settings.resolvedCloudEndpoint, store.settings.cloudModel,
         store.settings.cloudAPI, store.settings.cloudOutput, store.settings.chatGPTAccountID,
         store.settings.cloudReasoning].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker(L("Провайдер"), selection: Binding(get: { store.settings.cloudProvider }, set: {
                store.settings.switchCloudProvider($0)
            })) {
                Text(L("ChatGPT (подписка)")).tag("chatgpt")
                Text("OpenAI API").tag("openai")
                Text("OpenRouter").tag("openrouter")
                Text("Polza").tag("polza")
                Text(L("Свой провайдер")).tag("custom")
            }
            if store.settings.cloudProvider == "chatgpt" {
                ChatGPTSettingsView(account: chatGPTAccount)
            } else {
                apiSettings
            }
            if hasPendingKeys {
                Button(L("Отменить правки ключей")) { drafts = savedKeys; keyMessage = ""; registerDrafts() }
                    .buttonStyle(.bordered).accessibilityIdentifier("cloud.key.cancel")
            }
        }
        .onAppear { mounted = true; loadAccount(); registerDrafts() }
        .onChange(of: drafts) { _, _ in registerDrafts() }
        .onChange(of: savedKeys) { _, _ in registerDrafts() }
        .onDisappear { mounted = false; SettingsDraftRegistry.remove(id: editorID) }
        .onChange(of: account) { _, _ in keyMessage = ""; keyError = false; loadAccount() }
        .onChange(of: configuration) { _, _ in store.clearCloudConnectionResult() }
    }

    private var apiSettings: some View {
        Group {
            if store.settings.cloudProvider == "custom" {
                LabeledContent(L("Адрес API")) {
                    TextField("https://example.com/v1", text: $store.settings.cloudEndpoint)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(L("Базовый адрес облачного API"))
                        .help(L("Базовый URL совместимого API, включая /v1 при необходимости. HTTPS; HTTP разрешён только на localhost."))
                }
                if !store.settings.cloudEndpoint.isEmpty && account == nil {
                    Text(L("Нужен HTTPS-адрес без логина, пароля и параметров."))
                        .font(AppTypography.caption).foregroundStyle(Ink.warning)
                }
            } else {
                LabeledContent(L("Адрес API")) {
                    Text(store.settings.resolvedCloudEndpoint).font(AppTypography.caption)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(store.settings.resolvedCloudEndpoint)
                }
            }
            LabeledContent(L("Модель")) {
                TextField(L("ID модели у провайдера"), text: $store.settings.cloudModel)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(L("Облачная модель для конспекта и карточек"))
            }
            LabeledContent(L("API-ключ")) {
                SecureField(account == nil ? L("Сначала укажите адрес API") : L("Ключ выбранного провайдера"), text: keyBinding)
                    .textFieldStyle(.roundedBorder).disabled(account == nil)
                    .accessibilityLabel(LF("API-ключ {0}", arguments: [String(describing: (store.settings.cloudProviderTitle))])).accessibilityIdentifier("cloud.key")
            }
            HStack(spacing: 10) {
                Button(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !savedKey.isEmpty ? L("Удалить ключ") : L("Сохранить ключ"), action: saveKey)
                    .buttonStyle(.bordered).disabled(account == nil || !keyIsDirty).accessibilityIdentifier("cloud.key.save")
                if keyIsDirty {
                    Text(L("Не сохранён")).font(AppTypography.caption).foregroundStyle(Ink.warning)
                } else if !keyMessage.isEmpty {
                    Label(keyMessage, systemImage: keyError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(AppTypography.caption).foregroundStyle(keyError ? Ink.warning : Ink.green)
                }
            }
            DisclosureGroup(L("Дополнительно")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("Формат API"), selection: $store.settings.cloudAPI) {
                        Text("Chat Completions").tag("chat")
                        Text("Responses").tag("responses")
                    }
                    Picker(L("Формат ответа"), selection: $store.settings.cloudOutput) {
                        Text("JSON Schema").tag("schema")
                        Text("JSON").tag("json")
                        Text(L("JSON по инструкции")).tag("prompt")
                    }.help(L("JSON Schema проверяет структуру у провайдера. Два других режима нужны для моделей без этой возможности; «After» продолжает проверять поля и ссылки на источники."))
                    if store.settings.cloudOutput != "schema" {
                        Text(L("Модель должна соблюдать структуру JSON. Неподходящий ответ не заменит ваши данные."))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 10)
            }
            HStack(spacing: 10) {
                Button(L("Проверить подключение")) { store.checkCloudConnection() }
                    .buttonStyle(.bordered)
                    .disabled(account == nil || keyIsDirty || savedKey.isEmpty || store.settings.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                    .help(L("Один короткий запрос {ok:true}, без текста и записей встреч. Провайдер может списать стоимость запроса."))
                if let status = store.cloudConnectionStatus {
                    Text(status).font(AppTypography.caption)
                        .foregroundStyle(store.cloudConnectionError ? Ink.warning : Ink.green)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Text(L("Для конспекта сервис получает текст встречи. API и проверка подключения оплачиваются по тарифу провайдера."))
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadAccount() {
        guard let account, !loadedAccounts.contains(account) else { return }
        let value = ProcessInfo.processInfo.arguments.contains("--preview") ? "" : Keychain.read(account: account)
        drafts[account] = value; savedKeys[account] = value; loadedAccounts.insert(account)
    }

    private func saveKey() {
        guard !ProcessInfo.processInfo.arguments.contains("--preview"), let account else { return }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.save(value, account: account)
            drafts[account] = value; savedKeys[account] = value
            keyError = false; keyMessage = value.isEmpty ? L("Ключ удалён") : L("Сохранён в Связке ключей")
            store.clearCloudConnectionResult()
        } catch {
            keyError = true; keyMessage = error.localizedDescription
        }
    }
}
