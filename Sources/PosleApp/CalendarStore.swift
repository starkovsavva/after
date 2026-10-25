import AppKit
import Combine
import CryptoKit
import EventKit
import Foundation
import PosleCore

struct CalendarChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let account: String
    let writable: Bool
    let color: NSColor
    var label: String { "\(title) · \(account)" }
}

struct CalendarAgendaEvent: Identifiable {
    let id: String
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendarID: String
    let calendarTitle: String
    let account: String
    let color: NSColor
    let writable: Bool
    var taskID: String?
}

struct CalendarTaskLink: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var taskID: String
    var eventID: String = ""
    var externalID: String? = nil
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var lastTaskText: String
    var lastTaskCompleted: Bool
    var lastEventTitle: String
    var missing = false
    var conflict = false
    var sourceSignature: String? = nil
    var sourceChanged = false
    var marker: URL { URL(string: "posle://calendar-task/\(id)")! }
    func isCanonicalEvent(identifier: String?, url: URL?) -> Bool {
        !eventID.isEmpty && identifier == eventID && url == marker
    }
    static func eventTitle(_ text: String, completed: Bool) -> String {
        (completed ? "✓ " : "○ ") + text
    }
    static func completion(in title: String) -> Bool? {
        if title.hasPrefix("✓ ") { return true }
        if title.hasPrefix("○ ") { return false }
        return nil
    }
    static func plainTitle(_ title: String) -> String {
        completion(in: title) == nil ? title : String(title.dropFirst(2))
    }
    static func signature(for task: LibraryTask) -> String? {
        guard task.noteID == nil,
              let data = try? JSONSerialization.data(withJSONObject: ["text": task.text, "segments": task.segmentIDs, "meeting": task.meetingID ?? ""], options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CalendarPreferences: Codable {
    var enabled = false
    var selectedCalendarID: String = ""
    var visibleCalendarIDs: Set<String>? = nil
    var links: [CalendarTaskLink] = []
}

/// Merge only fields the task link owns. Calendar names/times remain the calendar's values.
struct CalendarTaskMerge {
    var remoteTitle: String?
    var taskCompleted: Bool?
    var conflict = false
    var writeBlocked = false
    static func decide(link: CalendarTaskLink, taskText: String, taskCompleted: Bool, remoteTitle: String, writable: Bool) -> Self {
        let localTextChanged = taskText != link.lastTaskText
        let localCompletionChanged = taskCompleted != link.lastTaskCompleted
        let remoteTitleChanged = remoteTitle != link.lastEventTitle
        let remoteCompletion = CalendarTaskLink.completion(in: remoteTitle)
        let remoteCompletionChanged = remoteCompletion.map { $0 != link.lastTaskCompleted } ?? false
        if link.conflict || (localTextChanged && remoteTitleChanged) ||
            (localCompletionChanged && remoteCompletionChanged && remoteCompletion != taskCompleted) {
            return Self(conflict: true)
        }
        if localTextChanged || localCompletionChanged {
            guard writable else { return Self(writeBlocked: true) }
            return Self(remoteTitle: CalendarTaskLink.eventTitle(localTextChanged ? taskText : CalendarTaskLink.plainTitle(remoteTitle), completed: taskCompleted))
        }
        if remoteCompletionChanged, let completed = remoteCompletion, completed != taskCompleted { return Self(taskCompleted: completed) }
        return Self()
    }
}

/// Calendar access is requested only by Connect. Preview never constructs an EKEventStore.
/// Google/Yandex transport and credentials belong to macOS Internet Accounts.
@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var events: [CalendarAgendaEvent] = []
    @Published private(set) var links: [CalendarTaskLink] = []
    @Published var selectedDate = Date()
    @Published var error: String?
    @Published private(set) var requesting = false
    @Published private(set) var lastRefreshed: Date?
    @Published var selectedCalendarID = ""
    @Published private(set) var visibleCalendarIDs: Set<String>? = nil
    let preview: Bool
    private let root: URL
    private var preferences = CalendarPreferences()
    private var eventStore: EKEventStore?
    private weak var notes: NotesStore?
    private var cancellables = Set<AnyCancellable>()
    private var refreshing = false
    private var pendingRefresh = false
    private var eventChanges: NSObjectProtocol?
    private var activation: NSObjectProtocol?
    private var preferenceLoadFailed = false

    init(root: URL, preview: Bool = false) {
        self.root = root; self.preview = preview
        if preview { return }
        do {
            let url = try stateURL()
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count < 8 * 1024 * 1024 else { throw CalendarError.invalidState }
                preferences = try JSONDecoder().decode(CalendarPreferences.self, from: data)
            }
            links = preferences.links; selectedCalendarID = preferences.selectedCalendarID
            visibleCalendarIDs = preferences.visibleCalendarIDs
        } catch {
            preferenceLoadFailed = true
            self.error = "Не удалось прочитать связи с календарём. Файл сохранён без изменений: \(error.localizedDescription)"
        }
        permissionDenied = [.denied, .restricted, .writeOnly].contains(EKEventStore.authorizationStatus(for: .event))
        // Existing explicit opt-in survives restart, but never asks the OS for access here.
        if preferences.enabled && EKEventStore.authorizationStatus(for: .event) == .fullAccess { activate() }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func bindNotes(_ notes: NotesStore) {
        self.notes = notes
        notes.$tasks.dropFirst().debounce(for: .milliseconds(180), scheduler: RunLoop.main).sink { [weak self] _ in self?.reconcileTasks() }.store(in: &cancellables)
        notes.$workspace.dropFirst().debounce(for: .milliseconds(180), scheduler: RunLoop.main).sink { [weak self, weak notes] _ in
            if self?.connected == true { notes?.loadTasks() }
        }.store(in: &cancellables)
        if connected { notes.loadTasks(); refresh() }
    }

    @discardableResult func openLink(_ url: URL) -> Bool {
        guard url.scheme == "posle", url.host == "calendar-task", url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil, url.pathComponents.count == 2,
              let id = UUID(uuidString: url.lastPathComponent),
              let link = links.first(where: { $0.marker.lastPathComponent.lowercased() == id.uuidString.lowercased() }) else { return false }
        selectedDate = link.start
        if connected { refresh() }
        return true
    }

    func stop() {
        if let eventChanges { NotificationCenter.default.removeObserver(eventChanges) }
        if let activation { NotificationCenter.default.removeObserver(activation) }
        eventChanges = nil; activation = nil; cancellables.removeAll()
    }

    func connect() async {
        guard !requesting, !preview else { return }
        guard !preferenceLoadFailed else { error = "Сначала восстановите файл calendar-state.json: новые связи не будут записаны поверх повреждённых."; return }
        requesting = true; defer { requesting = false }
        do {
            if eventStore == nil { eventStore = EKEventStore() }
            guard let eventStore else { return }
            let granted = try await eventStore.requestFullAccessToEvents()
            permissionDenied = !granted
            guard granted else { error = "Разрешите «После» доступ к календарям в настройках macOS."; return }
            preferences.enabled = true; try persist(); activate(); error = nil
        } catch { self.error = error.localizedDescription }
    }

    func disconnect() {
        preferences.enabled = false
        do { try persist() } catch { self.error = error.localizedDescription; return }
        connected = false; calendars = []; events = []; eventStore = nil
        if let eventChanges { NotificationCenter.default.removeObserver(eventChanges); self.eventChanges = nil }
    }

    private func activate() {
        guard !preview, !preferenceLoadFailed, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        if eventStore == nil { eventStore = EKEventStore() }
        connected = true; permissionDenied = false
        if eventChanges == nil {
            eventChanges = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        guard !preview else { return }
        guard preferences.enabled else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            connected = false; calendars = []; events = []; permissionDenied = true; return
        }
        if !connected { activate(); return }
        guard let eventStore else { return }
        if refreshing { pendingRefresh = true; return }
        refreshing = true
        defer {
            refreshing = false
            if pendingRefresh {
                pendingRefresh = false
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        calendars = eventStore.calendars(for: .event).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title,
                           writable: $0.allowsContentModifications, color: NSColor(cgColor: $0.cgColor) ?? .systemPurple)
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        if !calendars.contains(where: { $0.id == selectedCalendarID && $0.writable }) {
            selectedCalendarID = eventStore.defaultCalendarForNewEvents.flatMap { $0.allowsContentModifications ? $0.calendarIdentifier : nil }
                ?? calendars.first(where: \.writable)?.id ?? ""
        }
        notes?.loadTasks(); reconcileTasks()
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)) ?? calendar.startOfDay(for: selectedDate)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(32 * 86400)
        let chosen = eventStore.calendars(for: .event).filter { visibleCalendarIDs?.contains($0.calendarIdentifier) ?? true }
        if chosen.isEmpty { events = [] }
        else {
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: chosen)
            events = eventStore.events(matching: predicate).map { event in
                CalendarAgendaEvent(id: event.eventIdentifier + ":" + String(event.startDate.timeIntervalSince1970), eventID: event.eventIdentifier,
                                    title: event.title ?? "Без названия", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                                    calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                                    account: event.calendar.source.title, color: NSColor(cgColor: event.calendar.cgColor) ?? .systemPurple,
                                    writable: event.calendar.allowsContentModifications && !event.hasRecurrenceRules,
                                    taskID: links.first(where: { $0.isCanonicalEvent(identifier: event.eventIdentifier, url: event.url) })?.taskID)
            }.sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
        }
        lastRefreshed = Date()
    }

    func toggleVisible(_ id: String) {
        var ids = visibleCalendarIDs ?? Set(calendars.map(\.id))
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        visibleCalendarIDs = ids
        do { try persist(); refresh() } catch { self.error = error.localizedDescription }
    }

    func link(for task: LibraryTask) -> CalendarTaskLink? { links.first { $0.taskID == task.id } }
    func task(for id: String) -> LibraryTask? { notes?.tasks.first { $0.id == id } }
    func events(on date: Date) -> [CalendarAgendaEvent] {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return events.filter { $0.start < end && $0.end > start }
    }

    /// A new block is explicit. A persisted creation intent plus marker recovers an interrupted save.
    @discardableResult func schedule(task: LibraryTask?, title: String, start: Date, end: Date, calendarID: String, expected: CalendarTaskLink? = nil) -> Bool {
        guard !preview, connected, let eventStore, !preferenceLoadFailed else { error = "Сначала подключите календарь."; return false }
        guard end > start, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Укажите название и время окончания позже начала."; return false
        }
        guard let calendar = eventStore.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
            error = "Этот календарь недоступен для записи. Выберите другой."; return false
        }
        do {
            var link: CalendarTaskLink? = task.flatMap { self.link(for: $0) }
            var event: EKEvent
            if let existing = link {
                guard !existing.conflict && !existing.sourceChanged else { error = "Сначала разрешите конфликт связанной задачи."; return false }
                guard let recovered = findEvent(existing) else {
                    if !existing.eventID.isEmpty || existing.missing {
                        error = "Связанное событие удалено или недоступно. Сначала отвяжите его, чтобы создать новое."; return false
                    }
                    event = EKEvent(eventStore: eventStore); event.timeZone = .current
                    event.url = existing.marker
                    return try saveNew(event, task: task, existing: existing, title: title, start: start, end: end, calendar: calendar)
                }
                if let expected {
                    guard recovered.title == expected.lastEventTitle, recovered.startDate == expected.start,
                          recovered.endDate == expected.end, recovered.calendar.calendarIdentifier == expected.calendarID else {
                        error = "Событие изменилось в календаре. Закройте редактор и откройте его снова: ваши правки не перезаписаны."; refresh(); return false
                    }
                } else {
                    error = "Для задачи уже создан блок времени. Закройте и откройте редактор, чтобы обновить данные."; refresh(); return false
                }
                event = recovered
            } else {
                event = EKEvent(eventStore: eventStore); event.timeZone = .current
                if let task {
                    link = CalendarTaskLink(taskID: task.id, calendarID: calendarID, title: title, start: start, end: end,
                                            lastTaskText: task.text, lastTaskCompleted: task.completed,
                                            lastEventTitle: CalendarTaskLink.eventTitle(title, completed: task.completed))
                    link!.sourceSignature = CalendarTaskLink.signature(for: task)
                    links.append(link!); try persist() // Durable before event save: retries reuse this marker.
                    event.url = link!.marker
                }
            }
            guard !event.hasRecurrenceRules else { error = "Повторяющееся событие измените в системном Календаре."; return false }
            event.calendar = calendar; event.startDate = start; event.endDate = end; event.isAllDay = false
            event.title = task.map { CalendarTaskLink.eventTitle(title, completed: $0.completed) } ?? title
            try eventStore.save(event, span: .thisEvent, commit: true)
            if var link, let task {
                update(&link, from: event, task: task); replace(link); try persist()
            }
            selectedCalendarID = calendarID; try persist(); error = nil; refresh(); return true
        } catch { self.error = "Не удалось сохранить событие: \(error.localizedDescription)"; return false }
    }

    private func saveNew(_ event: EKEvent, task: LibraryTask?, existing: CalendarTaskLink, title: String, start: Date, end: Date, calendar: EKCalendar) throws -> Bool {
        guard let task, let eventStore else { return false }
        var intent = existing
        intent.calendarID = calendar.calendarIdentifier; intent.start = start; intent.end = end; intent.title = title
        replace(intent); try persist()
        event.calendar = calendar; event.startDate = start; event.endDate = end
        event.title = CalendarTaskLink.eventTitle(title, completed: task.completed)
        try eventStore.save(event, span: .thisEvent, commit: true)
        update(&intent, from: event, task: task); replace(intent); try persist(); error = nil; refresh(); return true
    }

    @discardableResult func edit(event item: CalendarAgendaEvent, title: String, start: Date, end: Date, calendarID: String) -> Bool {
        if let taskID = item.taskID, let task = task(for: taskID) {
            return schedule(task: task, title: title, start: start, end: end, calendarID: calendarID, expected: link(for: task))
        }
        guard connected, !preview, let eventStore,
              let event = eventStore.event(withIdentifier: item.eventID),
              event.calendar.allowsContentModifications, !event.hasRecurrenceRules,
              let calendar = eventStore.calendar(withIdentifier: calendarID), calendar.allowsContentModifications,
              end > start, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Событие изменилось или недоступно для редактирования. Обновите календарь."; return false
        }
        guard event.title == item.title, event.startDate == item.start, event.endDate == item.end,
              event.calendar.calendarIdentifier == item.calendarID else {
            error = "Событие изменилось в календаре. Закройте редактор и откройте его снова, чтобы сохранить обе правки."; refresh(); return false
        }
        // Foreign events are edited only from their explicit editor. Never replace attendees, URL, notes or alerts.
        do {
            event.title = title; event.startDate = start; event.endDate = end; event.calendar = calendar
            try eventStore.save(event, span: .thisEvent, commit: true); error = nil; refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func unlink(taskID: String) {
        let old = links
        links.removeAll { $0.taskID == taskID }
        do { try persist(); error = nil } catch { links = old; self.error = error.localizedDescription }
        // Leaves the event in the user's calendar. No deletion is implicit.
        refresh()
    }

    func resolve(task: LibraryTask, useTask: Bool) {
        guard var link = link(for: task), let event = findEvent(link), let eventStore else { return }
        do {
            if useTask {
                event.title = CalendarTaskLink.eventTitle(task.text, completed: task.completed)
                try eventStore.save(event, span: .thisEvent, commit: true)
            } else if let completed = CalendarTaskLink.completion(in: event.title ?? ""), completed != task.completed {
                notes?.complete(task, completed: completed)
                guard notes?.tasks.first(where: { $0.id == task.id })?.completed == completed else {
                    error = "Не удалось изменить задачу. Календарь сохранён без изменений."; return
                }
            }
            update(&link, from: event, task: notes?.tasks.first(where: { $0.id == task.id }) ?? task)
            link.sourceSignature = CalendarTaskLink.signature(for: task); link.sourceChanged = false
            replace(link); try persist(); refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func reconcileTasks() {
        guard connected, !preview, !preferenceLoadFailed, let notes, let eventStore, !links.isEmpty else { return }
        let original = links
        for index in links.indices {
            var link = links[index]
            guard let task = notes.tasks.first(where: { $0.id == link.taskID }) else { continue }
            guard let event = findEvent(link) else {
                // An empty identifier is a recoverable creation intent, not a deleted event.
                if !link.eventID.isEmpty { link.missing = true; links[index] = link }
                continue
            }
            let eventTitle = event.title ?? ""
            if let signature = link.sourceSignature, CalendarTaskLink.signature(for: task) != signature {
                link.sourceChanged = true; link.conflict = true; link.title = CalendarTaskLink.plainTitle(eventTitle)
                link.start = event.startDate; link.end = event.endDate; link.missing = false; links[index] = link
                continue
            }
            let decision = CalendarTaskMerge.decide(link: link, taskText: task.text, taskCompleted: task.completed,
                                                     remoteTitle: eventTitle, writable: !event.hasRecurrenceRules && event.calendar.allowsContentModifications)
            if decision.conflict {
                link.conflict = true; link.title = CalendarTaskLink.plainTitle(eventTitle)
                link.start = event.startDate; link.end = event.endDate; link.missing = false; links[index] = link
                continue
            }
            if decision.writeBlocked {
                link.start = event.startDate; link.end = event.endDate; link.title = CalendarTaskLink.plainTitle(eventTitle)
                link.missing = false; links[index] = link
                error = "Связанный календарь недоступен для изменений. Статус задачи сохранён в «После»."
                continue
            }
            do {
                if let title = decision.remoteTitle {
                    event.title = title
                    try eventStore.save(event, span: .thisEvent, commit: true)
                } else if let completed = decision.taskCompleted {
                    notes.complete(task, completed: completed)
                    guard notes.tasks.first(where: { $0.id == task.id })?.completed == completed else {
                        error = "Не удалось синхронизировать статус задачи. Обновите задачи и повторите."; continue
                    }
                }
                update(&link, from: event, task: notes.tasks.first(where: { $0.id == task.id }) ?? task)
                links[index] = link
            } catch { self.error = "Не удалось обновить связанное событие: \(error.localizedDescription)" }
        }
        if links != original { do { try persist() } catch { self.error = error.localizedDescription } }
    }

    private func update(_ link: inout CalendarTaskLink, from event: EKEvent, task: LibraryTask) {
        link.eventID = event.eventIdentifier; link.externalID = event.calendarItemExternalIdentifier
        link.calendarID = event.calendar.calendarIdentifier; link.title = CalendarTaskLink.plainTitle(event.title ?? "")
        link.start = event.startDate; link.end = event.endDate; link.lastEventTitle = event.title ?? ""
        link.lastTaskText = task.text; link.lastTaskCompleted = task.completed; link.missing = false; link.conflict = false
    }
    private func replace(_ link: CalendarTaskLink) {
        links.removeAll { $0.taskID == link.taskID }; links.append(link)
    }
    private func findEvent(_ link: CalendarTaskLink) -> EKEvent? {
        guard let eventStore else { return nil }
        if !link.eventID.isEmpty, let event = eventStore.event(withIdentifier: link.eventID), event.url == link.marker { return event }
        if let external = link.externalID {
            let candidates = eventStore.calendarItems(withExternalIdentifier: external).compactMap { $0 as? EKEvent }.filter { $0.url == link.marker }
            if candidates.count == 1 { return candidates[0] }
        }
        // Recovery is bounded to the persisted block's date. Never guesses by title or touches unrelated events.
        let predicate = eventStore.predicateForEvents(withStart: link.start.addingTimeInterval(-86400), end: link.end.addingTimeInterval(86400), calendars: nil)
        let matches = eventStore.events(matching: predicate).filter { $0.url == link.marker }
        return matches.count == 1 ? matches[0] : nil
    }

    private func stateURL() throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CalendarError.invalidState }
        }
        let url = root.appendingPathComponent("calendar-state.json")
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CalendarError.invalidState }
        } else if (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil { throw CalendarError.invalidState }
        return url
    }
    private func persist() throws {
        guard !preview else { return }
        guard !preferenceLoadFailed else { throw CalendarError.invalidState }
        preferences.links = links; preferences.selectedCalendarID = selectedCalendarID
        preferences.visibleCalendarIDs = visibleCalendarIDs
        let url = try stateURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        guard data.count < 8 * 1024 * 1024 else { throw CalendarError.invalidState }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func openAccounts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }
    static func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }
    static func openSystemCalendar() {
        // Calendar.app advertises ical, while calshow is an iOS-only scheme.
        NSWorkspace.shared.open(URL(string: "ical://")!)
    }

    #if DEBUG
    static func verifyPrivatePersistence(at directory: URL) throws {
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw AppError.message(message) }
        }
        let manager = FileManager.default
        let root = directory.appendingPathComponent("calendar-data")
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = CalendarStore(root: root)
        defer { store.stop() }
        try expect(store.eventStore == nil && !store.connected, "Calendar store accessed EventKit before explicit connection")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let link = CalendarTaskLink(taskID: "note:fixture", calendarID: "fixture", title: "Проверить договор", start: now, end: now.addingTimeInterval(1800),
                                    lastTaskText: "Проверить договор", lastTaskCompleted: false, lastEventTitle: "○ Проверить договор")
        store.links = [link]; store.selectedCalendarID = "fixture"; store.visibleCalendarIDs = ["fixture"]
        try store.persist()
        let file = root.appendingPathComponent("calendar-state.json")
        let permissions = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "Calendar identifiers are not private")
        let restored = CalendarStore(root: root); defer { restored.stop() }
        try expect(restored.links == [link] && restored.selectedCalendarID == "fixture" && restored.visibleCalendarIDs == ["fixture"], "Calendar link identity/date roundtrip failed")
        try expect(restored.eventStore == nil && !restored.connected, "Restoring a disabled calendar touched EventKit")
        let sentinel = directory.appendingPathComponent("calendar-sentinel.txt")
        let bytes = Data("must survive".utf8); try bytes.write(to: sentinel)
        try manager.removeItem(at: file); try manager.createSymbolicLink(at: file, withDestinationURL: sentinel)
        let blocked = CalendarStore(root: root); defer { blocked.stop() }
        try expect(blocked.preferenceLoadFailed && blocked.eventStore == nil, "Calendar symlink was accepted")
        do { try blocked.persist(); throw AppError.message("Calendar symlink write was accepted") }
        catch is CalendarError { }
        try expect(try Data(contentsOf: sentinel) == bytes, "Symlink target was modified")
        try manager.removeItem(at: file)
        let invalid = Data("{broken".utf8); try invalid.write(to: file)
        let corrupt = CalendarStore(root: root); defer { corrupt.stop() }
        try expect(corrupt.preferenceLoadFailed && corrupt.error != nil, "Corrupt calendar state was silently discarded")
        do { try corrupt.persist(); throw AppError.message("Corrupt calendar state was overwritten") }
        catch is CalendarError { }
        try expect(try Data(contentsOf: file) == invalid, "Corrupt calendar data was not preserved")
        let preview = CalendarStore(root: root, preview: true); defer { preview.stop() }
        preview.seedPreview(); preview.refresh()
        try expect(preview.eventStore == nil && preview.events.count == 2, "Preview accessed real calendars")
        try expect(try Data(contentsOf: file) == invalid, "Preview changed persisted calendar state")
    }

    /// Synthetic UI fixtures only; never reads real calendars or asks for permission.
    func seedPreview() {
        guard preview else { return }
        connected = true
        calendars = [CalendarChoice(id: "preview-google", title: "Рабочий", account: "Google", writable: true, color: .systemPurple),
                     CalendarChoice(id: "preview-yandex", title: "Личный", account: "Яндекс", writable: true, color: .systemOrange)]
        selectedCalendarID = calendars[0].id
        let today = Calendar.current.startOfDay(for: selectedDate)
        events = [CalendarAgendaEvent(id: "demo1", eventID: "demo1", title: "Планирование продукта", start: today.addingTimeInterval(11 * 3600), end: today.addingTimeInterval(12 * 3600), allDay: false, calendarID: "preview-google", calendarTitle: "Рабочий", account: "Google", color: .systemPurple, writable: true),
                  CalendarAgendaEvent(id: "demo2", eventID: "demo2", title: "○ Подготовить вопросы для следующего звонка", start: today.addingTimeInterval(15 * 3600), end: today.addingTimeInterval(15.5 * 3600), allDay: false, calendarID: "preview-yandex", calendarTitle: "Личный", account: "Яндекс", color: .systemOrange, writable: true)]
    }
    #endif
}

private enum CalendarError: LocalizedError {
    case invalidState
    var errorDescription: String? { "Файл связей с календарём повреждён или ведёт за пределы папки приложения." }
}
