import AppKit
import PosleCore
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var app: AppStore
    var body: some View { CalendarWorkspace(calendar: app.calendar) }
}

private struct CalendarWorkspace: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var calendar: CalendarStore
    @State private var creating: CalendarCreationDraft?
    @State private var editing: CalendarAgendaEvent?
    @State private var showingCalendars = false
    @State private var disconnecting = false
    private var canCreate: Bool { calendar.calendars.contains(where: \.writable) }

    var body: some View {
        Group {
            if calendar.connected {
                VStack(alignment: .leading, spacing: 16) {
                    AppWorkspaceHeader(title: "Календарь") {
                        Button { showingCalendars.toggle() } label: {
                            Label("Календари", systemImage: "line.3.horizontal.decrease")
                        }.buttonStyle(.bordered).accessibilityIdentifier("calendar.sources")
                            .popover(isPresented: $showingCalendars, arrowEdge: .bottom) { sources }
                        Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help(refreshHelp).accessibilityLabel("Обновить календарь")
                        Button { createDefault() } label: { Label("Событие", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(!canCreate)
                            .accessibilityIdentifier("calendar.add")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { navigation; Spacer(minLength: 10); viewPicker }
                        VStack(alignment: .leading, spacing: 12) { navigation; viewPicker }
                    }
                    if !calendar.calendars.isEmpty && calendar.calendars.allSatisfy({ !(calendar.visibleCalendarIDs?.contains($0.id) ?? true) }) {
                        HStack {
                            Label("Календари скрыты", systemImage: "eye.slash").foregroundStyle(Ink.secondaryText)
                            Button("Выбрать календари") { showingCalendars = true }.buttonStyle(.borderless)
                        }.font(AppTypography.control).accessibilityIdentifier("calendar.hiddenSources")
                    }
                    CalendarScheduleView(calendar: calendar, canCreate: canCreate,
                                         create: { create(at: $0) }, open: { editing = $0 },
                                         showDay: { calendar.selectedDate = $0; calendar.displayMode = .day })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let message = calendar.error {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled)
                    }
                }.padding(AppLayout.contentInset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        AppPageHeader(title: "Календарь")
                        CalendarConnection(calendar: calendar)
                        if let message = calendar.error { Text(message).foregroundStyle(Ink.warning).textSelection(.enabled) }
                    }.appContentLayout()
                }
            }
        }.appControlDefaults()
            .onAppear { calendar.refresh() }
            .sheet(item: $creating) { draft in
                CalendarEventEditor(calendar: calendar, initialStart: draft.start).environmentObject(app)
            }
            .sheet(item: $editing) { item in CalendarEventEditor(calendar: calendar, event: item).environmentObject(app) }
            .confirmationDialog("Отключить календарь от «После»?", isPresented: $disconnecting, titleVisibility: .visible) {
                Button("Отключить") { calendar.disconnect() }
                Button("Отмена", role: .cancel) { }
            } message: { Text("События сохранятся. Синхронизация продолжится после подключения.") }
    }
    private var navigation: some View {
        HStack(spacing: 10) {
            Button("Сегодня") { calendar.selectedDate = Date() }.buttonStyle(.bordered)
                .accessibilityIdentifier("calendar.today")
            HStack(spacing: 2) {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .help("Предыдущий период").accessibilityLabel("Предыдущий период").accessibilityIdentifier("calendar.previous")
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                    .help("Следующий период").accessibilityLabel("Следующий период").accessibilityIdentifier("calendar.next")
            }.buttonStyle(.plain)
            Text(periodTitle).font(AppTypography.heading).lineLimit(1)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("calendar.period")
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var viewPicker: some View {
        Picker("Вид календаря", selection: $calendar.displayMode) {
            ForEach(CalendarDisplayMode.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
            .accessibilityLabel("Вид календаря").accessibilityIdentifier("calendar.mode")
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            DatePicker("Перейти к дате", selection: $calendar.selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().tint(Ink.actionFill)
                .environment(\.locale, Locale(identifier: "ru_RU"))
            Divider()
            Text("Календари").font(AppTypography.controlStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(calendar.calendars) { item in
                        Button { calendar.toggleVisible(item.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: calendar.visibleCalendarIDs?.contains(item.id) ?? true ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(Color(nsColor: item.color))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1).foregroundStyle(.primary)
                                    Text(item.account).font(AppTypography.caption).lineLimit(1).foregroundStyle(Ink.secondaryText)
                                }
                                Spacer(minLength: 0)
                                if !item.writable { Image(systemName: "lock").font(AppTypography.caption).foregroundStyle(Ink.secondaryText) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help(item.label)
                            .accessibilityLabel("\(item.label), \(calendar.visibleCalendarIDs?.contains(item.id) ?? true ? "показан" : "скрыт")")
                    }
                }
            }.frame(maxHeight: 240)
            CalendarAccountHelp()
            Button("Отключить") { showingCalendars = false; disconnecting = true }
                .buttonStyle(.borderless).foregroundStyle(Ink.secondaryText)
        }.padding(20).frame(width: 280).appControlDefaults()
    }
    private var refreshHelp: String {
        calendar.lastRefreshed.map { "Обновлено в \($0.formatted(date: .omitted, time: .shortened))" } ?? "Обновить календарь"
    }
    private var periodTitle: String {
        let locale = Locale(identifier: "ru_RU")
        let style = Date.FormatStyle.dateTime.locale(locale)
        if calendar.displayMode == .month {
            let title = calendar.selectedDate.formatted(style.month(.wide).year())
            return title.prefix(1).uppercased() + title.dropFirst()
        }
        if calendar.displayMode == .day { return calendar.selectedDate.formatted(style.day().month(.wide).year()) }
        let period = calendar.displayPeriod
        let last = period.days.last ?? period.start
        if Calendar.current.isDate(period.start, equalTo: last, toGranularity: .month) {
            return "\(period.start.formatted(style.day()))–\(last.formatted(style.day().month(.wide).year()))"
        }
        return "\(period.start.formatted(style.day().month(.abbreviated))) – \(last.formatted(style.day().month(.abbreviated).year()))"
    }
    private func move(_ offset: Int) { calendar.selectedDate = calendar.displayPeriod.shifted(by: offset) }
    private func createDefault() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        var date = Calendar.current.date(bySettingHour: components.hour ?? 9,
            minute: (components.minute ?? 0) / 15 * 15, second: 0, of: calendar.selectedDate) ?? calendar.selectedDate
        if Calendar.current.isDateInToday(date), date < Date() { date = date.addingTimeInterval(900) }
        create(at: date)
    }
    private func create(at date: Date) {
        guard canCreate else { return }
        creating = CalendarCreationDraft(start: date)
    }
}

private struct CalendarCreationDraft: Identifiable {
    let id = UUID()
    let start: Date
}

private struct CalendarConnection: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var calendar: CalendarStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "calendar").font(.system(size: 32, weight: .light)).foregroundStyle(Ink.accent)
            Text(app.settings.isEnabled(.tasks) ? "Встречи и время для задач" : "Ваши встречи и события").font(AppTypography.sectionTitle)
            Text("Подключите календари macOS. Google и Яндекс появятся здесь после добавления аккаунтов.")
                .font(AppTypography.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(calendar.requesting ? "Подключение…" : "Подключить календарь") { Task { await calendar.connect() } }
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(calendar.requesting || calendar.preview)
                if calendar.permissionDenied {
                    Button("Доступ в macOS") { CalendarStore.openPermissions() }.buttonStyle(.bordered)
                }
            }
            CalendarAccountHelp()
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CalendarAccountHelp: View {
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Google и Яндекс", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Google: добавьте аккаунт в macOS и включите «Календари». Яндекс: добавьте учётную запись CalDAV в системном Календаре с паролем приложения.")
                    .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Аккаунты macOS") { CalendarStore.openAccounts() }.buttonStyle(.borderless)
                HStack(spacing: 14) {
                    Link("Google", destination: URL(string: "https://support.google.com/calendar/answer/99358?hl=ru")!)
                    Link("Яндекс", destination: URL(string: "https://yandex.ru/support/yandex-360/customers/calendar/web/ru/data-exchange/synchronization/sync-desktop")!)
                }.font(AppTypography.caption)
                Text("Синхронизацией с сервисами управляет macOS. Изменения отправятся при подключении к сети.")
                    .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 8)
        }.font(AppTypography.control)
    }
}

struct TaskCalendarSummary: View {
    @EnvironmentObject private var app: AppStore
    let task: LibraryTask
    var body: some View {
        if app.settings.isEnabled(.calendar) { TaskCalendarSummaryContent(calendar: app.calendar, task: task) }
    }
}

private struct TaskCalendarSummaryContent: View {
    @ObservedObject var calendar: CalendarStore
    let task: LibraryTask
    var body: some View {
        if let link = calendar.link(for: task) {
            Label(link.missing ? "Событие недоступно" : link.conflict ? "Конфликт календаря" : link.start.formatted(date: .abbreviated, time: .shortened),
                  systemImage: link.missing || link.conflict ? "calendar.badge.exclamationmark" : "calendar")
                .font(AppTypography.caption).foregroundStyle(link.missing || link.conflict ? Ink.warning : Ink.accent)
                .lineLimit(1).help(link.title)
        }
    }
}

struct TaskCalendarButton: View {
    @EnvironmentObject private var app: AppStore
    let task: LibraryTask
    var body: some View {
        if app.settings.isEnabled(.calendar) { TaskCalendarAction(calendar: app.calendar, task: task) }
    }
}

private struct TaskCalendarAction: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var calendar: CalendarStore
    let task: LibraryTask
    @State private var showing = false
    var body: some View {
        let link = calendar.link(for: task)
        Button { showing = true } label: {
            Image(systemName: link?.conflict == true || link?.missing == true ? "calendar.badge.exclamationmark" : link == nil ? "calendar.badge.plus" : "calendar.badge.clock")
                .foregroundStyle(link == nil ? Color.secondary : link?.conflict == true || link?.missing == true ? Ink.warning : Ink.accent)
                .frame(width: 24, height: 24)
        }.buttonStyle(.plain)
            .help(link.map { $0.missing ? "Связанное событие недоступно" : "\($0.start.formatted(date: .abbreviated, time: .shortened)) · \($0.title)" } ?? "Запланировать задачу")
            .accessibilityLabel(link == nil ? "Запланировать задачу в календаре" : "Изменить время задачи в календаре")
            .sheet(isPresented: $showing) { CalendarEventEditor(calendar: calendar, task: task).environmentObject(app) }
    }
}

struct CalendarEventEditor: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var calendar: CalendarStore
    var task: LibraryTask? = nil
    var event: CalendarAgendaEvent? = nil
    var initialStart: Date? = nil
    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(1800)
    @State private var calendarID = ""
    @State private var initialized = false
    @State private var baselineLink: CalendarTaskLink?
    @State private var unlinking = false
    private var currentTask: LibraryTask? { task.flatMap { calendar.task(for: $0.id) ?? $0 } ?? event?.taskID.flatMap { calendar.task(for: $0) } }
    private var link: CalendarTaskLink? { currentTask.flatMap { calendar.link(for: $0) } }
    private var canSave: Bool {
        calendar.connected && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && end > start &&
        calendar.calendars.contains(where: { $0.id == calendarID && $0.writable }) &&
        link?.missing != true && link?.conflict != true && (event == nil || event?.writable == true)
    }
    var body: some View {
        Group {
            if !app.settings.isEnabled(.calendar) {
                disabledFeature(.calendar)
            } else if !app.settings.isEnabled(.tasks), task != nil || event?.taskID != nil {
                disabledFeature(.tasks)
            } else { editorContent }
        }
    }
    private func disabledFeature(_ feature: AppFeature) -> some View {
        OptionalFeatureGate(feature: feature).frame(width: 520, height: 320)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Закрыть").padding(18)
            }
    }
    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(currentTask != nil ? "Задача в календаре" : event == nil ? "Новое событие" : "Событие").font(AppTypography.modalTitle)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Закрыть")
            }
            if !calendar.connected {
                CalendarConnection(calendar: calendar)
            } else {
                TextField("Название", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("calendar.editor.title").disabled(event?.writable == false)
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker("Начало", selection: $start, displayedComponents: event?.allDay == true ? .date : [.date, .hourAndMinute]).accessibilityIdentifier("calendar.editor.start")
                    DatePicker("Окончание", selection: $end, displayedComponents: event?.allDay == true ? .date : [.date, .hourAndMinute]).accessibilityIdentifier("calendar.editor.end")
                    if let event, !event.writable {
                        LabeledContent("Календарь", value: event.calendarTitle)
                    } else {
                        Picker("Календарь", selection: $calendarID) {
                            if calendarID.isEmpty { Text("Выберите календарь").tag("") }
                            ForEach(calendar.calendars.filter(\.writable)) { Text($0.label).tag($0.id) }
                        }
                    }
                }.disabled(event?.writable == false)
                if let link {
                    if link.missing {
                        Text("Событие удалено или календарь недоступен. Связь сохранена: обновите календарь или отвяжите событие.")
                            .font(AppTypography.control).foregroundStyle(Ink.warning)
                    } else if link.sourceChanged, let currentTask {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("После обновления конспекта на этом месте другая задача. Событие сохранено без изменений: отвяжите его или свяжите с новой задачей.")
                                .font(AppTypography.control).foregroundStyle(Ink.warning)
                            Button("Связать с этой задачей") { calendar.resolve(task: currentTask, useTask: true); load() }.buttonStyle(.bordered)
                        }
                    } else if link.conflict, let currentTask {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Задача и событие изменились одновременно. Выберите название и статус; время календаря сохранится.")
                                .font(AppTypography.control).foregroundStyle(Ink.warning)
                            HStack {
                                Button("Из задачи") { calendar.resolve(task: currentTask, useTask: true); load() }
                                Button("Из календаря") { calendar.resolve(task: currentTask, useTask: false); load() }
                            }.buttonStyle(.bordered)
                        }
                    }
                    DisclosureGroup("Как связаны задача и событие") {
                        Text("Время и название события видны в «После» и вашем календаре. Изменение текста задачи обновляет название блока. Отметки ○ и ✓ в начале названия синхронизируют завершение задачи. Переименование блока в календаре сохраняется отдельно от текста заметки.")
                            .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }.font(AppTypography.control)
                } else if currentTask != nil {
                    Text("Создаст блок времени в выбранном календаре. Статус задачи будет синхронизироваться по отметкам ○ и ✓.")
                        .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let event, !event.writable {
                    Text("Этот календарь доступен только для чтения или событие повторяется. Откройте его в системном Календаре.")
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if link != nil {
                        Button("Отвязать") { unlinking = true }.buttonStyle(.borderless)
                    }
                    if event != nil || link != nil {
                        Button("Открыть Календарь") { CalendarStore.openSystemCalendar() }.buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("Отмена") { dismiss() }.buttonStyle(.bordered)
                    Button(event == nil && link == nil ? "Добавить" : "Сохранить", action: save)
                        .buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.defaultAction).disabled(!canSave)
                }
            }
            if let error = calendar.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
        }.padding(24).frame(width: 520).fixedSize(horizontal: false, vertical: true).appControlDefaults()
            .onAppear { calendar.refresh(); if !initialized { initialized = true; load() } }
            .onChange(of: calendar.connected) { _, connected in if connected { load() } }
            .onChange(of: start) { old, new in if end <= new { end = new.addingTimeInterval(max(900, end.timeIntervalSince(old))) } }
            .confirmationDialog("Отвязать событие от задачи?", isPresented: $unlinking, titleVisibility: .visible) {
                Button("Отвязать") { if let currentTask { calendar.unlink(taskID: currentTask.id); dismiss() } }
                Button("Отмена", role: .cancel) { }
            } message: { Text("Событие останется в календаре. Изменения задачи больше не будут в него передаваться.") }
    }
    private func load() {
        baselineLink = link
        if let link {
            title = link.title; start = link.start; end = link.end; calendarID = link.calendarID
        } else if let event {
            title = event.taskID == nil ? event.title : CalendarTaskLink.plainTitle(event.title)
            start = event.start; end = event.end; calendarID = event.calendarID
        } else {
            title = currentTask?.text ?? ""
            if let initialStart {
                start = initialStart; end = initialStart.addingTimeInterval(1800)
                calendarID = calendar.selectedCalendarID
                return
            }
            let now = Date()
            let day = Calendar.current.startOfDay(for: calendar.selectedDate)
            let components = Calendar.current.dateComponents([.hour, .minute], from: now)
            start = Calendar.current.date(bySettingHour: components.hour ?? 10, minute: ((components.minute ?? 0) / 15) * 15, second: 0, of: day) ?? now
            if Calendar.current.isDateInToday(day) && start < now { start = start.addingTimeInterval(900) }
            end = start.addingTimeInterval(1800); calendarID = calendar.selectedCalendarID
        }
    }
    private func save() {
        let result: Bool
        if let event, currentTask == nil { result = calendar.edit(event: event, title: title, start: start, end: end, calendarID: calendarID) }
        else { result = calendar.schedule(task: currentTask, title: title, start: start, end: end, calendarID: calendarID, expected: baselineLink) }
        if result { dismiss() }
    }
}
