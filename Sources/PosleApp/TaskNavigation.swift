import Foundation
import PosleCore

extension AppStore {
    var activeTaskProjectID: String? {
        guard settings.isEnabled(.tasks), librarySection == "tasks" else { return nil }
        if notes.selectedTaskProject != "all" { return notes.selectedTaskProject }
        guard let id = notes.selectedTaskID,
              let task = notes.taskWorkspaces[id], !task.project.isEmpty else { return nil }
        return task.project
    }

    /// Opening a task never materializes or changes it. Both summary IDs and
    /// canonical IDs resolve after another process has accepted a summary task.
    func openTask(id: String) {
        guard settings.isEnabled(.tasks) else {
            error = "Включите «Задачи и проекты» в настройках → Возможности."
            return
        }
        notes.reload(); notes.loadTasks(); notes.loadTaskWorkspaces()
        guard let task = notes.tasks.first(where: { $0.id == id || $0.noteID == id || $0.taskOrigin?.summaryTaskID == id }) else {
            error = "Задача больше недоступна. Обновите список задач."
            return
        }
        notes.pendingTaskNavigationID = task.id
        notes.selectedTaskProject = "all"
        notes.selectedTaskID = task.id
        notes.taskNavigationRequest = UUID()
        librarySection = "tasks"
    }
}
