import Foundation

package enum CalendarAuthorizationStatus: Equatable, Sendable {
    case notDetermined, restricted, denied, fullAccess, writeOnly
}

package struct CalendarReadRequest: Equatable, Sendable {
    package let start: Date
    package let end: Date
    package let visibleCalendarIDs: Set<String>?
    package init(start: Date, end: Date, visibleCalendarIDs: Set<String>?) {
        self.start = start; self.end = end; self.visibleCalendarIDs = visibleCalendarIDs
    }
}

package struct CalendarReadSnapshot: Sendable {
    package struct Source: Equatable, Sendable {
        package let id: String
        package let title: String
        package let account: String
        package let writable: Bool
        package let red: Double
        package let green: Double
        package let blue: Double
        package let alpha: Double
        package init(id: String, title: String, account: String, writable: Bool,
                     red: Double, green: Double, blue: Double, alpha: Double) {
            self.id = id; self.title = title; self.account = account; self.writable = writable
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
    }
    package struct Event: Sendable {
        package let id: String
        package let title: String
        package let start: Date
        package let end: Date
        package let allDay: Bool
        package let calendarID: String
        package let writable: Bool
        package let marker: URL?
        package init(id: String, title: String, start: Date, end: Date, allDay: Bool,
                     calendarID: String, writable: Bool, marker: URL?) {
            self.id = id; self.title = title; self.start = start; self.end = end; self.allDay = allDay
            self.calendarID = calendarID; self.writable = writable; self.marker = marker
        }
    }
    package let sources: [Source]
    package let events: [Event]
    package let defaultCalendarID: String?
    package init(sources: [Source], events: [Event], defaultCalendarID: String?) {
        self.sources = sources; self.events = events; self.defaultCalendarID = defaultCalendarID
    }
}

/// Injection keeps permission, slow-read and revocation checks independent of the
/// user's actual calendars. A preview never constructs the system client.
@MainActor
package struct CalendarReadClient {
    package var authorizationStatus: () -> CalendarAuthorizationStatus
    package var requestAccess: () async throws -> Bool
    package var read: (CalendarReadRequest) async throws -> CalendarReadSnapshot
    package init(authorizationStatus: @escaping () -> CalendarAuthorizationStatus,
                 requestAccess: @escaping () async throws -> Bool,
                 read: @escaping (CalendarReadRequest) async throws -> CalendarReadSnapshot) {
        self.authorizationStatus = authorizationStatus; self.requestAccess = requestAccess; self.read = read
    }

}

/// Immutable read-for-write value. Native event objects never cross this boundary.
package struct CalendarEventSnapshot: Equatable, Sendable {
    package let id: String
    package let externalID: String?
    package let title: String?
    package let start: Date
    package let end: Date
    package let allDay: Bool
    package let calendar: CalendarReadSnapshot.Source
    package let hasRecurrence: Bool
    package let marker: URL?
    package init(id: String, externalID: String?, title: String?, start: Date, end: Date, allDay: Bool,
                 calendar: CalendarReadSnapshot.Source, hasRecurrence: Bool, marker: URL?) {
        self.id = id; self.externalID = externalID; self.title = title; self.start = start; self.end = end
        self.allDay = allDay; self.calendar = calendar; self.hasRecurrence = hasRecurrence; self.marker = marker
    }

    /// Only fields owned by an editor/link participate; unrelated notes, guests,
    /// alerts and account display properties remain native-store data.
    package func matchesEditableState(of current: Self) -> Bool {
        id == current.id && title == current.title && start == current.start && end == current.end
            && allDay == current.allDay && calendar.id == current.calendar.id
            && marker == current.marker && hasRecurrence == current.hasRecurrence
    }
}

package struct CalendarLinkedEventLookup: Sendable {
    package let id: String
    package let externalID: String?
    package let marker: URL
    package let start: Date
    package let end: Date
    package init(id: String, externalID: String?, marker: URL, start: Date, end: Date) {
        self.id = id; self.externalID = externalID; self.marker = marker; self.start = start; self.end = end
    }
}

/// A missing expected value means explicit creation. Updates preserve every native
/// event field not named here. A nil allDay keeps the existing event's value.
package struct CalendarEventMutation: Sendable {
    package let expected: CalendarEventSnapshot?
    package let title: String
    package let start: Date
    package let end: Date
    package let calendarID: String
    package let allDay: Bool?
    package let creationMarker: URL?
    package init(expected: CalendarEventSnapshot?, title: String, start: Date, end: Date,
                 calendarID: String, allDay: Bool? = nil, creationMarker: URL? = nil) {
        self.expected = expected; self.title = title; self.start = start; self.end = end
        self.calendarID = calendarID; self.allDay = allDay; self.creationMarker = creationMarker
    }
}

@MainActor
package protocol CalendarChangeObservation: AnyObject {
    func cancel()
}

/// The synchronous writer lives on the app's main actor, matching explicit
/// editor operations. Potentially slow agenda reads use CalendarReadClient.
@MainActor
package protocol CalendarWriteClient: AnyObject {
    func calendar(withIdentifier id: String) -> CalendarReadSnapshot.Source?
    func read(_ request: CalendarReadRequest) throws -> CalendarReadSnapshot
    func event(withIdentifier id: String) -> CalendarEventSnapshot?
    func findEvent(_ lookup: CalendarLinkedEventLookup) -> CalendarEventSnapshot?
    func save(_ mutation: CalendarEventMutation) throws -> CalendarEventSnapshot
    func observeChanges(_ changed: @escaping @MainActor @Sendable () -> Void) -> any CalendarChangeObservation
}
