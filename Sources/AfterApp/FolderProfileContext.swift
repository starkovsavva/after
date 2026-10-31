import AfterPlatformMacOS
import AfterLocalization
import Foundation
import AfterCore

extension AppStore {
    func folderID(for meetingID: String) -> String? {
        notes.context(for: meetingID).folderID
    }
    func effectiveSettings(for meetingID: String? = nil, folderID explicitFolderID: String? = nil) -> AppSettings {
        let id: String?
        if let meetingID { id = folderID(for: meetingID) } else { id = explicitFolderID }
        guard let id, let folder = notes.workspace.folders.first(where: { $0.id == id }) else { return settings }
        return folder.overrides.apply(to: settings)
    }
    func folderID(for task: LibraryTask) -> String? {
        if let noteID = task.noteID, let folderID = notes.workspace.notes.first(where: { $0.id == noteID })?.folderID { return folderID }
        return task.meetingID.flatMap { folderID(for: $0) }
    }
    func settingsForTask(_ task: LibraryTask) -> AppSettings {
        effectiveSettings(folderID: folderID(for: task))
    }
    var activeSettings: AppSettings { effectiveSettings(folderID: folderSelection) }
    var availableFeatures: AppFeatures {
        notes.workspace.folders.reduce(settings.features) { result, folder in
            var value = result
            let effective = folder.overrides.apply(to: settings).features
            for feature in AppFeature.allCases { value[feature] = value[feature] || effective[feature] }
            return value
        }
    }
    var visibleFeatures: AppFeatures { folderSelection == nil ? availableFeatures : activeSettings.features }
    func isFeatureEnabled(_ feature: AppFeature) -> Bool {
        guard feature == .assistant, folderSelection == nil else { return visibleFeatures[feature] }
        if librarySection == "meetings", let selection { return effectiveSettings(for: selection).features.assistant }
        if librarySection == "inbox", let id = notes.selectedNoteID, let note = notes.workspace.notes.first(where: { $0.id == id }) {
            return effectiveSettings(for: note.folderID == nil ? note.meetingID : nil, folderID: note.folderID).features.assistant
        }
        if librarySection == "tasks", let id = notes.selectedTaskID, let task = notes.tasks.first(where: { $0.id == id }) { return settingsForTask(task).features.assistant }
        return settings.features.assistant
    }
    func folderProfile(for meetingID: String? = nil, folderID: String? = nil) throws -> (ResolvedFolderProfile, Data) {
        var arguments: [String: Any] = [:]
        if let meetingID { arguments["meetingID"] = meetingID }
        else if let folderID { arguments["folderID"] = folderID }
        let data = try RustBridge.shared.get().request(root: root, command: "profile-resolve", arguments: arguments)
        return (try JSONDecoder().decode(ResolvedFolderProfile.self, from: data), data)
    }
    func inheritedCardGeneration(for meetingID: String) -> Bool {
        notes.folder(for: meetingID)?.overrides.generateCards ?? false
    }
    func cardGenerationInheritanceTitle(for meetingID: String) -> String {
        let source = folderID(for: meetingID) == nil ? L("По умолчанию") : L("Как в папке")
        return source + (inheritedCardGeneration(for: meetingID) ? L(" · создавать") : L(" · не создавать"))
    }
    func generatesCards(for meeting: Meeting) -> Bool {
        guard effectiveSettings(for: meeting.id).features.cards else { return false }
        if let override = meeting.generateCards { return override }
        return inheritedCardGeneration(for: meeting.id)
    }
    func showFolderSettings(_ id: String) {
        NotificationCenter.default.post(name: Notification.Name("PosleEditFolder"), object: id)
    }
}
