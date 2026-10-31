import AfterLocalization
import AfterPlatform
import AppKit
import EventKit
import Foundation

package extension CalendarReadClient {
    static func system() -> Self {
        let worker = CalendarReadWorker()
        return Self(authorizationStatus: { EventKitCalendarValues.authorizationStatus },
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
        try EventKitCalendarValues.requireAccess()
        let store = eventStore()
        store.reset()
        return EventKitCalendarValues.read(request, store: store)
    }
}

/// EventKit objects, notifications and mutations stay in the adapter. Its store
/// is created only by CalendarStore's already-authorized activation path.
@MainActor
package final class EventKitCalendarWriteClient: CalendarWriteClient {
    private let store = EKEventStore()
    package init() {}

    package func calendar(withIdentifier id: String) -> CalendarReadSnapshot.Source? {
        guard EventKitCalendarValues.authorizationStatus == .fullAccess else { return nil }
        return store.calendar(withIdentifier: id).map(EventKitCalendarValues.source)
    }
    package func read(_ request: CalendarReadRequest) throws -> CalendarReadSnapshot {
        try EventKitCalendarValues.requireAccess()
        return EventKitCalendarValues.read(request, store: store)
    }
    package func event(withIdentifier id: String) -> CalendarEventSnapshot? {
        guard EventKitCalendarValues.authorizationStatus == .fullAccess,
              let event = store.event(withIdentifier: id) else { return nil }
        return EventKitCalendarValues.snapshot(event)
    }
    package func findEvent(_ lookup: CalendarLinkedEventLookup) -> CalendarEventSnapshot? {
        guard EventKitCalendarValues.authorizationStatus == .fullAccess else { return nil }
        if !lookup.id.isEmpty, let event = store.event(withIdentifier: lookup.id), event.url == lookup.marker {
            return EventKitCalendarValues.snapshot(event)
        }
        if let external = lookup.externalID {
            let candidates = store.calendarItems(withExternalIdentifier: external).compactMap { $0 as? EKEvent }.filter { $0.url == lookup.marker }
            if candidates.count == 1 { return EventKitCalendarValues.snapshot(candidates[0]) }
        }
        // Recovery requires a unique marker in the persisted block's bounded
        // period. Titles never identify events, and no unrelated event is touched.
        let predicate = store.predicateForEvents(withStart: lookup.start.addingTimeInterval(-86400),
            end: lookup.end.addingTimeInterval(86400), calendars: nil)
        let matches = store.events(matching: predicate).filter { $0.url == lookup.marker }
        return matches.count == 1 ? EventKitCalendarValues.snapshot(matches[0]) : nil
    }
    package func save(_ mutation: CalendarEventMutation) throws -> CalendarEventSnapshot {
        try EventKitCalendarValues.requireAccess()
        guard mutation.end > mutation.start, !mutation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message(L("Укажите название и время окончания позже начала."))
        }
        guard let calendar = store.calendar(withIdentifier: mutation.calendarID), calendar.allowsContentModifications else {
            throw AppError.message(L("Этот календарь недоступен для записи. Выберите другой."))
        }
        let event: EKEvent
        if let expected = mutation.expected {
            guard let current = store.event(withIdentifier: expected.id),
                  let snapshot = EventKitCalendarValues.snapshot(current), expected.matchesEditableState(of: snapshot),
                  current.calendar.allowsContentModifications else {
                throw AppError.message(L("Событие изменилось или недоступно для редактирования. Обновите календарь."))
            }
            guard !current.hasRecurrenceRules else {
                throw AppError.message(L("Повторяющееся событие измените в системном Календаре."))
            }
            event = current
        } else {
            event = EKEvent(eventStore: store); event.timeZone = .current
            event.url = mutation.creationMarker
        }
        event.title = mutation.title; event.startDate = mutation.start; event.endDate = mutation.end; event.calendar = calendar
        if let allDay = mutation.allDay { event.isAllDay = allDay }
        try store.save(event, span: .thisEvent, commit: true)
        guard let snapshot = EventKitCalendarValues.snapshot(event) else {
            throw AppError.message(L("Событие изменилось или недоступно для редактирования. Обновите календарь."))
        }
        return snapshot
    }
    package func observeChanges(_ changed: @escaping @MainActor @Sendable () -> Void) -> any CalendarChangeObservation {
        EventKitCalendarObservation(store: store, changed: changed)
    }
}

@MainActor
private final class EventKitCalendarObservation: CalendarChangeObservation {
    private var observer: NSObjectProtocol?
    init(store: EKEventStore, changed: @escaping @MainActor @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in changed() }
        }
    }
    func cancel() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

private enum EventKitCalendarValues {
    static var authorizationStatus: CalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }
    static func requireAccess() throws {
        guard authorizationStatus == .fullAccess else {
            throw AppError.message(L("Разрешите «After» полный доступ к календарям в настройках macOS."))
        }
    }
    static func source(_ calendar: EKCalendar) -> CalendarReadSnapshot.Source {
        let color = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB) ?? NSColor.systemPurple.usingColorSpace(.sRGB)!
        return CalendarReadSnapshot.Source(id: calendar.calendarIdentifier, title: calendar.title,
            account: calendar.source.title, writable: calendar.allowsContentModifications,
            red: Double(color.redComponent), green: Double(color.greenComponent),
            blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
    }
    static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot? {
        guard let id = event.eventIdentifier, let start = event.startDate, let end = event.endDate,
              let calendar = event.calendar else { return nil }
        return CalendarEventSnapshot(id: id, externalID: event.calendarItemExternalIdentifier,
            title: event.title, start: start, end: end, allDay: event.isAllDay,
            calendar: source(calendar), hasRecurrence: event.hasRecurrenceRules, marker: event.url)
    }
    static func read(_ request: CalendarReadRequest, store: EKEventStore) -> CalendarReadSnapshot {
        let calendars = store.calendars(for: .event)
        let sources = calendars.map(source).sorted {
            ($0.title + $0.account).localizedCaseInsensitiveCompare($1.title + $1.account) == .orderedAscending
        }
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
