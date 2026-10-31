import AfterPlatform
import AfterPlatformMacOS
import AfterLocalization
import Foundation
import AfterCore
import SwiftUI

private struct KnowledgeTopicSource: Decodable, Identifiable {
    let noteID: String
    let revision: UInt64
    var id: String { noteID }
}
private struct KnowledgeTopic: Decodable, Identifiable {
    let id: String
    let terms: [String]
    let sources: [KnowledgeTopicSource]
    let method: String
}
private struct KnowledgeCollection: Decodable, Identifiable {
    let id: String
    let name: String
    let nameRedacted: Bool
    let pinned: Bool
    let hidden: Bool
    let revision: UInt64
    let sources: [KnowledgeTopicSource]
}
private struct KnowledgeTopicResult: Decodable {
    let workspaceRevision: UInt64
    let kbRevision: UInt64
    let topics: [KnowledgeTopic]
    let collections: [KnowledgeCollection]
    let examined: Int
    let total: Int
    let topicTotal: Int
    let offset: Int
    let nextOffset: Int?
    let partial: Bool
    let noteLimitReached: Bool
    let topicLimitReached: Bool
    let approximate: Bool
    let method: String
    let semanticIndexed: Int
    let semanticEligible: Int
}
private struct KnowledgeTopicRevision: Decodable {
    let workspaceRevision: UInt64
    let kbRevision: UInt64
}

@MainActor
private final class KnowledgeTopicsController: ObservableObject {
    @Published private(set) var result: KnowledgeTopicResult?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var topicRequestID: String?
    private var mutationTask: Task<Void, Never>?
    private static func request(root: URL, command: String, arguments: [String: Any]) async throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await Task.detached(priority: .utility) {
            guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                throw AppError.message(L("Не удалось подготовить запрос."))
            }
            return try RustBridge.shared.get().request(root: root, command: command, arguments: object)
        }.value
    }
    func load(root: URL, folderID: String?, offset: Int) {
        cancelTopic(root:root)
        generation = UUID(); let current = generation
        let requestID = UUID().uuidString.lowercased(); topicRequestID = requestID
        busy = true; error = nil; result = nil
        task = Task {
            do {
                // Allow consecutive edits to settle before starting a bounded
                // local rebuild; a changed revision discards an older result.
                try await Task.sleep(for: .milliseconds(200))
                let initial = try await Self.request(root: root, command: "kb-snapshot", arguments: [:])
                try Task.checkCancellation()
                let version = try JSONDecoder().decode(KnowledgeTopicRevision.self, from: initial)
                var input: [String: Any] = ["expectedWorkspaceRevision":version.workspaceRevision,
                                            "expectedKBRevision":version.kbRevision, "offset":offset, "requestID":requestID]
                if let folderID { input["folderID"] = folderID }
                let data = try await Self.request(root: root, command: "kb-topics", arguments: input)
                let topics = try JSONDecoder().decode(KnowledgeTopicResult.self, from: data)
                guard current == generation, !Task.isCancelled else { return }
                result = topics; busy = false; task = nil; topicRequestID = nil
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                busy = false; task = nil; topicRequestID = nil; self.error = error.localizedDescription
            }
        }
    }
    func change(root: URL, arguments: [String: Any], completed: @escaping (Bool) -> Void) {
        guard !busy, mutationTask == nil, let result else { return }
        busy = true; error = nil
        var input = arguments
        input["operationID"] = UUID().uuidString.lowercased()
        input["expectedWorkspaceRevision"] = result.workspaceRevision
        input["expectedKBRevision"] = result.kbRevision
        mutationTask = Task {
            do {
                _ = try await Self.request(root: root, command: "kb-collection-change", arguments: input)
                mutationTask = nil; busy = false; completed(true)
            } catch {
                mutationTask = nil; busy = false; self.error = error.localizedDescription; completed(false)
            }
        }
    }
    private func cancelTopic(root: URL) {
        let requestID = topicRequestID
        task?.cancel(); task = nil; topicRequestID = nil
        if let requestID {
            Task.detached(priority:.utility) {
                _ = try? RustBridge.shared.get().request(root:root, command:"kb-topics-cancel", arguments:["requestID":requestID])
            }
        }
    }
    func stop(root: URL) {
        generation = UUID(); cancelTopic(root:root); busy = false
    }
}

struct KnowledgeBaseView: View {
    @EnvironmentObject private var app: AppStore
    @StateObject private var controller = KnowledgeTopicsController()
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var navigationError: String?
    @State private var topicOffset = 0
    @State private var section = "materials"
    @State private var refreshToken = UUID()
    @State private var creatingCollection = false
    @State private var newCollectionName = ""
    @State private var showingRebuild = false
    @State private var showHiddenCollections = false
    @State private var renameCollection: KnowledgeCollection?
    @State private var addingCollection: KnowledgeCollection?
    @State private var collectionName = ""
    @State private var showingRenameCollection = false
    @State private var notesByID: [String: CapturedNote] = [:]
    private func available(_ note: CapturedNote) -> Bool {
        note.kind == "note" && note.trashedAt == nil &&
            app.effectiveSettings(for: note.folderID == nil ? note.meetingID : nil,
                                  folderID: note.folderID).features.knowledgeBase
    }
    private func note(_ source: KnowledgeTopicSource) -> CapturedNote? {
        guard let note=notesByID[source.noteID], note.revision >= 0 && UInt64(note.revision) == source.revision && available(note) else { return nil }
        return note
    }
    private func indexNotes() { notesByID = Dictionary(app.notes.workspace.notes.map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first }) }
    private var visible: [KnowledgeTopic] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (controller.result?.topics ?? []).filter { topic in
            let live = topic.sources.compactMap(note)
            guard live.count >= 4 else { return false }
            return search.isEmpty || topic.terms.joined(separator: " ").localizedCaseInsensitiveContains(search) ||
                live.contains { $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) }
        }
    }
    private var captureActive: Bool { app.isRecording || app.startingRecording || app.stoppingRecording }
    private func reload() {
        navigationError = nil
        if captureActive { controller.stop(root: app.root); return }
        controller.load(root: app.root, folderID: app.folderSelection, offset: topicOffset)
    }
    private func refreshPage() {
        app.notes.reload(); app.reloadLibrary(); indexNotes()
        topicOffset = 0; refreshToken = UUID(); reload()
    }
    private func open(_ source: KnowledgeTopicSource) {
        app.notes.reload()
        indexNotes()
        guard let current = note(source) else {
            navigationError = L("Заметка изменилась или стала недоступна. Обновите темы.")
            return
        }
        app.openCapturedNote(current)
    }
    private func change(_ arguments: [String: Any]) {
        controller.change(root: app.root, arguments: arguments) { succeeded in
            if succeeded { app.notes.reload(); topicOffset = 0; reload() }
        }
    }
    private func saveTopic(_ topic: KnowledgeTopic) {
        let title = KnowledgeMaterialPresentation.topicTitle(terms: topic.terms, semantic: topic.method == "mixed", notesOnly: true)
        change(["action":"create", "name":title,
                "sources":topic.sources.map { ["noteID":$0.noteID,"revision":$0.revision] }])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("База знаний")).font(AppTypography.pageTitle)
                    Text(L("Найдите материал, откройте источник или соберите подборку."))
                        .font(AppTypography.control).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Переорганизовать…")) { showingRebuild = true }
                    .disabled(captureActive || app.busy)
                    .accessibilityIdentifier("knowledge.rebuild.open")
                Button(L("Обновить список")) { refreshPage() }.disabled(controller.busy || captureActive)
                    .accessibilityIdentifier("knowledge.topics.refresh")
            }.padding(AppLayout.contentInset)
            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AppTabBar(label: L("База знаний"), selection: $section,
                        tabs: [AppTab(L("Материалы"), value: "materials"), AppTab(L("Подборки"), value: "collections")],
                        identifier: "knowledge.section")
                    Spacer()
                    if section == "collections" {
                        Button(L("Создать подборку")) { newCollectionName = L("Новая подборка"); creatingCollection = true }
                            .buttonStyle(.bordered).disabled(controller.busy || controller.result == nil)
                            .accessibilityIdentifier("knowledge.collection.create")
                    }
                }
                TextField(L("Найти заметку или встречу"), text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("knowledge.topics.search")
                if section == "materials" {
                    KnowledgeMaterialsView(query: query)
                } else {
                if captureActive {
                    Text(L("Построение тем приостановлено на время записи."))
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("knowledge.topics.paused")
                } else if controller.busy {
                    HStack { ProgressView().controlSize(.small); Text(L("Собираю темы…")) }
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                } else if let message = navigationError ?? controller.error {
                    Label(message, systemImage: "exclamationmark.circle").font(AppTypography.caption)
                        .foregroundStyle(Ink.warning).textSelection(.enabled)
                } else if let result = controller.result {
                    if !result.collections.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L("Сохранённые подборки")).font(AppTypography.controlStrong)
                                    .accessibilityIdentifier("knowledge.collections.heading")
                                Spacer()
                                if result.collections.contains(where: \.hidden) {
                                    Toggle(L("Показать скрытые"), isOn: $showHiddenCollections)
                                        .toggleStyle(.checkbox).font(AppTypography.caption)
                                }
                            }
                            VStack(alignment: .leading, spacing: 10) {
                               ForEach(result.collections.filter { collection in
                                   (!collection.hidden || showHiddenCollections) &&
                                   (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    collection.name.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)))
                               }) { collection in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: collection.pinned ? "pin.fill" : "folder")
                                            .foregroundStyle(Ink.accent)
                                        Text(collection.nameRedacted ? L("Подборка") : collection.name).font(AppTypography.heading).lineLimit(2)
                                        if collection.hidden { Text(L("Скрыта")).font(AppTypography.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                        Button { addingCollection=collection } label: { Image(systemName:"plus").frame(width:24,height:24) }
                                            .buttonStyle(.plain).help(L("Добавить заметки"))
                                            .accessibilityLabel(L("Добавить заметки"))
                                            .accessibilityIdentifier("knowledge.collection.add.\(collection.id)")
                                            .disabled(controller.busy || collection.nameRedacted || collection.sources.count >= 200)
                                        Menu {
                                            Button(L("Переименовать…")) {
                                                renameCollection=collection; collectionName=collection.name; showingRenameCollection=true
                                            }.disabled(collection.nameRedacted)
                                            Button(collection.pinned ? L("Открепить") : L("Закрепить")) {
                                                change(["action":collection.pinned ? "unpin" : "pin","collectionID":collection.id,"expectedRevision":collection.revision])
                                            }
                                            Button(collection.hidden ? L("Показать") : L("Скрыть")) {
                                                change(["action":collection.hidden ? "unhide" : "hide","collectionID":collection.id,"expectedRevision":collection.revision])
                                            }
                                        } label: { Image(systemName:"ellipsis").frame(width:24,height:24) }
                                            .menuStyle(.borderlessButton).fixedSize().disabled(controller.busy)
                                            .accessibilityLabel(L("Действия с подборкой"))
                                    }
                                    ForEach(Array(collection.sources.prefix(expanded.contains("saved:" + collection.id) ? collection.sources.count : 6))) { source in
                                        if let note = note(source) {
                                            HStack {
                                                Button { open(source) } label: {
                                                    KnowledgeMaterialRow(title: note.displayTitle,
                                                        metadata: KnowledgeMaterialPresentation.metadata(note), meeting: false)
                                                }.buttonStyle(.plain).accessibilityIdentifier("knowledge.collection.note.\(source.noteID)")
                                                Button {
                                                    change(["action":"remove-source","collectionID":collection.id,"expectedRevision":collection.revision,
                                                            "noteID":source.noteID,"noteRevision":source.revision])
                                                } label: { Image(systemName:"xmark").frame(width:22,height:22) }
                                                    .buttonStyle(.plain).help(L("Убрать из подборки"))
                                                    .accessibilityLabel(L("Убрать из подборки"))
                                                    .accessibilityIdentifier("knowledge.collection.remove.\(collection.id).\(source.noteID)")
                                                    .disabled(controller.busy || collection.nameRedacted || collection.sources.count<=1)
                                            }
                                        }
                                    }
                                    if collection.sources.count > 6 {
                                        Button(expanded.contains("saved:" + collection.id) ? L("Свернуть") : L("Показать все заметки")) {
                                            let id="saved:" + collection.id
                                            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                                        }.buttonStyle(.borderless).font(AppTypography.caption)
                                    }
                                }.padding(14).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
                               }
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("Предложенные связи")).font(AppTypography.heading)
                        Spacer()
                        Button(L("Настроить поиск по смыслу…")) {
                            app.openSettings(app.isFeatureEnabled(.semanticSearch) ? "semantic" : "features")
                        }.buttonStyle(.borderless).font(AppTypography.caption)
                            .accessibilityIdentifier("knowledge.topics.semantic-settings")
                    }
                    KnowledgeMixedTopicsView(query: query, refreshToken: refreshToken)
                    if result.offset > 0 || result.nextOffset != nil {
                        HStack {
                            if result.offset > 0 { Button(L("Назад")) { topicOffset=max(0,result.offset-50); expanded.removeAll(); reload() } }
                            if let next = result.nextOffset { Button(L("Следующая страница")) { topicOffset=next; expanded.removeAll(); reload() } }
                        }.buttonStyle(.borderless).font(AppTypography.caption)
                    }
                    if result.topicLimitReached {
                        Text(L("Показаны не все найденные темы."))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                    if visible.isEmpty {
                        Text(query.isEmpty ? L("Подборку заметок можно создать вручную, не дожидаясь предложений.") : L("Нет предложенных подборок заметок по этому запросу."))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                            ForEach(visible) { topic in
                                let sources = topic.sources.filter { note($0) != nil }
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Image(systemName: "books.vertical").foregroundStyle(Ink.accent)
                                        Text(KnowledgeMaterialPresentation.topicTitle(terms: topic.terms, semantic: topic.method == "mixed", notesOnly: true))
                                            .font(AppTypography.heading).lineLimit(2)
                                        Spacer()
                                        Text(String(sources.count)).font(AppTypography.caption).foregroundStyle(.secondary)
                                        Button { saveTopic(topic) } label: { Image(systemName:"pin") }
                                            .buttonStyle(.plain).help(L("Сохранить как подборку"))
                                            .accessibilityLabel(L("Сохранить как подборку"))
                                            .accessibilityIdentifier("knowledge.topic.save.\(topic.id)")
                                            .disabled(controller.busy)
                                    }
                                    DisclosureGroup(L("Почему связаны")) {
                                        Text(topic.method == "mixed" ? L("Предложено по смыслу и общим словам") : L("Предложено по общим словам"))
                                        if !topic.terms.isEmpty {
                                            Text(LF("Общие слова: {0}", arguments: [topic.terms.joined(separator: ", ")]))
                                        }
                                    }.font(AppTypography.caption).foregroundStyle(.secondary)
                                    ForEach(Array(sources.prefix(expanded.contains(topic.id) ? sources.count : 6))) { source in
                                        if let note = note(source) {
                                            Button { open(source) } label: {
                                                KnowledgeMaterialRow(title: note.displayTitle,
                                                    metadata: KnowledgeMaterialPresentation.metadata(note), meeting: false)
                                            }.buttonStyle(.plain)
                                                .accessibilityIdentifier("knowledge.topic.note.\(source.noteID)")
                                        }
                                    }
                                    if sources.count > 6 {
                                        Button(expanded.contains(topic.id) ? L("Свернуть") : L("Показать все заметки")) {
                                            if expanded.contains(topic.id) { expanded.remove(topic.id) } else { expanded.insert(topic.id) }
                                        }.buttonStyle(.borderless).font(AppTypography.caption)
                                    }
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
                            }
                    }
                }
                }
                DisclosureGroup(L("Как это работает")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Материалы — сохранённые заметки и расшифрованные встречи. Поиск здесь проверяет названия и текст заметок; содержимое встреч доступно в отдельном поиске."))
                        Text(L("В подборках можно сохранить выбранные заметки или предложенную связь. Поиск по смыслу необязателен: без него предложения основаны на общих словах."))
                        Text(L("Предложения могут быть неполными. Исходные заметки и встречи не изменяются."))
                    }.font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(AppTypography.caption).foregroundStyle(.secondary)
            }.padding(AppLayout.contentInset).frame(maxWidth: .infinity, alignment: .topLeading)
            }.accessibilityIdentifier("knowledge.page-scroll")
        }.background(Ink.paper)
            .sheet(isPresented: $showingRebuild) { KnowledgeRebuildSheet(store: app) }
            .sheet(isPresented: $creatingCollection) {
                KnowledgeCollectionPicker(excluded: [], capacity: 200, title: L("Новая подборка"), name: $newCollectionName) { selected in
                    change(["action":"create", "name":newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines),
                            "sources":selected.map { ["noteID":$0.id,"revision":$0.revision] }])
                    creatingCollection = false
                }.environmentObject(app)
            }
            .sheet(item:$addingCollection) { collection in
                KnowledgeCollectionPicker(excluded:Set(collection.sources.map(\.noteID)),
                    capacity:200-collection.sources.count) { selected in
                    change(["action":"add-sources","collectionID":collection.id,"expectedRevision":collection.revision,
                            "sources":selected.map { ["noteID":$0.id,"revision":$0.revision] }])
                    addingCollection=nil
                }.environmentObject(app)
            }
            .alert(L("Переименовать подборку"), isPresented: $showingRenameCollection) {
                TextField(L("Название"), text: $collectionName)
                Button(L("Отмена"), role: .cancel) { renameCollection=nil }
                Button(L("Сохранить")) {
                    if let collection=renameCollection {
                        change(["action":"rename","collectionID":collection.id,"expectedRevision":collection.revision,"name":collectionName])
                    }
                    renameCollection=nil
                }
            }
            .onAppear { indexNotes(); reload() }
            .onDisappear { controller.stop(root:app.root) }
            .onChange(of: captureActive) { _, _ in reload() }
            .onChange(of: app.folderSelection) { _, _ in topicOffset=0; expanded.removeAll(); reload() }
            .onChange(of: app.notes.workspace.notes) { _, _ in indexNotes(); topicOffset=0; reload() }
            .onChange(of: app.notes.workspace.folders) { _, _ in topicOffset=0; reload() }
            .onChange(of: app.settings.features) { _, _ in topicOffset=0; reload() }
            .onReceive(NotificationCenter.default.publisher(for: .knowledgeRebuildChanged)) { notification in
                if let changedRoot = notification.object as? URL,
                   changedRoot.standardizedFileURL.resolvingSymlinksInPath() == app.root.standardizedFileURL.resolvingSymlinksInPath() { refreshPage() }
            }
    }
}

/// User explicitly chooses note IDs; the callback captures each displayed
/// revision so edits while the picker is open cannot be added unnoticed.
private struct KnowledgeCollectionPicker: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<String>
    let capacity: Int
    var title = L("Добавить заметки")
    var name: Binding<String>? = nil
    let onAdd: ([CapturedNote]) -> Void
    @State private var query=""
    @State private var selected: [String:Int]=[:]
    @State private var error: String?

    private func permitted(_ note: CapturedNote) -> Bool {
        guard note.kind == "note", note.trashedAt == nil, !excluded.contains(note.id) else {return false}
        let folder=note.folderID ?? note.meetingID.flatMap { app.folderID(for:$0) }
        guard app.folderSelection == nil || folder == app.folderSelection else {return false}
        return app.effectiveSettings(for:note.folderID == nil ? note.meetingID : nil,folderID:note.folderID).features.knowledgeBase
    }
    private var candidates: [CapturedNote] {
        let value=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return app.notes.workspace.notes.filter { note in
            permitted(note) && (value.isEmpty || note.displayTitle.localizedCaseInsensitiveContains(value) ||
                note.text.localizedCaseInsensitiveContains(value))
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            AppPageHeader(title:title,modal:true)
            if let name {
                TextField(L("Название подборки"), text: name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("knowledge.collection.pick.name")
            }
            Text(L("Выберите заметки. Их содержимое останется без изменений."))
                .font(AppTypography.control).foregroundStyle(.secondary)
            Text(LF("Доступно мест в подборке: {0}",arguments:[String(capacity)]))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            TextField(L("Поиск заметок"),text:$query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:8) {
                    ForEach(candidates) { note in
                        Toggle(isOn:Binding(get:{selected[note.id] != nil},set:{value in
                            if value { if selected.count < capacity {selected[note.id]=note.revision} }
                            else {selected.removeValue(forKey:note.id)}
                        })) {
                            Text(note.displayTitle).lineLimit(2)
                        }.toggleStyle(.checkbox)
                            .disabled(selected[note.id] == nil && selected.count >= capacity)
                            .accessibilityIdentifier("knowledge.collection.pick.\(note.id)")
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:.infinity)
            if let error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
            HStack {
                Text(LF("Выбрано: {0}",arguments:[String(selected.count)])).font(AppTypography.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Отмена")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(name == nil ? L("Добавить") : L("Создать подборку")) {
                    let byID=Dictionary(app.notes.workspace.notes.map {($0.id,$0)},uniquingKeysWith:{first,_ in first})
                    let picked=selected.keys.sorted().compactMap { id -> CapturedNote? in
                        guard let note=byID[id],permitted(note),note.revision==selected[id] else {return nil}
                        return note
                    }
                    guard picked.count==selected.count else {
                        error=L("Заметки изменились или стали недоступны. Выберите их заново."); return
                    }
                    onAdd(picked)
                }.disabled(selected.isEmpty || name.map { $0.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("knowledge.collection.pick.confirm")
            }
        }.padding(24).frame(minWidth:500,idealWidth:580,minHeight:420,idealHeight:540).appControlDefaults()
    }
}
