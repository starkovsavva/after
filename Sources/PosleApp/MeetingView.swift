import AppKit
import PosleCore
import SwiftUI

struct MeetingView: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    @State private var folderEditor: FolderEditorTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    MeetingTitleHeading(store: store, edits: store.meetingTitleEdits, meeting: meeting)
                    Spacer(minLength: 10)
                    Menu {
                        Button(L("Переместить в папку…")) {
                            NotificationCenter.default.post(name: Notification.Name("PosleMoveMeeting"), object: meeting.id)
                        }.disabled(store.captureMeetingID == meeting.id)
                        if let folder = store.notes.folder(for: meeting.id) {
                            Button(L("Настройки папки…")) { folderEditor = FolderEditorTarget(folder: folder) }
                        }
                        if meeting.libraryKind != "cards" {
                            Divider()
                            Menu(L("Автосоздание карточек")) {
                                if store.effectiveSettings(for: meeting.id).features.cards {
                                    Picker(L("Автосоздание карточек"), selection: Binding(get: {
                                        meeting.generateCards.map { $0 ? "on" : "off" } ?? "inherit"
                                    }, set: { choice in
                                        store.updateMeeting(meeting.id) { $0.generateCards = choice == "inherit" ? nil : choice == "on" }
                                    })) {
                                        Text(store.cardGenerationInheritanceTitle(for: meeting.id)).tag("inherit")
                                        Text(L("Создавать при обновлении конспекта")).tag("on")
                                        Text(L("Не создавать для этой встречи")).tag("off")
                                    }.labelsHidden()
                                } else {
                                    Text(store.folderID(for: meeting.id) == nil ? L("Карточки выключены в настройках приложения") : L("Карточки выключены в настройках папки"))
                                    if let folder = store.notes.folder(for: meeting.id) {
                                        Button(L("Настройки папки…")) { folderEditor = FolderEditorTarget(folder: folder) }
                                    } else {
                                        Button(L("Выбрать возможности…")) { store.openSettings("features") }
                                    }
                                }
                            }.accessibilityIdentifier("meeting.cardGeneration")
                        }
                        Divider()
                        Button(L("Переименовать…")) { store.meetingTitleEdits.begin(meeting) }.disabled(store.captureMeetingID == meeting.id)
                        Button(L("Распознать заново")) { Task { await store.processMeeting(meeting.id) } }.disabled(!store.runtimeReady || store.jobs.contains(objectID: meeting.id, kinds: ["transcribe"]) || meeting.libraryKind == "cards")
                    } label: { Image(systemName: "ellipsis").frame(width: 25, height: 25) }.menuStyle(.borderlessButton).frame(width: 32)
                        .accessibilityLabel(L("Действия со встречей"))
                }
                HStack(spacing: 16) {
                    Label(Date(timeIntervalSince1970: meeting.createdAt).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(UILocale())), systemImage: "calendar")
                    if meeting.duration > 0 { Label(Exporter.timestamp(meeting.duration), systemImage: "clock") }
                    Button {
                        NotificationCenter.default.post(name: Notification.Name("PosleMoveMeeting"), object: meeting.id)
                    } label: {
                        Label(store.notes.folder(for: meeting.id)?.name ?? L("Без папки"), systemImage: "folder").lineLimit(1)
                    }.buttonStyle(.plain).help(L("Переместить встречу в папку"))
                        .accessibilityLabel(L("Папка встречи: ") + (store.notes.folder(for: meeting.id)?.name ?? L("Без папки")))
                        .accessibilityIdentifier("meeting.folder")
                        .disabled(store.captureMeetingID == meeting.id)

                }.font(AppTypography.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, AppLayout.contentInset).padding(.top, 22).padding(.bottom, 18)
            Picker(L("Раздел встречи"), selection: $store.tab) {
                Text(L("Заметки")).tag("notes")
                if meeting.libraryKind != "cards" {
                    Text(L("Конспект")).tag("summary")
                    Text(L("Транскрипт")).tag("transcript")
                }
                if store.effectiveSettings(for: meeting.id).features.cards { Text(L("Карточки")).tag("cards") }
            }.pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, AppLayout.contentInset).padding(.bottom, 16)
                .appLayoutAnchor("meeting.tabs")
            if let job = store.jobs.jobs.first(where: { $0.active && $0.objectID == meeting.id }) {
                HStack(spacing: 8) {
                    if job.state == "running" { ProgressView().controlSize(.small) }
                    Text(job.title + " · " + L(job.stateLabel)).font(AppTypography.caption).lineLimit(1)
                    Spacer()
                    Button(L("Подробнее")) { store.jobs.showing = true }.buttonStyle(.borderless)
                }.foregroundStyle(Ink.secondaryText).padding(.horizontal, AppLayout.contentInset).padding(.bottom, 10)
            }
            if store.tab == "notes" { NotesWorkspaceView(notes: store.notes, meeting: meeting) }
            else if store.transcript == nil && store.tab != "cards" && !(store.tab == "summary" && store.overviewDrafts[meeting.id] != nil) { unprocessed }
            else if store.tab == "transcript" { TranscriptView() }
            else if store.tab == "cards" {
                if store.effectiveSettings(for: meeting.id).features.cards { CardsView().id(meeting.id) }
                else { OptionalFeatureGate(feature: .cards) }
            }
            else { SummaryView() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(item: $folderEditor) { target in FolderSettingsView(folder: target.folder).environmentObject(store) }
    }
    private var unprocessed: some View {
        VStack(spacing: 16) {
            Image(systemName: store.stoppingRecording ? "square.and.arrow.down" : store.isRecording ? "waveform" : "waveform.badge.magnifyingglass").font(.system(size: 42)).foregroundStyle(Ink.accent)
            Text(store.stoppingRecording ? L("Сохраняю запись") : store.isRecording ? L("Идёт запись") : L("Запись сохранена")).font(.title3.weight(.semibold))
            if !store.isRecording {
                Button(store.runtimeReady ? (store.settings.speechMode == "cloud" ? L("Распознать в облаке…") : L("Распознать встречу")) : L("Установить модели")) {
                    if store.runtimeReady { Task { await store.processMeeting(meeting.id) } }
                    else { store.openSettings("speech") }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).controlSize(.large).disabled(store.jobs.contains(objectID: meeting.id))
            }
            if let error = meeting.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}
