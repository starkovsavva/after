import Foundation

public enum CalendarDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case day, threeDays, week, month
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .day: return "День"
        case .threeDays: return "3 дня"
        case .week: return "Неделя"
        case .month: return "Месяц"
        }
    }
    public func range(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        CalendarPeriod(anchor: date, mode: self, calendar: calendar).interval
    }
    public func shiftedDate(from date: Date, by offset: Int, calendar: Calendar = .current) -> Date {
        let stride = self == .threeDays ? 3 : self == .week ? 7 : 1
        let (amount, overflow) = offset.multipliedReportingOverflow(by: stride)
        guard !overflow, date.timeIntervalSinceReferenceDate.isFinite else { return date }
        return calendar.date(byAdding: self == .month ? .month : .day, value: amount, to: date) ?? date
    }
}

/// Visible dates use calendar arithmetic, so a day may contain 23 or 25 elapsed hours.
public struct CalendarPeriod: Equatable, Sendable {
    public let anchor: Date
    public let mode: CalendarDisplayMode
    public let calendar: Calendar
    public let interval: DateInterval
    public let days: [Date]
    public let monthStart: Date
    public var start: Date { interval.start }
    public var end: Date { interval.end }

    public init(anchor: Date, mode: CalendarDisplayMode, calendar: Calendar = .current) {
        let validAnchor = anchor.timeIntervalSinceReferenceDate.isFinite ? anchor : Date(timeIntervalSince1970: 0)
        self.anchor = validAnchor; self.mode = mode; self.calendar = calendar
        let selectedDay = calendar.startOfDay(for: validAnchor)
        monthStart = calendar.dateInterval(of: .month, for: selectedDay)?.start ?? selectedDay
        let first: Date
        let count: Int
        switch mode {
        case .day: first = selectedDay; count = 1
        case .threeDays: first = selectedDay; count = 3
        case .week:
            let weekday = calendar.component(.weekday, from: selectedDay)
            let offset = (weekday - calendar.firstWeekday + 7) % 7
            first = calendar.date(byAdding: .day, value: -offset, to: selectedDay) ?? selectedDay
            count = 7
        case .month:
            let weekday = calendar.component(.weekday, from: monthStart)
            let offset = (weekday - calendar.firstWeekday + 7) % 7
            first = calendar.date(byAdding: .day, value: -offset, to: monthStart) ?? monthStart
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            let dayCount = calendar.dateComponents([.day], from: first, to: nextMonth).day ?? 35
            count = max(35, ((dayCount + 6) / 7) * 7)
        }
        days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        let last = calendar.date(byAdding: .day, value: count, to: first) ?? first.addingTimeInterval(86_400)
        interval = DateInterval(start: first, end: max(first, last))
    }
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
    public func shifted(by offset: Int) -> Date { mode.shiftedDate(from: anchor, by: offset, calendar: calendar) }
}

public struct CalendarLayoutEvent: Equatable, Sendable {
    public let id: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public init(id: String, start: Date, end: Date, allDay: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.allDay = allDay
    }
}

public struct CalendarTimedPlacement: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let day: Date
    public let start: Date
    public let end: Date
    /// Local clock positions for a shared 24-hour grid. A repeated-hour interval is at least one minute tall.
    public let startMinute: Double
    public let endMinute: Double
    public let elapsedStartMinute: Double
    public let elapsedEndMinute: Double
    public let dayDurationMinutes: Double
    public let column: Int
    public let columnCount: Int
    public let continuesBefore: Bool
    public let continuesAfter: Bool
}

public struct CalendarAllDayPlacement: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let startDayIndex: Int
    /// Exclusive, just like EventKit's end date for all-day events.
    public let endDayIndex: Int
    public let row: Int
    public let continuesBefore: Bool
    public let continuesAfter: Bool
}

public enum CalendarLayout {
    /// Clips to one local day and assigns the minimum number of columns per connected overlap group.
    /// Adjacent events can share a column. Input order never changes placement.
    /// A positive visual minimum prevents short or repeated-hour chips from covering
    /// each other on a wall-clock grid; exact clipped dates and clock minutes stay intact.
    public static func timed(events: [CalendarLayoutEvent], on day: Date, calendar: Calendar = .current, minimumVisualMinutes: Double = 0) -> [CalendarTimedPlacement] {
        guard day.timeIntervalSinceReferenceDate.isFinite,
              let dayRange = calendar.dateInterval(of: .day, for: day) else { return [] }
        let visualMinimum = minimumVisualMinutes.isFinite ? min(1440, max(0, minimumVisualMinutes)) : 0
        struct Slice {
            let event: CalendarLayoutEvent
            let start: Date
            let end: Date
            let minuteStart: Double
            let minuteEnd: Double
            let laneStart: Double
            let laneEnd: Double
        }
        let slices: [Slice] = events.compactMap { event in
            guard !event.allDay, isValid(event), event.start < dayRange.end,
                  event.end != event.start || event.start >= dayRange.start else { return nil }
            // A zero-duration event is a one-minute marker belonging only to its start day.
            let effectiveEnd = event.end == event.start ? event.start.addingTimeInterval(60) : event.end
            guard effectiveEnd > dayRange.start else { return nil }
            let start = max(event.start, dayRange.start), end = min(effectiveEnd, dayRange.end)
            let minuteStart = clockMinute(start, in: dayRange, calendar: calendar)
            let minuteEnd = min(1440, max(minuteStart + 1, clockMinute(end, in: dayRange, calendar: calendar)))
            let laneStart = visualMinimum > 0 ? min(minuteStart, 1440 - visualMinimum) : start.timeIntervalSinceReferenceDate
            let laneEnd = visualMinimum > 0 ? min(1440, max(minuteEnd, laneStart + visualMinimum)) : end.timeIntervalSinceReferenceDate
            return Slice(event: event, start: start, end: end, minuteStart: minuteStart, minuteEnd: minuteEnd, laneStart: laneStart, laneEnd: laneEnd)
        }.sorted {
            if $0.laneStart != $1.laneStart { return $0.laneStart < $1.laneStart }
            if $0.laneEnd != $1.laneEnd { return $0.laneEnd > $1.laneEnd }
            return $0.event.id < $1.event.id
        }
        var result: [CalendarTimedPlacement] = []
        var groupStart = 0
        while groupStart < slices.count {
            var groupEnd = groupStart + 1
            var latestEnd = slices[groupStart].laneEnd
            while groupEnd < slices.count, slices[groupEnd].laneStart < latestEnd {
                latestEnd = max(latestEnd, slices[groupEnd].laneEnd)
                groupEnd += 1
            }
            var laneEnds: [Double] = []
            var assignments: [(Slice, Int)] = []
            for index in groupStart..<groupEnd {
                let slice = slices[index]
                let column: Int
                if let available = laneEnds.firstIndex(where: { $0 <= slice.laneStart }) {
                    column = available; laneEnds[available] = slice.laneEnd
                } else {
                    column = laneEnds.count; laneEnds.append(slice.laneEnd)
                }
                assignments.append((slice, column))
            }
            for (slice, column) in assignments {
                result.append(CalendarTimedPlacement(
                    eventID: slice.event.id, day: dayRange.start, start: slice.start, end: slice.end,
                    startMinute: slice.minuteStart, endMinute: slice.minuteEnd,
                    elapsedStartMinute: slice.start.timeIntervalSince(dayRange.start) / 60,
                    elapsedEndMinute: slice.end.timeIntervalSince(dayRange.start) / 60,
                    dayDurationMinutes: dayRange.duration / 60,
                    column: column, columnCount: laneEnds.count,
                    continuesBefore: slice.event.start < dayRange.start,
                    continuesAfter: slice.event.end > dayRange.end
                ))
            }
            groupStart = groupEnd
        }
        return result
    }

    /// All-day spans occupy independent rows and never reduce timed events' available width.
    public static func allDay(events: [CalendarLayoutEvent], in period: CalendarPeriod, calendar suppliedCalendar: Calendar? = nil) -> [CalendarAllDayPlacement] {
        let calendar = suppliedCalendar ?? period.calendar
        struct Span {
            let event: CalendarLayoutEvent
            let start: Int
            let end: Int
        }
        let spans: [Span] = events.compactMap { event in
            guard event.allDay, isValid(event), event.start < period.end else { return nil }
            let effectiveEnd = event.end == event.start
                ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.start)) ?? event.start)
                : event.end
            guard effectiveEnd > period.start else { return nil }
            let occupied = period.days.indices.filter { index in
                guard let end = calendar.date(byAdding: .day, value: 1, to: period.days[index]) else { return false }
                return event.start < end && effectiveEnd > period.days[index]
            }
            guard let first = occupied.first, let last = occupied.last else { return nil }
            return Span(event: event, start: first, end: last + 1)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.event.id < $1.event.id
        }
        var rowEnds: [Int] = []
        return spans.map { span in
            let row: Int
            if let available = rowEnds.firstIndex(where: { $0 <= span.start }) {
                row = available; rowEnds[available] = span.end
            } else { row = rowEnds.count; rowEnds.append(span.end) }
            return CalendarAllDayPlacement(eventID: span.event.id, startDayIndex: span.start, endDayIndex: span.end, row: row,
                                           continuesBefore: span.event.start < period.start,
                                           continuesAfter: span.event.end > period.end)
        }
    }

    private static func isValid(_ event: CalendarLayoutEvent) -> Bool {
        event.start.timeIntervalSinceReferenceDate.isFinite && event.end.timeIntervalSinceReferenceDate.isFinite && event.end >= event.start
    }
    private static func clockMinute(_ date: Date, in day: DateInterval, calendar: Calendar) -> Double {
        if date >= day.end { return 1440 }
        if date <= day.start { return 0 }
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return Double(parts.hour ?? 0) * 60 + Double(parts.minute ?? 0)
            + Double(parts.second ?? 0) / 60 + Double(parts.nanosecond ?? 0) / 60_000_000_000
    }
}
