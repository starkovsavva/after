import PosleCore
import SwiftUI

struct FolderEditorTarget: Identifiable {
    let id = UUID()
    var folder: LibraryFolder
}

/// Folder choices are a sparse layer over app preferences, never a second settings file.
struct FolderSettingsView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var editorID = UUID()
    @State private var baseline: LibraryFolder
    @State private var draft: LibraryFolder
    @State private var failure = ""
    @State private var section = "general"
    @State private var deleting = false
    @State private var confirmingDiscard = false
    let isNew: Bool
    var onSaved: ((LibraryFolder) -> Void)?
    var onDeleted: (() -> Void)?
    init(folder: LibraryFolder, isNew: Bool = false, onSaved: ((LibraryFolder) -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        _draft = State(initialValue: folder); _baseline = State(initialValue: folder); self.isNew = isNew
        self.onSaved = onSaved; self.onDeleted = onDeleted
    }
    private var locked: Bool { app.isRecording || app.startingRecording || app.stoppingRecording || app.isTerminating }
    private var inherited: AppSettings { app.settings }
    private var effective: AppSettings { draft.overrides.apply(to: inherited) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? "Новая папка" : draft.name).font(AppTypography.modalTitle).lineLimit(1)
                    if !isNew { Text("Настройки папки").font(AppTypography.caption).foregroundStyle(Ink.secondaryText) }
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(.plain).accessibilityLabel("Закрыть настройки папки")
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 3) {
                    tab("general", "Общие", "folder")
                    tab("features", "Возможности", "square.grid.2x2")
                    tab("summary", "Конспект и карточки", "text.alignleft")
                    tab("model", "Модель", "sparkles")
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
                HStack {
                    if !isNew {
                        Button("Удалить папку…", role: .destructive) { deleting = true }.disabled(locked).accessibilityIdentifier("folder.delete")
                    }
                    Spacer()
                    Button("Отмена") { close() }.keyboardShortcut(.cancelAction)
                    Button(isNew ? "Создать" : "Сохранить") { save() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        .disabled(locked || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("folder.save")
                }
            }.padding(18)
        }.frame(width: 840, height: 650).background(Ink.paper).tint(Ink.accent).appControlDefaults()
            .onChange(of: draft) { _, value in UnsavedEditorRegistry.set(id: editorID, title: "Настройки папки", dirty: value != baseline) }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .interactiveDismissDisabled(draft != baseline)
            .confirmationDialog("Отменить изменения папки?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Продолжить редактирование", role: .cancel) {}
                Button("Отменить изменения", role: .destructive) { UnsavedEditorRegistry.remove(id: editorID); dismiss() }
            }
            .confirmationDialog("Удалить папку «\(draft.name)»?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Удалить папку", role: .destructive) {
                    if app.notes.deleteFolder(draft) {
                        if app.folderSelection == draft.id { app.folderSelection = nil }
                        onDeleted?(); dismiss()
                    } else { failure = app.notes.error ?? "Не удалось удалить папку." }
                }.accessibilityIdentifier("folder.delete.confirm")
                Button("Отмена", role: .cancel) {}
            } message: { Text("Встречи и заметки останутся в библиотеке. Для них будут действовать настройки приложения.") }
    }
    private func tab(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { section = id } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(section == id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("folder.tab." + id)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Общие").font(AppTypography.heading)
            LabeledContent("Название") {
                TextField("Например, Английский", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("folder.name")
            }
            Text("Встречи и заметки этой папки используют выбранные здесь настройки. «Как в приложении» наследует общие настройки и их будущие изменения.")
                .font(AppTypography.control).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Возможности").font(AppTypography.heading)
            Text("Встречи, заметки, конспекты и транскрипты доступны всегда.").foregroundStyle(Ink.secondaryText)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                ForEach(AppFeature.allCases, id: \.self) { feature in
                    GridRow {
                        Text(FeaturePresentation.title(feature))
                        Picker(FeaturePresentation.title(feature), selection: featureBinding(feature)) {
                            Text("Как в приложении · " + (inherited.features[feature] ? "включено" : "выключено")).tag("inherit")
                            Text("Включено").tag("on")
                            Text("Выключено").tag("off")
                        }.labelsHidden().frame(maxWidth: .infinity).accessibilityIdentifier("folder.feature." + feature.rawValue)
                    }
                }
            }
            Text("Отключение сохраняет данные папки.").font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
        }.disabled(locked)
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Конспект и карточки").font(AppTypography.heading)
            Picker("Язык конспекта", selection: Binding(get: { draft.overrides.language ?? "" }, set: { draft.overrides.language = $0.isEmpty ? nil : $0 })) {
                Text("Как в приложении").tag("")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }.accessibilityIdentifier("folder.language")
            inheritedText("Стиль конспекта", field: \.focus, placeholder: inherited.focus, height: 90)
            inheritedText("Контекст обо мне", field: \.summaryUserContext, placeholder: inherited.summaryUserContext, height: 80)
            Picker("Генерация карточек", selection: boolBinding(\.generateCards)) {
                Text("Не создавать без выбора во встрече").tag("inherit")
                Text("По умолчанию включена").tag("on")
                Text("По умолчанию выключена").tag("off")
            }.accessibilityIdentifier("folder.generateCards")
            Text(effective.features.cards
                 ? "Действует для новых и существующих встреч этой папки. Выбор в меню конкретной встречи имеет приоритет; сохранённые карточки остаются на месте."
                 : "Карточки выключены для папки. Включите их в разделе «Возможности», чтобы создавать автоматически.")
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.disabled(locked)
    }
    @ViewBuilder private func inheritedText(_ title: String, field: WritableKeyPath<FolderOverrides, String?>, placeholder: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(AppTypography.controlStrong)
                Spacer()
                Toggle("Как в приложении", isOn: Binding(get: { draft.overrides[keyPath: field] == nil }, set: {
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
            Text("Модель").font(AppTypography.heading)
            Toggle("Как в приложении", isOn: Binding(get: { !draft.overrides.overridesModel }, set: {
                if $0 { draft.overrides.inheritModel() } else { draft.overrides.copyModel(from: inherited) }
            })).toggleStyle(.checkbox).accessibilityIdentifier("folder.model.inherit")
            if draft.overrides.overridesModel {
                Picker("Обработка", selection: modelString(\.mode, inherited: inherited.mode)) {
                    Text("На Mac").tag("local"); Text("В облаке").tag("cloud")
                }.pickerStyle(.segmented).accessibilityIdentifier("folder.model.mode")
                if effective.mode == "local" { localModel }
                else { cloudModel }
                Button("Использовать текущие настройки модели") { draft.overrides.copyModel(from: inherited) }
                    .buttonStyle(.bordered).accessibilityIdentifier("folder.model.copy")
            } else {
                Label(effective.mode == "local" ? "На Mac · " + effective.localModel : effective.cloudProviderTitle + " · " + effective.cloudModel, systemImage: effective.mode == "local" ? "desktopcomputer" : "cloud")
                    .foregroundStyle(Ink.secondaryText).textSelection(.enabled)
            }
            Text("Ключи и вход в аккаунт настраиваются в общих настройках. Папка использует подключение выбранного провайдера.")
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.disabled(locked)
    }
    private var localModel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Источник", selection: modelString(\.localProvider, inherited: inherited.localProvider)) {
                Text("После").tag("managed"); Text("Ollama").tag("ollama"); Text("LM Studio").tag("lmstudio")
            }
            LabeledContent("Модель") { TextField("ID локальной модели", text: modelString(\.localModel, inherited: inherited.localModel)).textFieldStyle(.roundedBorder).accessibilityIdentifier("folder.model.localModel") }
            if effective.localProvider != "managed" {
                LabeledContent("Адрес") { TextField(effective.resolvedLocalEndpoint, text: modelString(\.localEndpoint, inherited: inherited.localEndpoint)).textFieldStyle(.roundedBorder) }
            }
        }
    }
    private var cloudModel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Провайдер", selection: Binding(get: { effective.cloudProvider }, set: { provider in
                var configuration = effective
                configuration.switchCloudProvider(provider)
                draft.overrides.cloudProvider = configuration.cloudProvider
                draft.overrides.cloudModel = configuration.cloudModel.isEmpty ? nil : configuration.cloudModel
                draft.overrides.cloudEndpoint = configuration.cloudEndpoint
                draft.overrides.cloudAPI = configuration.cloudAPI
                draft.overrides.cloudOutput = configuration.cloudOutput
            })) {
                Text("ChatGPT (подписка)").tag("chatgpt"); Text("OpenAI API").tag("openai")
                Text("OpenRouter").tag("openrouter"); Text("Polza").tag("polza"); Text("Свой провайдер").tag("custom")
            }
            LabeledContent("Модель") { TextField("ID модели", text: modelString(\.cloudModel, inherited: inherited.cloudModel)).textFieldStyle(.roundedBorder).accessibilityIdentifier("folder.model.cloudModel") }
            if effective.cloudProvider == "custom" {
                LabeledContent("Адрес API") { TextField("https://example.com/v1", text: modelString(\.cloudEndpoint, inherited: inherited.cloudEndpoint)).textFieldStyle(.roundedBorder) }
            }
            DisclosureGroup("Дополнительно") {
                VStack(alignment: .leading, spacing: 12) {
                    if effective.cloudProvider != "chatgpt" {
                        Picker("Формат API", selection: modelString(\.cloudAPI, inherited: inherited.cloudAPI)) { Text("Chat Completions").tag("chat"); Text("Responses").tag("responses") }
                        Picker("Формат ответа", selection: modelString(\.cloudOutput, inherited: inherited.cloudOutput)) {
                            Text("JSON Schema").tag("schema"); Text("JSON").tag("json"); Text("JSON по инструкции").tag("prompt")
                        }
                    }
                    Picker("Рассуждение", selection: modelString(\.cloudReasoning, inherited: inherited.cloudReasoning)) {
                        Text("Без рассуждения").tag("none"); Text("Минимальное").tag("minimal"); Text("Низкое").tag("low"); Text("Среднее").tag("medium"); Text("Высокое").tag("high")
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
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isNew && draft == baseline { UnsavedEditorRegistry.remove(id: editorID); dismiss(); return }
        guard let saved = app.notes.saveFolder(draft) else { failure = app.notes.error ?? "Не удалось сохранить папку."; return }
        baseline = saved; draft = saved; UnsavedEditorRegistry.remove(id: editorID)
        onSaved?(saved); dismiss()
    }
}
