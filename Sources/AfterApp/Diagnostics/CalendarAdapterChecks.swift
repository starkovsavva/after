#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AfterPlatform
import Foundation
import AfterCore

/// Exercises the application through the same value-only port as EventKit. No
/// EventKit store, real permission request, or user calendar is constructed.
@MainActor
enum CalendarAdapterChecks {
    static func run(root: URL) async throws {
        let directory = root.appendingPathComponent("calendar-adapter")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = CalendarWriteFixture()
        var constructions = 0
        var status = CalendarAuthorizationStatus.fullAccess
        let reader = CalendarReadClient(authorizationStatus: { status }, requestAccess: {
            throw AppError.message("An already authorized synthetic calendar must not request access")
        }, read: { request in try fixture.read(request) })
        let calendar = CalendarStore(root: directory, readClient: reader, makeWriteClient: {
            constructions += 1; return fixture
        })
        defer { calendar.stop() }
        try expect(constructions == 0 && !calendar.connected, "Opening an unconnected store must not construct a calendar writer")
        await calendar.connect()
        try await CalendarConnectionChecks.settle { calendar.connected && !calendar.refreshing }
        try expect(constructions == 1, "Only explicit authorized activation may construct the calendar writer")
        let start = calendar.displayPeriod.start.addingTimeInterval(3600), end = start.addingTimeInterval(1800)
        try expect(calendar.schedule(task: nil, title: "Synthetic block", start: start, end: end, calendarID: fixture.source.id),
            "An explicit block must reach the value-only writer")
        try await CalendarConnectionChecks.settle { !calendar.refreshing }
        guard let created = fixture.record, let item = calendar.events.first else { throw AppError.message("Missing synthetic event") }
        try expect(fixture.mutations.last?.expected == nil && fixture.mutations.last?.creationMarker == nil
                   && fixture.mutations.last?.allDay == false, "Creation must be explicit and must not invent a task marker")
        let writes = fixture.mutations.count
        fixture.record = fixture.copy(created, title: "External edit")
        try expect(!calendar.edit(event: item, title: "Stale editor", start: start, end: end, calendarID: fixture.source.id)
                   && fixture.mutations.count == writes, "A stale editor must not send a mutation to the adapter")
        try await CalendarConnectionChecks.settle { !calendar.refreshing }
        guard let fresh = calendar.events.first else { throw AppError.message("Missing refreshed synthetic event") }
        try expect(calendar.edit(event: fresh, title: "Explicit update", start: start, end: end, calendarID: fixture.source.id),
            "A current editor must send an explicit update")
        try expect(fixture.mutations.last?.expected?.title == "External edit" && fixture.mutations.last?.allDay == nil,
            "Editing must carry the observed version and preserve unspecified native fields")
        try expect(!created.matchesEditableState(of: fixture.copy(created, title: "Changed"))
                   && !created.matchesEditableState(of: fixture.copy(created, marker: URL(string: "posle://calendar-task/other")))
                   && !created.matchesEditableState(of: fixture.copy(created, recurring: true)),
            "The native save guard must reject changed content, ownership marker and recurrence")

        fixture.record = nil
        let taskJSON: [String: Any] = ["id": "note:calendar-adapter", "noteID": "calendar-adapter", "title": "Synthetic", "text": "Linked task", "owner": "", "due": "", "completed": false, "segmentIDs": []]
        let task = try JSONDecoder().decode(LibraryTask.self, from: JSONSerialization.data(withJSONObject: taskJSON))
        var firstMarker: URL?
        fixture.beforeSave = { mutation in
            guard let marker = mutation.creationMarker,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("calendar-state.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let links = object["links"] as? [[String: Any]],
                  links.contains(where: { $0["id"] as? String == marker.lastPathComponent && $0["eventID"] as? String == "" }) else {
                throw AppError.message("Creation must persist its recovery marker before a native write")
            }
            if firstMarker == nil { firstMarker = marker; throw AppError.message("Synthetic interrupted save") }
            guard firstMarker == marker else { throw AppError.message("Retry changed the durable marker") }
        }
        try expect(!calendar.schedule(task: task, title: task.text, start: start, end: end, calendarID: fixture.source.id),
            "A failed native write must remain a recoverable creation intent")
        try expect(calendar.link(for: task)?.eventID.isEmpty == true && firstMarker != nil,
            "The pending task link must survive a failed adapter save")
        try expect(calendar.schedule(task: task, title: task.text, start: start, end: end, calendarID: fixture.source.id),
            "Retry must reuse the durable creation marker")
        try expect(calendar.link(for: task)?.marker == firstMarker && calendar.link(for: task)?.eventID == fixture.record?.id,
            "The saved event must retain the original task-link identity")
        fixture.beforeSave = nil
        status = .denied
        calendar.refreshIfNeeded()
        try expect(!calendar.connected && fixture.observation?.cancelled == true,
            "Permission revocation must tear down the writer observation and readable state")
        print("PASS: calendar value port preserves explicit activation, stale-editor guards, native-field ownership and durable task-marker recovery")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw AppError.message(message) }
    }
}

@MainActor
private final class CalendarWriteFixture: CalendarWriteClient {
    let source = CalendarReadSnapshot.Source(id: "synthetic-write", title: "Synthetic", account: "Fixture", writable: true,
        red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    var record: CalendarEventSnapshot?
    var mutations: [CalendarEventMutation] = []
    var beforeSave: ((CalendarEventMutation) throws -> Void)?
    var observation: CalendarFixtureObservation?
    func calendar(withIdentifier id: String) -> CalendarReadSnapshot.Source? { id == source.id ? source : nil }
    func read(_ request: CalendarReadRequest) throws -> CalendarReadSnapshot {
        let events = record.map { [CalendarReadSnapshot.Event(id: $0.id, title: $0.title ?? "", start: $0.start, end: $0.end,
            allDay: $0.allDay, calendarID: $0.calendar.id, writable: true, marker: $0.marker)] } ?? []
        return CalendarReadSnapshot(sources: [source], events: events, defaultCalendarID: source.id)
    }
    func event(withIdentifier id: String) -> CalendarEventSnapshot? { record?.id == id ? record : nil }
    func findEvent(_ lookup: CalendarLinkedEventLookup) -> CalendarEventSnapshot? { record?.marker == lookup.marker ? record : nil }
    func save(_ mutation: CalendarEventMutation) throws -> CalendarEventSnapshot {
        try beforeSave?(mutation)
        mutations.append(mutation)
        let value = CalendarEventSnapshot(id: mutation.expected?.id ?? "synthetic-created-\(mutations.count)", externalID: "external-synthetic",
            title: mutation.title, start: mutation.start, end: mutation.end, allDay: mutation.allDay ?? mutation.expected?.allDay ?? false,
            calendar: source, hasRecurrence: false, marker: mutation.expected?.marker ?? mutation.creationMarker)
        record = value; return value
    }
    func observeChanges(_ changed: @escaping @MainActor @Sendable () -> Void) -> any CalendarChangeObservation {
        let value = CalendarFixtureObservation(); observation = value; return value
    }
    func copy(_ value: CalendarEventSnapshot, title: String? = nil, marker: URL? = nil, recurring: Bool? = nil) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: value.id, externalID: value.externalID, title: title ?? value.title, start: value.start, end: value.end,
            allDay: value.allDay, calendar: value.calendar, hasRecurrence: recurring ?? value.hasRecurrence, marker: marker ?? value.marker)
    }
}

@MainActor
private final class CalendarFixtureObservation: CalendarChangeObservation {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}
#endif
