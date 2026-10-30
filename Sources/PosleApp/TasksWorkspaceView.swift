import AppKit
import Combine
import PosleCore
import SwiftUI

struct TasksWorkspaceView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @State private var presentation = "list"
    @State private var listStatusFilter = "open"
    @State private var boardStatusFilter = "all"
    @State private var sourceFilter = "all"
    @State private var query = ""
    @State private var newTaskSheet = false
    @State private var trackerSheet = false
    @State private var boardDetail = false
    @State private var workspaceFileStamp = ""

    private var statusFilter: String {
        get { presentation == "board" ? boardStatusFilter : listStatusFilter }
        nonmutating set {
            if presentation == "board" { boardStatusFilter = newValue } else { listStatusFilter = newValue }
        }
    }
    private var statusFilterBinding: Binding<String> { Binding(get: { statusFilter }, set: { statusFilter = $0 }) }
    private var taskDraftKey: String { app.folderSelection.map { "newtask:folder:" + $0 } ?? "newtask" }
    private var allTasks: [TaskWorkspace] {
        let ordered = notes.tasks.map { notes.taskWorkspace(for: $0) }
        let ids = Set(ordered.map(\.id))
        let all = ordered + notes.taskWorkspaces.values.filter { !ids.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
        guard let selectedFolderID = app.folderSelection else { return all }
        return all.filter { folderID(for: $0) == selectedFolderID }
    }
    private var projects: [String] { Set(allTasks.map(\.project).filter { !$0.isEmpty }).sorted() }
    private var filtered: [TaskWorkspace] {
        allTasks.filter { task in
            (statusFilter == "all" || (statusFilter == "done" ? task.status == .done : task.status != .done)) &&
            (sourceFilter == "all" || task.source.rawValue == sourceFilter) &&
            (notes.selectedTaskProject == "all" || task.project == notes.selectedTaskProject) &&
            notes.taskMatchesQuery(task, query: query)
        }
    }
    private var selected: TaskWorkspace? {
        guard let id = notes.selectedTaskID else { return nil }
        return allTasks.first { $0.id == id || notes.legacyTask(for: $0)?.taskOrigin?.summaryTaskID == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            if presentation == "board" {
                if filtered.isEmpty { emptyState }
                else {
                    TaskBoardView(tasks: filtered, selectedID: notes.selectedTaskID, select: { task in
                        notes.selectedTaskID = task.id; boardDetail = true
                    }, changeStatus: changeStatus)
                }
            } else {
                HStack(spacing: 0) {
                    TaskListPane(notes: notes, tasks: filtered, hasAnyTasks: !allTasks.isEmpty, draftKey: taskDraftKey, query: $query, select: { notes.selectedTaskID = $0.id }, addTask: addInlineTask, changeStatus: changeStatus)
                        .frame(minWidth: 250, idealWidth: 292, maxWidth: 320)
                    Divider()
                    detail
                }
            }
        }
        .appControlDefaults()
        .onAppear {
            workspaceFileStamp = currentFileStamp()
            if !consumeTaskNavigation() { selectFirstIfNeeded() }
        }
        .task {
            await notes.refresh(includeTasks: true)
            guard !Task.isCancelled else { return }
            if !consumeTaskNavigation() { selectFirstIfNeeded() }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let stamp = currentFileStamp()
            if stamp != workspaceFileStamp { workspaceFileStamp = stamp; Task { await notes.refresh(includeTasks: true) } }
        }
        .onChange(of: notes.selectedTaskID) { _, _ in Task { await notes.refresh(includeTasks: true) } }
        .onChange(of: notes.taskNavigationRequest) { _, _ in
            _ = consumeTaskNavigation()
        }
        .onChange(of: app.folderSelection) { _, _ in
            notes.selectedTaskProject = "all"; boardDetail = false; selectFirstIfNeeded()
        }
        .onChange(of: statusFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: sourceFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: query) { _, _ in selectFirstIfNeeded() }
        .onChange(of: notes.selectedTaskProject) { _, _ in selectFirstIfNeeded() }
        .onChange(of: notes.workspace.notes) { _, _ in Task { await notes.refresh(includeTasks: true) } }
        .onChange(of: app.busy) { _, busy in if !busy { Task { await notes.refresh(includeTasks: true) } } }
        .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
        .sheet(isPresented: $newTaskSheet) {
            TaskCreationSheet(notes: notes, initialProject: notes.selectedTaskProject == "all" ? "" : notes.selectedTaskProject, initialFolderID: app.folderSelection) { task in
                statusFilter = presentation == "board" ? "all" : "open"; sourceFilter = "all"; query = ""; notes.selectedTaskID = task.id
            }
        }
        .sheet(isPresented: $trackerSheet) { TaskTrackerSheet(notes: notes).environmentObject(app) }
        .sheet(isPresented: $boardDetail) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button(L("Готово")) { boardDetail = false }.keyboardShortcut(.cancelAction) }.padding(16)
                Divider(); detail
            }.frame(minWidth: 620, idealWidth: 720, minHeight: 620, idealHeight: 780)
        }
    }
    private var header: some View {
        AppWorkspaceHeader(title: L("Задачи")) {
            Button { trackerSheet = true } label: { Label(L("Трекеры"), systemImage: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(.borderless).accessibilityIdentifier("tasks.trackers")
            Button { newTaskSheet = true } label: { Label(L("Задача"), systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Ink.actionFill).accessibilityIdentifier("tasks.create")
        }.padding(.horizontal, AppLayout.contentInset).padding(.top, 20).padding(.bottom, 16)
    }
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { viewPicker; filters; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 12) { viewPicker; HStack(spacing: 12) { filters; Spacer(minLength: 0) } }
        }.padding(.horizontal, AppLayout.contentInset).padding(.bottom, 16)
    }
    private var viewPicker: some View {
        AppTabBar(label: L("Представление задач"), selection: $presentation,
                  tabs: [AppTab(L("Список"), value: "list"), AppTab(L("Доска"), value: "board")],
                  identifier: "tasks.presentation")
    }
    @ViewBuilder private var filters: some View {
        Picker(L("Состояние"), selection: statusFilterBinding) { Text(L("Открытые")).tag("open"); Text(L("Все задачи")).tag("all"); Text(L("Готовые")).tag("done") }
            .labelsHidden().frame(width: 132).accessibilityIdentifier("tasks.status-filter")
        Picker(L("Источник"), selection: $sourceFilter) {
            Text(L("Все источники")).tag("all")
            ForEach(TaskWorkspaceSource.allCases) { Text(L($0.title)).tag($0.rawValue) }
        }.labelsHidden().frame(width: 168).accessibilityIdentifier("tasks.source-filter")
        if !projects.isEmpty {
            Picker(L("Проект"), selection: $notes.selectedTaskProject) {
                Text(L("Все проекты")).tag("all")
                ForEach(projects, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 144).accessibilityIdentifier("tasks.project-filter")
        }
    }
    @ViewBuilder private var detail: some View {
        if let task = selected { TaskDetailView(notes: notes, task: task).environmentObject(app).id(task.id) }
        else { emptyState }
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: allTasks.isEmpty ? "checklist" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(allTasks.isEmpty ? L("Добавьте первую задачу") : filtered.isEmpty ? L("Задачи не найдены") : L("Выберите задачу"))
                .font(AppTypography.emptyTitle)
            if allTasks.isEmpty {
                HStack(spacing: 12) {
                    Button(L("Новая задача")) { newTaskSheet = true }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        .accessibilityIdentifier("tasks.empty-create")
                    Button(L("Надиктовать")) { app.voice.present(projectID: notes.selectedTaskProject == "all" ? nil : notes.selectedTaskProject) }.buttonStyle(.bordered)
                }
            } else if filtered.isEmpty {
                Button(L("Сбросить фильтры")) { resetFilters() }.buttonStyle(.bordered)
                    .accessibilityIdentifier("tasks.empty-reset")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func resetFilters() {
        statusFilter = "all"; sourceFilter = "all"; query = ""; notes.selectedTaskProject = "all"
        selectFirstIfNeeded()
    }
    private func currentFileStamp() -> String {
        // WAL commits may leave the main database mtime unchanged.
        ["core.sqlite", "core.sqlite-wal"].map { name in
            let path = notes.root.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return name + ":missing" }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name):\(modified):\(attributes[.size] as? UInt64 ?? 0)"
        }.joined(separator: "|")
    }
    private func consumeTaskNavigation() -> Bool {
        guard let id = notes.pendingTaskNavigationID else { return false }
        listStatusFilter = "all"; sourceFilter = "all"; query = ""; presentation = "list"; boardDetail = false
        notes.selectedTaskProject = "all"
        notes.selectedTaskID = id
        notes.pendingTaskNavigationID = nil
        return true
    }
    private func selectFirstIfNeeded() {
        guard notes.pendingTaskNavigationID == nil else { return }
        if !filtered.contains(where: { $0.id == notes.selectedTaskID }) { notes.selectedTaskID = filtered.first?.id }
    }
    private func addInlineTask() {
        let text = (notes.captureDrafts[taskDraftKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let task = notes.createWorkspaceTask(title: text, project: notes.selectedTaskProject == "all" ? "" : notes.selectedTaskProject, folderID: app.folderSelection) {
            notes.captureDrafts.removeValue(forKey: taskDraftKey); statusFilter = presentation == "board" ? "all" : "open"; sourceFilter = "all"; query = ""; notes.selectedTaskID = task.id
        }
    }
    private func folderID(for task: TaskWorkspace) -> String? {
        let noteID = notes.legacyTask(for: task)?.noteID ?? (task.id.hasPrefix("manual:") ? String(task.id.dropFirst("manual:".count)) : nil)
        if let noteID, let id = notes.workspace.notes.first(where: { $0.id == noteID })?.folderID { return id }
        return task.meetingID.flatMap { app.folderID(for: $0) }
    }
    private func changeStatus(_ task: TaskWorkspace, _ status: TaskWorkspaceStatus) {
        if notes.updateTaskWorkspace(task, patch: ["status": status.rawValue]) != nil {
            app.reloadLibrary()
            if app.selection == task.meetingID { app.refreshResults(task.meetingID ?? "") }
        }
    }
}
