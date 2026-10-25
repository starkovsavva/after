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

    @State private var section = "general"
    @State private var showingTemplates = false
    init(section: String = "general") { _section = State(initialValue: section) }
    private let sections: [(String, String, String)] = [
        ("general", "Общие", "gearshape"), ("record", "Запись", "record.circle"),
        ("speech", "Распознавание речи", "waveform"), ("ai", "Конспект и модели", "sparkles"),
        ("notes", "Заметки и шаблоны", "square.and.pencil"), ("keys", "Горячие клавиши", "keyboard"),
        ("data", "Данные и экспорт", "externaldrive")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Настройки После").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Button { store.saveSettings(); dismiss() } label: { Image(systemName: "xmark").padding(6) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Сохранить и закрыть настройки")
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(sections, id: \.0) { id, title, icon in
                        Button { section = id } label: {
                            Label(title, systemImage: icon).font(AppTypography.control)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 11)
                                .background(section == id ? Ink.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(section == id ? Ink.accent : Color.primary)
                        }.buttonStyle(.plain).accessibilityAddTraits(section == id ? .isSelected : [])
                    }
                    Spacer()
                    Text("После \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5")")
                        .font(AppTypography.caption).foregroundStyle(.secondary).padding(10)
                }.padding(12).frame(width: 215).background(Ink.soft)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if store.busy {
                            HStack { ProgressView().controlSize(.small); Text(store.progressText).font(AppTypography.control)
                                Spacer(); if store.canCancelJob { Button("Отменить") { store.cancelJob() } }
                            }
                        }
                        if let error = store.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(AppTypography.control)
                                .foregroundStyle(Ink.warning).textSelection(.enabled)
                        }
                        settingsContent
                    }.font(AppTypography.control).frame(maxWidth: .infinity, alignment: .leading).padding(26)
                }.frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Text("Изменения сохраняются при закрытии.").font(AppTypography.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { store.saveSettings(); dismiss() }.buttonStyle(.borderedProminent)
                    .tint(Ink.actionFill).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 900, height: 690).tint(Ink.accent)
            .sheet(isPresented: $showingTemplates) {
                VStack(spacing: 16) {
                    HStack { Spacer(); Button("Готово") { showingTemplates = false }.keyboardShortcut(.cancelAction) }
                    ScrollView { NotesTemplatesView(notes: store.notes).environmentObject(store) }
                }.padding(25).frame(width: 700, height: 600)
            }
            .onAppear {
                if !store.settings.defaultTemplateID.isEmpty && !store.notes.templates.contains(where: { $0.id == store.settings.defaultTemplateID }) { store.settings.defaultTemplateID = "" }
                apiKey = ProcessInfo.processInfo.arguments.contains("--preview") ? "" : Keychain.read()
                editingCustomLocalModel = !isPresetModel(store.settings.localModel)
                customLocalModel = editingCustomLocalModel ? store.settings.localModel : ""
            }
            .onChange(of: store.settings.localProvider) { _, _ in
                editingCustomLocalModel = !isPresetModel(store.settings.localModel)
                customLocalModel = editingCustomLocalModel ? store.settings.localModel : ""
            }
            .onChange(of: store.settings.localModel) { _, model in
                editingCustomLocalModel = !isPresetModel(model)
                if editingCustomLocalModel { customLocalModel = model }
            }
            .onDisappear { store.saveSettings() }
    }
    @ViewBuilder private var settingsContent: some View {
        switch section {
        case "speech": speechSettings.disabled(store.busy || store.isRecording)
        case "ai": aiSettings.disabled(store.busy || store.isRecording)
        case "record": recordSettings.disabled(store.isRecording)
        case "notes": notesSettings
        case "keys": shortcutSettings
        case "data": dataSettings
        default: generalSettings
        }
    }
    private var generalSettings: some View {
        settingsSection("Общие", "gearshape") {
            Text("Встречи, короткие мысли и повторение карточек в одном месте.").foregroundStyle(.secondary)
            Picker("При запуске открывать", selection: $store.settings.startSection) {
                Text("Все встречи").tag("meetings"); Text("Входящие заметки").tag("inbox")
                Text("Мои задачи").tag("tasks"); Text("Карточки").tag("cards")
            }
            Text("Быстрые заметки доступны без подготовки моделей. Распознавание речи и ИИ можно настроить отдельно.")
                .font(AppTypography.caption).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private var recordSettings: some View {
        settingsSection("Запись", "record.circle") {
            Toggle("По умолчанию записывать звук Mac", isOn: $store.settings.recordSystemAudio)
            Toggle("По умолчанию сохранять видео", isOn: $store.settings.recordVideo)
            Text("Аудио сохраняется в MP3. Видео — MP4, H.264, до 720p, 30 кадров/с. Выбор можно изменить перед каждой встречей.")
                .font(AppTypography.caption).foregroundStyle(.secondary).lineSpacing(4)
            Text("Во время записи можно добавлять заметки и отмечать важные моменты. Для разделения голосов в звонке используйте наушники.")
                .font(AppTypography.caption).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private var notesSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("Заметки и шаблоны", "square.and.pencil") {
                Toggle("Прикреплять быстрые заметки к текущей записи", isOn: $store.settings.notesSaveToActiveMeeting)
                Toggle("Добавлять таймкод к пометкам", isOn: $store.settings.notesAutoTimestamp)
                Picker("Шаблон новых заметок встречи", selection: $store.settings.defaultTemplateID) {
                    Text("Чистая заметка").tag("")
                    ForEach(store.notes.templates) { Text($0.name).tag($0.id) }
                }
                Button("Управлять шаблонами…") { showingTemplates = true }.buttonStyle(.bordered)
                Text("Собственный текст хранится отдельно от дополнений ИИ. Изображения и распознанный на них текст остаются в папке данных на Mac.")
                    .font(AppTypography.caption).foregroundStyle(.secondary).lineSpacing(4)
            }
            focusSettings
        }
    }
    private var shortcutSettings: some View {
        settingsSection("Горячие клавиши", "keyboard") {
            Toggle("Открывать быструю заметку из любого приложения", isOn: $store.settings.quickCaptureEnabled)
            Picker("Быстрая заметка", selection: $store.settings.quickCaptureShortcut) {
                Text("⌃⌥N").tag("controlOptionN"); Text("⌃⇧Пробел").tag("controlShiftSpace")
            }.disabled(!store.settings.quickCaptureEnabled)
            Toggle("Отмечать важный момент по ⌃⌥B", isOn: $store.settings.bookmarkShortcutEnabled)
            LabeledContent("Общий поиск", value: "⌘K")
            LabeledContent("Добавить запись", value: "⌘O")
            LabeledContent("Новая встреча", value: "⌘N")
            if let message = store.notes.hotkeyNotice { Text(message).foregroundStyle(Ink.warning).font(AppTypography.caption) }
            Text("Глобальные сочетания включаются после сохранения. Если сочетание занято другой программой, выберите другой вариант.")
                .font(AppTypography.caption).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private var speechSettings: some View {
        settingsSection("Распознавание речи", "waveform") {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.runtimeReady ? "Распознавание готово" : "Подготовьте распознавание").fontWeight(.medium)
                                Text("Русский и английский определяются автоматически. Можно использовать совместимый Parakeet, уже скачанный в другом приложении.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            }
                            Spacer()
                            if store.runtimeReady {
                                Button("Проверить и подготовить") { store.installRuntime() }.buttonStyle(.bordered)
                                    .help("Повторно подготовить распознавание речи и разделение собеседников")
                            } else {
                                Button("Подготовить распознавание") { store.installRuntime() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                            }
                        }
                        asrModelSettings
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
    }
    private var aiSettings: some View {
        settingsSection("Конспект и примеры", "sparkles") {
                        Picker("Где работает ИИ", selection: $store.settings.mode) {
                            Label("На Mac", systemImage: "laptopcomputer").tag("local")
                            Label("Облако", systemImage: "cloud").tag("cloud")
                        }.pickerStyle(.segmented).tint(Ink.actionFill)
                        if store.settings.mode == "local" {
                            Text("Выберите источник модели для конспекта и карточек.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            Picker("Источник моделей", selection: Binding(get: { store.settings.localProvider }, set: { store.changeLocalProvider($0) })) {
                                Text("После").tag("managed")
                                Text("Ollama").tag("ollama")
                                Text("LM Studio").tag("lmstudio")
                            }.pickerStyle(.segmented)
                            if store.settings.localProvider == "managed" {
                                Picker("Локальная модель", selection: localModelPreset) {
                                    Text("Качество · Qwen3.5 9B (6,6 ГБ)").tag("quality")
                                    Text("Быстрее · Qwen3.5 4B (3,3 ГБ)").tag("fast")
                                    Text("Своя модель").tag("custom")
                                }
                                if localModelPreset.wrappedValue == "custom" {
                                    LabeledContent("Имя своей модели") {
                                        TextField("Имя модели", text: $store.settings.localModel).textFieldStyle(.roundedBorder)
                                            .accessibilityLabel("Имя своей локальной модели")
                                            .help("Укажите точное имя модели из каталога Ollama.")
                                    }
                                }
                                Text("После хранит свою модель отдельно. Для уже установленной Ollama или LM Studio выберите соответствующий источник выше.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                            } else {
                                Text(store.settings.localProvider == "lmstudio"
                                     ? "В LM Studio загрузите модель и включите локальный сервер в разделе Developer. Чтобы текст оставался на этом Mac, отключите LM Link."
                                     : "Откройте Ollama, затем найдите установленные модели здесь.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                                LabeledContent("Адрес сервера") {
                                    TextField(store.settings.resolvedLocalEndpoint, text: Binding(get: { store.settings.localEndpoint }, set: { endpoint in
                                        store.settings.localEndpoint = endpoint
                                        store.installedLocalModels = []; store.localStatus = ""
                                    }))
                                        .textFieldStyle(.roundedBorder).accessibilityLabel("Адрес локального сервера")
                                        .help("Только сервер на этом Mac. Обычный адрес Ollama — http://127.0.0.1:11434, LM Studio — http://127.0.0.1:1234.")
                                }
                            }
                            installedLocalModelPicker
                            HStack {
                                Button("Найти установленные модели") { store.discoverLocalModels() }.buttonStyle(.bordered)
                                if store.settings.localProvider == "managed" {
                                    Button("Подготовить локальный ИИ") { store.prepareLocal() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(!store.runtimeReady)
                                }
                            }
                            if store.settings.localProvider == "managed" {
                                DisclosureGroup("Подключить модель из файла") { ggufModelSettings }
                                Text("Для Air с 16 ГБ модели запускаются по очереди. Цифры в списке показывают размер скачивания; память также нужна macOS и тексту встречи. Уже скачанная модель используется повторно.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                            } else {
                                Text("После обращается к выбранному локальному серверу. Модель повторно не скачивается; сервером управляет выбранное приложение.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                            }
                            if !store.localStatus.isEmpty {
                                Text(store.localStatus).font(.system(size: 12)).foregroundStyle(Ink.accent).textSelection(.enabled)
                            }
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
    }
    private var focusSettings: some View {
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
    }
    private var dataSettings: some View {
        settingsSection("Ваши данные", "lock") {
                        Text("Записи, транскрипты, конспекты и история повторений хранятся в папке приложения.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        Text("Обновления устанавливаются поверх приложения в «Программах» через файл .pkg. Встречи, модели и ключи хранятся отдельно и сохраняются.")
                            .font(AppTypography.caption).foregroundStyle(.secondary).lineSpacing(4)
                        Button("Открыть страницу обновлений") { NSWorkspace.shared.open(URL(string: "https://github.com/starkovsavva/posle/releases")!) }.buttonStyle(.bordered)
                        Button("Экспортировать мои заметки…") { store.exportManualNotes() }.buttonStyle(.bordered)
                        Button("Открыть папку данных") { NSWorkspace.shared.open(store.root) }.buttonStyle(.bordered)
                        Text("После \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3") · Apple Silicon · macOS 15+").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
    }

    @ViewBuilder
    private var installedLocalModelPicker: some View {
        let models = store.installedLocalModels.filter { $0.provider == store.settings.localProvider }
        if !models.isEmpty {
            Picker("Установленная модель", selection: Binding(get: { store.settings.localModel }, set: { id in
                if let model = models.first(where: { $0.id == id }) { store.selectLocalModel(model) }
            })) {
                if !models.contains(where: { $0.id == store.settings.localModel }) {
                    Text(store.settings.localModel.isEmpty ? "Выберите модель" : store.settings.localModel).tag(store.settings.localModel)
                }
                ForEach(models) { model in Text(model.name).tag(model.id) }
            }.accessibilityLabel("Установленная модель для конспекта и карточек")
        } else if store.settings.localProvider != "managed" && !store.settings.localModel.isEmpty {
            LabeledContent("Выбрана модель") {
                Text(store.settings.localModel).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
    }

    private var ggufModelSettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Подключить локальную модель из файла").font(.system(size: 12, weight: .medium))
            Text("Подключите уже скачанную модель в формате GGUF. Повторно скачивать её не нужно.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            HStack {
                Button("Найти модели на Mac") { store.discoverGGUFModels() }.buttonStyle(.bordered)
                Button("Выбрать файл…") { store.chooseGGUFFile() }.buttonStyle(.bordered).disabled(!store.runtimeReady)
            }
            if !store.runtimeReady {
                Text("Сначала подготовьте среду в разделе «Распознавание речи»: эта среда нужна для локального движка. Искать файлы можно уже сейчас.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !store.ggufStatus.isEmpty {
                Text(store.ggufStatus).font(.system(size: 12)).foregroundStyle(Ink.accent).textSelection(.enabled)
            }
            ForEach(Array(store.installedGGUFModels.prefix(4))) { model in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shippingbox").foregroundStyle(Ink.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(model.source) · \(model.sizeLabel)").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(model.path)
                    }
                    Spacer(minLength: 4)
                    Button("Подключить") { store.importGGUFModel(URL(fileURLWithPath: model.path)) }
                        .buttonStyle(.bordered).disabled(!store.runtimeReady)
                        .accessibilityLabel("Подключить \(model.name) из \(model.source)")
                }.padding(11).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if store.installedGGUFModels.count > 4 {
                Text("Показаны первые 4 модели. Другую можно выбрать через «Выбрать файл…».")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(store.ggufNotes.prefix(2).enumerated()), id: \.offset) { _, note in
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 5)
    }

    private var asrModelSettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Модель Parakeet").fontWeight(.medium)
                Spacer()
                if !store.settings.asrModelPath.isEmpty {
                    Button("Выбирать автоматически") { store.useAutomaticASRModel() }.buttonStyle(.link)
                }
            }
            if store.settings.asrModelPath.isEmpty {
                Text("Автоматический выбор: После сначала ищет совместимую модель на Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Label(URL(fileURLWithPath: store.settings.asrModelPath).lastPathComponent, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Ink.green).font(.system(size: 12, weight: .medium))
                Text(store.settings.asrModelPath).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(store.settings.asrModelPath).textSelection(.enabled)
            }
            HStack {
                Button("Найти на Mac") { store.discoverASRModels() }.buttonStyle(.bordered)
                Button("Выбрать папку…") { store.chooseASRFolder() }.buttonStyle(.bordered)
            }
            if !store.asrStatus.isEmpty {
                Text(store.asrStatus).font(.system(size: 12)).foregroundStyle(Ink.accent).textSelection(.enabled)
            }
            ForEach(Array(store.installedASRModels.prefix(6))) { model in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.compatible ? "waveform" : "exclamationmark.circle")
                        .foregroundStyle(model.compatible ? Ink.accent : Ink.warning).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(.system(size: 12, weight: .medium))
                        Text("\(model.source) · \(model.format.uppercased())").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(model.path)
                        if !model.reason.isEmpty {
                            Text(model.reason).font(.system(size: 11)).foregroundStyle(model.compatible ? Color.secondary : Ink.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if model.compatible {
                        if model.path == store.settings.asrModelPath {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.green)
                                .accessibilityLabel("Выбранная модель")
                        } else {
                            Button("Использовать") { store.selectASRModel(model) }.buttonStyle(.bordered)
                                .accessibilityLabel("Использовать \(model.name) из \(model.source)")
                        }
                    }
                }.padding(11).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if store.installedASRModels.count > 6 {
                Text("Показаны первые 6 моделей. Для другой модели выберите её папку.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(store.asrNotes.prefix(3).enumerated()), id: \.offset) { _, note in
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Обнаружение и выбор папки ничего не скачивают. Формат модели проверяется перед использованием.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }
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
                    if store.runtimeReady { Task { store.settings.recordSystemAudio = systemAudio; store.settings.recordVideo = video; store.saveSettings(); await store.startRecording(systemAudio: systemAudio, video: video, title: title) } }
                    else { dismiss(); store.showingSettings = true }
                }
                    .buttonStyle(.borderedProminent).tint(store.runtimeReady ? Ink.recordFill : Ink.actionFill).disabled(store.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 570).tint(Ink.accent)
            .onAppear { systemAudio = store.settings.recordSystemAudio; video = store.settings.recordVideo }
    }
}
