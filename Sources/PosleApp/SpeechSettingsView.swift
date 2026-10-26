import AppKit
import PosleCore
import SwiftUI

struct SpeechSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var key = ""
    @State private var savedKey = ""
    @State private var keyMessage = ""
    @State private var keyFailed = false
    private var lacksSpeakerTiming: Bool { store.settings.speechMode == "cloud" && store.settings.speechResponseFormat == "json" }
    private var preview: Bool { ProcessInfo.processInfo.arguments.contains("--preview") }
    private var selected: SpeechModelPreset { SpeechModelPreset.catalog.first { $0.id == store.settings.speechLocalModel } ?? SpeechModelPreset.catalog[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Распознавание речи", systemImage: "waveform").font(AppTypography.heading)
            Picker("Обработка", selection: $store.settings.speechMode) {
                Label("На Mac", systemImage: "laptopcomputer").tag("local")
                Label("Облако", systemImage: "cloud").tag("cloud")
            }.pickerStyle(.segmented).tint(Ink.actionFill)
            if store.settings.speechMode == "local" { localSettings } else { cloudSettings }
            Divider()
            Toggle("Разделять собеседников", isOn: $store.settings.diarization)
                .disabled(lacksSpeakerTiming).help(lacksSpeakerTiming ? "Ответ без таймкодов не позволяет точно разделить реплики." : "Разделять реплики по голосам.")
            HStack {
                Text("Участников по умолчанию")
                Spacer()
                Picker("Участников по умолчанию", selection: $store.settings.speakerCount) {
                    Text("Автоматически").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }.labelsHidden().frame(width: 170)
                    .help("Включая вас. Число можно уточнить отдельно для готовой встречи.")
            }.disabled(!store.settings.diarization || lacksSpeakerTiming)
            if store.settings.speechMode == "cloud", store.settings.diarization, store.settings.speechResponseFormat == "verbose_json" {
                Text("Для ответа с таймкодами без меток голосов используется локальное разделение. Его компоненты нужно установить на Mac.")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
        }.onAppear(perform: loadKey)
            .onChange(of: store.settings.speechKeyAccount) { _, _ in loadKey() }
    }
    private var localSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Модель", selection: Binding(get: { store.settings.speechLocalModel }, set: { model in
                store.settings.speechLocalModel = model
                store.settings.asrModelPath = ""; store.settings.asrModelFormat = "auto"
                store.saveSettings()
            })) {
                ForEach(SpeechModelPreset.catalog) { model in Text("\(model.name) · \(model.sizeLabel)").tag(model.id) }
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.detail).font(AppTypography.caption).foregroundStyle(.secondary)
                    Label(store.selectedASRVerified ? "Готова" : "Не проверена", systemImage: store.selectedASRVerified ? "checkmark.circle" : "circle.dashed")
                        .font(AppTypography.captionStrong).foregroundStyle(store.selectedASRVerified ? Ink.green : Color.secondary)
                }
                Spacer()
                Button(store.selectedASRVerified ? "Проверить" : "Скачать / проверить") { store.installRuntime() }
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill)
            }
            Text("Размер загрузки. Компоненты обработки устанавливаются отдельно.")
                .font(AppTypography.caption).foregroundStyle(.secondary)
            if !store.settings.asrModelPath.isEmpty {
                Label(URL(fileURLWithPath: store.settings.asrModelPath).lastPathComponent, systemImage: "folder")
                    .font(AppTypography.captionStrong).lineLimit(1).help(store.settings.asrModelPath)
                Button("Использовать модель из каталога") { store.useAutomaticASRModel() }.buttonStyle(.link)
            }
            DisclosureGroup("Использовать скачанную модель") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Найти на Mac") { store.discoverASRModels() }.buttonStyle(.bordered)
                        Button("Выбрать папку…") { store.chooseASRFolder() }.buttonStyle(.bordered)
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
                                Button(model.path == store.settings.asrModelPath ? "Выбрано" : "Использовать") { store.selectASRModel(model) }
                                    .buttonStyle(.bordered).disabled(model.path == store.settings.asrModelPath)
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
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Label(store.runtimeReady ? "Компоненты аудио готовы" : "Требуется подготовка аудио",
                          systemImage: store.runtimeReady ? "checkmark.circle" : "arrow.down.circle")
                        .font(AppTypography.captionStrong).foregroundStyle(store.runtimeReady ? Ink.green : Color.secondary)
                    Spacer(minLength: 4)
                    Button(store.runtimeReady ? "Проверить компоненты" : "Подготовить компоненты на Mac") { store.installRuntime() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("speech.cloud.prepare-audio")
                        .appLayoutAnchor("speech.cloud.prepare-audio")
                        .disabled(store.busy || store.isRecording)
                }
                Text("Нужны для подготовки аудио перед отправкой сервису.")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }.padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
            Picker("Сервис", selection: Binding(get: { store.settings.speechCloudProvider }, set: { provider in
                store.settings.speechCloudProvider = provider
                if provider == "openai" { store.settings.speechCloudModel = "gpt-transcribe"; store.settings.speechResponseFormat = "json" }
            })) {
                Text("OpenAI").tag("openai")
                Text("Совместимый API").tag("custom")
            }
            if store.settings.speechCloudProvider == "custom" {
                LabeledContent("Адрес API") {
                    TextField("https://example.com/v1", text: $store.settings.speechCloudEndpoint)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        .accessibilityLabel("Базовый адрес API распознавания")
                }
                Text("Нужен API /audio/transcriptions. Поддержка текстовых моделей сама по себе не означает поддержку аудио.")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Модель") {
                TextField("ID модели у сервиса", text: $store.settings.speechCloudModel)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .accessibilityLabel("Облачная модель распознавания")
            }
            LabeledContent("API-ключ") {
                SecureField("Ключ выбранного сервиса", text: $key).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("API-ключ распознавания")
            }
            HStack(spacing: 10) {
                Button(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !savedKey.isEmpty ? "Удалить ключ" : "Сохранить ключ") { saveKey() }
                    .buttonStyle(.bordered).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines) == savedKey)
                if key.trimmingCharacters(in: .whitespacesAndNewlines) != savedKey {
                    Text("Не сохранён").font(AppTypography.caption).foregroundStyle(Ink.warning)
                } else if !keyMessage.isEmpty {
                    Text(keyMessage).font(AppTypography.caption).foregroundStyle(keyFailed ? Ink.warning : Ink.green)
                }
            }
            DisclosureGroup("Дополнительно") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Ответ сервиса", selection: $store.settings.speechResponseFormat) {
                        Text("JSON — текст").tag("json")
                        Text("Verbose JSON — таймкоды").tag("verbose_json")
                        Text("Diarized JSON — собеседники").tag("diarized_json")
                    }.help("Выбранная модель должна поддерживать этот формат ответа. Совместимость зависит от сервиса.")
                    Text("Выберите формат, который поддерживает модель: таймкоды — для точных ссылок, метки голосов — для разделения собеседников сервисом.")
                        .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }
            if store.settings.speechResponseFormat == "json" {
                Text("Без таймкодов: ссылки ведут к началу минутных фрагментов. Точно разделить реплики и собеседников по такому ответу нельзя.")
                    .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Язык записи", selection: $store.settings.speechLanguage) {
                Text("Определять автоматически").tag("auto")
                Text("Русский").tag("ru")
                Text("Английский").tag("en")
            }
            Label("Аудиозапись отправляется на \(store.settings.speechDestinationLabel). Оплата — по тарифам сервиса.", systemImage: "cloud")
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func loadKey() {
        key = preview ? "" : Keychain.read(account: Keychain.speechAccount(for: store.settings))
        savedKey = key; keyMessage = ""; keyFailed = false
    }
    private func saveKey() {
        guard !preview else { return }
        do {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try Keychain.save(value, account: Keychain.speechAccount(for: store.settings))
            key = value; savedKey = value; keyMessage = value.isEmpty ? "Ключ удалён" : "Ключ сохранён"; keyFailed = false
            store.saveSettings()
        } catch { keyMessage = error.localizedDescription; keyFailed = true }
    }
}
