import Foundation
import PosleCore

/// A persisted baseline separates asynchronous attachment/AI changes from typed edits.
struct NoteEditingSession {
    var draft: CapturedNote
    private(set) var baseline: CapturedNote
    private(set) var conflicted = false
    init(note: CapturedNote) { draft = note; baseline = note }
    var hasUnsavedChanges: Bool { !Self.sameEditable(draft, baseline) }
    mutating func didPersist(_ note: CapturedNote) {
        draft = note; baseline = note; conflicted = false
    }
    mutating func receive(_ persisted: CapturedNote?) {
        guard let persisted, persisted.id == baseline.id else { conflicted = true; return }
        guard persisted.revision >= baseline.revision else { return }
        // A revision caused by OCR, copied attachments or generated additions
        // can safely advance while the user continues typing different text.
        if Self.sameEditable(persisted, baseline) {
            draft.revision = persisted.revision
            draft.attachments = persisted.attachments
            draft.expansion = persisted.expansion
            draft.updatedAt = persisted.updatedAt
            baseline = persisted; conflicted = false
        } else if !hasUnsavedChanges {
            // A clean editor can reflect a saved edit without losing local work.
            didPersist(persisted)
        } else {
            // Keep both the typed fields and old revision. Rust must reject an
            // overwrite until the user explicitly reloads or creates a new note.
            conflicted = true
        }
    }
    func asNewNote(preserveMeeting: Bool = true) -> CapturedNote {
        CapturedNote(text: draft.text, kind: draft.kind,
                     meetingID: preserveMeeting ? draft.meetingID : nil,
                     timestamp: preserveMeeting ? draft.timestamp : nil,
                     sourceURL: draft.sourceURL, owner: draft.owner, due: draft.due,
                     completed: draft.completed, title: draft.title, contentRTF: draft.contentRTF, folder: draft.folder, folderID: draft.folderID, tags: draft.tags, pinned: draft.pinned)
    }
    private static func sameEditable(_ left: CapturedNote, _ right: CapturedNote) -> Bool {
        left.text == right.text && left.kind == right.kind && left.meetingID == right.meetingID &&
        left.timestamp == right.timestamp && left.sourceURL == right.sourceURL && left.owner == right.owner &&
        left.due == right.due && left.completed == right.completed && left.title == right.title &&
        left.contentRTF == right.contentRTF && left.folder == right.folder && left.folderID == right.folderID && left.tags == right.tags &&
        left.pinned == right.pinned && left.trashedAt == right.trashedAt
    }
}
