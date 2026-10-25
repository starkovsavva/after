import PosleCore
import SwiftUI

/// A key draft belongs to its exact endpoint account, including while the URL
/// is being edited. Changing providers never silently forwards another key.
struct CloudSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var drafts: [String: String] = [:]
    @State private var savedKeys: [String: String] = [:]
    @State private var loadedAccounts: Set<String> = []
    @State private var keyMessage = ""
    @State private var keyError = false

    private var account: String? {
        guard store.settings.validatedCloudEndpoint() != nil else { return nil }
        return Keychain.account(for: store.settings)
    }
    private var key: String { account.flatMap { drafts[$0] } ?? "" }
    private var savedKey: String { account.flatMap { savedKeys[$0] } ?? "" }
    private var keyIsDirty: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines) != savedKey }
    private var keyBinding: Binding<String> {
        Binding(get: { key }, set: { value in
            if let account { drafts[account] = value; keyMessage = ""; store.cloudConnectionStatus = nil }
        })
    }
    private var configuration: String {
        [store.settings.cloudProvider, store.settings.resolvedCloudEndpoint, store.settings.cloudModel,
         store.settings.cloudAPI, store.settings.cloudOutput].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Провайдер", selection: Binding(get: { store.settings.cloudProvider }, set: {
                store.settings.switchCloudProvider($0)
            })) {
                Text("OpenAI").tag("openai")
                Text("OpenRouter").tag("openrouter")
                Text("Polza").tag("polza")
                Text("Свой провайдер").tag("custom")
            }
            if store.settings.cloudProvider == "custom" {
                LabeledContent("Адрес API") {
                    TextField("https://example.com/v1", text: $store.settings.cloudEndpoint)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Базовый адрес облачного API")
                        .help("Базовый URL совместимого API, включая /v1 при необходимости. HTTPS; HTTP разрешён только на localhost.")
                }
                if !store.settings.cloudEndpoint.isEmpty && account == nil {
                    Text("Нужен HTTPS-адрес без логина, пароля и параметров.")
                        .font(AppTypography.caption).foregroundStyle(Ink.warning)
                }
            } else {
                LabeledContent("Адрес API") {
                    Text(store.settings.resolvedCloudEndpoint).font(AppTypography.caption)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(store.settings.resolvedCloudEndpoint)
                }
            }
            LabeledContent("Модель") {
                TextField("ID модели у провайдера", text: $store.settings.cloudModel)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Облачная модель для конспекта и карточек")
            }
            LabeledContent("API-ключ") {
                SecureField(account == nil ? "Сначала укажите адрес API" : "Ключ выбранного провайдера", text: keyBinding)
                    .textFieldStyle(.roundedBorder).disabled(account == nil)
                    .accessibilityLabel("API-ключ \(store.settings.cloudProviderTitle)")
            }
            HStack(spacing: 10) {
                Button(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !savedKey.isEmpty ? "Удалить ключ" : "Сохранить ключ", action: saveKey)
                    .buttonStyle(.bordered).disabled(account == nil || !keyIsDirty)
                if keyIsDirty {
                    Text("Не сохранён").font(AppTypography.caption).foregroundStyle(Ink.warning)
                } else if !keyMessage.isEmpty {
                    Label(keyMessage, systemImage: keyError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(AppTypography.caption).foregroundStyle(keyError ? Ink.warning : Ink.green)
                }
            }
            DisclosureGroup("Дополнительно") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Формат API", selection: $store.settings.cloudAPI) {
                        Text("Chat Completions").tag("chat")
                        Text("Responses").tag("responses")
                    }
                    Picker("Формат ответа", selection: $store.settings.cloudOutput) {
                        Text("JSON Schema").tag("schema")
                        Text("JSON").tag("json")
                        Text("JSON по инструкции").tag("prompt")
                    }.help("JSON Schema проверяет структуру у провайдера. Два других режима нужны для моделей без этой возможности; «После» продолжает проверять поля и ссылки на источники.")
                    if store.settings.cloudOutput != "schema" {
                        Text("Модель должна соблюдать структуру JSON. Неподходящий ответ не заменит ваши данные.")
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 10)
            }
            HStack(spacing: 10) {
                Button("Проверить подключение") { store.checkCloudConnection() }
                    .buttonStyle(.bordered)
                    .disabled(account == nil || keyIsDirty || savedKey.isEmpty || store.settings.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                    .help("Один короткий запрос {ok:true}, без текста и записей встреч. Провайдер может списать стоимость запроса.")
                if let status = store.cloudConnectionStatus {
                    Text(status).font(AppTypography.caption)
                        .foregroundStyle(store.cloudConnectionError ? Ink.warning : Ink.green)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Text("Для конспекта сервис получает текст встречи. API и проверка подключения оплачиваются по тарифу провайдера.")
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { loadAccount() }
        .onChange(of: account) { _, _ in keyMessage = ""; keyError = false; loadAccount() }
        .onChange(of: configuration) { _, _ in store.cloudConnectionStatus = nil }
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
            keyError = false; keyMessage = value.isEmpty ? "Ключ удалён" : "Сохранён в Связке ключей"
            store.cloudConnectionStatus = nil
        } catch {
            keyError = true; keyMessage = error.localizedDescription
        }
    }
}
