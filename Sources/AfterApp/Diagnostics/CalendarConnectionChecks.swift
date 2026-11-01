#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AfterPlatform
import Foundation

/// Permission and deliberately delayed calendar reads are invented. This fixture
/// cannot construct EventKit, ask macOS for permission, or touch user accounts.
@MainActor
final class CalendarReadFixture {
    var status: CalendarAuthorizationStatus = .notDetermined
    private(set) var accessRequests = 0
    private(set) var reads: [CalendarReadRequest] = []
    private var access: CheckedContinuation<Bool, Error>?
    private var pending: [Int: CheckedContinuation<CalendarReadSnapshot, Error>] = [:]
    var client: CalendarReadClient {
        CalendarReadClient(authorizationStatus: { [self] in status },
            requestAccess: { [self] in
                accessRequests += 1
                return try await withCheckedThrowingContinuation { access = $0 }
            }, read: { [self] request in
                let index = reads.count; reads.append(request)
                return try await withCheckedThrowingContinuation { pending[index] = $0 }
            })
    }
    func grant(_ granted: Bool, status: CalendarAuthorizationStatus) {
        self.status = status
        let continuation = access; access = nil; continuation?.resume(returning: granted)
    }
    func complete(_ index: Int, title: String = "План на день", empty: Bool = false) {
        guard let continuation = pending.removeValue(forKey: index) else { return }
        continuation.resume(returning: empty ? CalendarReadSnapshot(sources: [], events: [], defaultCalendarID: nil)
                            : Self.snapshot(for: reads[index], title: title))
    }
    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: NSError(domain: "SyntheticCalendar", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Календарь временно недоступен"]))
    }
    func finish() {
        let request = access; access = nil; request?.resume(returning: false)
        let reads = pending; pending.removeAll()
        for continuation in reads.values { continuation.resume(throwing: CancellationError()) }
    }
    static func snapshot(for request: CalendarReadRequest, title: String) -> CalendarReadSnapshot {
        CalendarReadSnapshot(sources: [.init(id: "synthetic", title: "Личный", account: "На этом Mac", writable: true,
            red: 0.3, green: 0.5, blue: 0.8, alpha: 1)],
            events: [.init(id: "synthetic-event", title: title, start: request.start.addingTimeInterval(3600),
                end: request.start.addingTimeInterval(5400), allDay: false, calendarID: "synthetic", writable: true, marker: nil)],
            defaultCalendarID: "synthetic")
    }
}

@MainActor
enum CalendarConnectionChecks {
    static func run(root: URL) async throws {
        let fixture = CalendarReadFixture()
        let calendar = CalendarStore(root: root, preview: true, readClient: fixture.client)
        defer { calendar.stop(); fixture.finish() }
        try expect(calendar.canConnect && !calendar.connected, "A permission fixture must start disconnected without EventKit")
        let connection = Task { await calendar.connect() }
        try await settle { fixture.accessRequests == 1 && calendar.requesting }
        await calendar.connect()
        try expect(fixture.accessRequests == 1, "Repeated Connect while a permission request is pending must not open another request")
        fixture.grant(true, status: .fullAccess)
        await connection.value
        try await settle { calendar.connected && calendar.refreshing && fixture.reads.count == 1 }
        try expect(!calendar.requesting && !calendar.permissionDenied && calendar.error == nil,
            "A granted connection must leave onboarding even while its schedule is loading")
        calendar.refreshIfNeeded(); calendar.refreshIfNeeded()
        try expect(fixture.reads.count == 1, "Reopening the same pending period must share its in-flight read")
        print("PASS: one in-flight permission request connects immediately; schedule loading does not hold onboarding")

        var mainActorResponsive = false
        Task { @MainActor in mainActorResponsive = true }
        calendar.selectedDate = Calendar.current.date(byAdding: .month, value: 1, to: calendar.selectedDate)!
        calendar.selectedDate = Calendar.current.date(byAdding: .month, value: 1, to: calendar.selectedDate)!
        try await settle { mainActorResponsive }
        fixture.complete(0, title: "Устаревший результат")
        try await settle { fixture.reads.count == 2 }
        try expect(calendar.events.isEmpty && calendar.refreshing, "An old period response must not flash in the new period")
        let newest = calendar.displayPeriod
        try expect(fixture.reads[1].start == newest.start && fixture.reads[1].end == newest.end,
            "Rapid changes must coalesce to the newest period")
        fixture.complete(1, title: "Актуальная встреча")
        try await settle { !calendar.refreshing && calendar.events.first?.title == "Актуальная встреча" }
        calendar.refreshIfNeeded(); calendar.refreshIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try expect(fixture.reads.count == 2 && calendar.selectedCalendarID == "synthetic",
            "Reopening the same view must use the recent snapshot and retain its writable calendar")
        print("PASS: slow reads yield to navigation, coalesce rapid period changes and discard stale responses; reopening uses the cache")

        calendar.refresh()
        try await settle { fixture.reads.count == 3 }
        calendar.setFeatureEnabled(false, tasksEnabled: false)
        fixture.complete(2, title: "Результат после отключения")
        try await Task.sleep(for: .milliseconds(50))
        try expect(!calendar.connected && !calendar.refreshing && calendar.events.isEmpty,
            "A late read must not resurrect a disabled calendar")
        calendar.setFeatureEnabled(true, tasksEnabled: true)
        try await settle { calendar.connected && fixture.reads.count == 4 }
        fixture.complete(3)
        try await settle { !calendar.refreshing }
        try expect(fixture.accessRequests == 1, "Enabling calendar in another folder must reuse its shared authorization")
        print("PASS: folder feature suspension ignores late reads and resumes the shared connection without another permission prompt")

        fixture.status = .denied
        calendar.refreshIfNeeded()
        try expect(!calendar.connected && calendar.permissionDenied && calendar.events.isEmpty,
            "Permission revocation must bypass a fresh cache and clear readable events")
        await calendar.connect()
        try expect(fixture.accessRequests == 1 && calendar.error != nil && !calendar.requesting,
            "Denied permission needs an actionable error, not repeated macOS prompts or false success")
        fixture.status = .fullAccess
        calendar.refreshIfNeeded()
        try await settle { calendar.connected && fixture.reads.count == 5 }
        fixture.fail(4)
        try await settle { !calendar.refreshing && calendar.error != nil }
        try expect(calendar.connected, "A transient fetch error must retain the connection and allow refresh")
        calendar.refresh()
        try await settle { fixture.reads.count == 6 }
        fixture.complete(5)
        try await settle { !calendar.refreshing && calendar.error == nil }
        calendar.refresh()
        try await settle { fixture.reads.count == 7 }
        calendar.error = "Укажите название события"
        fixture.complete(6)
        try await settle { !calendar.refreshing }
        try expect(calendar.error == "Укажите название события", "An older background read must not dismiss a newer editor validation error")
        print("PASS: permission changes are reflected on return; temporary fetch failures expose retry without reconnecting")

        let deniedFixture = CalendarReadFixture()
        let denied = CalendarStore(root: root, preview: true, readClient: deniedFixture.client)
        defer { denied.stop(); deniedFixture.finish() }
        let denial = Task { await denied.connect() }
        try await settle { deniedFixture.accessRequests == 1 }
        deniedFixture.grant(true, status: .denied)
        await denial.value
        try expect(!denied.connected && denied.permissionDenied && denied.error != nil && !denied.requesting,
            "A positive callback with an unconfirmed/denied OS status cannot be silently treated as successful")
        try expect(deniedFixture.reads.isEmpty, "Denied authorization must never start a calendar read")

        let delayedFixture = CalendarReadFixture()
        let delayed = CalendarStore(root: root, preview: true, readClient: delayedFixture.client)
        defer { delayed.stop(); delayedFixture.finish() }
        let delayedConnection = Task { await delayed.connect() }
        try await settle { delayedFixture.accessRequests == 1 }
        delayedFixture.grant(true, status: .notDetermined)
        try await Task.sleep(for: .milliseconds(80))
        delayedFixture.status = .fullAccess
        await delayedConnection.value
        try await settle { delayed.connected && delayedFixture.reads.count == 1 }
        delayedFixture.complete(0)
        try await settle { !delayed.refreshing }
        print("PASS: callback/status disagreement is reported; a delayed authorization cache settles without another click")
        try await CalendarAdapterChecks.run(root: root)
    }

    static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Synthetic calendar connection did not settle")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw AppError.message(message) }
    }
}
#endif
