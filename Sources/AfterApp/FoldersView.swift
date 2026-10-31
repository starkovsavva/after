import AfterLocalization
import AfterCore
import SwiftUI

struct FolderEditorTarget: Identifiable {
    let id = UUID()
    var folder: LibraryFolder
    var section = "general"
}

/// Folder choices are a sparse layer over app preferences, never a second settings file.
struct FolderSettingsView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var editorID = UUID()
    @State private var baseline: LibraryFolder
    @State private var draft: LibraryFolder
    @State private var failure = ""
    @State private var section: String
    @State private var showingDefaults = false
    @State private var deleting = false
    @State private var confirmingDiscard = false
    let isNew: Bool
    var onSaved: ((LibraryFolder) -> Void)?
    var onDeleted: (() -> Void)?
    init(folder: LibraryFolder, isNew: Bool = false, section: String = "general", onSaved: ((LibraryFolder) -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        _section = State(initialValue: section)
        _draft = State(initialValue: folder); _baseline = State(initialValue: folder); self.isNew = isNew
        self.onSaved = onSaved; self.onDeleted = onDeleted
    }
    private var locked: Bool { app.isRecording || app.startingRecording || app.stoppingRecording || app.isTerminating || app.busy || app.jobs.activeCount > 0 }
    private var inherited: AppSettings { app.settings }
    private var effective: AppSettings { draft.overrides.apply(to: inherited) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? L("Новая папка") : draft.name).font(AppTypography.modalTitle).lineLimit(1)
                    if !isNew { Text(L("Настройки папки")).font(AppTypography.caption).foregroundStyle(Ink.secondaryText) }
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(.plain).accessibilityLabel(L("Закрыть настройки папки"))
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 3) {
                    tab("general", L("Общие"), "folder")
                    tab("features", L("Возможности"), "square.grid.2x2")
                    tab("summary", L("Конспект и карточки"), "text.alignleft")
                    tab("model", L("Модель"), "sparkles")
                    Spacer()
                }.padding(12).frame(width: 200).appSurface(.sidebar)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if section == "general" { general }
                        else if section == "features" { features }
                        else if section == "summary" { summary }
                        else { model }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !failure.isEmpty { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(Ink.warning).font(AppTypography.caption).textSelection(.enabled) }
                if section == "features", draft != baseline {
                    Text(L("Сохраните изменения папки, чтобы открыть общие возможности."))
                        .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                }
                HStack {
                    if !isNew {
                        Button(L("Удалить папку…"), role: .destructive) { deleting = true }.disabled(locked).accessibilityIdentifier("folder.delete")
                    }
                    Spacer()
                    Button(L("Отмена")) { close() }.keyboardShortcut(.cancelAction)
                    Button(isNew ? L("Создать") : L("Сохранить")) { save() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        .disabled(locked || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("folder.save")
                }
            }.padding(18)
        }.frame(width: 840, height: 650).background(Ink.paper).tint(Ink.accent).appControlDefaults()
            .sheet(isPresented: $showingDefaults) { FeatureDefaultsSheet().environmentObject(app) }
            .onChange(of: draft) { _, value in UnsavedEditorRegistry.set(id: editorID, title: L("Настройки папки"), dirty: value != baseline) }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .interactiveDismissDisabled(draft != baseline)
            .confirmationDialog(L("Отменить изменения папки?"), isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button(L("Продолжить редактирование"), role: .cancel) {}
                Button(L("Отменить изменения"), role: .destructive) { UnsavedEditorRegistry.remove(id: editorID); dismiss() }
            }
            .confirmationDialog(LF("Удалить папку «{0}»?", arguments: [draft.name]), isPresented: $deleting, titleVisibility: .visible) {
                Button(L("Удалить папку"), role: .destructive) {
                    guard !locked else { failure = L("Удалить папку можно после завершения записи и обработки."); return }
                    if app.notes.deleteFolder(draft) {
                        if app.folderSelection == draft.id { app.folderSelection = nil }
                        onDeleted?(); dismiss()
                    } else { failure = app.notes.error ?? L("Не удалось удалить папку.") }
                }.disabled(locked).accessibilityIdentifier("folder.delete.confirm")
                Button(L("Отмена"), role: .cancel) {}
            } message: { Text(L("Встречи и заметки останутся в библиотеке. Для них будут действовать настройки приложения.")) }
    }
    private func tab(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { section = id } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(section == id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("folder.tab." + id)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Общие")).font(AppTypography.heading)
            LabeledContent(L("Название")) {
                TextField(L("Например, Английский"), text: $draft.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("folder.name")
            }
            Text(L("Встречи и заметки этой папки используют выбранные здесь настройки. «Как в приложении» наследует общие настройки и их будущие изменения."))
                .font(AppTypography.control).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var features: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Возможности папки")).font(AppTypography.heading)
            Text(L("«Как в приложении» использует общие настройки и следует их изменениям. Свой выбор действует только в этой папке."))
                .font(AppTypography.control).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
            featureGroup(L("Разделы в этой папке"), features: [.tasks, .cards, .calendar])
            featureGroup(L("Помощь и поиск"), features: [.assistant, .semanticSearch])
            Text(L("Встречи, заметки, конспекты и транскрипты доступны всегда. Скрытие раздела сохраняет его данные."))
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button(L("Наследовать все возможности")) { draft.overrides.features = nil }
                    .disabled(locked || !hasFeatureOverrides).accessibilityIdentifier("folder.features.inheritAll")
                Spacer(minLength: 0)
                Button(L("Общие возможности…")) { showingDefaults = true }
                    .disabled(draft != baseline || locked).accessibilityIdentifier("folder.features.defaults")
                    .help(draft == baseline ? L("Изменить настройки по умолчанию для папок") : L("Сначала сохраните изменения папки"))
            }.font(AppTypography.control)
            if locked {
                Text(L("Изменить настройки можно после завершения записи и обработки."))
                    .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            }
        }
    }
    private var hasFeatureOverrides: Bool {
        AppFeature.allCases.contains { draft.overrides.features?[$0] != nil }
    }
    private func featureGroup(_ title: String, features: [AppFeature]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppTypography.controlStrong)
            VStack(spacing: 0) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    HStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: FeaturePresentation.icon(feature)).frame(width: 22).foregroundStyle(Ink.secondaryText)
                            Text(FeaturePresentation.title(feature))
                        }.font(AppTypography.control).frame(maxWidth: .infinity, alignment: .leading)
                        Picker(FeaturePresentation.title(feature), selection: featureBinding(feature)) {
                            Text(L("Как в приложении · ") + (inherited.features[feature] ? L("вкл.") : L("выкл."))).tag("inherit")
                            Text(L("Включено")).tag("on")
                            Text(L("Выключено")).tag("off")
                        }.labelsHidden().frame(width: 228).accessibilityIdentifier("folder.feature." + feature.rawValue)
                    }.padding(.vertical, 10)
                    if index < features.count - 1 { Divider() }
                }
            }.disabled(locked)
        }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Конспект и карточки")).font(AppTypography.heading)
            Picker(L("Язык конспекта"), selection: Binding(get: { draft.overrides.language ?? "" }, set: { draft.overrides.language = $0.isEmpty ? nil : $0 })) {
                Text(L("Как в приложении")).tag("")
                Text(L("Русский")).tag("ru")
                Text("English").tag("en")
            }.accessibilityIdentifier("folder.language")
            inheritedText(L("Стиль конспекта"), field: \.focus, placeholder: inherited.focus, height: 90)
            inheritedText(L("Контекст обо мне"), field: \.summaryUserContext, placeholder: inherited.summaryUserContext, height: 80)
            Picker(L("Генерация карточек"), selection: boolBinding(\.generateCards)) {
                Text(L("Не создавать без выбора во встрече")).tag("inherit")
                Text(L("По умолчанию включена")).tag("on")
                Text(L("По умолчанию выключена")).tag("off")
            }.accessibilityIdentifier("folder.generateCards")
            Text(effective.features.cards
                 ? L("Действует для новых и существующих встреч этой папки. Выбор в меню конкретной встречи имеет приоритет; сохранённые карточки остаются на месте.")
                 : L("Карточки выключены для папки. Включите их в разделе «Возможности», чтобы создавать автоматически."))
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.disabled(locked)
    }
    @ViewBuilder private func inheritedText(_ title: String, field: WritableKeyPath<FolderOverrides, String?>, placeholder: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(AppTypography.controlStrong)
                Spacer()
                Toggle(L("Как в приложении"), isOn: Binding(get: { draft.overrides[keyPath: field] == nil }, set: {
                    draft.overrides[keyPath: field] = $0 ? nil : placeholder
                })).toggleStyle(.checkbox)
            }
            if draft.overrides[keyPath: field] != nil {
                TextEditor(text: optional(field)).frame(height: height).padding(5).background(Ink.field, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line)).accessibilityLabel(title)
            } else if !placeholder.isEmpty {
                Text(placeholder).font(AppTypography.caption).foregroundStyle(Ink.secondaryText).lineLimit(3)
            }
        }
    }
    private var model: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Модель")).font(AppTypography.heading)
            Toggle(L("Как в приложении"), isOn: Binding(get: { !draft.overrides.overridesModel }, set: {
                if $0 { draft.overrides.inheritModel() } else { draft.overrides.copyModel(from: inherited) }
            })).toggleStyle(.checkbox).accessibilityIdentifier("folder.model.inherit")
            if draft.overrides.overridesModel {
                Picker(L("Обработка"), selection: modelString(\.mode, inherited: inherited.mode)) {
                    Text(L("На Mac")).tag("local"); Text(L("В облаке")).tag("cloud")
                }.pickerStyle(.segmented).accessibilityIdentifier("folder.model.mode")
                if effective.mode == "local" { localModel }
                else { cloudModel }
                Button(L("Использовать текущие настройки модели")) { draft.overrides.copyModel(from: inherited) }
                    .buttonStyle(.bordered).accessibilityIdentifier("folder.model.copy")
            } else {
                Label(effective.mode == "local" ? L("На Mac · ") + effective.localModel : L(effective.cloudProviderTitle) + " · " + effective.cloudModel, systemImage: effective.mode == "local" ? "desktopcomputer" : "cloud")
                    .foregroundStyle(Ink.secondaryText).textSelection(.enabled)
            }
            Text(L("Ключи и вход в аккаунт настраиваются в общих настройках. Папка использует подключение выбранного провайдера."))
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.disabled(locked)
    }
    private var localModel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("Источник"), selection: modelString(\.localProvider, inherited: inherited.localProvider)) {
                Text(L("After")).tag("managed"); Text("Ollama").tag("ollama"); Text("LM Studio").tag("lmstudio")
            }
            LabeledContent(L("Модель")) { TextField(L("ID локальной модели"), text: modelString(\.localModel, inherited: inherited.localModel)).textFieldStyle(.roundedBorder).accessibilityIdentifier("folder.model.localModel") }
            if effective.localProvider != "managed" {
                LabeledContent(L("Адрес")) { TextField(effective.resolvedLocalEndpoint, text: modelString(\.localEndpoint, inherited: inherited.localEndpoint)).textFieldStyle(.roundedBorder) }
            }
        }
    }
    private var cloudModel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("Провайдер"), selection: Binding(get: { effective.cloudProvider }, set: { provider in
                var configuration = effective
                configuration.switchCloudProvider(provider)
                draft.overrides.cloudProvider = configuration.cloudProvider
                draft.overrides.cloudModel = configuration.cloudModel.isEmpty ? nil : configuration.cloudModel
                draft.overrides.cloudEndpoint = configuration.cloudEndpoint
                draft.overrides.cloudAPI = configuration.cloudAPI
                draft.overrides.cloudOutput = configuration.cloudOutput
            })) {
                Text(L("ChatGPT (подписка)")).tag("chatgpt"); Text("OpenAI API").tag("openai")
                Text("OpenRouter").tag("openrouter"); Text("Polza").tag("polza"); Text(L("Свой провайдер")).tag("custom")
            }
            LabeledContent(L("Модель")) { TextField(L("ID модели"), text: modelString(\.cloudModel, inherited: inherited.cloudModel)).textFieldStyle(.roundedBorder).accessibilityIdentifier("folder.model.cloudModel") }
            if effective.cloudProvider == "custom" {
                LabeledContent(L("Адрес API")) { TextField("https://example.com/v1", text: modelString(\.cloudEndpoint, inherited: inherited.cloudEndpoint)).textFieldStyle(.roundedBorder) }
            }
            DisclosureGroup(L("Дополнительно")) {
                VStack(alignment: .leading, spacing: 12) {
                    if effective.cloudProvider != "chatgpt" {
                        Picker(L("Формат API"), selection: modelString(\.cloudAPI, inherited: inherited.cloudAPI)) { Text("Chat Completions").tag("chat"); Text("Responses").tag("responses") }
                        Picker(L("Формат ответа"), selection: modelString(\.cloudOutput, inherited: inherited.cloudOutput)) {
                            Text("JSON Schema").tag("schema"); Text("JSON").tag("json"); Text(L("JSON по инструкции")).tag("prompt")
                        }
                    }
                    Picker(L("Рассуждение"), selection: modelString(\.cloudReasoning, inherited: inherited.cloudReasoning)) {
                        Text(L("Без рассуждения")).tag("none"); Text(L("Минимальное")).tag("minimal"); Text(L("Низкое")).tag("low"); Text(L("Среднее")).tag("medium"); Text(L("Высокое")).tag("high")
                    }
                }.padding(.top, 10)
            }
        }
    }
    private func optional(_ field: WritableKeyPath<FolderOverrides, String?>) -> Binding<String> {
        Binding(get: { draft.overrides[keyPath: field] ?? "" }, set: { draft.overrides[keyPath: field] = $0 })
    }
    private func modelString(_ field: WritableKeyPath<FolderOverrides, String?>, inherited value: String) -> Binding<String> {
        Binding(get: { draft.overrides[keyPath: field] ?? value }, set: { draft.overrides[keyPath: field] = $0 })
    }
    private func boolBinding(_ field: WritableKeyPath<FolderOverrides, Bool?>) -> Binding<String> {
        Binding(get: { draft.overrides[keyPath: field].map { $0 ? "on" : "off" } ?? "inherit" }, set: { draft.overrides[keyPath: field] = $0 == "inherit" ? nil : $0 == "on" })
    }
    private func featureBinding(_ feature: AppFeature) -> Binding<String> {
        Binding(get: { draft.overrides.features?[feature].map { $0 ? "on" : "off" } ?? "inherit" }, set: { value in
            var features = draft.overrides.features ?? FolderFeatureOverrides()
            features[feature] = value == "inherit" ? nil : value == "on"; draft.overrides.features = features
        })
    }
    private func close() {
        if draft != baseline { confirmingDiscard = true }
        else { dismiss() }
    }
    private func save() {
        guard !locked else { failure = L("Сохранить настройки можно после завершения записи и обработки."); return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isNew && draft == baseline { UnsavedEditorRegistry.remove(id: editorID); dismiss(); return }
        guard let saved = app.notes.saveFolder(draft) else { failure = app.notes.error ?? L("Не удалось сохранить папку."); return }
        baseline = saved; draft = saved; UnsavedEditorRegistry.remove(id: editorID)
        onSaved?(saved); dismiss()
    }
}
