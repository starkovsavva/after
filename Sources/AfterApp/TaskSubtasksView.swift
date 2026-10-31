import AfterLocalization
import AfterCore
import SwiftUI

struct TaskSubtasksView: View {
    @ObservedObject var notes: NotesStore
    let task: LibraryTask
    private var key: String { "tasksubtask:\(task.id)" }
    private var draft: Binding<String> {
        Binding(get: { notes.captureDrafts[key] ?? "" }, set: { notes.setTaskDraft($0, task: task, prefix: "tasksubtask") })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Подзадачи")).font(AppTypography.heading)
            ForEach(task.subtasks ?? []) { subtask in
                HStack(alignment: .top, spacing: 9) {
                    Button {
                        var items = task.subtasks ?? []
                        if let index = items.firstIndex(where: { $0.id == subtask.id }) { items[index].completed.toggle(); save(items) }
                    } label: { Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(subtask.completed ? Ink.green : Color.secondary).frame(width: 24, height: 24) }
                        .buttonStyle(.plain).accessibilityLabel((subtask.completed ? L("Вернуть подзадачу в работу: ") : L("Завершить подзадачу: ")) + subtask.text)
                    Text(subtask.text).font(AppTypography.body).strikethrough(subtask.completed).frame(maxWidth: .infinity, alignment: .leading)
                    Button { save((task.subtasks ?? []).filter { $0.id != subtask.id }) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Удалить подзадачу: ") + subtask.text)
                }
            }
            HStack(spacing: 8) {
                TextField(L("Новая подзадача"), text: draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button(action: add) { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel(L("Добавить подзадачу"))
            }
        }.padding(.top, 12)
    }
    private func add() {
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if save((task.subtasks ?? []) + [TaskSubtask(text: text)]) { notes.captureDrafts.removeValue(forKey: key) }
    }
    @discardableResult private func save(_ subtasks: [TaskSubtask]) -> Bool {
        guard let data = try? JSONEncoder().encode(subtasks), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return notes.updateTask(task, patch: ["subtasks": object]) != nil
    }
}
