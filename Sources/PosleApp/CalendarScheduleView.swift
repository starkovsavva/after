import AppKit
import PosleCore
import SwiftUI

/// A calendar is a workspace: its grid uses the available width, independently
/// of the readable text column used by notes and meeting summaries.
struct CalendarScheduleView: View {
    @ObservedObject var calendar: CalendarStore
    let canCreate: Bool
    let create: (Date) -> Void
    let open: (CalendarAgendaEvent) -> Void
    let showDay: (Date) -> Void
    private let clock = Calendar.current
    private let hourHeight: CGFloat = 56
    private let gutter: CGFloat = 54
    private var period: CalendarPeriod { calendar.displayPeriod }
    private var visibleEvents: [CalendarAgendaEvent] {
        var seen = Set<String>()
        return period.days.flatMap { calendar.events(on: $0) }.filter { seen.insert($0.id).inserted }
    }
    private var models: [CalendarLayoutEvent] {
        visibleEvents.map { CalendarLayoutEvent(id: $0.id, start: $0.start, end: $0.end, allDay: $0.allDay) }
    }

    var body: some View {
        GeometryReader { geometry in
            if calendar.displayMode == .month {
                monthGrid(height: geometry.size.height)
            } else {
                let width = max(geometry.size.width, gutter + CGFloat(period.days.count) * 112)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        dayHeadings(width: width)
                        allDayEvents(width: width)
                        timeline(width: width)
                    }.frame(width: width, height: geometry.size.height)
                }.scrollBounceBehavior(.basedOnSize)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("calendar.grid")
    }

    private func dayHeadings(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(timeZoneLabel).font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                .frame(width: gutter).help(clock.timeZone.identifier)
            ForEach(period.days, id: \.self) { date in
                Button { showDay(date) } label: {
                    VStack(spacing: 4) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "ru_RU"))))
                            .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                        Text(date.formatted(.dateTime.day())).font(AppTypography.heading)
                            .frame(width: 30, height: 30)
                            .foregroundStyle(clock.isDateInToday(date) ? Color.white : Color.primary)
                            .background(clock.isDateInToday(date) ? Ink.actionFill : Color.clear, in: Circle())
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Открыть день")
                    .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    .accessibilityIdentifier("calendar.day.\(clock.component(.weekday, from: date))")
            }
        }.frame(width: width).overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func allDayEvents(width: CGFloat) -> some View {
        let placements = CalendarLayout.allDay(events: models, in: period)
        let rows = (placements.map(\.row).max() ?? -1) + 1
        if rows > 0 {
            let columnWidth = (width - gutter) / CGFloat(period.days.count)
            HStack(alignment: .top, spacing: 0) {
                Text("Весь день").font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                    .frame(width: gutter).padding(.top, 10)
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(height: CGFloat(rows) * 28 + 8)
                        ForEach(placements) { placement in
                            if let event = visibleEvents.first(where: { $0.id == placement.eventID }) {
                                Button { open(event) } label: {
                                    CalendarEventChip(event: event, compact: true, continuesBefore: placement.continuesBefore, continuesAfter: placement.continuesAfter)
                                        .frame(width: max(20, CGFloat(placement.endDayIndex - placement.startDayIndex) * columnWidth - 6), height: 24)
                                }.buttonStyle(.plain)
                                    .offset(x: CGFloat(placement.startDayIndex) * columnWidth + 3, y: CGFloat(placement.row) * 28 + 4)
                                    .help(event.title).accessibilityLabel(eventLabel(event))
                            }
                        }
                    }
                }.frame(height: min(120, CGFloat(rows) * 28 + 8))
            }.overlay(alignment: .bottom) { Divider() }.accessibilityIdentifier("calendar.allDay")
        }
    }

    private func timeline(width: CGFloat) -> some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<24) { hour in
                            Text(String(format: "%02d:00", hour)).font(AppTypography.caption)
                                .foregroundStyle(Ink.secondaryText).monospacedDigit()
                                .frame(width: gutter, height: hourHeight, alignment: .top)
                                .id("hour-\(hour)")
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(period.days, id: \.self) { day in
                            timedDay(day, width: (width - gutter) / CGFloat(period.days.count))
                        }
                    }
                }.frame(height: hourHeight * 24)
            }.scrollBounceBehavior(.basedOnSize)
                .onAppear { scrollToInitialTime(scroll) }
                .onChange(of: period.start) { _, _ in scrollToInitialTime(scroll) }
        }
    }

    private func timedDay(_ day: Date, width: CGFloat) -> some View {
        let placements = CalendarLayout.timed(events: models, on: day, minimumVisualMinutes: 22 / Double(hourHeight) * 60)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(clock.isDateInToday(day) ? Ink.accent.opacity(0.025) : Color.clear)
            VStack(spacing: 0) {
                ForEach(0..<48) { halfHour in
                    let availableDate = slotDate(day: day, halfHour: halfHour)
                    Button { if let availableDate { create(availableDate) } } label: {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .overlay(alignment: .top) { Rectangle().fill(Ink.line.opacity(halfHour.isMultiple(of: 2) ? 1 : 0.45)).frame(height: 0.5) }
                    }.buttonStyle(.plain).frame(height: hourHeight / 2).disabled(!canCreate || availableDate == nil)
                        .background(availableDate == nil ? Ink.soft : Color.clear)
                        .help(availableDate == nil ? "Время пропущено при переводе часов" : "Добавить событие")
                        .accessibilityLabel("Добавить событие, \(day.formatted(date: .abbreviated, time: .omitted)), \(halfHour / 2):\(halfHour.isMultiple(of: 2) ? "00" : "30")")
                        .accessibilityIdentifier("calendar.slot.\(clock.component(.weekday, from: day)).\(halfHour)")
                }
            }
            Rectangle().fill(Ink.line).frame(width: 0.5)
            ForEach(placements) { placement in
                if let event = visibleEvents.first(where: { $0.id == placement.eventID }) {
                    timedEvent(event, placement: placement, width: width)
                }
            }
            if clock.isDateInToday(day) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let components = clock.dateComponents([.hour, .minute], from: context.date)
                    let minute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
                    Rectangle().fill(Ink.recordFill).frame(height: 1)
                        .overlay(alignment: .leading) { Circle().fill(Ink.recordFill).frame(width: 5, height: 5) }
                        .offset(y: minute / 60 * hourHeight).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }.frame(width: width, height: hourHeight * 24).clipped()
    }

    private func timedEvent(_ event: CalendarAgendaEvent, placement: CalendarTimedPlacement, width: CGFloat) -> some View {
        let laneWidth: CGFloat = width / CGFloat(placement.columnCount)
        let durationHeight: CGFloat = CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight
        let height: CGFloat = max(22, durationHeight - 2)
        let chipWidth: CGFloat = max(20, laneWidth - 6)
        let x: CGFloat = CGFloat(placement.column) * laneWidth + 3
        let startY: CGFloat = CGFloat(placement.startMinute) / 60 * hourHeight + 1
        let lastY: CGFloat = hourHeight * 24 - height
        let y: CGFloat = min(startY, lastY)
        let label: String = eventLabel(event)
        let chip = CalendarEventChip(
            event: event, compact: height < 42,
            displayStart: placement.start, displayEnd: placement.end,
            continuesBefore: placement.continuesBefore, continuesAfter: placement.continuesAfter
        )
        return Button { open(event) } label: {
            chip.frame(width: chipWidth, height: height, alignment: .topLeading)
        }.buttonStyle(.plain)
            .offset(x: x, y: y)
            .help(label).accessibilityLabel(label)
            .accessibilityIdentifier("calendar.event.\(event.id)")
    }

    private func monthGrid(height: CGFloat) -> some View {
        let rows = max(1, period.days.count / 7)
        let cellHeight = max(110, (height - 28) / CGFloat(rows))
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(period.days.prefix(7)), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "ru_RU"))))
                        .font(AppTypography.captionStrong).foregroundStyle(Ink.secondaryText)
                        .frame(maxWidth: .infinity).frame(height: 28)
                }
            }
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(period.days, id: \.self) { day in
                        monthDay(day, height: cellHeight)
                    }
                }
            }.scrollBounceBehavior(.basedOnSize)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("calendar.month")
    }

    private func monthDay(_ day: Date, height: CGFloat) -> some View {
        let events = calendar.events(on: day).sorted {
            $0.allDay != $1.allDay ? $0.allDay : $0.start < $1.start
        }
        let maxEvents = max(1, min(3, Int((height - 60) / 24)))
        let currentMonth = clock.isDate(day, equalTo: period.monthStart, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 4) {
            Button { showDay(day) } label: {
                Text(day.formatted(.dateTime.day())).font(AppTypography.controlStrong)
                    .foregroundStyle(clock.isDateInToday(day) ? Color.white : currentMonth ? Color.primary : Ink.secondaryText)
                    .frame(width: 27, height: 27)
                    .background(clock.isDateInToday(day) ? Ink.actionFill : Color.clear, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Открыть \(day.formatted(date: .complete, time: .omitted))")
                .accessibilityIdentifier("calendar.month.day.\(Int(day.timeIntervalSince1970))")
            ForEach(events.prefix(maxEvents)) { event in
                Button { open(event) } label: {
                    let endOfDay = clock.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                    CalendarEventChip(event: event, compact: true, displayStart: max(event.start, day), displayEnd: min(event.end, endOfDay),
                                      continuesBefore: event.start < day, continuesAfter: event.end > endOfDay).frame(height: 22)
                }
                    .buttonStyle(.plain).help(eventLabel(event)).accessibilityLabel(eventLabel(event))
                    .accessibilityIdentifier("calendar.month.event.\(Int(day.timeIntervalSince1970)).\(event.id)")
            }
            if events.count > maxEvents {
                Button("Ещё \(events.count - maxEvents)") { showDay(day) }
                    .font(AppTypography.caption).foregroundStyle(Ink.accent).buttonStyle(.plain)
            }
            Spacer(minLength: 0).frame(maxWidth: .infinity).contentShape(Rectangle())
                .onTapGesture { showDay(day) }
        }.padding(6).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height)
            .background(currentMonth ? Color.clear : Ink.soft)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 0.5) }
            .overlay(alignment: .leading) { Rectangle().fill(Ink.line).frame(width: 0.5) }

    }

    private func slotDate(day: Date, halfHour: Int) -> Date? {
        let hour = halfHour / 2, minute = halfHour.isMultiple(of: 2) ? 0 : 30
        guard let date = clock.date(bySettingHour: hour, minute: minute, second: 0, of: day),
              clock.isDate(date, inSameDayAs: day), clock.component(.hour, from: date) == hour,
              clock.component(.minute, from: date) == minute else { return nil }
        return date
    }
    private func scrollToInitialTime(_ scroll: ScrollViewProxy) {
        let currentHour = clock.component(.hour, from: Date())
        let hour = !calendar.preview && period.days.contains(where: clock.isDateInToday) && (8...18).contains(currentHour) ? max(8, currentHour - 1) : 8
        scroll.scrollTo("hour-\(hour)", anchor: .top)
    }
    private var timeZoneLabel: String {
        let offset = clock.timeZone.secondsFromGMT(for: calendar.selectedDate) / 60
        let minutes = abs(offset) % 60
        return "UTC\(offset < 0 ? "−" : "+")\(abs(offset) / 60)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
    private func eventLabel(_ event: CalendarAgendaEvent) -> String {
        let time: String
        if event.allDay { time = "Весь день" }
        else if !clock.isDate(event.start, inSameDayAs: event.end) {
            time = "\(event.start.formatted(date: .abbreviated, time: .shortened)) — \(event.end.formatted(date: .abbreviated, time: .shortened))"
        } else { time = "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))" }
        return "\(event.title), \(time), \(event.calendarTitle)"
    }
}

private struct CalendarEventChip: View {
    let event: CalendarAgendaEvent
    var compact = false
    var displayStart: Date? = nil
    var displayEnd: Date? = nil
    var continuesBefore = false
    var continuesAfter = false
    private var startTime: String { (displayStart ?? event.start).formatted(date: .omitted, time: .shortened) }
    private var endTime: String { (displayEnd ?? event.end).formatted(date: .omitted, time: .shortened) }
    private func timeLabel(short: Bool) -> String {
        if continuesBefore && continuesAfter { return "↔" }
        if continuesBefore { return "←\(endTime)" }
        if continuesAfter { return "\(startTime)→" }
        return short ? startTime : "\(startTime)–\(endTime)"
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 110
            let titleLines = max(1, min(3, Int((geometry.size.height - 26) / 14)))
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: event.color)).frame(width: 3)
                if compact {
                    HStack(spacing: 4) {
                        if !event.allDay {
                            Text(timeLabel(short: geometry.size.width <= 260))
                                .font(AppTypography.caption).monospacedDigit().fixedSize().layoutPriority(2)
                        }
                        if event.taskID != nil { Image(systemName: "checklist").font(AppTypography.caption).accessibilityLabel("Задача") }
                        if event.allDay || geometry.size.width > 85 {
                            Text(event.title).font(AppTypography.captionStrong).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(AppTypography.captionStrong).lineLimit(titleLines)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        if !event.allDay {
                            HStack(spacing: 3) {
                                if event.taskID != nil { Image(systemName: "checklist") }
                                Text(timeLabel(short: narrow)).monospacedDigit().fixedSize()
                            }.font(AppTypography.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if event.allDay && (continuesBefore || continuesAfter) {
                    Image(systemName: continuesBefore && continuesAfter ? "arrow.left.and.right" : continuesBefore ? "arrow.left" : "arrow.right")
                        .font(.system(size: 9)).accessibilityHidden(true)
                }
            }.foregroundStyle(.primary).padding(.horizontal, 5).padding(.vertical, compact ? 3 : 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: event.color).opacity(0.12), in: RoundedRectangle(cornerRadius: 4)).clipped()
        }
    }
}
