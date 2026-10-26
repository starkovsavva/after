import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var theme = ThemeController.shared
    @State private var dropping = false
    @State private var confirmDelete = false
    @State private var filteringMeetings = false

    var body: some View {
        VStack(spacing: 0) {
            topbar
            HStack(spacing: 0) {
                sidebar.frame(width: 198).appLayoutAnchor("sidebar")
                Divider()
                if store.librarySection == "meetings" {
                    meetingList.frame(width: 220)
                    Divider()
                }
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if store.librarySection == "inbox" { NotesLibraryView(notes: store.notes) }
                            else if store.librarySection == "tasks" { NotesTasksView(notes: store.notes) }
                            else if store.librarySection == "calendar" { CalendarView() }
                            else if store.librarySection == "contexts" { NotesContextsView(notes: store.notes) }
                            else if store.librarySection == "cards" { CardsLibraryView() }
                            else if let meeting = store.selected { MeetingView(meeting: meeting) }
                            else { welcome }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).appLayoutAnchor("workspace")
                        VStack(spacing: 8) {
                            if let error = store.error { message(error, error: true) }
                            if let notice = store.notice { message(notice, error: false) }
                        }.frame(maxWidth: 520).padding(16)
                    }
                    if store.librarySection == "meetings", store.transcript != nil { player.appLayoutAnchor("status") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Ink.paper).tint(Ink.accent).appControlDefaults()
        .preferredColorScheme(theme.colorScheme)
        .onAppear { theme.configure(root: store.root) }
        .onChange(of: store.selection) { _, _ in store.selectionDidChange() }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard store.librarySection == "meetings", store.tab != "notes", let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.importFile(url) } }
            }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).fill(Ink.accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.accent, style: StrokeStyle(lineWidth: 2, dash: [8])))
                    .overlay(Label("Отпустите запись встречи", systemImage: "arrow.down.doc.fill").font(AppTypography.heading))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VoiceCommandOverlay(controller: store.voice).environmentObject(store)
                .padding(.trailing, 20)
                .padding(.bottom, store.librarySection == "meetings" && store.transcript != nil ? 64 : 20)
        }
        .sheet(isPresented: $store.showingCaptureDrafts) {
            VStack(spacing: 0) {
                HStack {
                    Text("Черновик заметки").font(AppTypography.modalTitle)
                    Spacer()
                    Button("Закрыть") { store.showingCaptureDrafts = false }.keyboardShortcut(.cancelAction)
                }.padding(22)
                Divider()
                NotesInboxView(notes: store.notes, draftKey: store.recoveryCaptureDraftKey).environmentObject(store)
            }.frame(width: 700, height: 600).appControlDefaults()
        }
        .sheet(isPresented: $store.showingSettings) { SettingsView(section: store.settingsSection).environmentObject(store) }
        .sheet(isPresented: $store.showingRecord) { RecordView().environmentObject(store) }
        .sheet(isPresented: $store.showingSearch) { SearchView().environmentObject(store) }
        .alert("Переместить встречу в Корзину?", isPresented: $confirmDelete) {
            Button("Отмена", role: .cancel) {}
            Button("В Корзину", role: .destructive) { store.trashSelected() }
        } message: { Text("Запись, конспект и карточки этой встречи можно будет восстановить из Корзины Finder.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.openGlobalSearch() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Поиск").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("⌘K").font(AppTypography.caption).foregroundStyle(.tertiary)
                }.font(AppTypography.control).padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 18)
                .accessibilityLabel("Поиск по всей библиотеке. Command K")
            VStack(spacing: 2) {
                libraryButton("meetings", "Встречи", "waveform")
                libraryButton("inbox", "Заметки", "note.text")
                libraryButton("tasks", "Задачи", "checklist")
                libraryButton("cards", "Карточки", "rectangle.on.rectangle")
                libraryButton("calendar", "Календарь", "calendar")
            }.padding(.horizontal, 8)
            Text("Библиотека").font(AppTypography.captionStrong).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 7)
            libraryButton("contexts", "Проекты и люди", "folder").padding(.horizontal, 8)
            Spacer(minLength: 12)
            if ProcessInfo.processInfo.arguments.contains("--preview") && !ProcessInfo.processInfo.arguments.contains("--snapshot") {
                Text("Демонстрационные данные").font(AppTypography.caption).foregroundStyle(Ink.warning).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Button { store.openSettings() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3").frame(width: 18)
                    Text("Настройки")
                    Spacer()
                }.font(AppTypography.control).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 34)
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 12)
        }.background(Ink.sidebar)
    }

    private func libraryButton(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { store.librarySection = id; store.pause() } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
                if id == "meetings" {
                    Text("\(store.meetings.filter { $0.libraryKind != "cards" }.count)").font(AppTypography.caption).foregroundStyle(.secondary)
                }
            }.font(AppTypography.control).padding(.horizontal, 10).frame(height: 34)
                .background(store.librarySection == id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(store.librarySection == id ? .isSelected : [])
    }

    private var meetingGroups: [(String, [Meeting])] {
        let calendar = Calendar.current
        let current = Date()
        let weekStart = calendar.date(byAdding: .day, value: -7, to: current) ?? current
        let rows = store.filteredMeetings
        let today = rows.filter { calendar.isDateInToday(Date(timeIntervalSince1970: $0.createdAt)) }
        let recent = rows.filter { !calendar.isDateInToday(Date(timeIntervalSince1970: $0.createdAt)) && Date(timeIntervalSince1970: $0.createdAt) >= weekStart }
        let earlier = rows.filter { Date(timeIntervalSince1970: $0.createdAt) < weekStart }
        return [("Сегодня", today), ("За неделю", recent), ("Ранее", earlier)].filter { !$0.1.isEmpty }
    }
    private var meetingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Встречи").font(AppTypography.controlStrong)
                Spacer()
                Button {
                    filteringMeetings.toggle()
                    if !filteringMeetings { store.libraryFilter = "" }
                } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(filteringMeetings ? Ink.accent : Color.secondary)
                    .accessibilityLabel("Фильтр встреч").help("Фильтр по названию")
            }.padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 12)
            if filteringMeetings || !store.libraryFilter.isEmpty {
                HStack(spacing: 7) {
                    TextField("Название встречи", text: $store.libraryFilter).textFieldStyle(.plain)
                    if !store.libraryFilter.isEmpty {
                        Button { store.libraryFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Очистить фильтр")
                    }
                }.font(AppTypography.control).padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(meetingGroups, id: \.0) { title, meetings in
                        Text(title).font(AppTypography.captionStrong).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                        ForEach(meetings) { meeting in
                            Button {
                                store.selection = meeting.id
                                if meeting.libraryKind == "cards" { store.tab = "cards" }
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(meeting.title).font(store.selection == meeting.id ? AppTypography.controlStrong : AppTypography.control)
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    HStack {
                                        Text(Date(timeIntervalSince1970: meeting.createdAt).formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))))
                                        Spacer()
                                        Text(meeting.status == "recording" ? "Запись" : meeting.duration > 0 ? Exporter.timestamp(meeting.duration) : "Добавлена")
                                    }.font(AppTypography.caption).foregroundStyle(.secondary)
                                }.padding(11).background(store.selection == meeting.id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 3)
                                .accessibilityValue(store.selection == meeting.id ? "Выбрана" : "")
                                .accessibilityAddTraits(store.selection == meeting.id ? .isSelected : [])
                        }
                    }
                    if store.filteredMeetings.isEmpty && !store.libraryFilter.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Встречи не найдены").font(AppTypography.controlStrong)
                            Button("Сбросить поиск") { store.libraryFilter = "" }.buttonStyle(.borderless)
                        }.padding(16)
                    }
                }
            }
        }.background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }

    private var topbar: some View {
        HStack(spacing: 10) {
            Text("После").font(AppTypography.controlStrong).padding(.leading, 4)
            HStack(spacing: 8) {
                if store.isRecording {
                    if store.stoppingRecording { ProgressView().controlSize(.small) }
                    else { Image(systemName: "record.circle.fill").foregroundStyle(Ink.recordFill) }
                    Text(store.stoppingRecording ? "Сохраняю запись…" : "Запись").lineLimit(1)
                    if !store.stoppingRecording, let date = store.recordingDate { Text(date, style: .timer).monospacedDigit() }
                    Button { store.bookmarkAction?() } label: { Image(systemName: "bookmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).disabled(store.stoppingRecording).accessibilityLabel("Отметить важный момент").help("Отметить момент · ⌃⌥B")
                } else if store.busy {
                    ProgressView().controlSize(.small)
                    Text(store.progressText).lineLimit(1).truncationMode(.middle).help(store.progressText)
                    if store.canCancelJob {
                        Button { store.cancelJob() } label: { Image(systemName: "xmark.circle").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).accessibilityLabel("Отменить обработку")
                    }
                }
            }.font(AppTypography.caption).foregroundStyle(.secondary).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
            Button { store.quickCaptureAction?() } label: { Image(systemName: "square.and.pencil").frame(width: 28, height: 28) }
                .buttonStyle(.plain).appLayoutAnchor("toolbar.note").help("Быстрая заметка · ⇧⌘N").accessibilityLabel("Быстрая заметка")
            Button { store.chooseFile() } label: { Image(systemName: "arrow.down.doc").frame(width: 28, height: 28) }
                .disabled(store.busy || store.isRecording).buttonStyle(.plain).appLayoutAnchor("toolbar.file").help("Импорт аудио или видео · ⌘O").accessibilityLabel("Импорт аудио или видео")
            Button { store.presentVoice() } label: { Image(systemName: "mic").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("Голосовое поручение · ⇧⌘M").accessibilityLabel("Голосовое поручение")
                .accessibilityIdentifier("voice.open")
            Divider().frame(height: 18).padding(.horizontal, 3)
            Button {
                if store.isRecording { Task { await store.stopRecording() } }
                else { store.showingRecord = true }
            } label: {
                Label(store.stoppingRecording ? "Сохраняю…" : store.isRecording ? "Остановить" : "Записать",
                      systemImage: store.isRecording ? "stop.circle" : "record.circle").frame(width: 108)
            }.disabled(store.stoppingRecording || store.busy && !store.isRecording)
                .buttonStyle(.bordered).foregroundStyle(store.isRecording ? Ink.recordFill : Color.primary)
                .appLayoutAnchor("toolbar.record").help(store.isRecording ? "Остановить и сохранить запись" : "Записать встречу · ⌘N")
        }.font(AppTypography.control).controlSize(.regular).padding(.horizontal, 16)
            .frame(height: AppLayout.toolbarHeight).appLayoutAnchor("toolbar")
            .overlay(alignment: .bottom) {
                Rectangle().fill(Ink.line).frame(height: 1)
                if store.busy && store.progress >= 0 { ProgressView(value: store.progress).progressViewStyle(.linear).frame(height: 2) }
            }
    }
    private func message(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(error ? Ink.warning : Ink.green)
            Text(text).font(AppTypography.control).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !error { OpenUpdateDraft(updates: store.updates).buttonStyle(.borderless) }
            Button { if error { store.error = nil } else { store.notice = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Закрыть сообщение")
        }.padding(14).background(Ink.paper, in: RoundedRectangle(cornerRadius: AppLayout.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: AppLayout.cardRadius).strokeBorder(error ? Ink.warning.opacity(0.5) : Ink.line))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.accent).accessibilityHidden(true)
            Text("Пока нет встреч").font(AppTypography.pageTitle)
            Text("Перетащите сюда аудио или видео").font(AppTypography.body).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Импортировать запись") { store.chooseFile() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(store.busy)
                Button("Записать встречу") { store.showingRecord = true }.buttonStyle(.bordered).disabled(store.busy)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(AppLayout.contentInset)
    }
    private var player: some View {
        HStack(spacing: 14) {
            Button { store.togglePlayback() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
            }.buttonStyle(.bordered).accessibilityLabel(store.isPlaying ? "Приостановить" : "Воспроизвести")
            Text(Exporter.timestamp(store.playbackTime)).monospacedDigit().frame(width: 52)
            Slider(value: Binding(get: { store.playbackTime }, set: { store.seek($0) }), in: 0...max(1, store.playbackDuration))
                .accessibilityLabel("Позиция в записи")
            Text(Exporter.timestamp(store.playbackDuration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52)
            Menu {
                Button("Конспект и транскрипция (.md)") { store.export(false) }
                Button("Аудиозапись (.mp3)") { store.exportAudio() }
                if store.selected?.hasVideo == true {
                    Button("Открыть видео (.mp4)") {
                        if let directory = store.selectedDirectory { NSWorkspace.shared.open(directory.appendingPathComponent("video.mp4")) }
                    }
                }
                Button("Карточки для Anki (.tsv)") { store.export(true) }.disabled(store.summary?.cards.isEmpty ?? true)
                Divider()
                Button("Показать файлы встречи") { if let directory = store.selectedDirectory { NSWorkspace.shared.open(directory) } }
                Button("Переместить в Корзину", role: .destructive) { confirmDelete = true }.disabled(store.busy || store.isRecording)
            } label: { Image(systemName: "square.and.arrow.up").frame(width: 25) }.menuStyle(.borderlessButton).frame(width: 35)
                .accessibilityLabel("Экспорт встречи")
        }.font(AppTypography.control).padding(.horizontal, AppLayout.contentInset)
            .frame(height: AppLayout.statusHeight).background(Ink.paper)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

struct MeetingView: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    @State private var rename = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(meeting.title).font(AppTypography.pageTitle)
                        .lineLimit(1).help(meeting.title).textSelection(.enabled)
                    Spacer(minLength: 10)
                    Menu {
                        Button("Переименовать") { newTitle = meeting.title; rename = true }.disabled(store.busy || store.isRecording)
                        Button("Распознать заново") { Task { await store.processMeeting(meeting.id) } }.disabled(store.busy || !store.runtimeReady || store.isRecording || meeting.libraryKind == "cards")
                    } label: { Image(systemName: "ellipsis").frame(width: 25, height: 25) }.menuStyle(.borderlessButton).frame(width: 32)
                        .accessibilityLabel("Действия со встречей")
                }
                HStack(spacing: 16) {
                    Label(Date(timeIntervalSince1970: meeting.createdAt).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU"))), systemImage: "calendar")
                    if meeting.duration > 0 { Label(Exporter.timestamp(meeting.duration), systemImage: "clock") }

                }.font(AppTypography.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, AppLayout.contentInset).padding(.top, 22).padding(.bottom, 18)
            Picker("Раздел встречи", selection: $store.tab) {
                Text("Заметки").tag("notes")
                if meeting.libraryKind != "cards" {
                    Text("Конспект").tag("summary")
                    Text("Транскрипт").tag("transcript")
                }
                Text("Карточки").tag("cards")
            }.pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, AppLayout.contentInset).padding(.bottom, 16)
                .appLayoutAnchor("meeting.tabs")
            if store.tab == "notes" { NotesWorkspaceView(notes: store.notes, meeting: meeting) }
            else if store.transcript == nil && store.tab != "cards" && !(store.tab == "summary" && store.overviewDrafts[meeting.id] != nil) { unprocessed }
            else if store.tab == "transcript" { TranscriptView() }
            else if store.tab == "cards" { CardsView().id(meeting.id) }
            else { SummaryView() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .alert("Название встречи", isPresented: $rename) {
                TextField("Название", text: $newTitle)
                Button("Сохранить") { store.updateMeeting(meeting.id) { $0.title = newTitle.isEmpty ? $0.title : newTitle } }
                Button("Отмена", role: .cancel) {}
            }
    }
    private var unprocessed: some View {
        VStack(spacing: 16) {
            Image(systemName: store.stoppingRecording ? "square.and.arrow.down" : store.isRecording ? "waveform" : "waveform.badge.magnifyingglass").font(.system(size: 42)).foregroundStyle(Ink.accent)
            Text(store.stoppingRecording ? "Сохраняю запись" : store.isRecording ? "Идёт запись" : "Запись сохранена").font(.title3.weight(.semibold))
            if !store.isRecording {
                Button(store.runtimeReady ? (store.settings.speechMode == "cloud" ? "Распознать в облаке…" : "Распознать встречу") : "Установить модели") {
                    if store.runtimeReady { Task { await store.processMeeting(meeting.id) } }
                    else { store.openSettings("speech") }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).controlSize(.large).disabled(store.busy)
            }
            if let error = meeting.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

struct SummaryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var overviewMeetingID: String?
    @State private var overviewDraft = ""
    @State private var originalOverview = ""
    @State private var originalGeneratedAt = 0.0
    @FocusState private var overviewFocused: Bool
    @State private var showingFocus = false

    private var overviewEditing: Bool { overviewMeetingID != nil && overviewMeetingID == store.selection }
    private var overviewLocked: Bool { store.busy || store.isRecording }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Menu {
                        Picker("Где создавать конспект", selection: $store.settings.mode) {
                            Text("На Mac").tag("local"); Text("Облако").tag("cloud")
                        }
                    } label: { Label(store.settings.mode == "cloud" ? "Облако" : "На Mac", systemImage: store.settings.mode == "cloud" ? "cloud" : "laptopcomputer") }
                        .menuStyle(.borderlessButton).frame(width: 110).disabled(overviewLocked || overviewEditing)
                        .onChange(of: store.settings.mode) { _, _ in store.saveSettings() }
                    Button { showingFocus = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(overviewLocked || overviewEditing).accessibilityLabel("Фокус конспекта")
                        .help("Что важно выписать из встречи")
                        .popover(isPresented: $showingFocus) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Фокус конспекта").font(AppTypography.heading)
                                TextEditor(text: Binding(get: { store.selected?.focus ?? "" }, set: { value in
                                    if let id = store.selection { store.updateMeeting(id) { $0.focus = value } }
                                })).font(AppTypography.body).frame(height: 110).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 6))
                                HStack { Spacer(); Button("Готово") { showingFocus = false } }
                            }.padding(20).frame(width: 420)
                        }
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("Создано ИИ. Проверяйте цифры и договорённости по исходным репликам.")
                        .accessibilityLabel("Создано ИИ. Проверяйте цифры и договорённости по исходным репликам.")
                    Spacer()
                    Button { store.summarizeSelected() } label: {
                        Label(store.summary == nil ? "Создать конспект" : "Обновить", systemImage: "sparkles").frame(minWidth: 120)
                    }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(overviewLocked || overviewEditing)
                }
                if store.settings.mode == "cloud" {
                    Text("\(store.settings.cloudProviderTitle) получит текст встречи. Запрос оплачивается через API.")
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }

                if store.summary == nil && overviewEditing {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Черновик конспекта").font(AppTypography.heading)
                        overviewEditor
                    }
                }
                if let summary = store.summary {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("Кратко").font(AppTypography.heading)
                            Spacer()
                            if !overviewEditing {
                                Button("Изменить") { beginOverviewEdit(summary) }
                                    .buttonStyle(.borderless).disabled(overviewLocked)
                            }
                        }
                        if overviewEditing {
                            overviewEditor
                        } else {
                            if summary.hasVerifiedOverviewClaims(transcript: store.transcript) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(summary.overviewClaims.enumerated()), id: \.offset) { index, claim in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(claim.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                                            ClaimReferenceButton(claim: claim, number: index + 1, summary: summary)
                                        }
                                    }
                                }.frame(maxWidth: 700, alignment: .leading)
                            } else {
                                Text(summary.overview).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                                    .frame(maxWidth: 700, alignment: .leading)
                                if !summary.items.isEmpty {
                                    DisclosureGroup("Факты этой встречи") {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text("Проверяйте конспект по фактам и исходным репликам ниже. Новый конспект добавит ссылки к отдельным утверждениям.")
                                                .font(AppTypography.caption).foregroundStyle(.secondary)
                                            ForEach(summary.items) { item in
                                                HStack(alignment: .top, spacing: 12) {
                                                    Text(item.text).font(AppTypography.body).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                                                    EvidenceButton(ids: item.segmentIDs)
                                                }
                                            }
                                        }.padding(.top, 12)
                                    }.font(AppTypography.control).padding(.top, 4)
                                }
                            }
                        }
                    }.padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(overviewTargeted ? Ink.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
                        .id("summary-overview")
                    ForEach(["decision", "action", "detail", "question"], id: \.self) { kind in
                        let items = summary.items.filter { $0.kind == kind }
                        if !items.isEmpty { section(kind, items) }
                    }
                    ForEach(summary.warnings, id: \.self) { Text($0).font(AppTypography.caption).foregroundStyle(Ink.warning) }
                } else if !overviewEditing {
                    VStack(alignment: .leading, spacing: 15) {
                        Image(systemName: "text.badge.star").font(.system(size: 35)).foregroundStyle(Ink.accent)
                        Text("Конспект не создан").font(AppTypography.emptyTitle)
                        Button("Настройки ИИ") { store.openSettings("ai") }.buttonStyle(.bordered)
                    }.padding(.vertical, 45).frame(maxWidth: 540, alignment: .leading)
                }
            }.appContentLayout()
        }
        .onAppear { scrollToTarget(proxy) }
        .onChange(of: store.navigationTarget?.id) { _, _ in scrollToTarget(proxy) }
        .onAppear { restoreOverviewDraft() }
        .onChange(of: store.selection) { _, _ in restoreOverviewDraft() }
        .onChange(of: store.summary?.generatedAt) { _, _ in
            if !overviewEditing { restoreOverviewDraft() }
        }
        .onDisappear { endOverviewEdit() }
        }
    }
    private var overviewEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: Binding(get: { overviewDraft }, set: { text in
                overviewDraft = text
                if let id = overviewMeetingID {
                    store.rememberOverviewDraft(text, meetingID: id, original: originalOverview, generatedAt: originalGeneratedAt)
                }
            }))
                .font(AppTypography.body).lineSpacing(7)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150, maxHeight: 280).padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
                .accessibilityLabel("Редактирование краткого конспекта")
                .focused($overviewFocused)
                .disabled(overviewLocked)
            if overviewConflict {
                HStack {
                    Text("Исходный конспект изменился. Правку можно сохранить в заметки.")
                        .font(AppTypography.control).foregroundStyle(Ink.warning)
                    Spacer()
                    Button("В заметки") {
                        guard let id = overviewMeetingID,
                              store.notes.capture(text: overviewDraft, meetingID: id) != nil else { return }
                        cancelOverviewEdit()
                        store.notice = "Правка сохранена в заметки встречи"
                    }.buttonStyle(.bordered)
                }
            }
            HStack(spacing: 10) {
                if overviewDraft != originalOverview {
                    Text("Есть несохранённые изменения").font(AppTypography.control).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена") { cancelOverviewEdit() }
                    .buttonStyle(.bordered).disabled(overviewLocked)
                Button("Сохранить") {
                    guard let id = overviewMeetingID else { return }
                    if store.saveOverview(overviewDraft, meetingID: id, expectedOverview: originalOverview,
                                          expectedGeneratedAt: originalGeneratedAt) {
                        cancelOverviewEdit()
                    }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(overviewLocked || overviewConflict || overviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || overviewDraft == originalOverview)
            }
        }
    }
    private var overviewTargeted: Bool {
        guard let target = store.navigationTarget, target.meetingID == store.selection else { return false }
        return ["overview", "title"].contains(target.kind)
    }
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = store.navigationTarget, target.meetingID == store.selection else { return }
        let id = target.kind == "item" ? "summary-item-\(target.itemIndex ?? -1)" : "summary-overview"
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
    }
    private var overviewConflict: Bool {
        guard overviewEditing else { return false }
        guard let summary = store.summary else { return true }
        return summary.generatedAt != originalGeneratedAt || summary.overview != originalOverview
    }
    private func restoreOverviewDraft() {
        endOverviewEdit()
        guard let id = store.selection, let draft = store.overviewDrafts[id] else { return }
        overviewMeetingID = id; overviewDraft = draft.text
        originalOverview = draft.original; originalGeneratedAt = draft.generatedAt
        store.editingOverview = true
    }
    private func beginOverviewEdit(_ summary: Summary) {
        guard let id = store.selection, !overviewLocked else { return }
        overviewMeetingID = id; store.editingOverview = true
        overviewDraft = summary.overview
        originalOverview = summary.overview
        originalGeneratedAt = summary.generatedAt
        DispatchQueue.main.async { overviewFocused = true }
    }
    private func cancelOverviewEdit() {
        if let id = overviewMeetingID { store.discardOverviewDraft(id) }
        endOverviewEdit()
    }
    private func endOverviewEdit() {
        overviewMeetingID = nil; store.editingOverview = false
        overviewDraft = ""
        originalOverview = ""
        originalGeneratedAt = 0
    }
    private func section(_ kind: String, _ items: [Insight]) -> some View {
        let title = ["decision": "Решения", "action": "Задачи", "detail": "Детали", "question": "Вопросы"][kind]!
        let icon = ["decision": "checkmark.seal", "action": "checklist", "detail": "pin", "question": "questionmark.bubble"][kind]!
        return VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(AppTypography.heading)
            ForEach(items) { item in
                let index = store.summary?.items.firstIndex(where: { $0.id == item.id }) ?? -1
                let targeted = store.navigationTarget?.meetingID == store.selection && store.navigationTarget?.kind == "item" && store.navigationTarget?.itemIndex == index
                HStack(alignment: .top, spacing: 12) {
                    if kind == "action" {
                        Button { store.toggleTask(item) } label: {
                            Image(systemName: store.taskCompleted(item) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Ink.accent).font(.system(size: 18)).frame(width: 30, height: 30).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy || store.isRecording).accessibilityLabel("Выполнение задачи")
                            .accessibilityValue(store.taskCompleted(item) ? "Выполнена" : "Не выполнена")
                    } else { Circle().fill(Ink.accent.opacity(0.45)).frame(width: 5, height: 5).padding(.top, 6) }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                            .strikethrough(kind == "action" && store.taskCompleted(item))
                        if !item.owner.isEmpty || !item.due.isEmpty {
                            HStack(spacing: 12) {
                                if !item.owner.isEmpty { Label(item.owner, systemImage: "person") }
                                if !item.due.isEmpty { Label(item.due, systemImage: "calendar") }
                            }.font(AppTypography.control).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    EvidenceButton(ids: item.segmentIDs)
                }.padding(.vertical, 9).padding(.horizontal, 10)
                    .background(targeted ? Ink.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .id("summary-item-\(index)")
            }
        }.padding(.bottom, 4)
    }
}

struct TranscriptView: View {
    @EnvironmentObject private var store: AppStore
    @State private var speaker: String?
    @State private var name = ""
    @State private var showingSpeakers = false
    @State private var transcriptCopied = ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-copied")
    private var segments: [Segment] {
        (store.transcript?.segments ?? []).filter { store.transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(store.transcriptSearch) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск по словам встречи", text: $store.transcriptSearch).textFieldStyle(.plain)
                    Text("Реплик: \(segments.count)").foregroundStyle(.secondary).monospacedDigit()
                }.padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
                Button { showingSpeakers = true } label: {
                    Label("Собеседники: \(Set((store.transcript?.segments ?? []).map(\.speaker).filter { $0 != "unknown" }).count)", systemImage: "person.2")
                }.buttonStyle(.bordered).disabled(store.busy || store.isRecording)
                    .help("Указать точное число участников и пересчитать голоса без повторного распознавания")
                Button {
                    if store.copyTranscriptMarkdown() { transcriptCopied = true }
                } label: {
                    Image(systemName: transcriptCopied ? "checkmark" : "doc.on.doc")
                        .frame(width: 20, height: 20)
                        .foregroundStyle(transcriptCopied ? Ink.green : .secondary)
                }.buttonStyle(.bordered)
                    .disabled(store.transcript?.segments.isEmpty ?? true)
                    .help(transcriptCopied ? "Транскрипт скопирован" : "Скопировать весь транскрипт в Markdown")
                    .accessibilityLabel("Скопировать транскрипт в Markdown")
                    .accessibilityValue(transcriptCopied ? "Скопировано" : "")
                    .accessibilityIdentifier("transcript.copy-markdown")
            }.font(AppTypography.control)
                .padding(.horizontal, AppLayout.contentInset).padding(.top, 16).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.transcript?.warnings ?? [], id: \.self) { Text($0).font(AppTypography.caption).foregroundStyle(Ink.warning).padding(.bottom, 10) }
                        ForEach(segments) { segment in
                            HStack(alignment: .top, spacing: 18) {
                                Button { store.seek(segment.start, play: true) } label: {
                                    Text(Exporter.timestamp(segment.start)).font(AppTypography.control).monospacedDigit()
                                        .foregroundStyle(Ink.accent).frame(width: 60, alignment: .leading)
                                }.buttonStyle(.plain).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Button {
                                            speaker = segment.speaker; name = store.selected?.speakerName(segment.speaker) ?? ""
                                        } label: {
                                            HStack(spacing: 7) {
                                                Circle().fill(speakerColor(segment.speaker)).frame(width: 7, height: 7)
                                                Text(store.selected?.speakerName(segment.speaker) ?? segment.speaker).font(AppTypography.controlStrong)
                                                Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.plain).help("Переименовать собеседника").disabled(store.busy || store.isRecording)
                                        if segment.overlap { Text("Голоса пересекаются").font(AppTypography.caption).foregroundStyle(Ink.warning) }
                                    }
                                    Text(segment.text).font(AppTypography.body).lineSpacing(6).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(14).background(active(segment) ? Ink.accent.opacity(0.06) : .clear,
                                                     in: RoundedRectangle(cornerRadius: 9)).id(segment.id)
                        }
                        if segments.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary).padding(30) }
                    }.padding(.horizontal, 18).padding(.vertical, 10)
                }.onAppear { scrollToTarget(proxy) }
                .onChange(of: store.navigationTarget?.id) { _, _ in scrollToTarget(proxy) }
                .onChange(of: store.playbackTime) { old, new in
                    if abs(new - old) > 1.5, let target = store.transcript?.segments.first(where: { new >= $0.start && new < $0.end }) {
                        withAnimation { proxy.scrollTo(target.id, anchor: .center) }
                    }
                }
            }
        }.task(id: transcriptCopied) {
            guard transcriptCopied, !(ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-copied")) else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            transcriptCopied = false
        }.onChange(of: store.selection) { _, _ in transcriptCopied = false }
        .sheet(isPresented: $showingSpeakers) {
            if let id = store.selection { SpeakerReviewView(meetingID: id).environmentObject(store) }
        }.alert("Имя собеседника", isPresented: Binding(get: { speaker != nil }, set: { if !$0 { speaker = nil } })) {
            TextField("Имя", text: $name)
            Button("Сохранить") { if let speaker { store.renameSpeaker(speaker, name: name) }; speaker = nil }
            Button("Отмена", role: .cancel) { speaker = nil }
        } message: { Text("Имя изменится во всех репликах этого собеседника. Метки голосов определены автоматически и могут ошибаться.") }
    }
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = store.navigationTarget, target.meetingID == store.selection, target.kind == "transcript", let id = target.segmentID else { return }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
    }
    private func active(_ s: Segment) -> Bool {
        (store.navigationTarget?.meetingID == store.selection && store.navigationTarget?.kind == "transcript" && store.navigationTarget?.segmentID == s.id) ||
        (store.playbackTime >= s.start && store.playbackTime < s.end)
    }
    private func speakerColor(_ key: String) -> Color {
        if key == "self" { return Ink.green }
        if key == "unknown" { return .gray }
        let value = Int(key.replacingOccurrences(of: "speaker_", with: "")) ?? 0
        return [Ink.accent, Ink.green, .orange, .pink, .cyan][abs(value % 5)]
    }
}
