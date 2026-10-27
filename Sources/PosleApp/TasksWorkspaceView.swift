import AppKit
import Combine
import PosleCore
import SwiftUI

struct TasksWorkspaceView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @State private var presentation = "list"
    @State private var statusFilter = "open"
    @State private var sourceFilter = "all"
    @State private var query = ""
    @State private var newTaskSheet = false
    @State private var trackerSheet = false
    @State private var boardDetail = false
    @State private var workspaceFileStamp = ""

    private var allTasks: [TaskWorkspace] {
        let ordered = notes.tasks.map { notes.taskWorkspace(for: $0) }
        let ids = Set(ordered.map(\.id))
        return ordered + notes.taskWorkspaces.values.filter { !ids.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
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
        return allTasks.first { $0.id == id } ?? notes.tasks.first { $0.taskOrigin?.summaryTaskID == id }.map { notes.taskWorkspace(for: $0) }
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
                    TaskListPane(notes: notes, tasks: filtered, hasAnyTasks: !allTasks.isEmpty, query: $query, select: { notes.selectedTaskID = $0.id }, addTask: addInlineTask, changeStatus: changeStatus)
                        .frame(minWidth: 250, idealWidth: 292, maxWidth: 320)
                    Divider()
                    detail
                }
            }
        }
        .appControlDefaults()
        .onAppear {
            notes.reload(); notes.loadTasks(); notes.loadTaskWorkspaces(); workspaceFileStamp = currentFileStamp()
            if !consumeTaskNavigation() { selectFirstIfNeeded() }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let stamp = currentFileStamp()
            if stamp != workspaceFileStamp { workspaceFileStamp = stamp; notes.reload(); notes.loadTasks(); notes.loadTaskWorkspaces() }
        }
        .onChange(of: notes.selectedTaskID) { _, _ in notes.loadSelectedTaskWorkspace() }
        .onChange(of: notes.taskNavigationRequest) { _, _ in
            _ = consumeTaskNavigation()
        }
        .onChange(of: statusFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: sourceFilter) { _, _ in selectFirstIfNeeded() }
        .onChange(of: query) { _, _ in selectFirstIfNeeded() }
        .onChange(of: notes.selectedTaskProject) { _, _ in selectFirstIfNeeded() }
        .onChange(of: notes.workspace.notes) { _, _ in notes.loadTasks(); notes.loadTaskWorkspaces() }
        .onChange(of: app.busy) { _, busy in if !busy { notes.reload(); notes.loadTasks(); notes.loadTaskWorkspaces() } }
        .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
        .sheet(isPresented: $newTaskSheet) {
            TaskCreationSheet(notes: notes, initialProject: notes.selectedTaskProject == "all" ? "" : notes.selectedTaskProject) { task in
                statusFilter = "open"; sourceFilter = "all"; query = ""; notes.selectedTaskID = task.id
            }
        }
        .sheet(isPresented: $trackerSheet) { TaskTrackerSheet(notes: notes).environmentObject(app) }
        .sheet(isPresented: $boardDetail) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Готово") { boardDetail = false }.keyboardShortcut(.cancelAction) }.padding(16)
                Divider(); detail
            }.frame(minWidth: 620, idealWidth: 720, minHeight: 620, idealHeight: 780)
        }
    }
    private var header: some View {
        AppWorkspaceHeader(title: "Задачи") {
            Button { trackerSheet = true } label: { Label("Трекеры", systemImage: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(.borderless).accessibilityIdentifier("tasks.trackers")
            Button { newTaskSheet = true } label: { Label("Задача", systemImage: "plus") }
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
        Picker("Представление задач", selection: $presentation) {
            Label("Список", systemImage: "list.bullet").tag("list")
            Label("Доска", systemImage: "rectangle.split.3x1").tag("board")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 200).accessibilityIdentifier("tasks.presentation")
    }
    @ViewBuilder private var filters: some View {
        Picker("Состояние", selection: $statusFilter) { Text("Открытые").tag("open"); Text("Все задачи").tag("all"); Text("Готовые").tag("done") }
            .labelsHidden().frame(width: 132).accessibilityIdentifier("tasks.status-filter")
        Picker("Источник", selection: $sourceFilter) {
            Text("Все источники").tag("all")
            ForEach(TaskWorkspaceSource.allCases) { Text($0.title).tag($0.rawValue) }
        }.labelsHidden().frame(width: 168).accessibilityIdentifier("tasks.source-filter")
        if !projects.isEmpty {
            Picker("Проект", selection: $notes.selectedTaskProject) {
                Text("Все проекты").tag("all")
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
            Text(allTasks.isEmpty ? "Добавьте первую задачу" : filtered.isEmpty ? "Задачи не найдены" : "Выберите задачу")
                .font(AppTypography.emptyTitle)
            if allTasks.isEmpty {
                HStack(spacing: 12) {
                    Button("Новая задача") { newTaskSheet = true }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        .accessibilityIdentifier("tasks.empty-create")
                    Button("Надиктовать") { app.voice.present(projectID: notes.selectedTaskProject == "all" ? nil : notes.selectedTaskProject) }.buttonStyle(.bordered)
                }
            } else if filtered.isEmpty {
                Button("Сбросить фильтры") { resetFilters() }.buttonStyle(.bordered)
                    .accessibilityIdentifier("tasks.empty-reset")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func resetFilters() {
        statusFilter = "all"; sourceFilter = "all"; query = ""; notes.selectedTaskProject = "all"
        selectFirstIfNeeded()
    }
    private func currentFileStamp() -> String {
        let path = notes.root.appendingPathComponent("notes/workspace.json").path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(modified):\(attributes[.size] as? UInt64 ?? 0)"
    }
    private func consumeTaskNavigation() -> Bool {
        guard let id = notes.pendingTaskNavigationID else { return false }
        statusFilter = "all"; sourceFilter = "all"; query = ""; presentation = "list"; boardDetail = false
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
        let text = (notes.captureDrafts["newtask"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let task = notes.createWorkspaceTask(title: text, project: notes.selectedTaskProject == "all" ? "" : notes.selectedTaskProject) {
            notes.captureDrafts.removeValue(forKey: "newtask"); statusFilter = "open"; sourceFilter = "all"; query = ""; notes.selectedTaskID = task.id
        }
    }
    private func changeStatus(_ task: TaskWorkspace, _ status: TaskWorkspaceStatus) {
        if notes.updateTaskWorkspace(task, patch: ["status": status.rawValue]) != nil {
            app.reloadLibrary()
            if app.selection == task.meetingID { app.refreshResults(task.meetingID ?? "") }
        }
    }
}
