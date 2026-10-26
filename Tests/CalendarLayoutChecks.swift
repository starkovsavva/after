import Foundation
#if SWIFT_PACKAGE
import XCTest
@testable import PosleCore
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct CalendarLayoutChecks {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        #if SWIFT_PACKAGE
        XCTAssertTrue(value(), message, line: line)
        #else
        precondition(value(), "Line \(line): \(message)")
        #endif
    }
    static func calendar(_ zone: String = "America/New_York", firstWeekday: Int = 2) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.locale = Locale(identifier: "en_US_POSIX")
        result.timeZone = TimeZone(identifier: zone)!
        result.firstWeekday = firstWeekday
        return result
    }
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static func day(_ value: String, _ calendar: Calendar) -> Date { calendar.startOfDay(for: date(value)) }
    static func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> CalendarLayoutEvent {
        CalendarLayoutEvent(id: id, start: date(start), end: date(end), allDay: allDay)
    }
    static func main() {
        let ny = calendar()
        let spring = CalendarPeriod(anchor: date("2026-03-08T12:00:00-04:00"), mode: .day, calendar: ny)
        let fall = CalendarPeriod(anchor: date("2026-11-01T12:00:00-05:00"), mode: .day, calendar: ny)
        expect(spring.interval.duration == 23 * 3600 && fall.interval.duration == 25 * 3600, "DST days use real boundaries")
        let springThree = CalendarPeriod(anchor: date("2026-03-07T12:00:00-05:00"), mode: .threeDays, calendar: ny)
        expect(springThree.days.count == 3 && springThree.interval.duration == 71 * 3600, "three-day range spans local dates, not 72 hours")
        let fallWeek = CalendarPeriod(anchor: date("2026-11-01T12:00:00-05:00"), mode: .week, calendar: ny)
        expect(fallWeek.days.count == 7 && fallWeek.interval.duration == 169 * 3600, "week includes the repeated hour")
        expect(spring.contains(spring.start) && !spring.contains(spring.end), "visible intervals are half-open")
        print("PASS: local day, 3-day and week ranges across both DST transitions")

        let utcMonday = calendar("UTC", firstWeekday: 2), utcSunday = calendar("UTC", firstWeekday: 1)
        let october = date("2026-10-20T10:00:00Z")
        expect(CalendarPeriod(anchor: october, mode: .week, calendar: utcMonday).start == date("2026-10-19T00:00:00Z"), "Monday week start")
        expect(CalendarPeriod(anchor: october, mode: .week, calendar: utcSunday).start == date("2026-10-18T00:00:00Z"), "Sunday week start")
        let fourWeekMonth = CalendarPeriod(anchor: date("2026-02-14T12:00:00Z"), mode: .month, calendar: utcSunday)
        expect(fourWeekMonth.days.count == 35 && fourWeekMonth.start == date("2026-02-01T00:00:00Z"), "short month still presents five full rows")
        let sixWeekMonth = CalendarPeriod(anchor: date("2026-08-19T12:00:00Z"), mode: .month, calendar: utcMonday)
        expect(sixWeekMonth.days.count == 42 && sixWeekMonth.start == date("2026-07-27T00:00:00Z"), "six-week month keeps leading and trailing days")
        expect(sixWeekMonth.end == date("2026-09-07T00:00:00Z"), "month query includes its visible trailing dates")
        let leapMonth = CalendarPeriod(anchor: date("2024-02-29T12:00:00Z"), mode: .month, calendar: utcMonday)
        expect(leapMonth.monthStart == date("2024-02-01T00:00:00Z") && leapMonth.contains(date("2024-02-29T12:00:00Z")), "leap-day month")
        print("PASS: locale week starts, five/six rows, leap years and visible month queries")

        let beforeDST = date("2026-03-07T12:00:00-05:00")
        expect(CalendarDisplayMode.day.shiftedDate(from: beforeDST, by: 1, calendar: ny) == date("2026-03-08T12:00:00-04:00"), "day navigation preserves local clock across DST")
        expect(CalendarDisplayMode.threeDays.shiftedDate(from: beforeDST, by: -1, calendar: ny) == date("2026-03-04T12:00:00-05:00"), "three-day previous navigation")
        expect(CalendarDisplayMode.week.shiftedDate(from: beforeDST, by: 1, calendar: ny) == date("2026-03-14T12:00:00-04:00"), "week navigation adds seven dates")
        expect(CalendarDisplayMode.month.shiftedDate(from: date("2026-01-31T12:00:00Z"), by: 1, calendar: utcMonday) == date("2026-02-28T12:00:00Z"), "month navigation clamps day at end of month")
        expect(springThree.shifted(by: 1) == date("2026-03-10T12:00:00-04:00"), "period navigation delegates calendar arithmetic")
        expect(CalendarDisplayMode.threeDays.shiftedDate(from: beforeDST, by: Int.max, calendar: ny) == beforeDST, "navigation multiplication cannot overflow")
        print("PASS: forward/backward period navigation, month clamping and overflow guard")

        let targetDay = date("2026-10-20T12:00:00Z")
        let spanning = event("overnight", "2026-10-19T23:00:00Z", "2026-10-21T02:00:00Z")
        let midnightEnd = event("previous", "2026-10-19T23:00:00Z", "2026-10-20T00:00:00Z")
        let midnightStart = event("next", "2026-10-21T00:00:00Z", "2026-10-21T01:00:00Z")
        let allDay = event("all-day", "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z", allDay: true)
        let clipped = CalendarLayout.timed(events: [spanning, midnightEnd, midnightStart, allDay], on: targetDay, calendar: utcMonday)
        expect(clipped.count == 1 && clipped[0].eventID == "overnight", "midnight boundaries and all-day exclusion")
        expect(clipped[0].start == date("2026-10-20T00:00:00Z") && clipped[0].end == date("2026-10-21T00:00:00Z"), "spanning event clips exactly to selected date")
        expect(clipped[0].startMinute == 0 && clipped[0].endMinute == 1440 && clipped[0].continuesBefore && clipped[0].continuesAfter, "clipped layout fills the day and preserves continuation flags")
        print("PASS: multi-day clipping, exclusive midnight ends and separate all-day events")

        let springEvent = event("spring", "2026-03-08T01:30:00-05:00", "2026-03-08T03:30:00-04:00")
        let springPlacement = CalendarLayout.timed(events: [springEvent], on: spring.anchor, calendar: ny)[0]
        expect(springPlacement.startMinute == 90 && springPlacement.endMinute == 210, "spring wall-clock grid preserves local labels")
        expect(springPlacement.elapsedStartMinute == 90 && springPlacement.elapsedEndMinute == 150 && springPlacement.dayDurationMinutes == 1380, "spring actual elapsed time remains exact")
        let repeatedHour = event("fall", "2026-11-01T01:30:00-04:00", "2026-11-01T01:15:00-05:00")
        let fallPlacement = CalendarLayout.timed(events: [repeatedHour], on: fall.anchor, calendar: ny)[0]
        expect(fallPlacement.start == repeatedHour.start && fallPlacement.end == repeatedHour.end && fallPlacement.elapsedEndMinute - fallPlacement.elapsedStartMinute == 45, "fall repeated-hour event keeps its real interval")
        expect(fallPlacement.endMinute > fallPlacement.startMinute && fallPlacement.dayDurationMinutes == 1500, "folded local hour remains visible without a negative frame")
        let wrongZone = CalendarLayout.timed(events: [event("local-night", "2026-03-08T02:00:00Z", "2026-03-08T03:00:00Z")], on: spring.anchor, calendar: ny)
        expect(wrongZone.isEmpty, "clipping uses the provided timezone, not UTC date components")
        print("PASS: DST gap/fold geometry, exact elapsed timing and timezone clipping")

        let chain = [
            event("a", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z"),
            event("b", "2026-10-20T09:30:00Z", "2026-10-20T10:30:00Z"),
            event("c", "2026-10-20T10:00:00Z", "2026-10-20T11:00:00Z"),
            event("d", "2026-10-20T11:00:00Z", "2026-10-20T12:00:00Z")
        ]
        let chainLayout = CalendarLayout.timed(events: chain, on: targetDay, calendar: utcMonday)
        expect(chainLayout.map(\.column) == [0, 1, 0, 0] && chainLayout.map(\.columnCount) == [2, 2, 2, 1], "connected overlap chain uses peak concurrency, with a new group at exclusive end")
        expect(CalendarLayout.timed(events: chain.reversed(), on: targetDay, calendar: utcMonday) == chainLayout, "input order cannot shuffle lanes")
        let simultaneous = [
            event("short", "2026-10-20T09:00:00Z", "2026-10-20T09:30:00Z"),
            event("long", "2026-10-20T09:00:00Z", "2026-10-20T11:00:00Z"),
            event("middle", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z")
        ]
        let concurrent = CalendarLayout.timed(events: simultaneous, on: targetDay, calendar: utcMonday)
        expect(concurrent.map(\.eventID) == ["long", "middle", "short"] && concurrent.map(\.column) == [0, 1, 2] && concurrent.allSatisfy { $0.columnCount == 3 }, "same-start events sort deterministically by descending end")
        print("PASS: connected overlap groups, optimal column count and stable lane assignment")


        let shortAdjacent = [
            event("short-a", "2026-10-20T09:00:00Z", "2026-10-20T09:05:00Z"),
            event("short-b", "2026-10-20T09:05:00Z", "2026-10-20T09:10:00Z")
        ]
        let shortExact = CalendarLayout.timed(events: shortAdjacent, on: targetDay, calendar: utcMonday)
        let shortVisual = CalendarLayout.timed(events: shortAdjacent, on: targetDay, calendar: utcMonday, minimumVisualMinutes: 30)
        expect(shortExact.allSatisfy { $0.columnCount == 1 } && shortVisual.map(\.column) == [0, 1] && shortVisual.allSatisfy { $0.columnCount == 2 }, "minimum visible chip heights get separate lanes even when exact short events are adjacent")
        expect(shortVisual.map(\.start) == shortExact.map(\.start) && shortVisual.map(\.endMinute) == shortExact.map(\.endMinute), "visual lane allocation cannot rewrite original clipped timing")
        let lateEvents = [
            event("late-a", "2026-10-20T23:55:00Z", "2026-10-20T23:59:00Z"),
            event("late-b", "2026-10-20T23:59:00Z", "2026-10-21T00:00:00Z")
        ]
        let lateVisual = CalendarLayout.timed(events: lateEvents, on: targetDay, calendar: utcMonday, minimumVisualMinutes: 30)
        expect(lateVisual.allSatisfy { $0.columnCount == 2 } && Set(lateVisual.map(\.column)) == [0, 1], "chips clamped up from 23:59 share a visible interval and need separate lanes")
        expect(lateVisual.first(where: { $0.eventID == "late-b" })?.startMinute == 1439, "bottom clipping correction must preserve the real 23:59 minute")
        let fallRepeated = [
            event("first-0130", "2026-11-01T01:30:00-04:00", "2026-11-01T01:40:00-04:00"),
            event("second-0130", "2026-11-01T01:30:00-05:00", "2026-11-01T01:40:00-05:00")
        ]
        expect(CalendarLayout.timed(events: fallRepeated, on: fall.anchor, calendar: ny).allSatisfy { $0.columnCount == 1 }, "repeated-hour events do not overlap in real time")
        let fallVisual = CalendarLayout.timed(events: fallRepeated, on: fall.anchor, calendar: ny, minimumVisualMinutes: 10)
        expect(fallVisual.map(\.column) == [0, 1] && fallVisual.allSatisfy { $0.columnCount == 2 }, "two repeated 01:30 intervals remain individually visible in the shared wall-clock grid")
        expect(CalendarLayout.timed(events: fallRepeated.reversed(), on: fall.anchor, calendar: ny, minimumVisualMinutes: 10) == fallVisual, "visual lanes stay stable when source order changes")
        expect(CalendarLayout.timed(events: shortAdjacent, on: targetDay, calendar: utcMonday, minimumVisualMinutes: .nan) == shortExact, "invalid visual minimum falls back to exact intervals")
        print("PASS: short chip heights, end-of-day clamping and repeated-hour visual collision lanes preserve exact event timing")

        let point = event("point", "2026-10-20T00:00:00Z", "2026-10-20T00:00:00Z")
        let latePoint = event("late-point", "2026-10-20T23:59:30Z", "2026-10-20T23:59:30Z")
        let invalid = event("invalid", "2026-10-20T12:00:00Z", "2026-10-20T11:00:00Z")
        let nonFinite = CalendarLayoutEvent(id: "corrupt", start: Date(timeIntervalSinceReferenceDate: .nan), end: targetDay)
        let points = CalendarLayout.timed(events: [point, latePoint, invalid, nonFinite], on: targetDay, calendar: utcMonday)
        expect(points.count == 2 && points[0].startMinute == 0 && points[0].endMinute == 1, "zero duration becomes a visible start-day marker, malformed dates are ignored")
        expect(CalendarLayout.timed(events: [point, latePoint], on: date("2026-10-21T12:00:00Z"), calendar: utcMonday).isEmpty, "late zero duration never spills into the following day")
        print("PASS: zero-duration markers, midnight ownership and malformed interval rejection")

        let period = CalendarPeriod(anchor: targetDay, mode: .week, calendar: utcMonday)
        let spans = [
            event("wide", "2026-10-18T00:00:00Z", "2026-10-22T00:00:00Z", allDay: true),
            event("nested", "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z", allDay: true),
            event("adjacent", "2026-10-22T00:00:00Z", "2026-10-23T00:00:00Z", allDay: true),
            event("after", "2026-10-25T00:00:00Z", "2026-10-28T00:00:00Z", allDay: true),
            event("ends-before", "2026-10-18T00:00:00Z", "2026-10-19T00:00:00Z", allDay: true)
        ]
        let allDayLayout = CalendarLayout.allDay(events: spans, in: period)
        expect(allDayLayout.map(\.eventID) == ["wide", "nested", "adjacent", "after"], "all-day clipping defaults to period timezone and skips excluded end")
        expect(allDayLayout.map(\.startDayIndex) == [0, 1, 3, 6] && allDayLayout.map(\.endDayIndex) == [3, 2, 4, 7], "all-day end dates are exclusive indexes")
        expect(allDayLayout.map(\.row) == [0, 1, 0, 0] && allDayLayout[0].continuesBefore && allDayLayout[3].continuesAfter, "all-day rows reuse free slots and preserve clipped continuations")
        expect(CalendarLayout.allDay(events: spans.reversed(), in: period) == allDayLayout, "all-day rows remain stable under source reorder")
        let nyPeriod = CalendarPeriod(anchor: spring.anchor, mode: .threeDays, calendar: ny)
        let nyAllDay = event("ny-all-day", "2026-03-08T00:00:00-05:00", "2026-03-09T00:00:00-04:00", allDay: true)
        let nySpans = CalendarLayout.allDay(events: [nyAllDay], in: nyPeriod)
        expect(nySpans.count == 1 && nySpans[0].startDayIndex == 0 && nySpans[0].endDayIndex == 1, "all-day default calendar inherits the period across DST")
        print("PASS: all-day multi-date spans, clipping, row reuse and DST exclusive ends")
    }
}

#if SWIFT_PACKAGE
final class CalendarLayoutChecksTests: XCTestCase {
    func testContracts() throws { CalendarLayoutChecks.main() }
}
#endif
