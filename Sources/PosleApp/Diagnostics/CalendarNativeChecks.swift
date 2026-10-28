#if DEBUG
import AppKit
import Foundation
import PosleCore

/// Deterministic task/calendar merge and private persistence checks. No calendar access prompt,
/// EKEventStore instance, user events, Google/Yandex accounts or network requests.
@MainActor
enum CalendarNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Calendar checks need an explicit preview fixture")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-"),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("calendar-data").path) else {
            throw AppError.message("Calendar checks need an empty /private/tmp/posle-native-check-* fixture")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let link = CalendarTaskLink(taskID: "note:123", calendarID: "test", title: "Подготовить вопросы", start: now, end: now.addingTimeInterval(1800),
                                    lastTaskText: "Подготовить вопросы", lastTaskCompleted: false, lastEventTitle: "○ Подготовить вопросы")
        let unchanged = CalendarTaskMerge.decide(link: link, taskText: link.lastTaskText, taskCompleted: false, remoteTitle: link.lastEventTitle, writable: true)
        try expect(unchanged.remoteTitle == nil && unchanged.taskCompleted == nil && !unchanged.conflict, "An unchanged link must not write anything")
        let complete = CalendarTaskMerge.decide(link: link, taskText: link.lastTaskText, taskCompleted: true, remoteTitle: link.lastEventTitle, writable: true)
        try expect(complete.remoteTitle == "✓ Подготовить вопросы" && complete.taskCompleted == nil, "Local completion must update only the managed title")
        let externalDone = CalendarTaskMerge.decide(link: link, taskText: link.lastTaskText, taskCompleted: false, remoteTitle: "✓ Подготовить вопросы", writable: true)
        try expect(externalDone.taskCompleted == true && externalDone.remoteTitle == nil, "Calendar completion must update the task without rewriting the event")
        let externalName = CalendarTaskMerge.decide(link: link, taskText: link.lastTaskText, taskCompleted: false, remoteTitle: "○ Внешнее название блока", writable: true)
        try expect(externalName.remoteTitle == nil && externalName.taskCompleted == nil && !externalName.conflict, "External block rename must be preserved")
        let combined = CalendarTaskMerge.decide(link: link, taskText: link.lastTaskText, taskCompleted: true, remoteTitle: "○ Внешнее название блока", writable: true)
        try expect(combined.remoteTitle == "✓ Внешнее название блока", "Completion must preserve an independently renamed calendar block")
        var canonical = link; canonical.eventID = "original-event"
        try expect(canonical.isCanonicalEvent(identifier: "original-event", url: canonical.marker), "Original managed event lost its task identity")
        try expect(!canonical.isCanonicalEvent(identifier: "duplicated-event", url: canonical.marker), "A copied calendar block with the same URL must not edit the original task block")
        try expect(!canonical.isCanonicalEvent(identifier: "original-event", url: nil), "An unrelated or unmarked event must not inherit a task link")
        var pending = link; pending.eventID = ""
        try expect(!pending.isCanonicalEvent(identifier: "", url: pending.marker), "A pending creation intent cannot impersonate an existing event")
        print("PASS: task/calendar completion merges, external rename preservation, canonical event identity and no redundant writes")
        let simultaneous = CalendarTaskMerge.decide(link: link, taskText: "Моя правка", taskCompleted: false, remoteTitle: "○ Правка календаря", writable: true)
        try expect(simultaneous.conflict && simultaneous.remoteTitle == nil && simultaneous.taskCompleted == nil, "Simultaneous edits must not overwrite each other")
        let readOnly = CalendarTaskMerge.decide(link: link, taskText: "Моя правка", taskCompleted: false, remoteTitle: link.lastEventTitle, writable: false)
        try expect(readOnly.writeBlocked && readOnly.remoteTitle == nil, "Read-only/recurring calendar cannot be rewritten")
        let unknown = CalendarTaskMerge.decide(link: link, taskText: link.lastTaskText, taskCompleted: false, remoteTitle: "Завершено, готово, [done]", writable: true)
        try expect(unknown.taskCompleted == nil && unknown.remoteTitle == nil, "Unknown title text must not fabricate completion")
        var conflicted = link; conflicted.conflict = true
        let sticky = CalendarTaskMerge.decide(link: conflicted, taskText: link.lastTaskText, taskCompleted: false, remoteTitle: link.lastEventTitle, writable: true)
        try expect(sticky.conflict && sticky.remoteTitle == nil, "An unresolved conflict cannot silently disappear")
        try expect(CalendarTaskLink.plainTitle("✓ Договор") == "Договор" && CalendarTaskLink.plainTitle("Готово") == "Готово", "Prefix parsing must preserve plain titles")
        print("PASS: simultaneous edits stay protected, missing markers do not fabricate status and read-only events stay untouched")
        let object: [String: Any] = ["id": "summary:meeting:0", "meetingID": "meeting", "title": "Демо", "text": "Проверить договор", "owner": "", "due": "", "completed": false, "segmentIDs": [1, 2]]
        var summaryTask = try JSONDecoder().decode(LibraryTask.self, from: JSONSerialization.data(withJSONObject: object))
        let originalSignature = CalendarTaskLink.signature(for: summaryTask)
        var legacy = CalendarTaskLink(taskID: summaryTask.id, calendarID: "fixture", title: summaryTask.text,
            start: now, end: now.addingTimeInterval(600), lastTaskText: summaryTask.text,
            lastTaskCompleted: false, lastEventTitle: summaryTask.text)
        legacy.sourceSignature = originalSignature
        var stable = summaryTask; stable.id = "summary:meeting:source-hash"
        try expect(legacy.replacement(in: [stable])?.id == stable.id, "Legacy calendar link must migrate only to an exact source fingerprint")
        var duplicate = stable; duplicate.id += "-duplicate"
        try expect(legacy.replacement(in: [stable, duplicate]) == nil, "Ambiguous source identity must not retarget a calendar link")
        var changed = stable; changed.segmentIDs = [99]
        try expect(legacy.replacement(in: [changed]) == nil, "A reused summary position must not acquire an old calendar link")
        var canonicalJSON = object
        canonicalJSON["id"] = "manual:canonical"; canonicalJSON["noteID"] = "canonical"
        canonicalJSON["text"] = "Проверить договор и дополнение"
        canonicalJSON["taskOrigin"] = ["meetingID": "meeting", "itemSignature": "source-hash", "sourceText": "Проверить договор", "segmentIDs": [1, 2], "summaryTaskID": "summary:meeting:source-hash"]
        let canonicalTask = try JSONDecoder().decode(LibraryTask.self, from: JSONSerialization.data(withJSONObject: canonicalJSON))
        try expect(legacy.replacement(in: [canonicalTask])?.id == canonicalTask.id, "Materialization must preserve the original calendar association despite task additions")
        summaryTask.text = "Другая задача на том же месте"
        try expect(CalendarTaskLink.signature(for: summaryTask) != originalSignature, "Regenerated summary index must not impersonate the original task")
        summaryTask.text = "Проверить договор"; summaryTask.segmentIDs = [4, 9]
        try expect(CalendarTaskLink.signature(for: summaryTask) != originalSignature, "Changed source references must invalidate a summary task link")
        summaryTask.noteID = "stable-note"
        try expect(CalendarTaskLink.signature(for: summaryTask) == nil, "Manual note edits must retain their stable identity")
        print("PASS: regenerated summary tasks cannot silently inherit another task's calendar block")
        let missingView = try JSONDecoder().decode(CalendarViewPreferences.self, from: Data("{}".utf8))
        let unknownView = try JSONDecoder().decode(CalendarViewPreferences.self, from: Data("{\"displayMode\":\"future-mode\"}".utf8))
        try expect(missingView.displayMode == .week && unknownView.displayMode == .week, "Missing/future calendar views must retain a usable default")
        for mode in CalendarDisplayMode.allCases {
            let data = try JSONEncoder().encode(CalendarViewPreferences(displayMode: mode))
            try expect(try JSONDecoder().decode(CalendarViewPreferences.self, from: data).displayMode == mode, "Calendar mode codec roundtrip failed")
        }
        try CalendarStore.verifyDisplayEventBoundaries()
        print("PASS: day boundaries, all-day exclusive ends, hidden calendars and view preferences work without calendar access")
        try CalendarStore.verifyPrivatePersistence(at: root)
        print("PASS: stable private calendar links roundtrip, symlinks/corrupt files are preserved, previews never instantiate EventKit")
        try await CalendarConnectionChecks.run(root: root)
        print("10 native calendar checks passed")
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AppError.message(message) }
    }
}
#endif
