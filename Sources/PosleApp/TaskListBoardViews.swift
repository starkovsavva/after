import PosleCore
import SwiftUI

struct TaskStatusMark: View {
    let status: TaskWorkspaceStatus
    var body: some View {
        Image(systemName: status.symbol).font(.system(size: 16))
            .foregroundStyle(status == .done ? Ink.green : status == .blocked ? Ink.warning : status == .doing ? Ink.accent : Color.secondary)
            .accessibilityLabel(status.title)
    }
}

struct TaskListPane: View {
    @ObservedObject var notes: NotesStore
    let tasks: [TaskWorkspace]
    let hasAnyTasks: Bool
    @Binding var query: String
    let select: (TaskWorkspace) -> Void
    let addTask: () -> Void
    let changeStatus: (TaskWorkspace, TaskWorkspaceStatus) -> Void
    private var selection: Binding<String?> {
        Binding(get: { notes.selectedTaskID }, set: { id in
            if let id, let task = tasks.first(where: { $0.id == id }) { select(task) }
        })
    }
    private var newTask: Binding<String> { Binding(get: { notes.captureDrafts["newtask"] ?? "" }, set: { notes.captureDrafts["newtask"] = $0 }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Найти задачу…", text: $query).textFieldStyle(.plain).accessibilityIdentifier("tasks.search")
            }.padding(9).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius)).padding(12)
            HStack {
                Text("Задачи").font(AppTypography.captionStrong)
                Spacer(); Text("\(tasks.count)").font(AppTypography.caption).monospacedDigit()
            }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
            List(selection: selection) {
                ForEach(tasks) { task in
                    row(task).tag(task.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityIdentifier("tasks.list")
                .overlay(alignment: .top) {
                    if tasks.isEmpty {
                        Text(hasAnyTasks ? "Нет подходящих задач" : "Здесь пока нет задач")
                            .foregroundStyle(.secondary).font(AppTypography.control).padding(24).allowsHitTesting(false)
                    }
                }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("Новая задача", text: newTask).textFieldStyle(.plain).onSubmit(addTask).accessibilityIdentifier("tasks.new-text")
                Button(action: addTask) { Image(systemName: "arrow.up.circle").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).disabled(newTask.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Добавить задачу").accessibilityIdentifier("tasks.new-submit")
            }.padding(12)
        }.background(Ink.field.opacity(0.3))
    }
    private func row(_ task: TaskWorkspace) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Button { changeStatus(task, task.status == .done ? .todo : .done) } label: {
                TaskStatusMark(status: task.status).frame(width: 24, height: 24)
            }.buttonStyle(.plain).accessibilityLabel((task.status == .done ? "Вернуть в работу: " : "Завершить задачу: ") + task.title)
            Button { select(task) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(notes.selectedTaskID == task.id ? AppTypography.controlStrong : AppTypography.control)
                        .lineLimit(2).strikethrough(task.status == .done).frame(maxWidth: .infinity, alignment: .leading)
                    TaskRowMetadata(task: task)
                }.padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("tasks.row." + task.id)
                .accessibilityAddTraits(notes.selectedTaskID == task.id ? .isSelected : [])
                .accessibilityValue(notes.selectedTaskID == task.id ? "Выбрана" : "")
        }.padding(10)
    }
}

struct TaskRowMetadata: View {
    let task: TaskWorkspace
    var body: some View {
        HStack(spacing: 6) {
            Text(task.source.title).lineLimit(1)
            if !task.due.isEmpty { Text("·").accessibilityHidden(true); Text(TaskDueDate.display(task.due, reference: task.createdAt > 0 ? Date(timeIntervalSince1970: task.createdAt) : nil)).lineLimit(1) }
        }.font(AppTypography.caption).foregroundStyle(.secondary)
    }
}

struct TaskBoardView: View {
    let tasks: [TaskWorkspace]
    let selectedID: String?
    let select: (TaskWorkspace) -> Void
    let changeStatus: (TaskWorkspace, TaskWorkspaceStatus) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(TaskWorkspaceStatus.allCases) { status in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 7) {
                            TaskStatusMark(status: status)
                            Text(status.title).font(AppTypography.controlStrong)
                            Spacer(minLength: 4)
                            Text("\(tasks.filter { $0.status == status }.count)").font(AppTypography.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 4)
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(tasks.filter { $0.status == status }) { task in
                                    Button { select(task) } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(task.title).font(AppTypography.controlStrong).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                            TaskRowMetadata(task: task)
                                            if !task.project.isEmpty { Text(task.project).font(AppTypography.caption).foregroundStyle(.secondary) }
                                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Ink.field, in: RoundedRectangle(cornerRadius: AppLayout.cardRadius))
                                            .overlay(RoundedRectangle(cornerRadius: AppLayout.cardRadius).stroke(selectedID == task.id ? Ink.accent.opacity(0.45) : Ink.line, lineWidth: 1))
                                    }.buttonStyle(.plain).accessibilityIdentifier("tasks.board." + task.id)
                                        .contextMenu {
                                            ForEach(TaskWorkspaceStatus.allCases) { target in Button(target.title) { changeStatus(task, target) }.disabled(target == task.status) }
                                        }
                                }
                            }
                        }
                    }.frame(width: 236).frame(maxHeight: .infinity, alignment: .top)
                }
            }.padding(AppLayout.contentInset)
        }.background(Ink.soft)
    }
}
