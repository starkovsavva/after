import AfterPlatformMacOS
import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

struct SpeechSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editorID = UUID()
    @State private var mounted = false
    @State private var drafts: [String: String] = [:]
    @State private var savedKeys: [String: String] = [:]
    @State private var loadedAccounts: Set<String> = []
    private var account: String { Keychain.speechAccount(for: store.settings) }
    private var key: String { drafts[account] ?? "" }
    private var savedKey: String { savedKeys[account] ?? "" }
    private var hasPendingKeys: Bool {
        drafts.contains { account, value in value.trimmingCharacters(in: .whitespacesAndNewlines) != (savedKeys[account] ?? "") }
    }
    private var keyBinding: Binding<String> {
        Binding(get: { key }, set: { value in drafts[account] = value; registerDrafts() })
    }
    private func registerDrafts() {
        guard mounted else { return }
        SettingsDraftRegistry.set(id: editorID, title: L("API-ключи распознавания"), dirty: hasPendingKeys)
    }
    @State private var keyMessage = ""
    @State private var keyFailed = false
    private var lacksSpeakerTiming: Bool { store.settings.speechMode == "cloud" && store.settings.speechResponseFormat == "json" }
    private var preview: Bool { ProcessInfo.processInfo.arguments.contains("--preview") }
    private var selected: SpeechModelPreset { SpeechModelPreset.catalog.first { $0.id == store.settings.speechLocalModel } ?? SpeechModelPreset.catalog[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("Распознавание речи"), systemImage: "waveform").font(AppTypography.heading)
            AfterChoicePicker(L("Обработка"), selection: $store.settings.speechMode,
                options: [.init(title: L("На Mac"), value: "local"), .init(title: L("Облако"), value: "cloud")], identifier: "speech.processingMode")
                .accessibilityIdentifier("speech.processingMode")
            if store.settings.speechMode == "local" { localSettings } else { cloudSettings }
            if hasPendingKeys {
                Button(L("Отменить правки ключей")) { drafts = savedKeys; keyMessage = ""; registerDrafts() }
                    .buttonStyle(AfterSoftButtonStyle()).accessibilityIdentifier("speech.key.cancel")
            }
            Divider()
            Toggle(L("Разделять собеседников"), isOn: $store.settings.diarization)
                .disabled(lacksSpeakerTiming).help(lacksSpeakerTiming ? L("Ответ без таймкодов не позволяет точно разделить реплики.") : L("Разделять реплики по голосам."))
            AfterCompactPicker(L("Участников по умолчанию"), selection: $store.settings.speakerCount,
                options: [.init(title: L("Автоматически"), value: 0)] + (1...10).map { .init(title: String($0), value: $0) })
                .help(L("Включая вас. Число можно уточнить отдельно для готовой встречи."))
                .disabled(!store.settings.diarization || lacksSpeakerTiming)
            if store.settings.speechMode == "cloud", store.settings.diarization, store.settings.speechResponseFormat == "verbose_json" {
                Text(L("Для ответа с таймкодами без меток голосов используется локальное разделение. Его компоненты нужно установить на Mac."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
        }.onAppear { mounted = true; loadKey(); registerDrafts() }
            .onChange(of: store.settings.speechKeyAccount) { _, _ in loadKey() }
            .onChange(of: drafts) { _, _ in registerDrafts() }
            .onChange(of: savedKeys) { _, _ in registerDrafts() }
            .onDisappear { mounted = false; SettingsDraftRegistry.remove(id: editorID) }
    }
    private var localSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            AfterCompactPicker(L("Модель"), selection: Binding(get: { store.settings.speechLocalModel }, set: { model in
                store.settings.speechLocalModel = model
                store.settings.asrModelPath = ""; store.settings.asrModelFormat = "auto"
                store.saveSettings()
            }), options: SpeechModelPreset.catalog.map { .init(title: "\($0.name) · \($0.sizeLabel)", value: $0.id) }, searchable: true)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(selected.detail)).font(AppTypography.caption).foregroundStyle(.secondary)
                    Label(store.selectedASRVerified ? L("Готова") : L("Не проверена"), systemImage: store.selectedASRVerified ? "checkmark.circle" : "circle.dashed")
                        .font(AppTypography.captionStrong).foregroundStyle(store.selectedASRVerified ? Ink.green : Color.secondary)
                }
                Spacer()
                Button(store.selectedASRVerified ? L("Проверить") : L("Скачать / проверить")) { store.installRuntime() }
                    .buttonStyle(AfterSoftButtonStyle(.primary)).tint(Ink.actionFill)
            }
            Text(L("Размер загрузки. Компоненты обработки устанавливаются отдельно."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            if !store.settings.asrModelPath.isEmpty {
                Label(URL(fileURLWithPath: store.settings.asrModelPath).lastPathComponent, systemImage: "folder")
                    .font(AppTypography.captionStrong).lineLimit(1).help(store.settings.asrModelPath)
                Button(L("Использовать модель из каталога")) { store.useAutomaticASRModel() }.buttonStyle(.link)
            }
            DisclosureGroup(L("Использовать скачанную модель")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(L("Найти на Mac")) { store.discoverASRModels() }.buttonStyle(AfterSoftButtonStyle())
                        Button(L("Выбрать папку…")) { store.chooseASRFolder() }.buttonStyle(AfterSoftButtonStyle())
                    }
                    if !store.asrStatus.isEmpty { Text(store.asrStatus).font(AppTypography.caption).foregroundStyle(.secondary) }
                    ForEach(store.installedASRModels) { model in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name).font(AppTypography.captionStrong).lineLimit(2)
                                Text(model.source + " · " + model.format.uppercased()).font(AppTypography.caption).foregroundStyle(.secondary)
                                Text(model.reason).font(AppTypography.caption).foregroundStyle(model.compatible ? Color.secondary : Ink.warning)
                            }
                            Spacer()
                            if model.compatible {
                                Button(model.path == store.settings.asrModelPath ? L("Выбрано") : L("Использовать")) { store.selectASRModel(model) }
                                    .buttonStyle(AfterSoftButtonStyle()).disabled(model.path == store.settings.asrModelPath)
                            }
                        }.padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(Array(store.asrNotes.enumerated()), id: \.offset) { _, note in Text(note).font(AppTypography.caption).foregroundStyle(.secondary) }
                }.padding(.top, 8)
            }
        }
    }
    private var cloudSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Облачное распознавание — через API-ключ сервиса. Подписка ChatGPT доступна для конспектов, карточек и помощника. Для работы без API-ключа выберите распознавание на Mac."))
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Label(store.runtimeReady ? L("Компоненты аудио готовы") : L("Требуется подготовка аудио"),
                          systemImage: store.runtimeReady ? "checkmark.circle" : "arrow.down.circle")
                        .font(AppTypography.captionStrong).foregroundStyle(store.runtimeReady ? Ink.green : Color.secondary)
                    Spacer(minLength: 4)
                    Button(store.runtimeReady ? L("Проверить компоненты") : L("Подготовить компоненты на Mac")) { store.installRuntime() }
                        .buttonStyle(AfterSoftButtonStyle())
                        .accessibilityIdentifier("speech.cloud.prepare-audio")
                        .appLayoutAnchor("speech.cloud.prepare-audio")
                        .disabled(store.busy || store.isRecording)
                }
                Text(L("Нужны для подготовки аудио перед отправкой сервису."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }.padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
            AfterCompactPicker(L("Сервис"), selection: Binding(get: { store.settings.speechCloudProvider }, set: { provider in
                store.settings.speechCloudProvider = provider
                if provider == "openai" { store.settings.speechCloudModel = "gpt-transcribe"; store.settings.speechResponseFormat = "json" }
            }), options: [.init(title: "OpenAI", value: "openai"), .init(title: L("Совместимый API"), value: "custom")])
            if store.settings.speechCloudProvider == "custom" {
                LabeledContent(L("Адрес API")) {
                    TextField("https://example.com/v1", text: $store.settings.speechCloudEndpoint)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        .accessibilityLabel(L("Базовый адрес API распознавания"))
                }
                Text(L("Нужен API /audio/transcriptions. Поддержка текстовых моделей сама по себе не означает поддержку аудио."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            LabeledContent(L("Модель")) {
                TextField(L("ID модели у сервиса"), text: $store.settings.speechCloudModel)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .accessibilityLabel(L("Облачная модель распознавания"))
            }
            LabeledContent(L("API-ключ")) {
                SecureField(L("Ключ выбранного сервиса"), text: keyBinding).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L("API-ключ распознавания")).accessibilityIdentifier("speech.key")
            }
            HStack(spacing: 10) {
                Button(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !savedKey.isEmpty ? L("Удалить ключ") : L("Сохранить ключ")) { saveKey() }
                    .buttonStyle(AfterSoftButtonStyle()).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines) == savedKey)
                if key.trimmingCharacters(in: .whitespacesAndNewlines) != savedKey {
                    Text(L("Не сохранён")).font(AppTypography.caption).foregroundStyle(Ink.warning)
                } else if !keyMessage.isEmpty {
                    Text(keyMessage).font(AppTypography.caption).foregroundStyle(keyFailed ? Ink.warning : Ink.green)
                }
            }
            DisclosureGroup(L("Дополнительно")) {
                VStack(alignment: .leading, spacing: 8) {
                    AfterCompactPicker(L("Ответ сервиса"), selection: $store.settings.speechResponseFormat, options: [
                        .init(title: L("JSON — текст"), value: "json"), .init(title: L("Verbose JSON — таймкоды"), value: "verbose_json"),
                        .init(title: L("Diarized JSON — собеседники"), value: "diarized_json")]).help(L("Выбранная модель должна поддерживать этот формат ответа. Совместимость зависит от сервиса."))
                    Text(L("Выберите формат, который поддерживает модель: таймкоды — для точных ссылок, метки голосов — для разделения собеседников сервисом."))
                        .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }
            if store.settings.speechResponseFormat == "json" {
                Text(L("Без таймкодов: ссылки ведут к началу минутных фрагментов. Точно разделить реплики и собеседников по такому ответу нельзя."))
                    .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            AfterCompactPicker(L("Язык записи"), selection: $store.settings.speechLanguage, options: [
                .init(title: L("Определять автоматически"), value: "auto"), .init(title: L("Русский"), value: "ru"), .init(title: L("Английский"), value: "en")])
            Label(LF("Аудиозапись отправляется на {0}. Оплата — по тарифам сервиса.", arguments: [L(store.settings.speechDestinationLabel)]), systemImage: "cloud")
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func loadKey() {
        guard !loadedAccounts.contains(account) else { return }
        let value = preview ? "" : Keychain.read(account: account)
        drafts[account] = value; savedKeys[account] = value; loadedAccounts.insert(account)
        keyMessage = ""; keyFailed = false; registerDrafts()
    }
    private func saveKey() {
        guard !preview else { return }
        do {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try Keychain.save(value, account: Keychain.speechAccount(for: store.settings))
            drafts[account] = value; savedKeys[account] = value; registerDrafts(); keyMessage = value.isEmpty ? L("Ключ удалён") : L("Ключ сохранён"); keyFailed = false
            store.saveSettings()
        } catch { keyMessage = error.localizedDescription; keyFailed = true }
    }
}
