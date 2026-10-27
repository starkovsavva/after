import AppKit
import Foundation
import PosleCore

/// Call only after core validation of the original source fingerprint.
extension AppStore {
    /// Read the current metadata instead of trusting a sidebar snapshot: a
    /// meeting can have moved to Trash since search generated this note source.
    /// The independent note stays editable and keeps its historical link.
    func openCapturedNote(_ note: CapturedNote) {
        if let id = note.meetingID,
           let meeting: Meeting = self.read(self.meetingDirectory(id).appendingPathComponent("meta.json")),
           meeting.id == id, meeting.libraryKind != "cards" {
            self.openMeeting(id, tab: "notes")
        } else {
            self.librarySection = "inbox"
            self.pause()
        }
        self.notes.selectedNoteID = note.id
        self.notes.highlightedNoteID = note.id
    }

    func permitsKnowledgeSource(_ source: KnowledgeSource) -> Bool {
        guard settings.features.allowsKnowledgeKind(source.kind),
              source.cardID == nil || settings.isEnabled(.cards),
              source.taskID == nil || settings.isEnabled(.tasks),
              source.eventID == nil || settings.isEnabled(.calendar) else { return false }
        if let id = source.meetingID {
            guard !id.isEmpty, id.utf8.count <= 128,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
            if !settings.isEnabled(.cards),
               let meeting: Meeting = read(meetingDirectory(id).appendingPathComponent("meta.json")), meeting.libraryKind == "cards" { return false }
        }
        return true
    }

    func revealKnowledgeSource(_ source: KnowledgeSource, calendar: KnowledgeCalendarSnapshot? = nil) throws {
        guard permitsKnowledgeSource(source) else { throw AppError.message("Этот раздел выключен. Включите его в настройках → Возможности.") }
        switch source.kind {
        case "task":
            guard let id = source.taskID else { throw AppError.message("Задача больше недоступна.") }
            self.openTask(id: id)
        case "note":
            guard let id = source.noteID else { throw AppError.message("Заметка больше недоступна.") }
            self.notes.reload()
            guard let note = self.notes.notes.first(where: { $0.id == id }) else { throw AppError.message("Заметка больше недоступна.") }
            self.openCapturedNote(note)
        case "meeting", "transcript", "summary", "card":
            guard let id = source.meetingID else { throw AppError.message("Встреча больше недоступна.") }
            self.openMeeting(id, tab: source.kind == "transcript" ? "transcript" : source.kind == "card" ? "cards" : "summary", segmentID: source.kind == "transcript" ? source.segmentID : nil)
            self.navigationTarget = AppStore.NavigationTarget(meetingID: id,
                kind: source.kind == "summary" ? (source.itemIndex == nil ? "overview" : "item") : source.kind == "meeting" ? "title" : source.kind,
                segmentID: source.segmentID, itemIndex: source.itemIndex, cardID: source.cardID)
        case "code":
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
            let data = try RustBridge.shared.get().request(root: self.root, command: "code-index-open", arguments: ["source": object])
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let path = value["path"] as? String else { throw AppError.message("Файл больше недоступен.") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case "calendar":
            guard let id = source.eventID, let event = calendar?.events.first(where: { $0.id == id }), self.calendar.revealKnowledgeEvent(event) else { throw AppError.message("Событие больше недоступно в подключённом календаре.") }
            self.librarySection = "calendar"
        default: throw AppError.message("Этот источник пока нельзя открыть.")
        }
    }
}
