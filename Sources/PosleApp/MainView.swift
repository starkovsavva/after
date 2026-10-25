import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @State private var dropping = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 248)
            Rectangle().fill(Ink.line).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                if store.busy { processingBar }
                if store.isRecording { recordingBar }
                if let error = store.error { message(error, error: true) }
                if let notice = store.notice { message(notice, error: false) }
                if store.librarySection == "inbox" { NotesInboxView(notes: store.notes) }
                else if store.librarySection == "tasks" { NotesTasksView(notes: store.notes) }
                else if store.librarySection == "contexts" { NotesContextsView(notes: store.notes) }
                else if store.librarySection == "cards" { CardsLibraryView() }
                else if let meeting = store.selected { MeetingView(meeting: meeting) }
                else { welcome }
                if store.librarySection == "meetings", store.transcript != nil { player }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Ink.paper)
        .tint(Ink.accent)
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
                RoundedRectangle(cornerRadius: 16).fill(Ink.accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.accent, style: StrokeStyle(lineWidth: 3, dash: [10])))
                    .overlay(Label("Отпустите запись встречи", systemImage: "arrow.down.doc.fill").font(.title2.weight(.semibold)))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $store.showingSettings) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $store.showingRecord) { RecordView().environmentObject(store) }
        .sheet(isPresented: $store.showingSearch) { SearchView().environmentObject(store) }
        .alert("Переместить встречу в Корзину?", isPresented: $confirmDelete) {
            Button("Отмена", role: .cancel) {}
            Button("В Корзину", role: .destructive) { store.trashSelected() }
        } message: { Text("Запись, конспект и карточки этой встречи можно будет восстановить из Корзины Finder.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Ink.accent).frame(width: 39, height: 39)
                    Image(systemName: "waveform").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("после").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Место для важного").font(AppTypography.control).foregroundStyle(.secondary)
                }
            }.padding(.top, 42).padding(.horizontal, 24).padding(.bottom, 30)

            VStack(spacing: 3) {
                libraryButton("meetings", "Все встречи", "rectangle.stack")
                libraryButton("inbox", "Входящие", "tray")
                libraryButton("tasks", "Мои задачи", "checklist")
                libraryButton("contexts", "Проекты и люди", "person.2")
                libraryButton("cards", "Карточки", "rectangle.on.rectangle.angled")
            }.padding(.horizontal, 14)

            Button { store.openGlobalSearch() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                    Text("Поиск по всей библиотеке").lineLimit(2)
                    Spacer(minLength: 0)
                    Text("⌘K").font(.system(size: 11)).foregroundStyle(.secondary)
                }.font(AppTypography.control).padding(11).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 16)
                .accessibilityLabel("Поиск по всей библиотеке. Command K")

            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Фильтр по названию", text: $store.libraryFilter).textFieldStyle(.plain)
                    .accessibilityLabel("Фильтр списка встреч по названию")
            }.font(AppTypography.control).padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.filteredMeetings) { meeting in
                        Button { store.librarySection = "meetings"; store.selection = meeting.id; if meeting.libraryKind == "cards" { store.tab = "cards" } } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: meeting.status == "ready" ? "text.badge.checkmark" : "waveform")
                                        .foregroundStyle(store.selection == meeting.id ? Ink.accent : .secondary)
                                    Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                HStack {
                                    Text(Date(timeIntervalSince1970: meeting.createdAt).formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))))
                                    Spacer()
                                    Text(meeting.status == "recording" ? "Запись" : (meeting.duration > 0 ? Exporter.timestamp(meeting.duration) : "Добавлена"))
                                }.font(AppTypography.control).foregroundStyle(.secondary)
                            }.padding(12).background(store.selection == meeting.id ? Color.primary.opacity(0.055) : .clear,
                                                      in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                            .accessibilityValue(store.selection == meeting.id ? "Выбрана" : "")
                            .accessibilityAddTraits(store.selection == meeting.id ? .isSelected : [])
                    }
                    if store.filteredMeetings.isEmpty && !store.libraryFilter.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Встречи не найдены").font(.system(size: 13, weight: .medium))
                            Text("Попробуйте другое название.").font(AppTypography.caption).foregroundStyle(.secondary)
                            Button("Сбросить поиск") { store.libraryFilter = "" }.buttonStyle(.borderless)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 10)
            if ProcessInfo.processInfo.arguments.contains("--preview") {
                Text("Демонстрационные данные").font(.caption2).foregroundStyle(Ink.warning).padding(.horizontal, 22).padding(.bottom, 10)
            }
            Button { store.showingSettings = true } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("Настройки")
                    Spacer()
                    Circle().fill(store.runtimeReady ? Ink.green : .orange).frame(width: 6, height: 6)
                }.font(AppTypography.control).padding(13)
            }.buttonStyle(.plain).padding(.horizontal, 12)
            Label("Аудио хранится на Mac", systemImage: "lock").font(AppTypography.control).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.bottom, 20)
        }.background(Color.primary.opacity(0.018))
    }

    private func libraryButton(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { store.librarySection = id; store.pause() } label: {
            HStack { Label(title, systemImage: icon); Spacer(); if id == "meetings" { Text("\(store.meetings.count)").foregroundStyle(.secondary) } }
                .font(.system(size: 13, weight: store.librarySection == id ? .semibold : .regular)).padding(10)
                .background(store.librarySection == id ? Ink.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(store.librarySection == id ? Ink.accent : Color.primary)
        }.buttonStyle(.plain).accessibilityAddTraits(store.librarySection == id ? .isSelected : [])
    }

    private var topbar: some View {
        HStack(spacing: 12) {
            Label("Ваша библиотека", systemImage: "square.stack.3d.up").font(AppTypography.control).foregroundStyle(.secondary)
            Spacer()
            Button { store.quickCaptureAction?() } label: { Label("Заметка", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
            Button { store.chooseFile() } label: { Label("Добавить файл", systemImage: "plus") }
                .disabled(store.busy || store.isRecording).buttonStyle(.bordered)
            Button { store.showingRecord = true } label: { Label("Записать встречу", systemImage: "record.circle") }
                .disabled(store.busy || store.isRecording).buttonStyle(.borderedProminent).tint(Ink.actionFill)
        }.controlSize(.regular).padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 14)
    }

    private var processingBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.progressText).font(AppTypography.control).lineLimit(2)
                    if let id = store.processingID, let meeting = store.meetings.first(where: { $0.id == id }) {
                        Text(meeting.title).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if store.canCancelJob {
                    Button("Отменить") { store.cancelJob() }.font(AppTypography.caption).buttonStyle(.borderless)
                }
            }
            if store.progress >= 0 { ProgressView(value: store.progress).progressViewStyle(.linear) }
        }.padding(14).background(Ink.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 30).padding(.bottom, 12)
    }
    private var recordingBar: some View {
        HStack {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
            Text(store.stoppingRecording ? "Сохраняю запись…" : "Идёт запись").fontWeight(.semibold)
            if !store.stoppingRecording, let date = store.recordingDate { Text(date, style: .timer).monospacedDigit() }
            Spacer()
            Button { store.bookmarkAction?() } label: { Label("Важно", systemImage: "bookmark") }.buttonStyle(.bordered).disabled(store.stoppingRecording)
            Button("Остановить и сохранить") { Task { await store.stopRecording() } }.buttonStyle(.borderedProminent).tint(Ink.recordFill)
                .disabled(store.busy || store.stoppingRecording)
        }.font(AppTypography.control).padding(12).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 30).padding(.bottom, 12)
    }
    private func message(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(error ? Ink.warning : Ink.green)
            Text(text).font(AppTypography.control).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { if error { store.error = nil } else { store.notice = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Закрыть сообщение")
        }.padding(12).background(error ? Color.orange.opacity(0.08) : Ink.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 30).padding(.bottom, 10)
    }

    private var welcome: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<19) { i in
                    Capsule().fill(Ink.accent.opacity(i % 4 == 0 ? 0.28 : 0.8))
                        .frame(width: 5, height: CGFloat([18, 32, 48, 27, 60, 80, 40, 64, 96, 58, 38, 72, 48, 24, 42, 60, 28, 18, 10][i]))
                }
            }.frame(height: 100).accessibilityHidden(true)
            Text("Разговор закончился.\nВажное осталось.")
                .font(.system(size: 43, weight: .semibold, design: .rounded)).tracking(-1.3).lineSpacing(2)
            Text("Записывайте встречи на русском и английском.\nВозвращайтесь к решениям, деталям и полезным фразам.")
                .font(.system(size: 15)).lineSpacing(6).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { store.chooseFile() } label: { Label("Добавить первую запись", systemImage: "arrow.up.doc") }
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill).controlSize(.large).disabled(store.busy)
                Button("Настроить приложение") { store.showingSettings = true }.buttonStyle(.bordered).controlSize(.large)
            }.padding(.top, 6)
            Text("Или перетащите сюда аудио или видео").font(AppTypography.control).foregroundStyle(.secondary)
            Spacer()
            HStack(alignment: .top, spacing: 40) {
                welcomeFeature("text.alignleft", "Каждая реплика", "Текст, собеседники и таймкоды")
                welcomeFeature("checkmark.bubble", "Суть и детали", "Решения, задачи, цифры и сроки")
                welcomeFeature("rectangle.on.rectangle.angled", "В долгую память", "Карточки и новые примеры")
            }.padding(.bottom, 45)
        }.padding(.horizontal, 60).padding(.vertical, 28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func welcomeFeature(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Ink.accent).padding(.bottom, 4)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var player: some View {
        HStack(spacing: 14) {
            Button { store.togglePlayback() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").frame(width: 30, height: 30)
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
        }.font(AppTypography.control).padding(.horizontal, 28).padding(.vertical, 16)
            .background(Color.primary.opacity(0.025)).overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

struct MeetingView: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    @State private var rename = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    Text(meeting.title).font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.5)
                        .lineLimit(2).textSelection(.enabled)
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
                    if let summary = store.summary {
                        Label(summary.provider == "cloud" ? "Конспект в облаке" : "Конспект на Mac", systemImage: summary.provider == "cloud" ? "cloud" : "laptopcomputer")
                    }
                }.font(AppTypography.control).foregroundStyle(.secondary)
            }.padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 18)
            HStack(spacing: 25) {
                tab("notes", "Мои заметки", nil)
                if meeting.libraryKind != "cards" {
                    tab("summary", "Конспект", nil)
                    tab("transcript", "Транскрипт", store.transcript?.segments.count)
                }
                tab("cards", "Карточки", store.summary?.cards.count)
                Spacer()
            }.padding(.horizontal, 32).overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
            if store.tab == "notes" { NotesWorkspaceView(notes: store.notes, meeting: meeting) }
            else if store.transcript == nil && store.tab != "cards" { unprocessed }
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
    private func tab(_ key: String, _ label: String, _ count: Int?) -> some View {
        Button { store.tab = key } label: {
            HStack(spacing: 7) {
                Text(label)
                if let count, count > 0 { Text("\(count)").font(AppTypography.control).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Ink.soft, in: Capsule()) }
            }.font(.system(size: 13, weight: store.tab == key ? .semibold : .regular))
                .foregroundStyle(store.tab == key ? Ink.accent : .secondary)
                .padding(.bottom, 14).overlay(alignment: .bottom) {
                    if store.tab == key { Rectangle().fill(Ink.accent).frame(height: 2) }
                }
        }.buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(store.tab == key ? "Выбрана" : "")
            .accessibilityAddTraits(store.tab == key ? .isSelected : [])
            .keyboardShortcut(key == "summary" ? "1" : key == "transcript" ? "2" : "3", modifiers: .command)
    }
    private var unprocessed: some View {
        VStack(spacing: 16) {
            Image(systemName: store.stoppingRecording ? "square.and.arrow.down" : store.isRecording ? "waveform" : "waveform.badge.magnifyingglass").font(.system(size: 42)).foregroundStyle(Ink.accent)
            Text(store.stoppingRecording ? "Сохраняем встречу" : store.isRecording ? "Идёт запись встречи" : "Запись готова к распознаванию").font(.title3.weight(.semibold))
            Text(store.stoppingRecording ? "Подождите: создаю MP3 и сохраняю звуковые дорожки." : store.isRecording ? "Когда встреча закончится, нажмите «Остановить и сохранить»." : "Речь останется на исходном языке. Собеседники получат отдельные метки.")
                .font(AppTypography.control).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !store.isRecording {
                Button(store.runtimeReady ? "Распознать встречу" : "Установить модели") {
                    if store.runtimeReady { Task { await store.processMeeting(meeting.id) } }
                    else { store.showingSettings = true }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).controlSize(.large).disabled(store.busy)
            }
            if let error = meeting.error { Text(error).font(.caption).foregroundStyle(Ink.warning) }
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

    private var overviewEditing: Bool { overviewMeetingID != nil && overviewMeetingID == store.selection }
    private var overviewLocked: Bool { store.busy || store.isRecording }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 12) {
                    Picker("Где создавать конспект", selection: $store.settings.mode) {
                        Label("На Mac", systemImage: "laptopcomputer").tag("local")
                        Label("Облако", systemImage: "cloud").tag("cloud")
                    }.pickerStyle(.segmented).tint(Ink.actionFill).labelsHidden().frame(width: 235).disabled(store.busy || store.isRecording)
                        .onChange(of: store.settings.mode) { _, _ in store.saveSettings() }
                    Spacer()
                    Button { store.summarizeSelected() } label: {
                        Label(store.settings.mode == "cloud" ? "Конспект в облаке" : (store.summary == nil ? "Создать конспект" : "Обновить конспект"), systemImage: "sparkles")
                    }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(store.busy || store.isRecording)
                }
                if store.settings.mode == "cloud" {
                    Label("По этой кнопке текст встречи отправится в OpenAI. Аудио останется на Mac. API оплачивается отдельно.", systemImage: "cloud")
                        .font(AppTypography.control).foregroundStyle(.secondary)
                }
                DisclosureGroup("Что важно выписать из этой встречи") {
                    TextEditor(text: Binding(get: { store.selected?.focus ?? "" }, set: { value in
                        if let id = store.selection { store.updateMeeting(id) { $0.focus = value } }
                    })).font(AppTypography.control).frame(height: 70).padding(8).disabled(store.busy || store.isRecording)
                        .background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                }.font(AppTypography.control).foregroundStyle(.secondary)

                if let summary = store.summary {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Label("Главное из разговора", systemImage: "text.bubble").font(AppTypography.heading)
                            Spacer()
                            if !overviewEditing {
                                Button("Исправить") { beginOverviewEdit(summary) }
                                    .buttonStyle(.bordered).controlSize(.small).disabled(overviewLocked)
                            }
                        }
                        if overviewEditing {
                            TextEditor(text: $overviewDraft)
                                .font(AppTypography.body).lineSpacing(7)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 150, maxHeight: 280).padding(10)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
                                .accessibilityLabel("Редактирование краткого конспекта")
                                .focused($overviewFocused)
                                .disabled(overviewLocked)
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
                                    .disabled(overviewLocked || overviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                              || overviewDraft == originalOverview)
                            }
                        } else {
                            if summary.hasVerifiedOverviewClaims(transcript: store.transcript) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(summary.overviewClaims.enumerated()), id: \.offset) { index, claim in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(claim.text).font(AppTypography.body).lineSpacing(7).textSelection(.enabled)
                                            ClaimReferenceButton(claim: claim, number: index + 1, summary: summary)
                                        }
                                    }
                                }.frame(maxWidth: 700, alignment: .leading)
                            } else {
                                Text(summary.overview).font(AppTypography.body).lineSpacing(7).textSelection(.enabled)
                                    .frame(maxWidth: 700, alignment: .leading)
                                if !summary.items.isEmpty {
                                    DisclosureGroup("Факты этой встречи") {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text("Проверяйте конспект по фактам и исходным репликам ниже. Новый конспект добавит ссылки к отдельным утверждениям.")
                                                .font(AppTypography.caption).foregroundStyle(.secondary)
                                            ForEach(summary.items) { item in
                                                HStack(alignment: .top, spacing: 12) {
                                                    Text(item.text).font(AppTypography.control).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                                                    EvidenceButton(ids: item.segmentIDs)
                                                }
                                            }
                                        }.padding(.top, 12)
                                    }.font(AppTypography.control).padding(.top, 4)
                                }
                            }
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.accent.opacity(overviewTargeted ? 0.11 : 0.055), in: RoundedRectangle(cornerRadius: 12))
                        .id("summary-overview")
                    ForEach(["decision", "action", "detail", "question"], id: \.self) { kind in
                        let items = summary.items.filter { $0.kind == kind }
                        if !items.isEmpty { section(kind, items) }
                    }
                    if !summary.cards.isEmpty {
                        Button { store.tab = "cards" } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 23)).foregroundStyle(Ink.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Заберите полезное в память").font(.system(size: 13, weight: .semibold))
                                    Text("\(summary.cards.count) карточек с фразами и понятиями из этой встречи").font(AppTypography.control).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "arrow.right").foregroundStyle(Ink.accent)
                            }.padding(18).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    Text("Создано ИИ. Цифры, имена и обязательства проверяйте по исходным репликам.")
                        .font(AppTypography.control).foregroundStyle(.secondary)
                    ForEach(summary.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(Ink.warning) }
                } else {
                    VStack(alignment: .leading, spacing: 15) {
                        Image(systemName: "text.badge.star").font(.system(size: 35)).foregroundStyle(Ink.accent)
                        Text("От разговора — к понятному плану").font(.system(size: 23, weight: .semibold, design: .rounded))
                        Text("Создайте конспект, чтобы собрать решения, задачи, сроки и важные детали. Полезные фразы и понятия появятся в карточках.")
                            .font(AppTypography.body).foregroundStyle(.secondary).lineSpacing(6)
                        Button("Настроить ИИ для конспекта") { store.showingSettings = true }.buttonStyle(.bordered)
                    }.padding(.vertical, 45).frame(maxWidth: 540, alignment: .leading)
                }
            }.padding(32)
        }
        .onAppear { scrollToTarget(proxy) }
        .onChange(of: store.navigationTarget?.id) { _, _ in scrollToTarget(proxy) }
        .onChange(of: store.selection) { _, _ in cancelOverviewEdit() }
        .onChange(of: store.summary?.generatedAt) { _, _ in cancelOverviewEdit() }
        .onDisappear { cancelOverviewEdit() }
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
    private func beginOverviewEdit(_ summary: Summary) {
        guard let id = store.selection, !overviewLocked else { return }
        overviewMeetingID = id
        overviewDraft = summary.overview
        originalOverview = summary.overview
        originalGeneratedAt = summary.generatedAt
        DispatchQueue.main.async { overviewFocused = true }
    }
    private func cancelOverviewEdit() {
        overviewMeetingID = nil
        overviewDraft = ""
        originalOverview = ""
        originalGeneratedAt = 0
    }
    private func section(_ kind: String, _ items: [Insight]) -> some View {
        let title = ["decision": "Решения", "action": "Следующие шаги", "detail": "Детали, которые важно сохранить", "question": "Открытые вопросы"][kind]!
        let icon = ["decision": "checkmark.seal", "action": "checklist", "detail": "pin", "question": "questionmark.bubble"][kind]!
        return VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.system(size: 16, weight: .semibold, design: .rounded))
            ForEach(items) { item in
                let index = store.summary?.items.firstIndex(where: { $0.id == item.id }) ?? -1
                let targeted = store.navigationTarget?.meetingID == store.selection && store.navigationTarget?.kind == "item" && store.navigationTarget?.itemIndex == index
                HStack(alignment: .top, spacing: 12) {
                    if kind == "action" {
                        Button { store.toggleTask(item) } label: {
                            Image(systemName: store.selected?.completedTasks.contains(item.id) == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Ink.accent).font(.system(size: 18)).frame(width: 30, height: 30).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy || store.isRecording).accessibilityLabel("Выполнение задачи")
                            .accessibilityValue(store.selected?.completedTasks.contains(item.id) == true ? "Выполнена" : "Не выполнена")
                    } else { Circle().fill(Ink.accent.opacity(0.45)).frame(width: 5, height: 5).padding(.top, 6) }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.text).font(AppTypography.control).lineSpacing(4).textSelection(.enabled)
                            .strikethrough(kind == "action" && store.selected?.completedTasks.contains(item.id) == true)
                        if !item.owner.isEmpty || !item.due.isEmpty {
                            HStack(spacing: 12) {
                                if !item.owner.isEmpty { Label(item.owner, systemImage: "person") }
                                if !item.due.isEmpty { Label(item.due, systemImage: "calendar") }
                            }.font(AppTypography.control).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    EvidenceButton(ids: item.segmentIDs)
                }.padding(.vertical, 9).padding(.horizontal, targeted ? 10 : 0)
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
    private var segments: [Segment] {
        (store.transcript?.segments ?? []).filter { store.transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(store.transcriptSearch) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по словам встречи", text: $store.transcriptSearch).textFieldStyle(.plain)
                Text("\(segments.count) реплик").foregroundStyle(.secondary)
            }.font(AppTypography.control).padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.transcript?.warnings ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(Ink.warning).padding(.bottom, 10) }
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
                                                Text(store.selected?.speakerName(segment.speaker) ?? segment.speaker).font(.system(size: 13, weight: .semibold))
                                                Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.plain).help("Переименовать собеседника").disabled(store.busy || store.isRecording)
                                        if segment.overlap { Text("Голоса пересекаются").font(.system(size: 9)).foregroundStyle(Ink.warning) }
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
        return [Ink.accent, Ink.green, .orange, .pink, .cyan][abs(value) % 5]
    }
}
