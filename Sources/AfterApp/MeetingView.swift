import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

struct MeetingView: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    @State private var folderEditor: FolderEditorTarget?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    MeetingTitleHeading(store: store, edits: store.meetingTitleEdits, meeting: meeting)
                    Spacer(minLength: 10)
                    Menu {
                        Button(L("Переместить в папку…")) {
                            NotificationCenter.default.post(name: Notification.Name("PosleMoveMeeting"), object: meeting.id)
                        }.disabled(store.isMeetingMediaProtected(meeting.id))
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
                        Button(L("Переименовать…")) { store.meetingTitleEdits.begin(meeting) }.disabled(store.isMeetingMediaProtected(meeting.id))
                        Button(L("Распознать заново")) { Task { await store.processMeeting(meeting.id) } }.disabled(!store.runtimeReady || store.isMeetingMediaProtected(meeting.id) || store.jobs.contains(objectID: meeting.id) || meeting.libraryKind == "cards")
                        Divider()
                        MeetingFileActions(meeting: meeting) { confirmDelete = true }
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
                        .disabled(store.isMeetingMediaProtected(meeting.id))
                    if store.effectiveSettings(for: meeting.id).features.knowledgeBase {
                        MeetingKnowledgeBacklinks(meetingID:meeting.id)
                    }

                }.font(AppTypography.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, AppLayout.contentInset).padding(.top, 22).padding(.bottom, 18)
            AppTabBar(label: L("Раздел встречи"), selection: $store.tab, tabs: meetingTabs,
                      identifier: "meeting.tabs.control", fillsWidth: true)
                .padding(.horizontal, AppLayout.contentInset).padding(.bottom, 16)
                .appLayoutAnchor("meeting.tabs")
            if let job = store.jobs.jobs.first(where: { $0.active && $0.objectID == meeting.id }) {
                HStack(spacing: 8) {
                    if job.state == "running" { ProgressView().controlSize(.small) }
                    Text(BackgroundJobPresentation.title(job) + " · " + L(job.stateLabel)).font(AppTypography.caption).lineLimit(1)
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
            .alert(L("Переместить встречу в Корзину?"), isPresented: $confirmDelete) {
                Button(L("Отмена"), role: .cancel) {}
                Button(L("В Корзину"), role: .destructive) { store.trashMeeting(meeting.id) }
            } message: { Text(L("Встречу и все её материалы можно будет восстановить в Корзине приложения в течение 30 дней.")) }
    }
    private var meetingTabs: [AppTab<String>] {
        var result = [AppTab(L("Заметки"), value: "notes")]
        if meeting.libraryKind != "cards" {
            result.append(AppTab(L("Конспект"), value: "summary"))
            result.append(AppTab(L("Транскрипт"), value: "transcript"))
        }
        if store.effectiveSettings(for: meeting.id).features.cards {
            result.append(AppTab(L("Карточки"), value: "cards"))
        }
        return result
    }

    private var unprocessed: some View {
        let saving = store.isMeetingSaving(meeting.id)
        let recording = store.captureMeetingID == meeting.id
        let playback = store.playbackURL(for: meeting.id)
        let source = store.sourceMediaURL(for: meeting.id)
        return VStack(spacing: 16) {
            Image(systemName: saving ? "square.and.arrow.down" : recording ? "waveform" : source == nil && playback == nil ? "waveform.slash" : "waveform.badge.magnifyingglass")
                .font(.system(size: 42)).foregroundStyle(Ink.accent)
            Text(saving ? L("Сохраняю запись") : recording ? L("Идёт запись") : source == nil && playback == nil ? L("Медиафайл недоступен") : L("Запись сохранена"))
                .font(.title3.weight(.semibold)).accessibilityIdentifier("meeting.mediaStatus")
            if !saving && !recording {
                if playback == nil, source != nil {
                    Text(L("Исходная запись доступна. Её можно открыть или сохранить до распознавания."))
                        .font(AppTypography.control).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button(L("Открыть исходную запись")) { store.openMeetingSource(meeting.id) }
                            .accessibilityIdentifier("meeting.source.open")
                        Button(L("Сохранить исходную запись…")) { store.exportMeetingAudio(meeting.id, original: true) }
                            .accessibilityIdentifier("meeting.source.export")
                    }.buttonStyle(.bordered)
                } else if playback == nil {
                    Text(L("Откройте файлы встречи, чтобы проверить исходную запись."))
                        .font(AppTypography.control).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L("Показать файлы встречи")) { store.showMeetingFiles(meeting.id) }.buttonStyle(.bordered)
                }
                if source != nil || playback != nil {
                    Button(store.runtimeReady ? (store.settings.speechMode == "cloud" ? L("Распознать в облаке…") : L("Распознать встречу")) : L("Установить модели")) {
                        if store.runtimeReady { Task { await store.processMeeting(meeting.id) } }
                        else { store.openSettings("speech") }
                    }.buttonStyle(.borderedProminent).tint(Ink.actionFill).controlSize(.large).disabled(store.jobs.contains(objectID: meeting.id))
                }
            }
            if let error = meeting.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

/// The same file actions remain reachable before transcription, in the meeting
/// header, sidebar context menu and player. The confirmation captures its ID.
struct MeetingFileActions: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    let trash: () -> Void
    var body: some View {
        if store.selection == meeting.id {
            Button(L("Конспект и транскрипция (.md)")) { store.export(false) }
                .disabled(store.transcript == nil && store.summary == nil)
            if store.isFeatureEnabled(.cards) {
                Button(L("Карточки для Anki (.tsv)")) { store.export(true) }.disabled(store.summary?.cards.isEmpty ?? true)
            }
        }
        Button(L("Аудиозапись (.mp3)")) { store.exportMeetingAudio(meeting.id) }
            .disabled(store.playbackURL(for: meeting.id) == nil).accessibilityIdentifier("meeting.audio.export")
        if store.sourceMediaURL(for: meeting.id) != nil {
            Button(L("Открыть исходную запись")) { store.openMeetingSource(meeting.id) }
            Button(L("Сохранить исходную запись…")) { store.exportMeetingAudio(meeting.id, original: true) }
        }
        if meeting.hasVideo {
            Button(L("Открыть видео (.mp4)")) { store.openMeetingVideo(meeting.id) }
                .disabled(store.isMeetingMediaProtected(meeting.id))
        }
        Button(L("Показать файлы встречи")) { store.showMeetingFiles(meeting.id) }
        Divider()
        Button(L("Переместить в Корзину"), role: .destructive, action: trash)
            .disabled(!store.canTrashMeeting(meeting.id)).accessibilityIdentifier("meeting.trash")
    }
}
