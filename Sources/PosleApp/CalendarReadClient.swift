import AppKit
import EventKit
import Foundation

/// Only immutable value types cross the EventKit worker boundary. EventKit objects
/// and their lazy properties are read on the worker that created the store.
struct CalendarReadRequest: Equatable, Sendable {
    let start: Date
    let end: Date
    let visibleCalendarIDs: Set<String>?
}

struct CalendarReadSnapshot: Sendable {
    struct Source: Sendable {
        let id: String
        let title: String
        let account: String
        let writable: Bool
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }
    struct Event: Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let calendarID: String
        let writable: Bool
        let marker: URL?
    }
    let sources: [Source]
    let events: [Event]
    let defaultCalendarID: String?
}

/// Injection keeps permission, slow-read and revocation checks independent of the
/// user's actual calendars. A preview never constructs the system client.
@MainActor
struct CalendarReadClient {
    var authorizationStatus: () -> EKAuthorizationStatus
    var requestAccess: () async throws -> Bool
    var read: (CalendarReadRequest) async throws -> CalendarReadSnapshot

    static func system() -> Self {
        let worker = CalendarReadWorker()
        return Self(authorizationStatus: { EKEventStore.authorizationStatus(for: .event) },
                    requestAccess: { try await worker.requestAccess() },
                    read: { try await worker.read($0) })
    }
}

private actor CalendarReadWorker {
    private var store: EKEventStore?
    private func eventStore() -> EKEventStore {
        if let store { return store }
        let value = EKEventStore(); store = value; return value
    }
    func requestAccess() async throws -> Bool {
        let store = eventStore()
        let granted = try await store.requestFullAccessToEvents()
        if granted { store.reset() }
        return granted
    }
    func read(_ request: CalendarReadRequest) throws -> CalendarReadSnapshot {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarReadError.permissionRequired
        }
        let store = eventStore()
        store.reset()
        let calendars = store.calendars(for: .event)
        let sources = calendars.map { calendar in
            let color = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB) ?? NSColor.systemPurple.usingColorSpace(.sRGB)!
            return CalendarReadSnapshot.Source(id: calendar.calendarIdentifier, title: calendar.title,
                account: calendar.source.title, writable: calendar.allowsContentModifications,
                red: Double(color.redComponent), green: Double(color.greenComponent),
                blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
        }.sorted { ($0.title + $0.account).localizedCaseInsensitiveCompare($1.title + $1.account) == .orderedAscending }
        let chosen = calendars.filter { request.visibleCalendarIDs?.contains($0.calendarIdentifier) ?? true }
        let events: [CalendarReadSnapshot.Event]
        if chosen.isEmpty { events = [] }
        else {
            let predicate = store.predicateForEvents(withStart: request.start, end: request.end, calendars: chosen)
            events = store.events(matching: predicate).compactMap { event in
                guard let id = event.eventIdentifier, let start = event.startDate, let end = event.endDate,
                      let calendar = event.calendar else { return nil }
                return CalendarReadSnapshot.Event(id: id, title: event.title ?? L("Без названия"), start: start, end: end,
                    allDay: event.isAllDay, calendarID: calendar.calendarIdentifier,
                    writable: calendar.allowsContentModifications && !event.hasRecurrenceRules, marker: event.url)
            }
        }
        return CalendarReadSnapshot(sources: sources, events: events,
            defaultCalendarID: store.defaultCalendarForNewEvents.flatMap { $0.allowsContentModifications ? $0.calendarIdentifier : nil })
    }
}

enum CalendarReadError: LocalizedError {
    case permissionRequired
    var errorDescription: String? { L("Разрешите «После» полный доступ к календарям в настройках macOS.") }
}
