import AppKit
import PosleCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var keyMessage = ""
    @State private var keyMessageIsError = false
    @State private var editingCustomLocalModel = false
    @State private var customLocalModel = ""

    private var localModelPreset: Binding<String> {
        Binding {
            if editingCustomLocalModel { return "custom" }
            switch store.settings.localModel {
            case AppSettings.qualityLocalModel: return "quality"
            case AppSettings.fastLocalModel: return "fast"
            default: return "custom"
            }
        } set: { preset in
            let current = store.settings.localModel
            if editingCustomLocalModel || !isPresetModel(current) {
                customLocalModel = current
            }
            switch preset {
            case "quality":
                editingCustomLocalModel = false
                store.settings.localModel = AppSettings.qualityLocalModel
            case "fast":
                editingCustomLocalModel = false
                store.settings.localModel = AppSettings.fastLocalModel
            default:
                editingCustomLocalModel = true
                if !customLocalModel.isEmpty { store.settings.localModel = customLocalModel }
            }
        }
    }

    private func isPresetModel(_ model: String) -> Bool {
        model == AppSettings.qualityLocalModel || model == AppSettings.fastLocalModel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Настройки После").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Распознавание, конспекты и ваши данные.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.saveSettings(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).background(Ink.soft, in: Circle())
                }
                    .buttonStyle(.plain).accessibilityLabel("Сохранить и закрыть настройки")
                    .help("Сохранить и закрыть").keyboardShortcut(.cancelAction)
            }.padding(26)
            Divider()
            if store.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(store.progressText.isEmpty ? "Выполняется задача…" : store.progressText).font(.system(size: 12)).lineLimit(3)
                    Spacer()
                }.padding(16).accessibilityElement(children: .combine)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Ink.warning).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.vertical, 10)
                    .accessibilityLabel("Ошибка: \(error)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    settingsSection("Распознавание речи", "waveform") {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.runtimeReady ? "Распознавание готово" : "Подготовьте распознавание").fontWeight(.medium)
                                Text("Русский и английский определяются автоматически. Модели загружаются один раз; затем транскрипт можно создавать офлайн.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            }
                            Spacer()
                            if store.runtimeReady {
                                Button("Переустановить модели") { store.installRuntime() }.buttonStyle(.bordered)
                                    .help("Повторно подготовить распознавание речи и разделение собеседников")
                            } else {
                                Button("Установить модели") { store.installRuntime() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                            }
                        }
                        Toggle("Разделять собеседников", isOn: $store.settings.diarization).tint(Ink.actionFill)
                        HStack {
                            Text("Количество собеседников")
                            Spacer()
                            Picker("Количество собеседников", selection: $store.settings.speakerCount) {
                                Text("Определить автоматически").tag(0)
                                ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                            }.labelsHidden().frame(width: 220)
                                .accessibilityLabel("Количество собеседников")
                        }.disabled(!store.settings.diarization)
                        Text("Если голоса путаются, укажите число участников и создайте транскрипт заново.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    settingsSection("Конспект и примеры", "sparkles") {
                        Picker("Где работает ИИ", selection: $store.settings.mode) {
                            Label("На Mac", systemImage: "laptopcomputer").tag("local")
                            Label("Облако", systemImage: "cloud").tag("cloud")
                        }.pickerStyle(.segmented).tint(Ink.actionFill)
                        if store.settings.mode == "local" {
                            Text("Транскрипт и карточки обрабатываются на вашем Mac. Обе модели подходят для русского и английского.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            Picker("Локальная модель", selection: localModelPreset) {
                                Text("Качество · Qwen3.5 9B (6,6 ГБ)").tag("quality")
                                Text("Быстрее · Qwen3.5 4B (3,3 ГБ)").tag("fast")
                                Text("Своя модель").tag("custom")
                            }
                            if localModelPreset.wrappedValue == "custom" {
                                LabeledContent("Имя своей модели") {
                                    TextField("Имя модели в Ollama", text: $store.settings.localModel).textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Имя своей локальной модели")
                                        .help("Укажите имя из каталога Ollama или локальную модель, которую установили самостоятельно.")
                                }
                            }
                            HStack {
                                Button("Подготовить локальный ИИ") { store.prepareLocal() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(!store.runtimeReady)
                                Button("Проверить локальный ИИ") { store.ollama("check") }.buttonStyle(.bordered).disabled(!store.runtimeReady)
                            }
                            Text("Для Air с 16 ГБ модели запускаются по очереди. Цифры в списке показывают размер скачивания; память также нужна macOS и тексту встречи. Выбранная модель загружается один раз, затем работает офлайн.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                            if !store.localStatus.isEmpty { Text(store.localStatus).font(.system(size: 12)).foregroundStyle(Ink.accent).textSelection(.enabled) }
                            Toggle("Создавать конспект после транскрипта", isOn: $store.settings.autoSummary).tint(Ink.actionFill)
                        } else {
                            Text("Для конспекта OpenAI получает транскрипт, для примера — одну карточку с контекстом. Аудио остаётся на Mac. Каждый облачный запрос запускается отдельной кнопкой.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            LabeledContent("Модель OpenAI") {
                                TextField("Имя модели", text: $store.settings.cloudModel).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Модель OpenAI для конспекта и примеров")
                            }
                            LabeledContent("API-ключ OpenAI") {
                                SecureField("API-ключ", text: $apiKey).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("API-ключ OpenAI")
                            }
                            Button("Сохранить ключ в macOS") {
                                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                do {
                                    try Keychain.save(key)
                                    keyMessageIsError = false
                                    keyMessage = key.isEmpty ? "API-ключ удалён" : "API-ключ сохранён в Связке ключей macOS"
                                } catch {
                                    keyMessageIsError = true
                                    keyMessage = error.localizedDescription
                                }
                            }.buttonStyle(.bordered).help("Пустое поле удалит сохранённый API-ключ")
                            if !keyMessage.isEmpty {
                                Label(keyMessage, systemImage: keyMessageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                                    .font(.system(size: 11)).foregroundStyle(keyMessageIsError ? Ink.warning : Ink.green)
                            }
                            Text("Подписка ChatGPT не включает API. Стоимость запросов зависит от модели и длины текста.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Picker("Язык конспекта", selection: $store.settings.language) {
                            Text("Русский").tag("ru"); Text("English").tag("en")
                        }.frame(maxWidth: 340)
                    }
                    settingsSection("На что обращать внимание", "pin") {
                        Text("Этот фокус будет использоваться для новых встреч. Его можно изменить отдельно в конспекте каждой встречи.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextEditor(text: $store.settings.focus).font(.system(size: 12)).frame(height: 80).padding(8)
                            .scrollContentBackground(.hidden)
                            .background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
                            .accessibilityLabel("Фокус конспекта")
                            .accessibilityHint("Что выписывать из встречи: решения, задачи, детали и темы для карточек")
                    }
                    settingsSection("Ваши данные", "lock") {
                        Text("Записи, транскрипты, конспекты и история повторений хранятся в папке приложения.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        Button("Открыть папку данных") { NSWorkspace.shared.open(store.root) }.buttonStyle(.bordered)
                        Text("После 0.2 · Apple Silicon · macOS 15+").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 12)).padding(26).disabled(store.busy || store.isRecording)
            }
            Divider()
            HStack {
                Text("Примеры ИИ отмечены отдельно от цитат транскрипта.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Сохранить и закрыть") { store.saveSettings(); dismiss() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.defaultAction)
            }.padding(18)
        }.frame(width: 710).frame(minHeight: 560, idealHeight: 680, maxHeight: 760).tint(Ink.accent)
            .onAppear {
                apiKey = ProcessInfo.processInfo.arguments.contains("--preview") ? "" : Keychain.read()
                editingCustomLocalModel = !isPresetModel(store.settings.localModel)
                customLocalModel = editingCustomLocalModel ? store.settings.localModel : ""
            }
            .onDisappear { store.saveSettings() }
    }

    private func settingsSection<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 20).overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

struct RecordView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var systemAudio = true
    @State private var video = false
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Label("Новая встреча", systemImage: "record.circle").font(.system(size: 26, weight: .semibold, design: .rounded))
            TextField("Название встречи", text: $title).textFieldStyle(.roundedBorder).controlSize(.large)
                .accessibilityLabel("Название новой встречи")
            Picker("Источник звука", selection: $systemAudio) {
                Text("Звонок: микрофон и звук Mac").tag(true)
                Text("Встреча в комнате: только микрофон").tag(false)
            }.pickerStyle(.radioGroup).tint(Ink.actionFill)
            Toggle("Также сохранить видео экрана", isOn: $video).tint(Ink.actionFill)
            if video {
                Text("MP4 · H.264 · до 720p · 30 кадров/с · около 0,5 ГБ в час. Запишется основной экран, включая видимые на нём окна.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }
            Text(systemAudio ? "Запишутся ваш микрофон и звук приложений: Zoom, Meet, Teams и других. Для чистого разделения используйте наушники."
                 : "Запишется выбранный в macOS микрофон. Поставьте ноутбук ближе к участникам.")
                .font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary)
            Label(video ? "MP4 с видео и отдельный MP3" : "Итоговая запись — MP3, только аудио", systemImage: video ? "video" : "waveform").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.accent)
            if !store.runtimeReady {
                Text("Подготовьте модели в настройках, чтобы записывать встречи и создавать транскрипты.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Label("Убедитесь, что участники знают о записи.", systemImage: "person.2").font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Ink.warning).textSelection(.enabled)
                    .accessibilityLabel("Ошибка: \(error)")
            }
            if store.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(store.progressText.isEmpty ? "Подготавливаю запись…" : store.progressText).font(.system(size: 12))
                }.accessibilityElement(children: .combine)
            }
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.buttonStyle(.bordered).disabled(store.busy).keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.runtimeReady ? "Начать запись" : "Установить модели") {
                    if store.runtimeReady { Task { await store.startRecording(systemAudio: systemAudio, video: video, title: title) } }
                    else { dismiss(); store.showingSettings = true }
                }
                    .buttonStyle(.borderedProminent).tint(store.runtimeReady ? Ink.recordFill : Ink.actionFill).disabled(store.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 570).tint(Ink.accent)
    }
}
