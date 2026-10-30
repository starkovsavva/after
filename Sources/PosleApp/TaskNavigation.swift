import Foundation
import PosleCore

extension AppStore {
    var activeTaskProjectID: String? {
        guard isFeatureEnabled(.tasks), librarySection == "tasks" else { return nil }
        if notes.selectedTaskProject != "all" { return notes.selectedTaskProject }
        guard let id = notes.selectedTaskID,
              let task = notes.taskWorkspaces[id], !task.project.isEmpty else { return nil }
        return task.project
    }

    /// Opening a task never materializes or changes it. Both summary IDs and
    /// canonical IDs resolve after another process has accepted a summary task.
    func openTask(id: String) {
        guard availableFeatures.tasks else {
            error = L("Включите «Задачи и проекты» в настройках → Возможности.")
            return
        }
        notes.reload(); notes.loadTasks(); notes.loadTaskWorkspaces()
        guard let task = notes.tasks.first(where: { $0.id == id || $0.noteID == id || $0.taskOrigin?.summaryTaskID == id }) else {
            error = L("Задача больше недоступна. Обновите список задач.")
            return
        }
        guard settingsForTask(task).features.tasks else {
            error = L("Задачи выключены в настройках этой папки."); return
        }
        if folderSelection != nil, folderSelection != folderID(for: task) { folderSelection = folderID(for: task) }
        notes.pendingTaskNavigationID = task.id
        notes.selectedTaskProject = "all"
        notes.selectedTaskID = task.id
        notes.taskNavigationRequest = UUID()
        librarySection = "tasks"
    }
}
