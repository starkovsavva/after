import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeController.shared
    @ObservedObject private var localization = UILocalization.shared
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
    private var sections: [(String, String, String)] {
        var result = [
            ("general", L("Общие"), "gearshape"), ("features", L("Возможности"), "square.grid.2x2"),
            ("appearance", L("Оформление"), "paintpalette"), ("record", L("Запись"), "record.circle"),
            ("speech", L("Распознавание речи"), "waveform"),
            ("ai", store.isFeatureEnabled(.cards) ? L("Конспект и карточки") : L("Конспект"), "sparkles")
        ]
        if store.isFeatureEnabled(.semanticSearch) { result.append(("semantic", L("Смысловой поиск"), "sparkle.magnifyingglass")) }
        result += [("notes", L("Заметки и шаблоны"), "square.and.pencil"), ("keys", L("Горячие клавиши"), "keyboard")]
        // Snapshot grants have their own lifecycle. Their revoke control must
        // remain reachable even after the user disables the Tasks feature.
        result.append(("integrations", L("Интеграции"), "point.3.connected.trianglepath.dotted"))
        result += [("data", L("Данные и экспорт"), "externaldrive"), ("updates", L("Обновления"), "arrow.triangle.2.circlepath")]
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Настройки")).font(AppTypography.modalTitle)
                Spacer()
                Button { closeSettings() } label: { Image(systemName: "xmark").padding(6) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(L("Сохранить и закрыть настройки"))
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(sections, id: \.0) { id, title, icon in
                                Button { selectSection(id) } label: {
                                    Label(title, systemImage: icon).font(AppTypography.control)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 11)
                                        .background(section == id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .foregroundStyle(Color.primary)
                                }.buttonStyle(.plain).accessibilityIdentifier("settings." + id)
                                    .accessibilityAddTraits(section == id ? .isSelected : [])
                            }
                        }
                    }.scrollIndicators(.hidden)
                    Text(AppVersion.current.map { LF("After {0}", arguments: [$0]) } ?? L("After"))
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
                            Text(store.progressText.isEmpty ? L("Подготавливаю модели…") : L(store.progressText))
                                .font(AppTypography.control).lineLimit(1).help(store.progressText)
                            if store.canCancelJob { Button(L("Отменить")) { store.cancelJob() }.buttonStyle(.bordered) }
                        }.accessibilityElement(children: .contain)
                    }
                    SettingsDraftWarning(updates: store.updates)
                    if let error = store.error {
                        Label(L(error), systemImage: "exclamationmark.triangle")
                            .font(AppTypography.caption).foregroundStyle(Ink.warning)
                            .lineLimit(2).help(error).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Готово")) { closeSettings() }.buttonStyle(.borderedProminent)
                    .tint(Ink.actionFill).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 16).frame(height: AppLayout.statusHeight)
        }.frame(width: 900, height: 690).background(Ink.paper).tint(Ink.accent).appControlDefaults()
            .background(UpdateSettingsWindowReader(updates: store.updates).frame(width: 0, height: 0))
            .preferredColorScheme(theme.colorScheme)
            .sheet(isPresented: $showingTemplates) {
                VStack(spacing: 16) {
                    HStack { Spacer(); Button(L("Готово")) { showingTemplates = false }.keyboardShortcut(.cancelAction) }
                    ScrollView { NotesTemplatesView(notes: store.notes).environmentObject(store) }
                }.padding(25).frame(width: 700, height: 600)
            }
            .onAppear {
                theme.configure(root: store.root)
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
            .onChange(of: store.settingsSection) { _, selected in selectSection(selected) }
            .onChange(of: section) { _, selected in store.settingsSection = selected }
            .onDisappear { store.saveSettings() }
    }
    private func selectSection(_ target: String) {
        guard target != section else { return }
        guard !SettingsDraftRegistry.hasUnsaved else {
            store.updates.revealSettingsDrafts(); store.settingsSection = section; return
        }
        section = target
    }
    private func closeSettings() {
        guard !SettingsDraftRegistry.hasUnsaved else { store.updates.revealSettingsDrafts(); return }
        guard store.saveSettings() else { return }
        store.updates.settingsDidSave()
        dismiss()
    }
    @ViewBuilder private var settingsContent: some View {
        switch section {
        case "features": FeatureSettingsView()
        case "appearance": ThemeSettingsView(theme: theme)
        case "speech": SpeechSettingsView().disabled(store.busy || store.isRecording)
        case "ai": aiSettings.disabled(store.busy || store.isRecording)
        case "record": recordSettings.disabled(store.busy || store.isRecording)
        case "notes": notesSettings
        case "keys": shortcutSettings
        case "semantic":
            if store.isFeatureEnabled(.semanticSearch) { SemanticSearchSettings() }
            else { OptionalFeatureGate(feature: .semanticSearch) }
        case "integrations":
            if store.isFeatureEnabled(.tasks) { IntegrationSettingsView() }
            else { SnapshotAgentSettings(root: store.root) }
        case "data": dataSettings
        case "updates": UpdateSettingsView(updates: store.updates)
        default: generalSettings
        }
    }
    private var generalSettings: some View {
        settingsSection(L("Общие"), "gearshape") {
            Picker(L("Язык интерфейса"), selection: Binding(get: { localization.language.rawValue }, set: { localization.setLanguage(fromString: $0) })) {
                ForEach(UILanguage.allCases) { language in Text(language.title).tag(language.rawValue) }
            }.accessibilityIdentifier("settings.language")
            Text(L("Язык интерфейса не меняет язык конспектов, распознавания и сохранённых материалов."))
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let error = localization.error {
                Text(L(error)).font(AppTypography.caption).foregroundStyle(Ink.warning).accessibilityIdentifier("settings.language.error")
            }
            Divider()
            Picker(L("При запуске открывать"), selection: Binding(get: {
                let section = store.settings.startSection
                return ["meetings", "inbox", "tasks", "cards"].contains(section) && store.settings.allowsSection(section) ? section : "meetings"
            }, set: { store.settings.startSection = $0 })) {
                Text(L("Все встречи")).tag("meetings"); Text(L("Заметки")).tag("inbox")
                if store.isFeatureEnabled(.tasks) { Text(L("Мои задачи")).tag("tasks") }
                if store.isFeatureEnabled(.cards) { Text(L("Карточки")).tag("cards") }
            }
        }
    }
    private var recordSettings: some View {
        settingsSection(L("Запись"), "record.circle") {
            Toggle(L("Записывать звук Mac"), isOn: $store.settings.recordSystemAudio)
                .help(L("Вместе с микрофоном. Для разделения голосов в звонке используйте наушники."))
            RecordingOptionsView(audioQuality: $store.settings.recordAudioQuality,
                                 video: $store.settings.recordVideo, videoQuality: $store.settings.recordVideoQuality,
                                 systemAudio: store.settings.recordSystemAudio)
            LabeledContent(L("Формат аудио"), value: "MP3")
        }
    }
    private var notesSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection(L("Заметки и шаблоны"), "square.and.pencil") {
                Toggle(L("Прикреплять быстрые заметки к текущей записи"), isOn: $store.settings.notesSaveToActiveMeeting)
                Toggle(L("Добавлять таймкод к пометкам"), isOn: $store.settings.notesAutoTimestamp)
                Picker(L("Шаблон новых заметок встречи"), selection: $store.settings.defaultTemplateID) {
                    Text(L("Чистая заметка")).tag("")
                    ForEach(store.notes.templates) { Text($0.name).tag($0.id) }
                }
                Button(L("Управлять шаблонами…")) { showingTemplates = true }.buttonStyle(.bordered)
            }
            focusSettings
        }
    }
    private var shortcutSettings: some View {
        settingsSection(L("Горячие клавиши"), "keyboard") {
            Toggle(L("Открывать быструю заметку из любого приложения"), isOn: $store.settings.quickCaptureEnabled)
            Picker(L("Быстрая заметка"), selection: $store.settings.quickCaptureShortcut) {
                Text("⌃⌥N").tag("controlOptionN"); Text(L("⌃⇧Пробел")).tag("controlShiftSpace")
            }.disabled(!store.settings.quickCaptureEnabled)
            Toggle(L("Отмечать важный момент по ⌃⌥B"), isOn: $store.settings.bookmarkShortcutEnabled)
            if store.isFeatureEnabled(.assistant) {
                Toggle(L("Голосовое поручение по ⌃⌥M"), isOn: $store.settings.voiceShortcutEnabled)
            }
            LabeledContent(L("Общий поиск"), value: "⌘K")
            LabeledContent(L("Добавить запись"), value: "⌘O")
            LabeledContent(L("Новая заметка или запись"), value: "⌘N")
            if let message = store.notes.hotkeyNotice { Text(message).foregroundStyle(Ink.warning).font(AppTypography.caption) }
        }
    }
    private var aiSettings: some View {
        settingsSection(store.isFeatureEnabled(.cards) ? L("Конспект и карточки") : L("Конспект"), "sparkles") {
            Picker(L("Обработка"), selection: Binding(get: { store.settings.mode }, set: { mode in
                guard !SettingsDraftRegistry.hasUnsaved else {
                    store.updates.revealSettingsDrafts(); store.objectWillChange.send(); return
                }
                store.settings.mode = mode
            })) {
                Label(L("На Mac"), systemImage: "laptopcomputer").tag("local")
                Label(L("Облако"), systemImage: "cloud").tag("cloud")
            }.pickerStyle(.segmented).tint(Ink.actionFill)
            if store.settings.mode == "local" {
                Picker(L("Источник"), selection: Binding(get: { store.settings.localProvider }, set: { store.changeLocalProvider($0) })) {
                    Text(L("After")).tag("managed"); Text("Ollama").tag("ollama"); Text("LM Studio").tag("lmstudio")
                }.pickerStyle(.segmented).tint(Ink.actionFill)
                    .help(L("After хранит свою модель отдельно. Ollama и LM Studio используют свои установленные модели."))
                if store.settings.localProvider == "managed" {
                    Picker(L("Модель"), selection: localModelPreset) {
                        Text(L("Qwen3.5 9B · качество · 6,6 ГБ")).tag("quality")
                        Text(L("Qwen3.5 4B · быстрее · 3,3 ГБ")).tag("fast")
                        Text(L("Своя модель")).tag("custom")
                    }.help(L("Размер скачивания. На Mac с 16 ГБ распознавание и конспект выполняются по очереди."))
                    if localModelPreset.wrappedValue == "custom" {
                        LabeledContent(L("Имя модели")) {
                            TextField(L("Имя из каталога Ollama"), text: $store.settings.localModel).textFieldStyle(.roundedBorder)
                                .accessibilityLabel(L("Имя своей локальной модели"))
                        }
                    }
                } else {
                    LabeledContent(L("Адрес сервера")) {
                        TextField(store.settings.resolvedLocalEndpoint, text: Binding(get: { store.settings.localEndpoint }, set: { endpoint in
                            store.settings.localEndpoint = endpoint; store.installedLocalModels = []; store.localStatus = ""
                        })).textFieldStyle(.roundedBorder).accessibilityLabel(L("Адрес локального сервера"))
                    }
                    DisclosureGroup(L("Как подключить")) {
                        Text(store.settings.localProvider == "lmstudio"
                             ? L("Загрузите модель в LM Studio и включите сервер в разделе Developer. Обычный адрес — http://127.0.0.1:1234.")
                             : L("Откройте Ollama. Обычный адрес — http://127.0.0.1:11434."))
                            .font(AppTypography.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if store.settings.localProvider == "lmstudio" {
                        Text(L("Для обработки на этом Mac отключите LM Link в LM Studio."))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }
                installedLocalModelPicker
                HStack {
                    if store.settings.localProvider != "managed" || store.runtimeReady {
                        Button(L("Найти модели")) { store.discoverLocalModels() }.buttonStyle(.bordered)
                    }
                    if store.settings.localProvider == "managed" {
                        if store.runtimeReady {
                            Button(L("Подготовить ИИ")) { store.prepareLocal() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("Сначала установите компоненты обработки."))
                                    .font(AppTypography.caption).foregroundStyle(.secondary)
                                Button(L("Установить компоненты…")) { section = "speech" }
                                    .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                                    .help(L("Откроется раздел «Распознавание речи». После установки вернитесь к подготовке ИИ."))
                            }
                        }
                    }
                }
                if store.settings.localProvider == "managed" {
                    DisclosureGroup(L("Подключить файл GGUF")) { ggufModelSettings }
                }
                if !store.localStatus.isEmpty {
                    Text(store.localStatus).font(AppTypography.caption).foregroundStyle(Ink.accent).textSelection(.enabled)
                }
                Toggle(L("Создавать конспект после транскрипта"), isOn: $store.settings.autoSummary)
            } else {
                CloudSettingsView()
            }
            Picker(L("Язык конспекта"), selection: $store.settings.language) {
                Text(L("Русский")).tag("ru"); Text("English").tag("en")
            }.frame(maxWidth: 340)
            Divider().padding(.vertical, 8)
            SummaryContextSettingsView()
        }
    }
    private var focusSettings: some View {
        settingsSection(L("На что обращать внимание"), "pin") {
                        TextEditor(text: $store.settings.focus).font(AppTypography.caption).frame(height: 80).padding(8)
                            .scrollContentBackground(.hidden)
                            .background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
                            .accessibilityLabel(L("Фокус конспекта"))
                            .accessibilityHint(store.isFeatureEnabled(.cards) ? L("Что выписывать из встречи: решения, задачи, детали и темы для карточек") : L("Что выписывать из встречи: решения и важные детали"))
                            .help(L("Для новых встреч. Фокус отдельной встречи можно изменить в её конспекте."))
                    }
    }
    private var dataSettings: some View {
        settingsSection(L("Данные и экспорт"), "externaldrive") {
            Button(L("Экспортировать заметки…")) { store.exportManualNotes() }.buttonStyle(.bordered)
            Button(L("Открыть папку данных")) { NSWorkspace.shared.open(store.root) }.buttonStyle(.bordered)
                .help(store.root.path)
        }
    }

    @ViewBuilder
    private var installedLocalModelPicker: some View {
        let models = store.installedLocalModels.filter { $0.provider == store.settings.localProvider }
        if !models.isEmpty {
            Picker(L("Установленная модель"), selection: Binding(get: { store.settings.localModel }, set: { id in
                if let model = models.first(where: { $0.id == id }) { store.selectLocalModel(model) }
            })) {
                if !models.contains(where: { $0.id == store.settings.localModel }) {
                    Text(store.settings.localModel.isEmpty ? L("Выберите модель") : store.settings.localModel).tag(store.settings.localModel)
                }
                ForEach(models) { model in Text(model.name).tag(model.id) }
            }.accessibilityLabel(store.isFeatureEnabled(.cards) ? L("Установленная модель для конспекта и карточек") : L("Установленная модель для конспекта"))
        } else if store.settings.localProvider != "managed" && !store.settings.localModel.isEmpty {
            LabeledContent(L("Выбрана модель")) {
                Text(store.settings.localModel).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
    }

    private var ggufModelSettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Button(L("Найти модели на Mac")) { store.discoverGGUFModels() }.buttonStyle(.bordered)
                Button(L("Выбрать файл…")) { store.chooseGGUFFile() }.buttonStyle(.bordered).disabled(!store.runtimeReady)
            }
            if !store.runtimeReady {
                Button(L("Установить компоненты…")) { section = "speech" }.buttonStyle(.link)
                    .help(L("Компоненты устанавливаются в разделе «Распознавание речи»."))
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
                    Button(L("Подключить")) { store.importGGUFModel(URL(fileURLWithPath: model.path)) }
                        .buttonStyle(.bordered).disabled(!store.runtimeReady)
                        .accessibilityLabel(LF("Подключить {0} из {1}", arguments: [model.name, model.source]))
                }.padding(11).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if store.installedGGUFModels.count > 4 {
                Text(L("Показаны первые 4 модели. Другую можно выбрать через «Выбрать файл…»."))
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
    @StateObject private var audioCheck = AudioCheckController()
    @State private var systemAudio = true
    @State private var video = false
    @State private var audioQuality: RecordingAudioQuality = .standard
    @State private var videoQuality: RecordingVideoQuality = .compact
    @State private var recordingError: String?
    @State private var folderID = ""
    @State private var cardsChoice = "inherit"
    @State private var showingProcessing = false
    @State private var preparingCapture = false
    @State private var captureTask: Task<Void, Never>?
    private var startLocked: Bool { preparingCapture || store.startingRecording }
    private var destinationExists: Bool { folderID.isEmpty || store.notes.folder(folderID) != nil }
    private var profileSettings: AppSettings { store.effectiveSettings(folderID: folderID.isEmpty ? nil : folderID) }
    private var folderGeneratesCards: Bool { store.notes.folder(folderID)?.overrides.generateCards ?? false }
    private var processingSummary: String {
        let model = profileSettings.mode == "cloud" ? profileSettings.cloudProviderTitle + " · " + profileSettings.cloudModel : L("На Mac · ") + profileSettings.localModel
        let cards = profileSettings.features.cards && (cardsChoice == "inherit" ? folderGeneratesCards : cardsChoice == "on")
        return (profileSettings.language == "en" ? "English" : L("Русский")) + " · " + model + (cards ? L(" · карточки создавать") : L(" · карточки не создавать"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Запись встречи")).font(AppTypography.modalTitle)
            TextField(L("Название встречи"), text: $title).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L("Название новой встречи")).disabled(startLocked)
            Picker(L("Папка"), selection: $folderID) {
                Text(L("Без папки · настройки приложения")).tag("")
                ForEach(store.notes.folders) { Text($0.name).tag($0.id) }
                if !destinationExists { Text(L("Папка недоступна")).tag(folderID) }
            }.accessibilityIdentifier("record.folder").disabled(startLocked)
            Button { showingProcessing = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(Ink.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Конспект · ") + (profileSettings.language == "en" ? "English" : L("Русский")))
                            .font(AppTypography.control).accessibilityIdentifier("record.profile.language")
                        Text(profileSettings.mode == "cloud" ? profileSettings.cloudProviderTitle + " · " + profileSettings.cloudModel : L("На Mac · ") + profileSettings.localModel)
                            .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).lineLimit(1)
                            .accessibilityIdentifier("record.profile.model")
                    }
                    Spacer()
                    Text(L("Стиль и карточки…")).font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L("Настройки конспекта новой встречи")).accessibilityValue(processingSummary)
                .accessibilityIdentifier("record.processing").disabled(startLocked)
                .popover(isPresented: $showingProcessing) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(profileSettings.features.cards ? L("Конспект и карточки") : L("Конспект")).font(AppTypography.heading)
                        Text(profileSettings.focus.isEmpty ? L("Стиль конспекта: по умолчанию") : L("Стиль конспекта: ") + profileSettings.focus)
                            .font(AppTypography.control).foregroundStyle(Ink.secondaryText).lineLimit(3)
                            .accessibilityIdentifier("record.profile.focus")
                        if profileSettings.features.cards {
                            CardGenerationPicker(selection: $cardsChoice, inherited: folderGeneratesCards,
                                                 inheritedTitle: folderID.isEmpty ? L("По умолчанию") : L("Как в папке"),
                                                 identifier: "record.generateCards")
                        } else {
                            Text(folderID.isEmpty ? L("Карточки выключены в настройках приложения.") : L("Карточки выключены в настройках папки."))
                                .font(AppTypography.control).foregroundStyle(Ink.secondaryText)
                                .accessibilityIdentifier("record.cardsUnavailable")
                        }
                        Text(L("Язык, стиль и модель берутся из выбранной папки. Выбор карточек действует только для новой встречи."))
                            .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
                        HStack { Spacer(); Button(L("Готово")) { showingProcessing = false }.keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("record.processing.done") }
                    }.padding(20).frame(width: 420).appControlDefaults()
                }
            Picker(L("Звук"), selection: $systemAudio) {
                Text(L("Микрофон и звук Mac")).tag(true)
                Text(L("Только микрофон")).tag(false)
            }.pickerStyle(.radioGroup).disabled(startLocked)
                .help(L("Для звонков выберите звук Mac и используйте наушники. Для встречи в комнате — только микрофон."))
            RecordingOptionsView(audioQuality: $audioQuality, video: $video,
                                 videoQuality: $videoQuality, systemAudio: systemAudio).disabled(startLocked)
            HStack {
                Text(video ? "MP3 + MP4" : "MP3").font(AppTypography.captionStrong).foregroundStyle(Ink.secondaryText)
                Spacer()
                if systemAudio {
                    Label(L("Используйте наушники"), systemImage: "headphones").font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                }
            }
            if let recordingError {
                Label(recordingError, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            RecordingAudioCheck(check: audioCheck, systemAudio: systemAudio).environmentObject(store)
            if startLocked {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(systemAudio || video ? L("Выберите экран в окне macOS…") : L("Включаю микрофон…")).font(AppTypography.control)
                }.accessibilityElement(children: .combine)
            }
            HStack {
                Button(startLocked ? L("Отменить запуск") : L("Отмена"), role: .cancel) {
                    if startLocked {
                        captureTask?.cancel()
                        Task { await audioCheck.stop(); await store.cancelRecordingStart() }
                    } else { dismiss() }
                }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("record.cancel")
                Spacer()
                Button(L("Начать запись")) {
                    guard !startLocked else { return }
                    recordingError = nil
                    store.settings.recordSystemAudio = systemAudio; store.settings.recordVideo = video
                    store.settings.recordAudioQuality = audioQuality; store.settings.recordVideoQuality = videoQuality
                    guard store.saveSettings() else { recordingError = store.error; return }
                    let destination = RecordingDestination(folderID: folderID.isEmpty ? nil : folderID,
                        generateCards: cardsChoice == "inherit" ? nil : cardsChoice == "on")
                    let captureTitle = title, captureSystemAudio = systemAudio, captureVideo = video
                    preparingCapture = true
                    captureTask = Task {
                        defer { preparingCapture = false; captureTask = nil }
                        await audioCheck.stop()
                        guard !Task.isCancelled else { return }
                        await store.startRecording(systemAudio: captureSystemAudio, video: captureVideo, title: captureTitle, destination: destination)
                        if !store.isRecording { recordingError = store.error }
                    }
                }.buttonStyle(.borderedProminent).tint(Ink.recordFill)
                    .disabled(startLocked || !destinationExists).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("record.start")
            }
        }.padding(AppLayout.contentInset).frame(width: 560).appControlDefaults().tint(Ink.accent)
            .interactiveDismissDisabled(startLocked)
            .onAppear {
                folderID = store.folderSelection ?? ""
                systemAudio = store.settings.recordSystemAudio; video = store.settings.recordVideo
                audioQuality = store.settings.recordAudioQuality; videoQuality = store.settings.recordVideoQuality
                if ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-error") {
                    recordingError = "Нет доступа к микрофону. Разрешите его в настройках macOS и повторите запись."
                }
            }
            .onChange(of: folderID) { _, _ in cardsChoice = "inherit" }
    }
}
