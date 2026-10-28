import AppKit
import PosleCore
import SwiftUI

struct TaskDetailView: View {
    @ObservedObject private var theme = ThemeController.shared
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let task: TaskWorkspace
    @State private var tab = "materials"
    @State private var editing: TaskWorkspace?
    @State private var access = false
    @State private var exporting = false
    @State private var context: TaskSnapshotPresentation?
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    properties
                    if !description.isEmpty { Text(description).font(AppTypography.body).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    TrackerSyncTaskStatus(coordinator: app.trackerSync, taskID: task.id, hasExternalLink: task.source != .local)
                    tabs
                    if tab == "materials" { TaskMaterialsView(notes: notes, task: task).environmentObject(app) }
                    else { TaskHistoryView(task: task) }
                }.appContentLayout()
            }
            if tab == "materials" {
                Divider()
                TaskThoughtComposer(notes: notes, task: task).environmentObject(app)
                    .frame(maxWidth: AppLayout.readableWidth)
                    .padding(.horizontal, AppLayout.contentInset).padding(.vertical, 12)
                    .frame(maxWidth: .infinity).background(Ink.paper)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(item: $editing) { selected in TaskCreationSheet(notes: notes, task: selected) { _ in } }
            .sheet(isPresented: $access) { TaskAgentAccessSheet(notes: notes, taskID: task.id) }
            .sheet(isPresented: $exporting) { TrackerSyncExportSheet(coordinator: app.trackerSync, taskID: task.id, taskTitle: task.title) }
            .sheet(item: $context) { TaskSnapshotSheet(snapshot: $0.snapshot, title: L("Контекст для агента")) }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Label(L(task.source.title), systemImage: task.source.symbol).font(AppTypography.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let url = TaskWorkspaceURL.external(task.externalURL) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help(L("Открыть оригинал задачи")).accessibilityLabel(L("Открыть оригинал задачи"))
                }
                Menu {
                    Button(L("Изменить задачу…")) { editing = task }
                    Divider()
                    Button(L("Доступ агентам…")) { access = true }
                    Button(L("Что увидит агент…")) {
                        if let snapshot = notes.taskContext(task) { context = TaskSnapshotPresentation(snapshot: snapshot) }
                    }.disabled(!task.agentAccess.enabled)
                    Divider()
                    Button(L("Отправить в трекер…")) { exporting = true }
                        .disabled(app.trackerSync.busy)
                    Button(L("Дополнить голосом…")) { app.voice.present(taskID: task.id, title: task.title) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().help(L("Действия с задачей"))
                    .accessibilityLabel(L("Действия с задачей")).accessibilityIdentifier("tasks.more")
            }
            Text(task.title).font(AppTypography.pageTitle).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tasks.detail-title")
        }
    }
    private var properties: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { status; metadata }
                VStack(alignment: .leading, spacing: 10) { status; HStack(spacing: 14) { metadata } }
            }
            if let legacy = notes.legacyTask(for: task) {
                TaskCalendarSummary(task: legacy)
            }
        }
    }
    private var status: some View {
        Picker(L("В «После»"), selection: Binding(get: { task.status }, set: { value in
            if notes.updateTaskWorkspace(task, patch: ["status": value.rawValue]) != nil { app.reloadLibrary() }
        })) {
            ForEach(TaskWorkspaceStatus.allCases) { Label(L($0.title), systemImage: $0.symbol).tag($0) }
        }.fixedSize().accessibilityIdentifier("tasks.detail-status")
    }
    @ViewBuilder private var metadata: some View {
        if !task.due.isEmpty {
            Label(TaskDueDate.display(task.due, reference: task.createdAt > 0 ? Date(timeIntervalSince1970: task.createdAt) : nil), systemImage: "calendar")
                .font(AppTypography.control).foregroundStyle(.secondary).lineLimit(1)
        }
        if !task.owner.isEmpty { Label(task.owner, systemImage: "person").font(AppTypography.control).foregroundStyle(.secondary).lineLimit(1) }
        if !task.project.isEmpty { Label(task.project, systemImage: "folder").font(AppTypography.control).foregroundStyle(.secondary).lineLimit(1) }
        if let legacy = notes.legacyTask(for: task) { TaskCalendarButton(task: legacy) }
    }
    private var tabs: some View {
        AppTabBar(label: L("Задача"), selection: $tab, tabs: [
            AppTab(L("Материалы") + " · " + String(task.materialCount ?? task.materials.count), value: "materials"),
            AppTab(L("История"), value: "history")
        ], identifier: "tasks.tab", fillsWidth: true)
    }
    private var description: String {
        TaskWorkspaceDescription.body(title: task.title, text: task.text)
    }
}

/// Legacy task notes include their title as a separate first line. A matching
/// prefix in a normal sentence is part of the description and must survive.
enum TaskWorkspaceDescription {
    static func body(title: String, text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == title.trimmingCharacters(in: .whitespacesAndNewlines) else { return text }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TaskSnapshotPresentation: Identifiable {
    let id = UUID()
    let snapshot: TaskContextSnapshot
}

enum TaskWorkspaceURL {
    static func external(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
