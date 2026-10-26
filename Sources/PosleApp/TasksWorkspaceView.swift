import AppKit
import PosleCore
import SwiftUI

/// Task mutations use the same revision-checked domain operations as voice
/// commands. A summary task acquires one stable note identity before editing.
extension NotesStore {
    @discardableResult func materializeTask(_ task: LibraryTask) -> CapturedNote? {
        performTaskOperation(task, command: "task-materialize", arguments: [:])
    }
    @discardableResult func updateTask(_ task: LibraryTask, patch: [String: Any], expectedRevision: Int? = nil) -> CapturedNote? {
        var arguments: [String: Any] = ["patch": patch]
        if let revision = expectedRevision ?? task.noteRevision { arguments["expectedRevision"] = revision }
        return performTaskOperation(task, command: "task-update", arguments: arguments)
    }
    @discardableResult func appendTask(_ task: LibraryTask, text: String) -> CapturedNote? {
        var arguments: [String: Any] = ["text": text]
        if let revision = task.noteRevision { arguments["expectedRevision"] = revision }
        return performTaskOperation(task, command: "task-append", arguments: arguments)
    }
    /// A voice command can materialize a summary task while its inline draft
    /// is hidden. Reconcile by stable provenance instead of a summary position.
    func reconcileTaskDrafts() {
        for task in tasks {
            guard let originalID = task.taskOrigin?.summaryTaskID, originalID != task.id else { continue }
            for prefix in ["taskappend", "tasksubtask", "taskmeta"] {
                let original = "\(prefix):\(originalID)"
                let canonical = "\(prefix):\(task.id)"
                if let text = captureDrafts[original], captureDrafts[canonical] == nil || captureDrafts[canonical] == "" {
                    captureDrafts[canonical] = text
                    captureDrafts.removeValue(forKey: original)
                }
            }
            if selectedTaskID == originalID { selectedTaskID = task.id }
        }
    }
    /// Editing a generated task explicitly accepts it into the tracker. Bind
    /// the first character to a UUID before a regenerated summary can remove it.
    func setTaskDraft(_ text: String, task: LibraryTask, prefix: String) {
        let original = "\(prefix):\(task.id)"
        guard task.noteID == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            captureDrafts[original] = text
            return
        }
        guard let note = materializeTask(task) else {
            captureDrafts[original] = text
            return
        }
        captureDrafts["\(prefix):manual:\(note.id)"] = text
    }
    private func performTaskOperation(_ task: LibraryTask, command: String, arguments: [String: Any]) -> CapturedNote? {
        do {
            var input = arguments; input["taskID"] = task.id
            if task.noteID == nil, let meetingID = task.meetingID {
                input["expectedSource"] = ["text": task.text, "segmentIDs": task.segmentIDs, "meetingID": meetingID]
            }
            let data = try RustBridge.shared.get().request(root: root, command: command, arguments: input)
            let saved = try JSONDecoder().decode(CapturedNote.self, from: data)
            let canonicalID = "manual:\(saved.id)"
            reload(); loadTasks(); selectedTaskID = canonicalID; error = nil
            return saved
        } catch { self.error = error.localizedDescription; return nil }
    }
}

private struct TaskMetadataDraft: Codable {
    var owner: String
    var due: String
    var revision: Int?
}

struct TasksWorkspaceView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @State private var filter = "open"
    @State private var query = ""
    @State private var editing: CapturedNote?
    private var newTask: Binding<String> { draft("newtask") }
    private func draft(_ key: String) -> Binding<String> {
        Binding(get: { notes.captureDrafts[key] ?? "" }, set: { notes.captureDrafts[key] = $0 })
    }
    private func taskDraft(_ task: LibraryTask, prefix: String) -> Binding<String> {
        Binding(get: { notes.captureDrafts["\(prefix):\(task.id)"] ?? "" },
                set: { notes.setTaskDraft($0, task: task, prefix: prefix) })
    }
    private var filtered: [LibraryTask] {
        notes.tasks.filter { task in
            (filter == "all" || (filter == "open" ? !task.completed : task.completed)) &&
            (query.isEmpty || [task.text, task.owner, task.due, task.title, task.taskTitle ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }
    private var selected: LibraryTask? {
        guard let id = notes.selectedTaskID else { return nil }
        return notes.tasks.first { $0.id == id || $0.noteID == id || $0.taskOrigin?.summaryTaskID == id }
    }
    private func isSelected(_ task: LibraryTask) -> Bool {
        guard let id = notes.selectedTaskID else { return false }
        return task.id == id || task.noteID == id || task.taskOrigin?.summaryTaskID == id
    }
    private var groups: [(String, [LibraryTask])] {
        let active = filtered.filter { !$0.completed }
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        var dated: [(task: LibraryTask, date: Date)] = []
        for task in active { if let date = deadline(task) { dated.append((task, date)) } }
        dated.sort { left, right in
            if left.date == right.date { return left.task.text.localizedStandardCompare(right.task.text) == .orderedAscending }
            return left.date < right.date
        }
        let datedIDs = Set(dated.map { $0.task.id })
        var overdue: [LibraryTask] = []
        var dueToday: [LibraryTask] = []
        var upcoming: [LibraryTask] = []
        for entry in dated {
            if entry.date < today { overdue.append(entry.task) }
            else if entry.date < tomorrow { dueToday.append(entry.task) }
            else { upcoming.append(entry.task) }
        }
        let unresolved = active.filter { !$0.due.isEmpty && !datedIDs.contains($0.id) }
        let noDeadline = active.filter { $0.due.isEmpty }
        let completed = filtered.filter(\.completed)
        let result: [(String, [LibraryTask])] = [("Просрочено", overdue), ("Сегодня", dueToday),
            ("Предстоящие", upcoming), ("Уточнить срок", unresolved), ("Без срока", noDeadline), ("Завершённые", completed)]
        return result.filter { !$0.1.isEmpty }
    }
    var body: some View {
        HStack(spacing: 0) {
            taskList.frame(width: 300)
            Divider()
            if let task = selected { detail(task) }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "checklist").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text(notes.tasks.isEmpty ? "Добавьте первую задачу" : "Выберите задачу").font(AppTypography.emptyTitle)
                    Button("Надиктовать задачу") { app.voice.present() }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            notes.reload(); notes.loadTasks()
            if selected == nil { notes.selectedTaskID = filtered.first?.id }
        }
        .onChange(of: filter) { _, _ in selectFirstFilteredIfNeeded() }
        .onChange(of: query) { _, _ in selectFirstFilteredIfNeeded() }
        .onChange(of: notes.workspace.notes) { _, _ in notes.loadTasks() }
        .onChange(of: app.busy) { _, busy in if !busy { notes.reload(); notes.loadTasks() } }
        .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
        .sheet(item: $editing, onDismiss: { notes.loadTasks() }) { note in NoteEditorView(notes: notes, note: note).environmentObject(app) }
    }
    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppListHeader(title: "Задачи") {
                Button { notes.reload(); notes.loadTasks(); app.reloadLibrary() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Обновить задачи")
            }
            Picker("Статус задач", selection: $filter) {
                Text("В работе").tag("open"); Text("Готово").tag("done"); Text("Все").tag("all")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в задачах", text: $query).textFieldStyle(.plain)
            }.padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 12).padding(.bottom, 12)
            HStack(spacing: 7) {
                TextField("Новая задача", text: newTask).textFieldStyle(.plain).onSubmit(addTask).accessibilityIdentifier("tasks.new-text")
                Button(action: addTask) { Image(systemName: "plus.circle").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).disabled(newTask.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Добавить задачу")
            }.padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { title, tasks in
                        Text(title).font(AppTypography.captionStrong).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                        ForEach(tasks) { task in row(task) }
                    }
                    if filtered.isEmpty {
                        Text(query.isEmpty ? filter == "done" ? "Нет завершённых задач" : "Задач пока нет" : "Задачи не найдены")
                            .font(AppTypography.control).foregroundStyle(.secondary).padding(16)
                    }
                }
            }
        }.background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }
    private func row(_ task: LibraryTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { complete(task) } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
                    .foregroundStyle(task.completed ? Ink.green : Color.secondary).frame(width: 26, height: 26)
            }.buttonStyle(.plain).accessibilityLabel((task.completed ? "Вернуть в работу: " : "Завершить задачу: ") + Self.title(task))
            Button { notes.selectedTaskID = task.id } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.title(task)).font(isSelected(task) ? AppTypography.controlStrong : AppTypography.control)
                        .lineLimit(2).strikethrough(task.completed).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 7) {
                        if !task.due.isEmpty { Text(displayDeadline(task)).foregroundStyle(isOverdue(task) ? Ink.warning : Color.secondary) }
                        if !task.owner.isEmpty { Text(task.owner).foregroundStyle(.secondary) }
                    }.font(AppTypography.caption).lineLimit(1)
                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(isSelected(task) ? .isSelected : [])
                .accessibilityIdentifier("tasks.row." + task.id).accessibilityValue(isSelected(task) ? "Выбрана" : "")
        }.padding(.horizontal, 8).padding(.vertical, 8)
            .background(isSelected(task) ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8).padding(.bottom, 3)
    }
    private func detail(_ task: LibraryTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(Self.title(task)).font(AppTypography.pageTitle).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("tasks.detail-title")
                        Button {
                            if let note = notes.materializeTask(task) { editing = note }
                        } label: { Image(systemName: "pencil").frame(width: 24, height: 24) }.buttonStyle(.plain).accessibilityLabel("Изменить задачу")
                    }
                    HStack(spacing: 12) {
                        Button(task.completed ? "Вернуть в работу" : "Завершить") { complete(task) }.buttonStyle(.bordered)
                        Button { app.voice.present(taskID: task.id, title: Self.title(task)) } label: { Label("Дополнить голосом", systemImage: "mic") }.buttonStyle(.borderless)
                    }
                    metadata(task)
                    if let text = description(task), !text.isEmpty { Text(text).font(AppTypography.body).lineSpacing(6).textSelection(.enabled) }
                }
                subtasks(task)
                append(task)
                if let history = task.history, !history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("История").font(AppTypography.heading)
                        ForEach(history.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.text).font(AppTypography.body).lineSpacing(4).textSelection(.enabled)
                                Text(Date(timeIntervalSince1970: entry.createdAt).formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "ru_RU")))).font(AppTypography.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
                source(task)
            }.appContentLayout()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private func metadata(_ task: LibraryTask) -> some View {
        let key = "taskmeta:\(task.id)"
        if let value = metadataDraft(task) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Ответственный", text: Binding(get: { metadataDraft(task)?.owner ?? value.owner }, set: { owner in var next = metadataDraft(task) ?? value; next.owner = owner; saveMetadataDraft(next, key: key) })).textFieldStyle(.roundedBorder)
                deadlineEditor(task, value: value, key: key)
                HStack {
                    Button("Отмена") { clearDraft(key) }
                    Button("Сохранить") {
                        guard let next = metadataDraft(task) else { return }
                        if notes.updateTask(task, patch: ["owner": next.owner, "due": next.due], expectedRevision: next.revision) != nil { clearDraft(key) }
                    }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                }
            }.font(AppTypography.control)
        } else {
            HStack(spacing: 12) {
                if !task.owner.isEmpty { Label(task.owner, systemImage: "person").lineLimit(1).help(task.owner) }
                if !task.due.isEmpty { Label(displayDeadline(task), systemImage: "calendar").lineLimit(1).help(task.due).foregroundStyle(isOverdue(task) ? Ink.warning : Color.secondary) }
                Button(task.owner.isEmpty && task.due.isEmpty ? "Указать срок и ответственного" : "Изменить") {
                    guard let note = notes.materializeTask(task) else { return }
                    saveMetadataDraft(TaskMetadataDraft(owner: note.owner, due: note.due, revision: note.revision), key: "taskmeta:manual:\(note.id)")
                }.buttonStyle(.borderless)
                Spacer(minLength: 0)
                TaskCalendarButton(task: task)
            }.font(AppTypography.control).foregroundStyle(.secondary)
            TaskCalendarSummary(task: task)
        }
    }
    private func subtasks(_ task: LibraryTask) -> some View {
        let key = "tasksubtask:\(task.id)"
        return VStack(alignment: .leading, spacing: 12) {
            Text("Подзадачи").font(AppTypography.heading)
            ForEach(task.subtasks ?? []) { subtask in
                HStack(alignment: .top, spacing: 9) {
                    Button {
                        var items = task.subtasks ?? []
                        if let index = items.firstIndex(where: { $0.id == subtask.id }) { items[index].completed.toggle(); saveSubtasks(items, task: task) }
                    } label: { Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(subtask.completed ? Ink.green : Color.secondary).frame(width: 24, height: 24) }
                        .buttonStyle(.plain).accessibilityLabel((subtask.completed ? "Вернуть подзадачу в работу: " : "Завершить подзадачу: ") + subtask.text)
                    Text(subtask.text).font(AppTypography.body).strikethrough(subtask.completed).frame(maxWidth: .infinity, alignment: .leading)
                    Button { saveSubtasks((task.subtasks ?? []).filter { $0.id != subtask.id }, task: task) } label: { Image(systemName: "minus.circle").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Удалить подзадачу: " + subtask.text)
                }
            }
            HStack(spacing: 10) {
                TextField("Новая подзадача", text: taskDraft(task, prefix: "tasksubtask")).textFieldStyle(.roundedBorder).onSubmit { addSubtask(task) }
                Button { addSubtask(task) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).disabled((notes.captureDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Добавить подзадачу")
            }
        }
    }
    private func append(_ task: LibraryTask) -> some View {
        let key = "taskappend:\(task.id)"
        return VStack(alignment: .leading, spacing: 12) {
            Text("Дополнить").font(AppTypography.heading)
            TextField("Детали, которые нужно добавить", text: taskDraft(task, prefix: "taskappend"), axis: .vertical).lineLimit(2...8).textFieldStyle(.plain)
                .font(AppTypography.body).padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: 6)).accessibilityIdentifier("tasks.append-text")
            HStack {
                Spacer()
                Button("Добавить") {
                    let text = (notes.captureDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if notes.appendTask(task, text: text) != nil { clearDraft(key) }
                }.buttonStyle(.bordered).disabled((notes.captureDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    @ViewBuilder private func source(_ task: LibraryTask) -> some View {
        if let meetingID = task.meetingID, app.noteMeetings.contains(where: { $0.id == meetingID }) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Button(task.title) { app.openMeeting(meetingID, tab: task.noteID == nil ? "summary" : "notes"); notes.highlightedNoteID = task.noteID }.buttonStyle(.borderless)
                if let segment = (task.taskOrigin?.segmentIDs ?? task.segmentIDs).first {
                    Button { app.openMeeting(meetingID, tab: "transcript", segmentID: segment) } label: { Image(systemName: "quote.bubble").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Исходная реплика").accessibilityLabel("Открыть исходную реплику задачи")
                }
            }.font(AppTypography.caption).foregroundStyle(.secondary)
        }
    }
    private func clearDraft(_ key: String) {
        notes.captureDrafts.removeValue(forKey: key)
        if let prefix = key.split(separator: ":", maxSplits: 1).first, let id = notes.selectedTaskID {
            notes.captureDrafts.removeValue(forKey: "\(prefix):\(id)")
        }
        notes.reconcileTaskDrafts()
    }
    private func metadataDraft(_ task: LibraryTask) -> TaskMetadataDraft? {
        guard let text = notes.captureDrafts["taskmeta:\(task.id)"], let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskMetadataDraft.self, from: data)
    }
    private func saveMetadataDraft(_ value: TaskMetadataDraft, key: String) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        notes.captureDrafts[key] = text
    }
    private func selectFirstFilteredIfNeeded() {
        if !filtered.contains(where: { isSelected($0) }) {
            notes.selectedTaskID = filtered.first?.id
        }
    }
    private func addTask() {
        let text = newTask.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let note = notes.capture(text: text, kind: "task") {
            notes.captureDrafts.removeValue(forKey: "newtask"); notes.loadTasks(); notes.selectedTaskID = "manual:\(note.id)"; filter = "open"; query = ""
        }
    }
    private func addSubtask(_ task: LibraryTask) {
        let key = "tasksubtask:\(task.id)"
        let text = (notes.captureDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if saveSubtasks((task.subtasks ?? []) + [TaskSubtask(text: text)], task: task) { clearDraft(key) }
    }
    @discardableResult private func saveSubtasks(_ value: [TaskSubtask], task: LibraryTask) -> Bool {
        guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return notes.updateTask(task, patch: ["subtasks": object]) != nil
    }
    private func complete(_ task: LibraryTask) {
        if notes.updateTask(task, patch: ["completed": !task.completed]) != nil {
            app.reloadLibrary()
            if app.selection == task.meetingID { app.refreshResults(task.meetingID ?? "") }
        }
    }
    private static func title(_ task: LibraryTask) -> String {
        let explicit = task.taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return explicit.isEmpty ? task.text.split(separator: "\n").first.map(String.init) ?? "Новая задача" : explicit
    }
    private func description(_ task: LibraryTask) -> String? {
        let title = Self.title(task)
        return task.text.hasPrefix(title) ? String(task.text.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines) : task.text
    }
    private func referenceDate(_ task: LibraryTask) -> Date? {
        if let id = task.meetingID, let meeting = app.noteMeetings.first(where: { $0.id == id }) {
            return Date(timeIntervalSince1970: meeting.createdAt)
        }
        if let id = task.noteID, let note = notes.workspace.notes.first(where: { $0.id == id }) {
            return Date(timeIntervalSince1970: note.createdAt)
        }
        return nil
    }
    private func deadline(_ task: LibraryTask) -> Date? { TaskDueDate.resolve(task.due, reference: referenceDate(task)) }
    private func displayDeadline(_ task: LibraryTask) -> String { TaskDueDate.display(task.due, reference: referenceDate(task)) }
    private func isOverdue(_ task: LibraryTask) -> Bool {
        guard !task.completed, let due = deadline(task) else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }
    private func deadlineEditor(_ task: LibraryTask, value: TaskMetadataDraft, key: String) -> some View {
        let current = metadataDraft(task) ?? value
        let resolved = TaskDueDate.resolve(current.due, reference: referenceDate(task))
        func set(_ date: Date?) {
            var next = metadataDraft(task) ?? value
            next.due = date.map { TaskDueDate.storage($0) } ?? ""
            saveMetadataDraft(next, key: key)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Срок").foregroundStyle(.secondary)
                if let resolved {
                    DatePicker("Срок задачи", selection: Binding(get: { TaskDueDate.resolve((metadataDraft(task) ?? value).due, reference: referenceDate(task)) ?? resolved }, set: { set($0) }), displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden().accessibilityIdentifier("tasks.due-date")
                } else {
                    Text(current.due.isEmpty ? "Не указан" : current.due).lineLimit(2)
                    Button("Выбрать дату") { set(Date()) }.buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Button("Сегодня") { set(Date()) }.accessibilityIdentifier("tasks.due-today")
                Button("Завтра") { set(Calendar.current.date(byAdding: .day, value: 1, to: Date())) }.accessibilityIdentifier("tasks.due-tomorrow")
                Button("Без срока") { set(nil) }.disabled(current.due.isEmpty).accessibilityIdentifier("tasks.due-none")
            }.buttonStyle(.bordered)
        }
    }
}
