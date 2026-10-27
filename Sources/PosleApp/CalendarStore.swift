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
    /// Resolve a legacy source ID or a task materialized as a stable note.
    /// Matching needs an exact source fingerprint and a unique same-meeting
    /// candidate; a reused summary position can never inherit an event.
    func replacement(in tasks: [LibraryTask]) -> LibraryTask? {
        guard taskID.hasPrefix("summary:"), !tasks.contains(where: { $0.id == taskID }),
              let sourceSignature else { return nil }
        let matches = tasks.filter { task in
            guard let meetingID = task.meetingID, taskID.hasPrefix("summary:\(meetingID):") else { return false }
            if let origin = task.taskOrigin {
                return Self.fingerprint(text: origin.sourceText, segments: origin.segmentIDs, meetingID: origin.meetingID) == sourceSignature
            }
            return Self.signature(for: task) == sourceSignature
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func fingerprint(text: String, segments: [Int], meetingID: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["text": text, "segments": segments, "meeting": meetingID], options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func signature(for task: LibraryTask) -> String? {
        guard task.noteID == nil else { return nil }
        return fingerprint(text: task.text, segments: task.segmentIDs, meetingID: task.meetingID ?? "")
    }
}

/// Display preferences never grant calendar access or change calendar/task links.
struct CalendarViewPreferences: Codable {
    var displayMode: CalendarDisplayMode = .week

    init(displayMode: CalendarDisplayMode = .week) { self.displayMode = displayMode }
    private enum CodingKeys: String, CodingKey { case displayMode }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decodeIfPresent(String.self, forKey: .displayMode)
        displayMode = raw.flatMap(CalendarDisplayMode.init(rawValue:)) ?? .week
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
    @Published var selectedDate = Date() {
        didSet { if selectedDate != oldValue && !knowledgeNavigation { refresh() } }
    }
    @Published var displayMode: CalendarDisplayMode = .week {
        didSet {
            guard displayMode != oldValue, !knowledgeNavigation else { return }
            do { try persistViewPreferences() } catch { self.error = error.localizedDescription }
            refresh()
        }
    }
    var displayPeriod: CalendarPeriod { CalendarPeriod(anchor: selectedDate, mode: displayMode, calendar: .current) }
    @Published var error: String?
    @Published private(set) var requesting = false
    @Published private(set) var lastRefreshed: Date?
    @Published var selectedCalendarID = ""
    @Published private(set) var visibleCalendarIDs: Set<String>? = nil
    let preview: Bool
    private let root: URL
    private var preferences = CalendarPreferences()
    private var eventStore: EKEventStore?
    private var knowledgeNavigation = false
    private weak var notes: NotesStore?
    private var cancellables = Set<AnyCancellable>()
    private var featureEnabled: Bool
    private var tasksEnabled: Bool
    private var refreshing = false
    private var pendingRefresh = false
    private var eventChanges: NSObjectProtocol?
    private var activation: NSObjectProtocol?
    private var preferenceLoadFailed = false
    private var viewPreferenceLoadFailed = false

    init(root: URL, preview: Bool = false, featureEnabled: Bool = true, tasksEnabled: Bool = true) {
        self.root = root; self.preview = preview
        self.featureEnabled = featureEnabled; self.tasksEnabled = tasksEnabled
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
        do {
            let url = try stateURL(filename: "calendar-view.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count < 64 * 1024 else { throw CalendarError.invalidState }
                displayMode = try JSONDecoder().decode(CalendarViewPreferences.self, from: data).displayMode
            }
        } catch {
            viewPreferenceLoadFailed = true
            if self.error == nil { self.error = "Не удалось прочитать вид календаря. Файл calendar-view.json сохранён без изменений." }
        }
        permissionDenied = [.denied, .restricted, .writeOnly].contains(EKEventStore.authorizationStatus(for: .event))
        // Existing explicit opt-in survives restart, but never asks the OS for access here.
        if featureEnabled && preferences.enabled && EKEventStore.authorizationStatus(for: .event) == .fullAccess { activate() }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Suspend the optional workflow without changing its saved connection or links.
    func setFeatureEnabled(_ enabled: Bool, tasksEnabled: Bool) {
        let resumeTasks = tasksEnabled && !self.tasksEnabled
        self.tasksEnabled = tasksEnabled
        guard enabled != featureEnabled else {
            if enabled && resumeTasks { notes?.loadTasks(); refresh() }
            return
        }
        featureEnabled = enabled
        if !enabled {
            connected = false; calendars = []; events = []; eventStore = nil
            if let eventChanges { NotificationCenter.default.removeObserver(eventChanges); self.eventChanges = nil }
        } else if !preview && preferences.enabled { activate() }
    }

    func bindNotes(_ notes: NotesStore) {
        self.notes = notes
        notes.$tasks.dropFirst().debounce(for: .milliseconds(180), scheduler: RunLoop.main).sink { [weak self] _ in self?.migrateTaskIdentities(); self?.reconcileTasks() }.store(in: &cancellables)
        notes.$workspace.dropFirst().debounce(for: .milliseconds(180), scheduler: RunLoop.main).sink { [weak self, weak notes] _ in
            if self?.connected == true, self?.tasksEnabled == true { notes?.loadTasks() }
        }.store(in: &cancellables)
        if connected { if tasksEnabled { notes.loadTasks() }; refresh() }
    }

    @discardableResult func openLink(_ url: URL) -> Bool {
        guard url.scheme == "posle", url.host == "calendar-task", url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil, url.pathComponents.count == 2,
              let id = UUID(uuidString: url.lastPathComponent),
              let link = links.first(where: { $0.marker.lastPathComponent.lowercased() == id.uuidString.lowercased() }) else { return false }
        selectedDate = link.start
        return true
    }

    func stop() {
        if let eventChanges { NotificationCenter.default.removeObserver(eventChanges) }
        if let activation { NotificationCenter.default.removeObserver(activation) }
        eventChanges = nil; activation = nil; cancellables.removeAll()
    }

    func connect() async {
        guard featureEnabled, !requesting, !preview else { return }
        guard !preferenceLoadFailed else { error = "Сначала восстановите файл calendar-state.json: новые связи не будут записаны поверх повреждённых."; return }
        requesting = true; defer { requesting = false }
        do {
            if eventStore == nil { eventStore = EKEventStore() }
            guard let eventStore else { return }
            let granted = try await eventStore.requestFullAccessToEvents()
            permissionDenied = !granted
            guard featureEnabled else { return }
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
        guard featureEnabled, !preview, !preferenceLoadFailed, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
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
        guard featureEnabled, !preview else { return }
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
        if tasksEnabled { notes?.loadTasks(); reconcileTasks() }
        // Match the exact visible interval. A week can cross a month boundary,
        // and the month grid includes its leading/trailing week days.
        let period = displayPeriod
        let start = period.start
        let end = period.end
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

    /// Reads only calendars the user has already connected and made visible.
    /// Unlike refresh(), this never activates EventKit, requests permission,
    /// reconciles task links, or changes the visible calendar period.
    func knowledgeSnapshot(question: String, now: Date = Date(), includingEventIDs: Set<String> = []) -> KnowledgeCalendarSnapshot {
        let period = Self.knowledgePeriod(question, now: now)
        let anchor = period?.start ?? now
        let day = Calendar.current.startOfDay(for: anchor)
        // A literal day/range has exact coverage; general questions keep the
        // bounded surrounding window. Period hints preserve local DST offsets.
        let start = period?.start ?? Calendar.current.date(byAdding: .day, value: -7, to: day) ?? day.addingTimeInterval(-7 * 86400)
        let end = period?.end ?? Calendar.current.date(byAdding: .day, value: 31, to: day) ?? day.addingTimeInterval(31 * 86400)
        guard let agenda = knowledgeEvents(start: start, end: end) else {
            return KnowledgeCalendarSnapshot(connected: false, coverageStart: start.timeIntervalSince1970,
                coverageEnd: end.timeIntervalSince1970, events: [], requestedStart: period?.start.timeIntervalSince1970,
                requestedEnd: period?.end.timeIntervalSince1970)
        }
        let terms = Self.knowledgeSubjectTerms(question)
        let valid = agenda.filter { event in
            !event.id.isEmpty && event.id.utf8.count <= 1024 && event.start.timeIntervalSince1970.isFinite
                && event.end.timeIntervalSince1970.isFinite && event.end >= event.start
                && event.start < end && (event.end > start || event.start >= start)
        }.sorted {
            let lhsCited = includingEventIDs.contains($0.id), rhsCited = includingEventIDs.contains($1.id)
            if lhsCited != rhsCited { return lhsCited }
            let lhsScore = Self.knowledgeSubjectScore($0, terms: terms), rhsScore = Self.knowledgeSubjectScore($1, terms: terms)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhs = abs($0.start.timeIntervalSince(anchor)), rhs = abs($1.start.timeIntervalSince(anchor))
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        var snapshot = KnowledgeCalendarSnapshot(connected: true, coverageStart: start.timeIntervalSince1970,
            coverageEnd: end.timeIntervalSince1970, events: [], requestedStart: period?.start.timeIntervalSince1970,
            requestedEnd: period?.end.timeIntervalSince1970)
        let encoder = JSONEncoder()
        for event in valid {
            guard snapshot.events.count < 128 else { break }
            let value = KnowledgeCalendarEvent(id: event.id, title: Self.knowledgeText(event.title, bytes: 1024),
                start: event.start.timeIntervalSince1970, end: event.end.timeIntervalSince1970,
                allDay: event.allDay, calendarTitle: Self.knowledgeText(event.calendarTitle, bytes: 512),
                startOffsetMinutes: TimeZone.current.secondsFromGMT(for: event.start) / 60,
                endOffsetMinutes: TimeZone.current.secondsFromGMT(for: event.end) / 60)
            snapshot.events.append(value)
            // Measure complete UTF-8 JSON objects, never slice serialized bytes.
            guard let encoded = try? encoder.encode(snapshot), encoded.count < 128 * 1024 else {
                snapshot.events.removeLast(); break
            }
        }
        snapshot.truncated = valid.count > snapshot.events.count
        return snapshot
    }

    /// Called only after the fresh snapshot and source fingerprint were checked.
    /// Navigation reads the destination day without running task/calendar sync.
    @discardableResult func revealKnowledgeEvent(_ event: KnowledgeCalendarEvent) -> Bool {
        let date = Date(timeIntervalSince1970: event.start)
        let day = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        guard let visible = knowledgeEvents(start: day, end: end), visible.contains(where: { $0.id == event.id }) else { return false }
        knowledgeNavigation = true
        selectedDate = date; displayMode = .day
        knowledgeNavigation = false
        events = visible.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        return true
    }

    private func knowledgeEvents(start: Date, end: Date) -> [CalendarAgendaEvent]? {
        guard featureEnabled, connected else { return nil }
        if preview {
            return events.filter { (visibleCalendarIDs?.contains($0.calendarID) ?? true) && $0.start < end && ($0.end > start || $0.start >= start) }
        }
        guard preferences.enabled, let eventStore,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let chosen = eventStore.calendars(for: .event).filter { visibleCalendarIDs?.contains($0.calendarIdentifier) ?? true }
        guard !chosen.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: chosen)
        return eventStore.events(matching: predicate).map { event in
            CalendarAgendaEvent(id: event.eventIdentifier + ":" + String(event.startDate.timeIntervalSince1970), eventID: event.eventIdentifier,
                title: event.title ?? "Без названия", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                account: event.calendar.source.title, color: NSColor(cgColor: event.calendar.cgColor) ?? .systemPurple,
                writable: event.calendar.allowsContentModifications && !event.hasRecurrenceRules)
        }
    }

    private static func knowledgePeriod(_ question: String, now: Date) -> DateInterval? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        var dates: [Date] = []
        for (pattern, format) in [(#"\b\d{4}-\d{2}-\d{2}\b"#, "yyyy-MM-dd"), (#"\b\d{2}\.\d{2}\.\d{4}\b"#, "dd.MM.yyyy")] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
            formatter.dateFormat = format; formatter.isLenient = false
            for match in regex.matches(in: question, range: NSRange(question.startIndex..., in: question)).prefix(2) {
                if let range = Range(match.range, in: question), let date = formatter.date(from: String(question[range])) { dates.append(date) }
            }
        }
        let text = question.lowercased()
        let begin: Date, end: Date
        if let first = dates.min(), let last = dates.max(), let next = calendar.date(byAdding: .day, value: 1, to: last) {
            begin = first; end = next
        } else {
            let delta: Int?
            if text.contains("послезавтра") || text.contains("day after tomorrow") { delta = 2 }
            else if text.contains("завтра") || text.contains("tomorrow") { delta = 1 }
            else if text.contains("вчера") || text.contains("yesterday") { delta = -1 }
            else if text.contains("сегодня") || text.contains("today") { delta = 0 }
            else { delta = nil }
            if let delta, let date = calendar.date(byAdding: .day, value: delta, to: day),
               let next = calendar.date(byAdding: .day, value: 1, to: date) { begin = date; end = next }
            else if text.contains("следующей неделе") || text.contains("next week") || text.contains("этой неделе") || text.contains("this week") {
                let weekday = (calendar.component(.weekday, from: day) + 5) % 7
                let next = text.contains("следующей неделе") || text.contains("next week") ? 7 : 0
                guard let date = calendar.date(byAdding: .day, value: next - weekday, to: day),
                      let finish = calendar.date(byAdding: .day, value: 7, to: date) else { return nil }
                begin = date; end = finish
            } else { return nil }
        }
        guard begin.timeIntervalSince1970 >= 0, end.timeIntervalSince1970 <= 4_133_980_800,
              end > begin, end.timeIntervalSince(begin) <= 93 * 86400 else { return nil }
        return DateInterval(start: begin, end: end)
    }

    private static func knowledgeWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
    }
    private static func knowledgeSubjectTerms(_ question: String) -> [String] {
        let ignored: Set<String> = ["what", "when", "where", "which", "show", "find", "about", "have", "does", "with", "that", "this", "there", "were", "will", "today", "tomorrow", "yesterday", "after", "next", "week", "last", "когда", "какие", "какая", "какой", "найди", "найти", "покажи", "календарь", "меня", "есть", "будет", "будут", "были", "было", "запланировано", "сегодня", "завтра", "послезавтра", "вчера", "следующей", "этой", "неделе", "встречи", "встреча", "события"]
        return Array(Set(knowledgeWords(question).filter { !ignored.contains($0) && $0.contains(where: \.isLetter) })).sorted()
    }
    private static func knowledgeSubjectScore(_ event: CalendarAgendaEvent, terms: [String]) -> Int {
        let title = knowledgeWords(event.title), calendar = knowledgeWords(event.calendarTitle)
        func matches(_ term: String, in words: [String]) -> Bool {
            words.contains { word in
                if word == term || (min(word.count, term.count) >= 4 && (word.hasPrefix(term) || term.hasPrefix(word))) { return true }
                // A bounded lexical preselection, not semantic retrieval. Keep
                // common RU endings from dropping an otherwise exact topic.
                return min(word.count, term.count) >= 6 && word.prefix(min(word.count, term.count) - 2) == term.prefix(min(word.count, term.count) - 2)
            }
        }
        return terms.reduce(0) { $0 + (matches($1, in: title) ? 4 : 0) + (matches($1, in: calendar) ? 1 : 0) }
    }
    private static func knowledgeText(_ text: String, bytes: Int) -> String {
        var value = "", size = 0
        for scalar in text.unicodeScalars {
            guard scalar != "\0", size + scalar.utf8.count <= bytes else { break }
            value.unicodeScalars.append(scalar); size += scalar.utf8.count
        }
        return value
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
        return events.filter { event in
            guard visibleCalendarIDs?.contains(event.calendarID) ?? true else { return false }
            // Calendar end dates are exclusive: an event ending at midnight is
            // absent on the next day. A zero-duration event belongs to its start day.
            if event.end == event.start { return event.start >= start && event.start < end }
            return event.end > event.start && event.start < end && event.end > start
        }
    }

    /// A new block is explicit. A persisted creation intent plus marker recovers an interrupted save.
    @discardableResult func schedule(task: LibraryTask?, title: String, start: Date, end: Date, calendarID: String, expected: CalendarTaskLink? = nil) -> Bool {
        guard featureEnabled, task == nil || tasksEnabled else { error = "Включите нужную возможность в настройках."; return false }
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
        guard featureEnabled, item.taskID == nil || tasksEnabled else { error = "Включите нужную возможность в настройках."; return false }
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
        guard featureEnabled, tasksEnabled else { return }
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

    private func migrateTaskIdentities() {
        guard featureEnabled, tasksEnabled, !preview, !preferenceLoadFailed, let notes else { return }
        let original = links
        for index in links.indices {
            if let task = links[index].replacement(in: notes.tasks) {
                links[index].taskID = task.id
                links[index].sourceSignature = CalendarTaskLink.signature(for: task)
            }
        }
        if links != original { do { try persist() } catch { links = original; self.error = error.localizedDescription } }
    }
    private func reconcileTasks() {
        guard featureEnabled, tasksEnabled, connected, !preview, !preferenceLoadFailed, let notes, let eventStore, !links.isEmpty else { return }
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

    private func stateURL(filename: String = "calendar-state.json") throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CalendarError.invalidState }
        }
        let url = root.appendingPathComponent(filename)
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

    private func persistViewPreferences() throws {
        guard !preview else { return }
        guard !viewPreferenceLoadFailed else { throw CalendarError.invalidState }
        let url = try stateURL(filename: "calendar-view.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CalendarViewPreferences(displayMode: displayMode))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
        try expect(restored.displayMode == .week, "An existing calendar without view preferences must default to week")
        store.displayMode = .month
        let viewFile = root.appendingPathComponent("calendar-view.json")
        let viewPermissions = try manager.attributesOfItem(atPath: viewFile.path)[.posixPermissions] as? NSNumber
        try expect(viewPermissions?.intValue == 0o600, "Calendar view preferences are not private")
        let viewRestored = CalendarStore(root: root); defer { viewRestored.stop() }
        try expect(viewRestored.displayMode == .month && viewRestored.eventStore == nil, "Calendar view did not roundtrip independently of access")
        try expect(viewRestored.links == [link], "Changing calendar view modified task/calendar links")
        let invalidView = Data("{broken-view".utf8)
        try invalidView.write(to: viewFile)
        let corruptView = CalendarStore(root: root); defer { corruptView.stop() }
        try expect(corruptView.viewPreferenceLoadFailed && corruptView.displayMode == .week, "Corrupt calendar view was silently accepted")
        corruptView.displayMode = .day
        try expect(try Data(contentsOf: viewFile) == invalidView, "Changing view overwrote corrupt preferences")
        let viewSentinel = directory.appendingPathComponent("calendar-view-sentinel.txt")
        let viewBytes = Data("view target must survive".utf8); try viewBytes.write(to: viewSentinel)
        try manager.removeItem(at: viewFile); try manager.createSymbolicLink(at: viewFile, withDestinationURL: viewSentinel)
        let symlinkView = CalendarStore(root: root); defer { symlinkView.stop() }
        try expect(symlinkView.viewPreferenceLoadFailed && symlinkView.eventStore == nil, "Calendar view symlink was accepted")
        symlinkView.displayMode = .threeDays
        try expect(try Data(contentsOf: viewSentinel) == viewBytes, "Calendar view modified a symlink target")
        try manager.removeItem(at: viewFile)
        try invalidView.write(to: viewFile)
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
        preview.seedPreview(); preview.displayMode = .threeDays; preview.refresh()
        try expect(preview.eventStore == nil && preview.events.count >= 10, "Preview accessed real calendars")
        try expect(try Data(contentsOf: file) == invalid, "Preview changed persisted calendar state")
        try expect(try Data(contentsOf: viewFile) == invalidView, "Preview changed persisted view preferences")
    }

    static func verifyDisplayEventBoundaries() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw AppError.message(message) }
        }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let third = calendar.date(byAdding: .day, value: 2, to: day)!
        func event(_ id: String, start: Date, end: Date, allDay: Bool = false) -> CalendarAgendaEvent {
            CalendarAgendaEvent(id: id, eventID: id, title: id, start: start, end: end,
                allDay: allDay, calendarID: "fiction", calendarTitle: "Календарь",
                account: "Локальный", color: .systemBlue, writable: true)
        }
        let store = CalendarStore(root: URL(fileURLWithPath: "/private/tmp/posle-calendar-memory-only"), preview: true)
        store.events = [event("ends-at-midnight", start: day, end: next),
                        event("all-day-two-days", start: day, end: third, allDay: true),
                        event("zero-midnight", start: next, end: next),
                        event("crosses-midnight", start: next.addingTimeInterval(-1800), end: next.addingTimeInterval(1800)),
                        event("invalid-negative", start: next, end: day)]
        try expect(Set(store.events(on: day).map(\.id)) == ["ends-at-midnight", "all-day-two-days", "crosses-midnight"], "First day event clipping is incorrect")
        try expect(Set(store.events(on: next).map(\.id)) == ["all-day-two-days", "zero-midnight", "crosses-midnight"], "Midnight boundaries must be exclusive and zero events stay on their start day")
        try expect(store.events(on: third).isEmpty, "An all-day event leaked beyond its exclusive end")
        store.visibleCalendarIDs = []
        try expect(store.events(on: day).isEmpty, "Hidden preview calendars remain visible")
        store.visibleCalendarIDs = ["fiction"]
        try expect(store.events(on: next).count == 3 && store.eventStore == nil, "Restoring calendar visibility touched EventKit or lost events")
    }

    static func verifyKnowledgeSnapshotBounds() throws {
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw AppError.message(message) }
        }
        let root = URL(fileURLWithPath: "/private/tmp/posle-knowledge-calendar-memory-only")
        let store = CalendarStore(root: root, preview: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try expect(!store.knowledgeSnapshot(question: "Сегодня", now: now).connected && store.eventStore == nil,
                   "A disconnected knowledge query must not construct EventKit")
        store.connected = true
        func event(_ index: Int, large: Bool) -> CalendarAgendaEvent {
            CalendarAgendaEvent(id: "event-\(index)" + (large ? String(repeating: "x", count: 900) : ""), eventID: "event-\(index)",
                title: large ? String(repeating: "Ж", count: 1000) : "Встреча", start: now.addingTimeInterval(Double(index)),
                end: now.addingTimeInterval(Double(index) + 60), allDay: false, calendarID: "fixture",
                calendarTitle: large ? String(repeating: "К", count: 1000) : "Личный", account: "Synthetic", color: .systemBlue, writable: false)
        }
        store.events = (0..<200).map { event($0, large: false) }
        let countBounded = store.knowledgeSnapshot(question: "Сегодня", now: now)
        try expect(countBounded.events.count == 128 && countBounded.truncated, "Knowledge calendar event-count limit failed")
        store.events = (0..<200).map { event($0, large: true) }
        let bytesBounded = store.knowledgeSnapshot(question: "Сегодня", now: now)
        try expect(bytesBounded.events.count < 128 && !bytesBounded.events.isEmpty && bytesBounded.truncated,
                   "UTF-8 calendar payload must be bounded by bytes as well as event count")
        try expect(try JSONEncoder().encode(bytesBounded).count < 128 * 1024, "Knowledge calendar JSON exceeds its input budget")
        try expect(bytesBounded.coverageStart == countBounded.coverageStart && bytesBounded.coverageEnd == countBounded.coverageEnd,
                   "Truncation must retain honest calendar coverage")
        let dated = store.knowledgeSnapshot(question: "Что запланировано на 2027-06-15?", now: now)
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        let expected = formatter.date(from: "2027-06-15")!
        try expect(dated.coverageStart == expected.timeIntervalSince1970 && dated.requestedStart == dated.coverageStart && store.eventStore == nil,
                   "Explicit question date must use exact coverage and the local timezone without EventKit access")
        // A distant topical match must survive preselection before the 128 cap.
        let far = calendarDate(now, days: 25)
        let target = CalendarAgendaEvent(id: "far-astrolabe", eventID: "far-astrolabe", title: "Проверка астролябии",
            start: far, end: far.addingTimeInterval(3600), allDay: false, calendarID: "fixture",
            calendarTitle: "Личный", account: "Synthetic", color: .systemBlue, writable: false)
        store.events = (0..<200).map { event($0, large: false) } + [target]
        let topical = store.knowledgeSnapshot(question: "Когда проверка астролябии?", now: now)
        try expect(topical.events.contains { $0.id == target.id } && topical.events.count == 128 && topical.truncated,
                   "A far topic match was discarded before calendar ranking")
        let validation = store.knowledgeSnapshot(question: "Какие события?", now: now, includingEventIDs: [target.id])
        try expect(validation.events.contains { $0.id == target.id }, "Fresh citation validation must retain a real occurrence even when its rank changes")
        let explicit = store.knowledgeSnapshot(question: "Что запланировано на \(formatter.string(from: far))?", now: now)
        try expect(explicit.events.map(\.id) == [target.id] && explicit.requestedStart == explicit.coverageStart,
                   "An explicit date must fetch its matching far occurrence before the cap")
        func calendarDate(_ date: Date, days: Int) -> Date {
            Calendar.current.date(byAdding: .day, value: days, to: date)!
        }
    }

    /// More nearby records than the input cap, plus a relevant later event.
    @discardableResult func seedKnowledgeLongTailForChecks(anchor: Date = Date()) -> Date {
        precondition(preview)
        connected = true; visibleCalendarIDs = nil; links = []
        calendars = [CalendarChoice(id: "knowledge-fixture", title: "Личный", account: "Synthetic", writable: false, color: .systemBlue)]
        let day = Calendar.current.startOfDay(for: anchor)
        events = (0..<200).map { index in
            let start = day.addingTimeInterval(Double(index) * 60)
            return CalendarAgendaEvent(id: "near-\(index)", eventID: "near-\(index)", title: "Синхронизация команды", start: start,
                end: start.addingTimeInterval(30), allDay: false, calendarID: "knowledge-fixture", calendarTitle: "Личный",
                account: "Synthetic", color: .systemBlue, writable: false)
        }
        let far = Calendar.current.date(byAdding: .day, value: 25, to: day)!.addingTimeInterval(12 * 3600)
        events.append(CalendarAgendaEvent(id: "far-astrolabe", eventID: "far-astrolabe", title: "Проверка астролябии",
            start: far, end: far.addingTimeInterval(3600), allDay: false, calendarID: "knowledge-fixture",
            calendarTitle: "Личный", account: "Synthetic", color: .systemBlue, writable: false))
        return far
    }

    /// Deterministic in-flight-answer regression; never touches EventKit.
    func changeKnowledgeEventForChecks(id: String, title: String) {
        precondition(preview)
        if let index = events.firstIndex(where: { $0.id == id }) {
            let old = events[index]
            events[index] = CalendarAgendaEvent(id: old.id, eventID: old.eventID, title: title,
                start: old.start, end: old.end, allDay: old.allDay, calendarID: old.calendarID,
                calendarTitle: old.calendarTitle, account: old.account, color: old.color,
                writable: old.writable, taskID: old.taskID)
        }
    }

    /// Synthetic UI fixtures only; never reads real calendars or asks for permission.
    func seedPreview() {
        guard preview else { return }
        connected = true
        calendars = [CalendarChoice(id: "preview-google", title: "Рабочий", account: "Google", writable: true, color: .systemPurple),
                     CalendarChoice(id: "preview-yandex", title: "Личный", account: "Яндекс", writable: true, color: .systemOrange)]
        selectedCalendarID = calendars[0].id
        let calendar = Calendar.current
        let week = CalendarPeriod(anchor: selectedDate, mode: .week, calendar: calendar)
        func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            let start = calendar.date(byAdding: .day, value: day, to: week.start) ?? week.start
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
        }
        func event(_ id: String, _ title: String, _ day: Int, _ hour: Int, _ minute: Int,
                   _ duration: TimeInterval, personal: Bool = false, taskID: String? = nil) -> CalendarAgendaEvent {
            let choice = calendars[personal ? 1 : 0]
            let start = date(day, hour, minute)
            return CalendarAgendaEvent(id: id, eventID: id, title: title, start: start,
                end: start.addingTimeInterval(duration), allDay: false,
                calendarID: choice.id, calendarTitle: choice.title, account: choice.account,
                color: choice.color, writable: true, taskID: taskID)
        }
        let linkedTask = notes?.tasks.first(where: { !$0.completed })
        let taskText = linkedTask?.text ?? "Подготовить вопросы к интервью"
        let taskID = linkedTask?.id ?? "preview-interview-questions"
        events = [
            event("plan-week", "Планы на неделю", 0, 10, 0, 45 * 60),
            event("product-review", "Обсуждение продукта", 0, 11, 0, 60 * 60),
            event("design-review", "Разбор макетов", 0, 11, 30, 60 * 60),
            event("evening-training", "Тренировка", 0, 18, 30, 60 * 60, personal: true),
            event("team-sync", "Командная встреча", 1, 9, 30, 30 * 60),
            event("interview-questions", taskText, 1, 15, 0, 45 * 60, taskID: taskID),
            event("research", "Интервью с пользователем", 2, 13, 0, 60 * 60),
            event("project-checkpoint", "Промежуточные результаты", 3, 10, 0, 60 * 60),
            event("release-support", "Релиз: окно поддержки", 3, 23, 30, 90 * 60),
            event("week-review", "Итоги недели", 4, 16, 0, 45 * 60)
        ]
        events.append(CalendarAgendaEvent(id: "launch-preparation", eventID: "launch-preparation",
            title: "Подготовка запуска", start: date(1), end: date(3), allDay: true,
            calendarID: calendars[0].id, calendarTitle: calendars[0].title,
            account: calendars[0].account, color: calendars[0].color, writable: true))
        if let block = events.first(where: { $0.taskID == taskID }) {
            links = [CalendarTaskLink(taskID: taskID, eventID: block.eventID,
                calendarID: block.calendarID, title: block.title, start: block.start, end: block.end,
                lastTaskText: taskText, lastTaskCompleted: false, lastEventTitle: block.title)]
        }
        events.sort { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
        lastRefreshed = Date()

    }
    #endif
}

private enum CalendarError: LocalizedError {
    case invalidState
    var errorDescription: String? { "Файл связей с календарём повреждён или ведёт за пределы папки приложения." }
}
