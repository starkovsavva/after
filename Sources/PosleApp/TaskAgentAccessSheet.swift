import PosleCore
import SwiftUI

struct TaskAgentAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @State var taskID: String
    private var task: TaskWorkspace? { notes.taskWorkspaces[taskID] }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppPageHeader(title: "Доступ агентам", modal: true)
            if let task {
                Toggle("Эта задача", isOn: Binding(get: { task.agentAccess.enabled }, set: { enabled in
                    if let saved = notes.updateTaskWorkspace(task, patch: ["agentAccess": ["enabled": enabled]]) { taskID = saved.id }
                })).toggleStyle(.switch).accessibilityIdentifier("tasks.agent-access")
                Text("Описание, срок и статус доступны вместе с выбранными материалами.")
                    .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(task.materials) { material in
                            Toggle(isOn: Binding(get: { material.shared }, set: { shared in
                                if let saved = notes.shareTaskMaterial(material, task: task, shared: shared) { taskID = saved.id }
                            })) { Label(material.title, systemImage: material.symbol).lineLimit(2) }
                                .disabled(!task.agentAccess.enabled || notes.taskWorkspaceBusy)
                                .accessibilityIdentifier("tasks.agent-material." + (material.id ?? ""))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if task.materials.contains(where: \.isWorkspace) {
                    Text("Для папок и репозиториев передаётся только путь или адрес. Доступ к файлам агент получает отдельно в своей среде.")
                        .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else { Text("Задача недоступна").foregroundStyle(.secondary) }
            if let error = notes.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning) }
            HStack {
                Button("Настроить агентов…") { dismiss(); app.openSettings("integrations") }.buttonStyle(.borderless)
                Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520).frame(minHeight: 360, idealHeight: 520).appControlDefaults()
    }
}

struct TaskTrackerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @State private var newSource: TaskWorkspaceSource?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppPageHeader(title: "Трекеры", modal: true)
            ForEach([TaskWorkspaceSource.yandex, .google]) { source in
                HStack(spacing: 12) {
                    Image(systemName: source == .yandex ? "point.3.connected.trianglepath.dotted" : "checklist").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.title).font(AppTypography.controlStrong)
                        Text("Добавление по ссылке").font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Добавить задачу…") { newSource = source }.buttonStyle(.bordered)
                }.padding(.vertical, 10)
            }
            Text("Ссылка открывает оригинал. Статус, мысли и материалы остаются в «После»; автоматическая синхронизация не подключена.")
                .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Интеграции…") { dismiss(); app.openSettings("integrations") }.buttonStyle(.borderless)
                Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 540).appControlDefaults()
            .sheet(item: $newSource) { source in TaskCreationSheet(notes: notes, initialSource: source) { _ in dismiss() } }
    }
}
