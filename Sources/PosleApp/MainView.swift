import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var theme = ThemeController.shared
    @ObservedObject private var guide = GuidanceController.shared
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
        .onAppear {
            theme.configure(root: store.root)
            guide.configure(root: store.root, preview: store.isPreview)
            guide.considerStartup(hasMeetings: !store.meetings.isEmpty)
        }
        .onReceive(NotificationCenter.default.publisher(for: .posleJobsChanged)) { _ in
            store.reloadLibrary()
            if let id = store.selection { store.refreshResults(id) }
        }
        .sheet(item: $guide.presentation, onDismiss: {
            guide.finishPresentation()
            switch guide.takeAction() {
            case .record: store.showingRecord = true
            case .importFile: store.chooseFile()
            case .speechSettings: store.openSettings("speech")
            case .aiSettings: store.openSettings("ai")
            case .cards: store.librarySection = "cards"
            case .tasks: store.librarySection = "tasks"
            case .integrations: store.openSettings("integrations")
            case nil: break
            }
        }) { _ in GuidanceSheet(controller: guide) }
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
        }.appSurface(.sidebar)
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
                    if !store.stoppingRecording { AudioLevelView(levels: store.audioLevels, systemAudio: store.settings.recordSystemAudio, compact: true) }
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
            BackgroundJobsButton(jobs: store.jobs)
            UpdateAvailabilityButton(updates: store.updates)
            Button { store.quickCaptureAction?() } label: { Image(systemName: "square.and.pencil").frame(width: 28, height: 28) }
                .buttonStyle(.plain).appLayoutAnchor("toolbar.note").help("Быстрая заметка · ⇧⌘N").accessibilityLabel("Быстрая заметка")
            Button { store.chooseFile() } label: { Image(systemName: "arrow.down.doc").frame(width: 28, height: 28) }
                .disabled(store.startingRecording).buttonStyle(.plain).appLayoutAnchor("toolbar.file").help("Импорт аудио или видео · ⌘O").accessibilityLabel("Импорт аудио или видео")
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
            }.disabled(store.stoppingRecording || store.startingRecording)
                .buttonStyle(.bordered).foregroundStyle(store.isRecording ? Ink.recordFill : Color.primary)
                .appLayoutAnchor("toolbar.record").help(store.isRecording ? "Остановить и сохранить запись" : "Записать встречу · ⌘N")
        }.font(AppTypography.control).controlSize(.regular).padding(.horizontal, 16)
            .frame(height: AppLayout.toolbarHeight).appSurface(.toolbar).appLayoutAnchor("toolbar")
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
                Button("Записать встречу") { store.showingRecord = true }.buttonStyle(.bordered).disabled(store.startingRecording)
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
            .frame(height: AppLayout.statusHeight).appSurface(.toolbar)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}
