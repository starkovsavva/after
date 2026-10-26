import AppKit
import PosleCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
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
        ("speech", "Распознавание речи", "waveform"), ("ai", "Конспект и карточки", "sparkles"),
        ("notes", "Заметки и шаблоны", "square.and.pencil"), ("keys", "Горячие клавиши", "keyboard"),
        ("data", "Данные и экспорт", "externaldrive"),
        ("updates", "Обновления", "arrow.triangle.2.circlepath")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Настройки").font(AppTypography.modalTitle)
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
                    Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "После \($0)" } ?? "После")
                        .font(AppTypography.caption).foregroundStyle(.secondary).padding(10)
                }.padding(12).frame(width: 215).background(Ink.soft)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        settingsContent
                    }.font(AppTypography.control).frame(maxWidth: .infinity, alignment: .leading).padding(26)
                }.frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if store.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text(store.progressText.isEmpty ? "Подготавливаю модели…" : store.progressText)
                                .font(AppTypography.control).lineLimit(1).help(store.progressText)
                            if store.canCancelJob { Button("Отменить") { store.cancelJob() }.buttonStyle(.bordered) }
                        }.accessibilityElement(children: .contain)
                    }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(AppTypography.caption).foregroundStyle(Ink.warning)
                            .lineLimit(2).help(error).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Готово") { store.saveSettings(); dismiss() }.buttonStyle(.borderedProminent)
                    .tint(Ink.actionFill).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 16).frame(height: AppLayout.statusHeight)
        }.frame(width: 900, height: 690).tint(Ink.accent).appControlDefaults()
            .sheet(isPresented: $showingTemplates) {
                VStack(spacing: 16) {
                    HStack { Spacer(); Button("Готово") { showingTemplates = false }.keyboardShortcut(.cancelAction) }
                    ScrollView { NotesTemplatesView(notes: store.notes).environmentObject(store) }
                }.padding(25).frame(width: 700, height: 600)
            }
            .onAppear {
                if !store.settings.defaultTemplateID.isEmpty && !store.notes.templates.contains(where: { $0.id == store.settings.defaultTemplateID }) { store.settings.defaultTemplateID = "" }
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
            .onChange(of: store.settingsSection) { _, selected in section = selected }
            .onChange(of: section) { _, selected in store.settingsSection = selected }
            .onDisappear { store.saveSettings() }
    }
    @ViewBuilder private var settingsContent: some View {
        switch section {
        case "speech": SpeechSettingsView().disabled(store.busy || store.isRecording)
        case "ai": aiSettings.disabled(store.busy || store.isRecording)
        case "record": recordSettings.disabled(store.isRecording)
        case "notes": notesSettings
        case "keys": shortcutSettings
        case "data": dataSettings
        case "updates": UpdateSettingsView(updates: store.updates)
        default: generalSettings
        }
    }
    private var generalSettings: some View {
        settingsSection("Общие", "gearshape") {
            Picker("При запуске открывать", selection: $store.settings.startSection) {
                Text("Все встречи").tag("meetings"); Text("Заметки").tag("inbox")
                Text("Мои задачи").tag("tasks"); Text("Карточки").tag("cards")
            }
        }
    }
    private var recordSettings: some View {
        settingsSection("Запись", "record.circle") {
            Toggle("Записывать звук Mac", isOn: $store.settings.recordSystemAudio)
                .help("Вместе с микрофоном. Для разделения голосов в звонке используйте наушники.")
            Toggle("Сохранять видео экрана", isOn: $store.settings.recordVideo)
                .help("MP4, H.264, до 720p, 30 кадров/с. Эти параметры можно изменить перед каждой встречей.")
            LabeledContent("Формат аудио", value: "MP3")
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
            LabeledContent("Новая заметка или запись", value: "⌘N")
            if let message = store.notes.hotkeyNotice { Text(message).foregroundStyle(Ink.warning).font(AppTypography.caption) }
        }
    }
    private var aiSettings: some View {
        settingsSection("Конспект и карточки", "sparkles") {
            Picker("Обработка", selection: $store.settings.mode) {
                Label("На Mac", systemImage: "laptopcomputer").tag("local")
                Label("Облако", systemImage: "cloud").tag("cloud")
            }.pickerStyle(.segmented).tint(Ink.actionFill)
            if store.settings.mode == "local" {
                Picker("Источник", selection: Binding(get: { store.settings.localProvider }, set: { store.changeLocalProvider($0) })) {
                    Text("После").tag("managed"); Text("Ollama").tag("ollama"); Text("LM Studio").tag("lmstudio")
                }.pickerStyle(.segmented).tint(Ink.actionFill)
                    .help("После хранит свою модель отдельно. Ollama и LM Studio используют свои установленные модели.")
                if store.settings.localProvider == "managed" {
                    Picker("Модель", selection: localModelPreset) {
                        Text("Qwen3.5 9B · качество · 6,6 ГБ").tag("quality")
                        Text("Qwen3.5 4B · быстрее · 3,3 ГБ").tag("fast")
                        Text("Своя модель").tag("custom")
                    }.help("Размер скачивания. На Mac с 16 ГБ распознавание и конспект выполняются по очереди.")
                    if localModelPreset.wrappedValue == "custom" {
                        LabeledContent("Имя модели") {
                            TextField("Имя из каталога Ollama", text: $store.settings.localModel).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Имя своей локальной модели")
                        }
                    }
                } else {
                    LabeledContent("Адрес сервера") {
                        TextField(store.settings.resolvedLocalEndpoint, text: Binding(get: { store.settings.localEndpoint }, set: { endpoint in
                            store.settings.localEndpoint = endpoint; store.installedLocalModels = []; store.localStatus = ""
                        })).textFieldStyle(.roundedBorder).accessibilityLabel("Адрес локального сервера")
                    }
                    DisclosureGroup("Как подключить") {
                        Text(store.settings.localProvider == "lmstudio"
                             ? "Загрузите модель в LM Studio и включите сервер в разделе Developer. Обычный адрес — http://127.0.0.1:1234."
                             : "Откройте Ollama. Обычный адрес — http://127.0.0.1:11434.")
                            .font(AppTypography.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if store.settings.localProvider == "lmstudio" {
                        Text("Для обработки на этом Mac отключите LM Link в LM Studio.")
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }
                installedLocalModelPicker
                HStack {
                    if store.settings.localProvider != "managed" || store.runtimeReady {
                        Button("Найти модели") { store.discoverLocalModels() }.buttonStyle(.bordered)
                    }
                    if store.settings.localProvider == "managed" {
                        if store.runtimeReady {
                            Button("Подготовить ИИ") { store.prepareLocal() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Сначала установите компоненты обработки.")
                                    .font(AppTypography.caption).foregroundStyle(.secondary)
                                Button("Установить компоненты…") { section = "speech" }
                                    .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                                    .help("Откроется раздел «Распознавание речи». После установки вернитесь к подготовке ИИ.")
                            }
                        }
                    }
                }
                if store.settings.localProvider == "managed" {
                    DisclosureGroup("Подключить файл GGUF") { ggufModelSettings }
                }
                if !store.localStatus.isEmpty {
                    Text(store.localStatus).font(AppTypography.caption).foregroundStyle(Ink.accent).textSelection(.enabled)
                }
                Toggle("Создавать конспект после транскрипта", isOn: $store.settings.autoSummary)
            } else {
                CloudSettingsView()
            }
            Picker("Язык конспекта", selection: $store.settings.language) {
                Text("Русский").tag("ru"); Text("English").tag("en")
            }.frame(maxWidth: 340)
        }
    }
    private var focusSettings: some View {
        settingsSection("На что обращать внимание", "pin") {
                        TextEditor(text: $store.settings.focus).font(AppTypography.caption).frame(height: 80).padding(8)
                            .scrollContentBackground(.hidden)
                            .background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
                            .accessibilityLabel("Фокус конспекта")
                            .accessibilityHint("Что выписывать из встречи: решения, задачи, детали и темы для карточек")
                            .help("Для новых встреч. Фокус отдельной встречи можно изменить в её конспекте.")
                    }
    }
    private var dataSettings: some View {
        settingsSection("Данные и экспорт", "externaldrive") {
            Button("Экспортировать заметки…") { store.exportManualNotes() }.buttonStyle(.bordered)
            Button("Открыть папку данных") { NSWorkspace.shared.open(store.root) }.buttonStyle(.bordered)
                .help(store.root.path)
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
            HStack {
                Button("Найти модели на Mac") { store.discoverGGUFModels() }.buttonStyle(.bordered)
                Button("Выбрать файл…") { store.chooseGGUFFile() }.buttonStyle(.bordered).disabled(!store.runtimeReady)
            }
            if !store.runtimeReady {
                Button("Установить компоненты…") { section = "speech" }.buttonStyle(.link)
                    .help("Компоненты устанавливаются в разделе «Распознавание речи».")
            }
            if !store.ggufStatus.isEmpty {
                Text(store.ggufStatus).font(AppTypography.caption).foregroundStyle(Ink.accent).textSelection(.enabled)
            }
            ForEach(Array(store.installedGGUFModels.prefix(4))) { model in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shippingbox").foregroundStyle(Ink.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(AppTypography.captionStrong).lineLimit(2)
                        Text("\(model.source) · \(model.sizeLabel)").font(AppTypography.caption).foregroundStyle(.secondary)
                        Text(model.path).font(AppTypography.caption).foregroundStyle(.secondary)
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
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(store.ggufNotes.prefix(2).enumerated()), id: \.offset) { _, note in
                Text(note).font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 5)
    }

    private func settingsSection<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(AppTypography.heading)
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
    @State private var recordingError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Запись встречи").font(AppTypography.modalTitle)
            TextField("Название встречи", text: $title).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Название новой встречи")
            Picker("Звук", selection: $systemAudio) {
                Text("Микрофон и звук Mac").tag(true)
                Text("Только микрофон").tag(false)
            }.pickerStyle(.radioGroup)
                .help("Для звонков выберите звук Mac и используйте наушники. Для встречи в комнате — только микрофон.")
            Toggle("Записывать видео экрана", isOn: $video)
            if video {
                Text("Будет виден весь основной экран, включая другие окна.")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                    .help("MP4 · H.264 · до 720p · 30 кадров/с · около 0,5 ГБ в час")
            }
            HStack {
                Text(video ? "MP3 + MP4" : "MP3").font(AppTypography.captionStrong).foregroundStyle(.secondary)
                Spacer()
                if systemAudio {
                    Label("Используйте наушники", systemImage: "headphones").font(AppTypography.caption).foregroundStyle(.secondary)
                }
            }
            Text("Участники должны знать о записи.").font(AppTypography.caption).foregroundStyle(.secondary)
            if let recordingError {
                Label(recordingError, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if store.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Проверяю доступ к записи…").font(AppTypography.control)
                }.accessibilityElement(children: .combine)
            }
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.buttonStyle(.bordered).disabled(store.busy).keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.runtimeReady ? "Начать запись" : "Подготовить распознавание") {
                    if store.runtimeReady {
                        recordingError = nil
                        Task {
                            store.settings.recordSystemAudio = systemAudio; store.settings.recordVideo = video; store.saveSettings()
                            await store.startRecording(systemAudio: systemAudio, video: video, title: title)
                            if !store.isRecording { recordingError = store.error }
                        }
                    } else { dismiss(); store.openSettings("speech") }
                }.buttonStyle(.borderedProminent).tint(store.runtimeReady ? Ink.recordFill : Ink.actionFill)
                    .disabled(store.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(AppLayout.contentInset).frame(width: 520).appControlDefaults().tint(Ink.accent)
            .onAppear {
                systemAudio = store.settings.recordSystemAudio; video = store.settings.recordVideo
                if ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-error") {
                    recordingError = "Нет доступа к микрофону. Разрешите его в настройках macOS и повторите запись."
                }
            }
    }
}
