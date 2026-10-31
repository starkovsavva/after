import AfterPlatform
import AfterPlatformMacOS
import AfterLocalization
import AppKit
import Combine
import AfterCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    struct TaskHistoryRoute: Equatable {
        let taskID: String
        let eventID: String
        let artifactID: String?
        let plan: AssistantReadPlan
        let target: AssistantReadTarget
        let nonce = UUID()
    }
    @Published var taskHistoryRoute: TaskHistoryRoute?
    @Published var meetings: [Meeting] = []
    @Published var folderSelection: String? { didSet { if folderSelection != oldValue, featureLifecycleReady { folderSelectionDidChange() } } }
    struct SidebarPreferences: Codable { var foldersExpanded = true }
    @Published private(set) var foldersExpanded = true
    @Published var librarySection = "meetings"
    let notes: NotesStore
    let calendar: CalendarStore
    let trackerSync: TrackerSyncCoordinator
    let updates = AppUpdateController()
    let voice = VoiceCommandController()
    let meetingTitleEdits = MeetingTitleEdits()
    var assistantCardMeetingID: String?
    let jobs: BackgroundJobsController
    private var jobsSubscription: AnyCancellable?
    private var folderSubscription: AnyCancellable?
    private var notesSubscription: AnyCancellable?
    private var languageSubscription: AnyCancellable?
    private var lifecycleFeatures: AppFeatures?
    @Published var startingRecording = false
    @Published var isTerminating = false
    var isPreview: Bool { preview }
    var quickCaptureAction: (() -> Void)?
    var bookmarkAction: (() -> Void)?
    var captureMeetingID: String? { isRecording ? recordingID : nil }
    @Published var selection: String?
    @Published var transcript: Transcript? {
        didSet {
            if oldValue?.segments != transcript?.segments {
                transcriptRevision &+= 1
                // Match the previous first(where:) behavior for legacy duplicate IDs.
                transcriptSegments = Dictionary((transcript?.segments ?? []).map { ($0.id, $0) },
                                                uniquingKeysWith: { first, _ in first })
            }
        }
    }
    @Published var summary: Summary? {
        didSet {
            if oldValue?.generatedAt != summary?.generatedAt || oldValue?.overview != summary?.overview
                || oldValue?.items != summary?.items || oldValue?.overviewClaims != summary?.overviewClaims
                || oldValue?.sourceStale != summary?.sourceStale || oldValue?.overviewStale != summary?.overviewStale {
                summaryRevision &+= 1
            }
        }
    }
    private(set) var transcriptRevision: UInt64 = 0
    private(set) var summaryRevision: UInt64 = 0
    private var transcriptSegments: [Int: Segment] = [:]
    func transcriptSegment(_ id: Int, meetingID: String? = nil) -> Segment? {
        guard meetingID == nil || (loadedSelectionID == meetingID && selection == meetingID) else { return nil }
        return transcriptSegments[id]
    }
    @Published var examples: [String: CardExample] = [:]
    @Published var reviews: [String: ReviewState] = [:]
    @Published var settings = AppSettings() {
        didSet {
            if !Self.sameCloudCheckConfiguration(settings, oldValue) { clearCloudConnectionResult() }
            if featureLifecycleReady, settings.features != oldValue.features { applyFeatureChanges(previous: oldValue.features) }
        }
    }
    @Published var busy = false
    @Published var canCancelJob = false
    @Published var processingID: String?
    @Published var progress = -1.0
    @Published var progressText = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var editingOverview = false
    struct OverviewDraft: Codable, Equatable {
        var text: String
        var original: String
        var generatedAt: Double
    }
    @Published private(set) var overviewDrafts: [String: OverviewDraft] = [:]
    private var overviewDraftsDirty = false
    @Published var showingSettings = false
    @Published var showingSupport = false
    var supportFeedbackPending = false
    @Published var settingsSection = "general"
    @Published var integrationSettingsSection = "trackers"
    @Published var showingRecord = false
    @Published var showingCaptureDrafts = false
    var recoveryCaptureDraftKey = "inbox"
    @Published var showingSearch = false
    @Published var searchQuery = ""
    @Published var searchScope = "all"
    @Published var searchHits: [SearchHit] = []
    @Published var searchTotal = 0
    @Published var searchTruncated = false
    @Published var searching = false
    @Published var searchOpeningID: String?
    @Published var searchError: String?
    @Published var searchWarnings: [String] = []
    @Published var navigationTarget: NavigationTarget?
    struct NavigationTarget: Identifiable {
        let id = UUID()
        let meetingID: String
        let kind: String
        var segmentID: Int?
        var itemIndex: Int?
        var cardID: String?
    }
    private var loadedSelectionID: String?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    @Published var runtimeReady = false
    @Published var tab = "summary"
    @Published var libraryFilter = ""
    @Published var transcriptSearch = ""
    @Published var isPlaying = false
    @Published var playbackTime = 0.0
    @Published var playbackDuration = 1.0
    @Published var cloudConnectionStatus: String?
    @Published var cloudConnectionError = false
    @Published private(set) var cloudConnectionDiagnostic: ChatGPTDiagnosticReport?
    var cloudCheckAccountID: String?
    @Published var disconnectingChatGPTAccounts: Set<String> = []
    @Published var localStatus = ""
    @Published var installedLocalModels: [InstalledLocalModel] = []
    @Published var installedASRModels: [InstalledASRModel] = []
    @Published var installedGGUFModels: [InstalledGGUFModel] = []
    @Published var ggufStatus = ""
    @Published var ggufNotes: [String] = []
    @Published private(set) var verifiedASRSelection: String?
    var asrSelectionIdentity: String { [settings.speechLocalModel, settings.asrModelPath, settings.asrModelFormat].joined(separator: "\u{1F}") }
    var selectedASRVerified: Bool { verifiedASRSelection == asrSelectionIdentity }
    @Published var asrStatus = ""
    @Published var asrNotes: [String] = []
    private var modelsByProvider: [String: String] = [:]
    private var endpointsByProvider: [String: String] = [:]
    @Published var isRecording = false
    @Published var stoppingRecording = false
    @Published var finalizingMeetingIDs: Set<String> = []
    var processAfterRecording = true
    var recordingFolderFailures: Set<String> = []
    @Published var recordingDate: Date?

    let root: URL
    let runner = ProcessRunner()
    let embeddedSpeech = EmbeddedSpeechService()
    private let mediaPlatform: ApplicationMediaServices
    let recorder: any MeetingRecordingBackend
    let audioLevels = AudioLevels()
    let localService = LocalModelService()
    let localRuntimeLease = LocalRuntimeLease()
    var knowledgeRebuildRunner: ProcessRunner?
    var knowledgeRebuildRunID: UUID?
    var knowledgeRebuildCloudAccountID: String?
    var knowledgeRebuildOwnsLocalRuntime = false
    var knowledgeRebuildCancelled = false
    private var player: (any AudioPlaybackSession)?
    private var playbackGeneration = UUID()
    var recordingID: String?
    var startingRecordingID: String?
    var recordingStartTask: Task<Void, Error>?
    var pendingRecordingFailure: RecordingFailure?
    let processingSleepLease: any IdleSleepPreventing
    let recordingSleepLease: any IdleSleepPreventing
    var cancellationRequested = false
    private var jobGeneration = UUID()
    private var confirmingCloudSpeech = false
    static var stoppedProcessingMessage: String { L("Обработка остановлена. Запись сохранена.") }
    private var preview: Bool
    private var featureLifecycleReady = false

    var selected: Meeting? { meetings.first { $0.id == selection } }
    var selectedDirectory: URL? { selection.map { meetingDirectory($0) } }
    var filteredMeetings: [Meeting] {
        meetings.filter { $0.libraryKind != "cards" && (folderSelection == nil || folderID(for: $0.id) == folderSelection) && (libraryFilter.isEmpty || $0.title.localizedCaseInsensitiveContains(libraryFilter)) }
    }
    var dueCards: [Flashcard] {
        (summary?.cards ?? []).filter { reviews[$0.id]?.isDue ?? true }
    }
    var backend: URL {
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("backend")
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("engine.py").path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("backend")
    }
    var python: URL { root.appendingPathComponent("runtime/venv/bin/python") }
    var rustEngine: URL {
        #if DEBUG
        // Only isolated developer diagnostics may select another executable.
        if let path = ProcessInfo.processInfo.environment["POSLE_RUST_ENGINE"] { return URL(fileURLWithPath: path) }
        #endif
        let helperDirectory = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/После Обработка.app/Contents/MacOS")
        // Keep a fallback for an older bundle during an interrupted update.
        for executable in ["After Processing", "После Обработка"] {
            let helper = helperDirectory.appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        }
        let current = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/After Engine")
        if FileManager.default.isExecutableFile(atPath: current.path) { return current }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/posle-engine")
    }

    init(preview: Bool = false, recorder: (any MeetingRecordingBackend)? = nil,
         executor: JobCoordinator.Executor? = nil, platform: ApplicationMediaServices? = nil) {
        let platform = platform ?? .macOS
        self.mediaPlatform = platform
        self.processingSleepLease = platform.makeSleepLease(); self.recordingSleepLease = platform.makeSleepLease()
        self.preview = preview; self.recorder = recorder ?? platform.makeRecorder()
        let dataRoot: URL
        if let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] { dataRoot = URL(fileURLWithPath: path) }
        else {
            dataRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(preview ? "PoslePreview" : "Posle")
        }
        root = dataRoot
        UILocalization.shared.configure(root: dataRoot)
        jobs = BackgroundJobsController(root: dataRoot)
        let initialNotes = NotesStore(root: dataRoot)
        notes = initialNotes
        let initialSettings = (try? Data(contentsOf: dataRoot.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        let initialFeatures = initialNotes.workspace.folders.reduce(initialSettings.features) { result, folder in
            var value = result
            let effective = folder.overrides.apply(to: initialSettings).features
            for feature in AppFeature.allCases { value[feature] = value[feature] || effective[feature] }
            return value
        }
        calendar = CalendarStore(root: dataRoot, preview: preview, featureEnabled: initialFeatures.calendar, tasksEnabled: initialFeatures.tasks)
        trackerSync = TrackerSyncCoordinator(root: dataRoot)
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            if let saved: AppSettings = read(root.appendingPathComponent("settings.json")) { settings = saved }
            overviewDrafts = read(root.appendingPathComponent("overview-drafts.json")) ?? [:]
            if let sidebar: SidebarPreferences = read(root.appendingPathComponent("sidebar-state.json")) { foldersExpanded = sidebar.foldersExpanded }
            // Finish only previously committed, explicitly authorized operations.
            do { _ = try RustBridge.shared.get().request(root: root, command: "voice-recover") }
            catch { self.error = "Не удалось завершить прерванное поручение: \(error.localizedDescription)" }
            librarySection = ["meetings", "inbox", "tasks", "cards", "knowledge"].contains(settings.startSection) && settings.allowsSection(settings.startSection) ? settings.startSection : "meetings"
            runtimeReady = FileManager.default.isExecutableFile(atPath: python.path)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/ready-v2").path)
            reloadLibrary()
            selection = meetings.first?.id
            loadSelection()
        } catch { self.error = error.localizedDescription }
        calendar.taskIsEnabled = { [weak self] task in self?.settingsForTask(task).features.tasks == true }
        calendar.bindNotes(notes)
        voice.connect(self)
        jobs.reopenVoiceCommand = { [weak self] job in self?.voice.reopenFailedCommand(job) }
        jobs.restartWithCurrentProfile = { [weak self] job in self?.restartProfileFailedJob(job) }
        jobsSubscription = jobs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let executor { jobs.connect(executor) }
        else {
            jobs.connect { [weak self] job, cancellation, event in
                guard let self else { throw CancellationError() }
                return try await self.executeBackgroundJob(job, cancellation: cancellation, event: event)
            }
        }
        trackerSync.connectionIsEnabled = { [weak self] config in
            guard let self, let (profile, _) = try? self.folderProfile(folderID: config.folderID) else { return false }
            return profile.features?.tasks ?? self.effectiveSettings(folderID: config.folderID).features.tasks
        }
        notesSubscription = notes.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        languageSubscription = NotificationCenter.default.publisher(for: .posleUILanguageChanged).receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.notes.objectWillChange.send(); self.calendar.objectWillChange.send(); self.jobs.objectWillChange.send()
        }
        featureLifecycleReady = true
        applyFeatureChanges()
        folderSubscription = notes.$workspace.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            if let id = self.folderSelection, !self.notes.workspace.folders.contains(where: { $0.id == id }) { self.folderSelection = nil }
            self.applyFeatureChanges()
            self.objectWillChange.send()
        }
        self.recorder.levels = { [weak self] microphone, system in
            Task { @MainActor in self?.audioLevels.receive(microphone: microphone, system: system) }
        }
        self.recorder.microphoneStatus = { [weak self] update in
            Task { @MainActor in
                guard let self, !self.stoppingRecording, !self.isTerminating,
                      (self.startingRecording && self.startingRecordingID == update.sessionID)
                        || (self.isRecording && self.recordingID == update.sessionID) else { return }
                self.audioLevels.receive(state: update.state)
            }
        }
        self.recorder.failed = { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                if self.startingRecording, self.startingRecordingID == failure.sessionID {
                    self.pendingRecordingFailure = failure
                    return
                }
                guard self.isRecording, self.recordingID == failure.sessionID else { return }
                if failure.userInitiated {
                    await self.stopRecording(finalize: false)
                    if self.error == nil { self.notice = L("Запись завершена в macOS. Исходная запись сохранена; обработку можно запустить во встрече.") }
                } else {
                    self.error = LF("Запись прервалась: {0}. Завершаю сохранение доступного аудио.", arguments: [failure.message])
                    await self.stopRecording()
                }
            }
        }
    }

    /// Layout preferences do not alter processing profiles or library content.
    @discardableResult
    func setFoldersExpanded(_ expanded: Bool) -> Bool {
        guard foldersExpanded != expanded else { return true }
        do {
            try write(SidebarPreferences(foldersExpanded: expanded), root.appendingPathComponent("sidebar-state.json"))
            foldersExpanded = expanded
            return true
        } catch {
            self.error = L("Не удалось сохранить вид папок. ") + error.localizedDescription
            return false
        }
    }
    private func folderSelectionDidChange() {
        if !visibleFeaturesSection(librarySection) { librarySection = "meetings" }
        if !filteredMeetings.contains(where: { $0.id == selection }) {
            selection = filteredMeetings.first?.id; loadSelection()
        }
        if showingSearch { updateSearch(immediate: true) }
        NotificationCenter.default.post(name: Notification.Name("PosleShortcutsChanged"), object: nil)
    }
    private func visibleFeaturesSection(_ section: String) -> Bool {
        switch section {
        case "cards": visibleFeatures.cards
        case "tasks", "contexts": visibleFeatures.tasks
        case "calendar": visibleFeatures.calendar
        default: true
        }
    }
    private func applyFeatureChanges(previous: AppFeatures? = nil) {
        let features = availableFeatures
        let before = lifecycleFeatures
        lifecycleFeatures = features
        if !visibleFeaturesSection(librarySection) { librarySection = "meetings" }
        if !effectiveSettings(for: selection).features.cards, tab == "cards" { tab = "summary" }
        if !features.assistant { voice.dismiss() }
        calendar.setFeatureEnabled(features.calendar, tasksEnabled: features.tasks)
        if !preview, features.semanticSearch {
            SemanticIndexController.shared.connect(self)
            SemanticIndexController.shared.requestRefresh()
        } else if !preview { SemanticIndexController.shared.stop() }
        if before?.tasks != features.tasks {
            trackerSync.stop()
            if !preview, features.tasks {
                trackerSync.start(isIdle: { [weak self] in
                    guard let self else { return false }
                    return self.availableFeatures.tasks && !self.isTerminating && !self.startingRecording && !self.isRecording && !self.stoppingRecording && !self.busy && self.jobs.activeCount == 0
                }, onChange: { [weak self] in
                    self?.notes.reload(); self?.notes.loadTasks(); self?.notes.loadTaskWorkspaces()
                })
            }
        }
        if showingSearch { updateSearch(immediate: true) }
        NotificationCenter.default.post(name: Notification.Name("PosleShortcutsChanged"), object: nil)
    }

    func meetingDirectory(_ id: String) -> URL { root.appendingPathComponent("meetings/\(id)") }
    func read<T: Decodable>(_ url: URL) -> T? {
        guard let bridge = try? RustBridge.shared.get(), let data = try? bridge.read(root: root, url: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try RustBridge.shared.get().write(root: root, url: url, value: value)
    }
    func openSettings(_ section: String = "general", integrationSection: String? = nil) {
        if let integrationSection, ["trackers", "agents"].contains(integrationSection) {
            integrationSettingsSection = integrationSection
        }
        settingsSection = section
        showingSettings = true
    }
    func openSupport() {
        guard !isTerminating, !showingSupport else { return }
        if GuidanceController.shared.presentation != nil {
            GuidanceController.shared.complete(with: .support)
        } else if !showingSettings && !showingRecord && !showingSearch && !showingCaptureDrafts {
            showingSupport = true
        }
    }
    func openBugReport() {
        guard !isTerminating else { return }
        let profile = librarySection == "meetings" ? effectiveSettings(for: selection, folderID: folderSelection) : activeSettings
        let failure = jobs.jobs.filter { ["failed", "interrupted"].contains($0.state) }.max { $0.updatedAt < $1.updatedAt }
        BugReportController.shared.present(settings: profile, lastFailure: failure)
    }
    var canPresentGuidance: Bool {
        !isRecording && !startingRecording && !stoppingRecording && !isTerminating && !busy
            && jobs.activeCount == 0 && !voice.isWorking && !voice.isPresented && !trackerSync.busy
            && !notes.attachmentBusy && !notes.taskWorkspaceBusy && !editingOverview && !notes.editingNewTask
            && !showingSettings && !showingSupport && !showingRecord && !showingSearch && !showingCaptureDrafts
            && !notes.hasUnsavedCaptureDrafts && !UnsavedEditorRegistry.hasUnsaved && !SettingsDraftRegistry.hasUnsaved
            && NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
    }
    func updateGuidanceContext(_ guide: GuidanceController) {
        guide.updateFeatures(availableFeatures)
        var stored: Set<String> = []
        if meetings.contains(where: { $0.source.hasPrefix("recording.") }) { stored.insert("recording") }
        if meetings.contains(where: { !$0.source.isEmpty && !$0.source.hasPrefix("recording.") && $0.libraryKind != "cards" }) { stored.insert("import") }
        if summary != nil || meetings.contains(where: { $0.status == "ready" }) { stored.insert("summary") }
        if !calendar.links.isEmpty { stored.insert("calendar") }
        if !notes.tasks.isEmpty { stored.insert("tasks") }
        guide.seedUsage(stored)
    }
    @discardableResult func saveSettings() -> Bool {
        do {
            try write(settings, root.appendingPathComponent("settings.json"))
            NotificationCenter.default.post(name: Notification.Name("PosleShortcutsChanged"), object: nil)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func reloadLibrary() {
        struct Library: Decodable { var meetings: [Meeting] }
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "list")
            meetings = try JSONDecoder().decode(Library.self, from: data).meetings
        } catch { self.error = error.localizedDescription; return }
        // Interrupted jobs stay retryable. Never discard an existing source or transcript.
        for i in meetings.indices where ["processing", "recording"].contains(meetings[i].status) && !busy && !isRecording && !jobs.contains(objectID: meetings[i].id) {
            meetings[i].status = FileManager.default.fileExists(atPath: meetingDirectory(meetings[i].id).appendingPathComponent("transcript.json").path)
                ? "transcribed" : "imported"
            meetings[i].error = L("Предыдущая обработка прервалась. Можно продолжить.")
            try? write(meetings[i], meetingDirectory(meetings[i].id).appendingPathComponent("meta.json"))
        }
    }
    func selectionDidChange() {
        if loadedSelectionID != selection { loadSelection() }
    }
    func loadSelection() {
        // Removing an AVPlayer observer does not cancel a MainActor task that
        // its callback already queued for the previously loaded recording.
        playbackGeneration = UUID()
        loadedSelectionID = selection
        if selected?.libraryKind == "cards", effectiveSettings(for: selection).features.cards { tab = "cards" }
        if tab == "cards", !effectiveSettings(for: selection).features.cards { tab = "summary" }
        navigationTarget = nil
        pause()
        player?.invalidate()
        player = nil; playbackTime = 0
        transcriptSearch = ""
        guard let directory = selectedDirectory else { transcript = nil; summary = nil; return }
        transcript = read(directory.appendingPathComponent("transcript.json"))
        summary = read(directory.appendingPathComponent("summary.json"))
        examples = read(directory.appendingPathComponent("examples.json")) ?? [:]
        reviews = read(directory.appendingPathComponent("review-state.json")) ?? [:]
        playbackDuration = max(transcript?.duration ?? selected?.duration ?? 1, 1)
        prepareSelectedPlayback()
    }
    /// Reattach newly finalized audio without resetting navigation or editors.
    func prepareSelectedPlayback() {
        playbackGeneration = UUID()
        pause()
        player?.invalidate(); player = nil
        guard let id = selection, let playback = playbackURL(for: id) else { return }
        let generation = playbackGeneration
        let player = mediaPlatform.makePlayback(playback)
        self.player = player
        let updateTime = playbackTimeCallback()
        player.observeTime { time in
            _ = updateTime(time)
        }
        Task { [weak self] in
            guard let duration = try? await player.duration(), duration.isFinite, duration > 0,
                  let self, self.playbackGeneration == generation, self.selection == id else { return }
            self.playbackDuration = duration
        }
    }
    private func playbackTimeCallback() -> @Sendable (Double) -> Task<Void, Never> {
        let generation = playbackGeneration, meetingID = loadedSelectionID
        return { [weak self] time in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation,
                      self.loadedSelectionID == meetingID, self.selection == meetingID else { return }
                self.playbackTime = time.isFinite ? time : 0
                if self.playbackTime >= self.playbackDuration - 0.2 { self.isPlaying = false }
            }
        }
    }
    #if DEBUG
    /// Drives the real callback queue with invented timestamps, without an
    /// audio asset or output device. Awaiting its task makes late delivery deterministic.
    func playbackTimeCallbackForChecks() -> @Sendable (Double) -> Task<Void, Never> { playbackTimeCallback() }
    func muteMeetingPlaybackForChecks() { player?.isMuted = true }
    var meetingPlayerReadyForChecks: Bool { player?.isReady == true }
    #endif
    func refreshResults(_ id: String) {
        if selection == id {
            navigationTarget = nil
            let directory = meetingDirectory(id)
            transcript = read(directory.appendingPathComponent("transcript.json"))
            summary = read(directory.appendingPathComponent("summary.json"))
            examples = read(directory.appendingPathComponent("examples.json")) ?? [:]
            reviews = read(directory.appendingPathComponent("review-state.json")) ?? [:]
            // A worker can create playable audio before ASR fails or is cancelled.
            // Attach it on result refresh without resetting the current editor.
            if player == nil, playbackURL(for: id) != nil { prepareSelectedPlayback() }
        }
    }
    func updateMeeting(_ id: String, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let url = meetingDirectory(id).appendingPathComponent("meta.json")
        // Finalization can replace a temporary MOV with MP3 in the worker.
        // Always patch its latest metadata, including after cancellation/error.
        guard var current: Meeting = read(url) else {
            error = L("Не удалось прочитать данные встречи. Откройте её заново.")
            return
        }
        let original = current
        change(&current)
        do {
            let encoder = JSONEncoder()
            guard let before = try JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any],
                  let after = try JSONSerialization.jsonObject(with: encoder.encode(current)) as? [String: Any] else {
                throw AppError.message(L("Не удалось подготовить изменения встречи."))
            }
            var patch: [String: Any] = [:]
            for key in Set(before.keys).union(after.keys) {
                let previous = (before[key] as? NSObject) ?? NSNull()
                let next = (after[key] as? NSObject) ?? NSNull()
                if !previous.isEqual(next) { patch[key] = next }
            }
            let data = try RustBridge.shared.get().request(root: root, command: "update", arguments: ["id": id, "patch": patch])
            meetings[index] = try JSONDecoder().decode(Meeting.self, from: data)
        } catch { self.error = error.localizedDescription }
    }

    func renameSpeaker(_ key: String, name: String) {
        guard let id = selection else { return }
        updateMeeting(id) { $0.speakerNames[key] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func taskCompleted(_ item: Insight) -> Bool {
        if let meetingID = selection,
           let note = notes.notes.first(where: { note in
               guard let origin = note.taskOrigin else { return false }
               return origin.meetingID == meetingID && origin.sourceText == item.text && origin.segmentIDs == item.segmentIDs
           }) { return note.completed }
        return selected?.completedTasks.contains(item.id) == true
    }
    func toggleTask(_ item: Insight) {
        guard effectiveSettings(for: selection).features.tasks else { openSettings("features"); return }
        guard let id = selection, let index = summary?.items.firstIndex(where: { $0.id == item.id }) else { return }
        do {
            _ = try RustBridge.shared.get().request(root: root, command: "notes-task-complete", arguments: [
                "meetingID": id, "itemIndex": index, "text": item.text, "expectedSegmentIDs": item.segmentIDs, "completed": !taskCompleted(item)
            ])
            notes.reload(); notes.loadTasks(); reloadLibrary()
        } catch { self.error = error.localizedDescription }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3, .wav]
        panel.allowsMultipleSelection = false
        panel.message = L("Добавьте запись встречи на русском или английском")
        if panel.runModal() == .OK, let url = panel.url { importFile(url) }
    }
    func importFile(_ source: URL) {
        guard !isTerminating else { return }
        guard !busy, !startingRecording else { error = L("Дождитесь сохранения файла или завершения настройки компонентов."); return }
        let ext = source.pathExtension.lowercased()
        guard ["mp4", "mov", "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "webm", "mkv", "aac"].contains(ext) else {
            error = L("Добавьте аудио или видео: MP4, MOV, M4A, MP3, WAV, FLAC или WebM."); return
        }
        canCancelJob = false
        busy = true; progress = -1; progressText = L("Сохраняю запись…"); error = nil
        let focus = ""
        let destinationFolderID = folderSelection
        let root = self.root
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    return try RustBridge.shared.get().request(root: root, command: "import", arguments: ["source": source.path, "focus": focus])
                }.value
                let meeting = try JSONDecoder().decode(Meeting.self, from: data)
                GuidanceController.shared.recordUsage("import", root: root)
                busy = false
                let assigned = destinationFolderID.map { notes.assignMeetingFolder(meeting.id, folderID: $0) } ?? true
                // The destination was chosen before the asynchronous copy. Open
                // that saved meeting even if the sidebar or its folder changed.
                folderSelection = notes.context(for: meeting.id).folderID; libraryFilter = ""
                reloadLibrary(); librarySection = "meetings"; selection = meeting.id; tab = "transcript"; loadSelection()
                guard assigned else { error = L("Запись сохранена без папки. Выберите папку перед обработкой."); return }
                applyDefaultNoteTemplate(to: meeting.id)
                if runtimeReady { await processMeeting(meeting.id) }
                else { notice = L("Запись сохранена. Установите модели один раз, чтобы начать распознавание."); showingSettings = true }
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }

    private var runtimeWorkCancelled: Bool { cancellationRequested || isTerminating }

    @discardableResult
    func worker(_ command: String, id: String? = nil, extra: [String] = [], input: Data? = nil) async throws -> WorkerEvent? {
        guard !isTerminating else { throw CancellationError() }
        if Self.queuedCommands.contains(command) { return try await queuedWorker(command, id: id, extra: extra, input: input) }
        let lease: UUID?
        if ["prepare", "install-local", "check", "pull", "discover-local", "import-gguf"].contains(command) {
            lease = try await localRuntimeLease.acquire { [weak self] in
                guard let self else { return true }
                return await self.runtimeWorkCancelled
            }
        } else { lease = nil }
        defer { if let lease { Task { await localRuntimeLease.release(lease) } } }
        return try await utilityWorker(command, id: id, extra: extra, input: input)
    }

    @discardableResult
    private func utilityWorker(_ command: String, id: String? = nil, extra: [String] = [], input: Data? = nil) async throws -> WorkerEvent? {
        guard !cancellationRequested, !isTerminating else { throw CancellationError() }
        let configuration = settings
        if ["install-local", "import-gguf"].contains(command) && !runtimeReady {
            throw AppError.message(L("Сначала подготовьте распознавание в настройках."))
        }
        if command == "pull" && configuration.localProvider != "managed" {
            throw AppError.message(L("Выберите установленную модель в настройках. Для Ollama и LM Studio скачивание выполняется в самом приложении."))
        }
        try write(configuration, root.appendingPathComponent("settings.json"))
        if ["check", "pull", "discover-local", "import-gguf"].contains(command) {
            try await localService.ensure(root: root, settings: configuration, cancelled: { self.cancellationRequested })
        }
        guard !cancellationRequested else { throw AppError.message(L("Обработка остановлена. Запись сохранена.")) }
        var arguments = [command, "--root", root.path, "--backend", backend.path]
        if let id { arguments += ["--meeting", meetingDirectory(id).path] }
        arguments += extra
        // Secrets live only in Keychain and the short-lived child environment, never argv/files.
        var environment = ["PYTHONUNBUFFERED": "1", "HF_HOME": root.appendingPathComponent("cache/huggingface").path,
                           "HF_HUB_DISABLE_TELEMETRY": "1", "POSLE_OLLAMA_URL": localService.baseURL,
                           "POSLE_JOB_SETTINGS": WorkerEnvironment.json(try JSONEncoder().encode(configuration))]
        if configuration.mode == "cloud" && command == "check-cloud" {
            environment["POSLE_API_KEY"] = try await cloudCredential(for: configuration)
        }
        guard !cancellationRequested, !isTerminating else { throw CancellationError() }
        let generation = jobGeneration
        let receive: @Sendable (WorkerEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                guard let self, self.busy, self.jobGeneration == generation, !self.cancellationRequested else { return }
                if let message = event.message { self.progressText = message }
                if let fraction = event.fraction { self.progress = fraction }
            }
        }
        // Recording/AI jobs always enter queuedWorker above. Utilities have no
        // second transcription/generation path with a different profile policy.
        let result = try await runner.run(rustEngine, arguments: arguments, environment: environment, input: input, event: receive)
        try Task.checkCancellation()
        guard !cancellationRequested, !isTerminating else { throw CancellationError() }
        if let models = result?.installedModels { installedLocalModels = models }
        if let models = result?.models {
            installedLocalModels = models.map { InstalledLocalModel(id: $0, name: $0, provider: configuration.localProvider, endpoint: localService.baseURL) }
        }
        if let models = result?.asrModels { installedASRModels = models }
        if let models = result?.ggufModels { installedGGUFModels = models }
        if let notes = result?.notes {
            if command == "discover-models" { asrNotes = notes }
            if command == "discover-gguf" { ggufNotes = notes }
        }
        return result
    }
    func checkCloudConnection() {
        guard !busy, !isRecording else { return }
        beginJob(id: nil); progressText = L("Проверяю подключение…")
        clearCloudConnectionResult()
        let configuration = settings
        cloudCheckAccountID = configuration.cloudProvider == "chatgpt" ? configuration.chatGPTAccountID : nil
        Task {
            defer { cloudCheckAccountID = nil; endJob() }
            do {
                try await worker("check-cloud")
                guard Self.sameCloudCheckConfiguration(settings, configuration) else { return }
                cloudConnectionStatus = L("Подключение работает")
            } catch {
                guard Self.sameCloudCheckConfiguration(settings, configuration) else { return }
                recordCloudConnectionFailure(error, configuration: configuration)
            }
        }
    }
    func clearCloudConnectionResult() {
        cloudConnectionStatus = nil; cloudConnectionError = false; cloudConnectionDiagnostic = nil
    }

    func recordCloudConnectionFailure(_ error: Error, configuration: AppSettings) {
        guard Self.sameCloudCheckConfiguration(settings, configuration) else { return }
        cloudConnectionError = true; cloudConnectionStatus = error.localizedDescription
        cloudConnectionDiagnostic = nil
        if configuration.cloudProvider == "chatgpt", let diagnostic = (error as? WorkerFailure)?.chatGPTDiagnostics {
            cloudConnectionDiagnostic = ChatGPTDiagnosticReport(diagnostics: diagnostic, settings: configuration)
        }
    }

    @discardableResult
    func copyCloudConnectionDiagnostic(to pasteboard: NSPasteboard = .general) -> Bool {
        guard cloudConnectionError, settings.cloudProvider == "chatgpt", let report = cloudConnectionDiagnostic else { return false }
        return report.copy(to: pasteboard)
    }

    private static func sameCloudCheckConfiguration(_ lhs: AppSettings, _ rhs: AppSettings) -> Bool {
        lhs.mode == rhs.mode && lhs.cloudProvider == rhs.cloudProvider &&
        lhs.resolvedCloudEndpoint == rhs.resolvedCloudEndpoint && lhs.cloudModel == rhs.cloudModel &&
        lhs.cloudAPI == rhs.cloudAPI && lhs.cloudOutput == rhs.cloudOutput &&
        lhs.cloudReasoning == rhs.cloudReasoning && lhs.chatGPTAccountID == rhs.chatGPTAccountID
    }

    func beginJob(id: String?) {
        jobGeneration = UUID()
        cancellationRequested = false; runner.resetCancellation()
        canCancelJob = true
        busy = true; processingID = id; progress = -1; progressText = L("Начинаю обработку…"); error = nil; notice = nil
        processingSleepLease.setActive(true, reason: L("After обрабатывает встречу"))
    }
    func endJob() {
        jobGeneration = UUID()
        cancellationRequested = false
        canCancelJob = false
        busy = false; processingID = nil; progress = -1
        processingSleepLease.setActive(false, reason: "")
    }
    func cancelJob() {
        guard canCancelJob else { return }
        if voice.isWorking { voice.cancelWork(); return }
        cancellationRequested = true; runner.cancel(); cancelKnowledgeRebuildGeneration()
        progressText = L("Останавливаю обработку…")
    }
    /// Importing or finishing a recording never authorizes a cloud upload by
    /// itself. Confirm this meeting and the current destination on every run.
    private func confirmCloudTranscription(_ id: String) -> Bool {
        guard settings.speechMode == "cloud" else { return true }
        guard !preview else { return false }
        let provider = settings.speechCloudProvider
        let endpoint = settings.resolvedSpeechEndpoint
        let model = settings.speechCloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            error = L("Укажите корректное имя модели распознавания в настройках."); return false
        }
        guard ["openai", "custom"].contains(provider), let destination = URLComponents(string: endpoint),
              let host = destination.host?.lowercased(), !host.isEmpty,
              destination.user == nil, destination.password == nil, destination.query == nil, destination.fragment == nil,
              destination.scheme?.lowercased() == "https" ||
                (destination.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            error = L("Укажите HTTPS-адрес API распознавания без логина, пароля и параметров. HTTP доступен только на этом Mac."); return false
        }
        let title = meetings.first(where: { $0.id == id })?.title ?? L("Встреча")
        let service = provider == "openai" ? "OpenAI" : settings.speechDestinationLabel
        confirmingCloudSpeech = true
        defer { confirmingCloudSpeech = false }
        let alert = NSAlert()
        alert.messageText = L("Отправить запись в облако?")
        alert.informativeText = LF("«{0}»\n\nСервис: {1}\nАдрес API: {2}\nМодель: {3}\n\nАудиозапись этой встречи будет отправлена выбранному сервису для распознавания. Запрос оплачивается по его тарифам.", arguments: [String(describing: title), String(describing: service), String(describing: endpoint), String(describing: model)])
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Отправить и распознать"))
        alert.addButton(withTitle: L("Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            self.error = nil; notice = Self.stoppedProcessingMessage
            return false
        }
        guard settings.speechMode == "cloud", settings.speechCloudProvider == provider,
              settings.resolvedSpeechEndpoint == endpoint,
              settings.speechCloudModel.trimmingCharacters(in: .whitespacesAndNewlines) == model else {
            notice = L("Настройки распознавания изменились. Запустите обработку ещё раз.")
            return false
        }
        return true
    }
    func processingWasCancelled(_ error: Error) -> Bool {
        error is CancellationError || cancellationRequested
    }
    private func reportJobFailure(_ error: Error) {
        if processingWasCancelled(error) { self.error = nil; notice = Self.stoppedProcessingMessage }
        else { self.error = error.localizedDescription }
    }
    func processMeeting(_ id: String) async {
        guard !isMeetingMediaProtected(id), !confirmingCloudSpeech, !jobs.contains(objectID: id, kinds: ["transcribe"]) else { return }
        guard confirmCloudTranscription(id) else { return }
        updateMeeting(id) { $0.status = "processing"; $0.error = nil }
        do {
            var arguments = ["--speakers", String(settings.speakerCount)]
            if !settings.diarization { arguments.append("--no-diarization") }
            try await worker("transcribe", id: id, extra: arguments)
            if let fresh: Meeting = read(meetingDirectory(id).appendingPathComponent("meta.json")),
               let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = fresh }
            let result: Transcript? = read(meetingDirectory(id).appendingPathComponent("transcript.json"))
            updateMeeting(id) { $0.duration = result?.duration ?? 0 }
            refreshResults(id)
            let profileSettings = effectiveSettings(for: id)
            if profileSettings.mode == "cloud" {
                notice = LF("Транскрипция готова. Создайте конспект через {0}.", arguments: [String(describing: profileSettings.cloudProviderTitle)])
            } else if settings.autoSummary {
                notice = L("Транскрипция готова. Конспект поставлен в очередь.")
            }
            if selection == id { loadSelection() }
        } catch {
            let savedTranscript: Transcript? = read(meetingDirectory(id).appendingPathComponent("transcript.json"))
            let savedSummary: Summary? = read(meetingDirectory(id).appendingPathComponent("summary.json"))
            let savedStatus = savedTranscript == nil ? "imported" : savedSummary == nil ? "transcribed" : "ready"
            if error is CancellationError {
                updateMeeting(id) {
                    $0.status = savedStatus
                    $0.error = nil
                }
                self.error = nil; notice = Self.stoppedProcessingMessage
            } else {
                updateMeeting(id) {
                    $0.status = savedStatus
                    $0.error = error.localizedDescription
                }
                self.error = error.localizedDescription
            }
            refreshResults(id)
        }
    }
    func rediarizeMeeting(_ id: String, speakers: Int) async {
        guard runtimeReady, (0...100).contains(speakers), !jobs.contains(objectID: id, kinds: ["diarize"]) else { return }
        do {
            try await worker("diarize", id: id, extra: ["--speakers", String(speakers)])
            reloadLibrary(); refreshResults(id)
            if selection == id { tab = "transcript" }
            notice = L("Собеседники пересчитаны. Проверьте реплики и задайте имена голосам. Предыдущая версия сохранена в истории.")
        } catch {
            if error is CancellationError { self.error = nil; notice = Self.stoppedProcessingMessage }
            else { self.error = error.localizedDescription }
            reloadLibrary(); refreshResults(id)
        }
    }
    func summarizeSelected() {
        guard let id = selection, !jobs.contains(objectID: id, kinds: ["summarize"]) else { return }
        var extra: [String] = []
        if summary?.manuallyEdited == true {
            let alert = NSAlert()
            alert.messageText = L("Обновить конспект с ручными правками?")
            alert.informativeText = L("Новый конспект заменит исправленные пункты. Предыдущая версия сохранится в истории; ваши карточки сохранятся.")
            alert.addButton(withTitle: L("Обновить")); alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            extra = ["--replace-manual-summary"]
        }
        Task {
            do {
                try await worker("summarize", id: id, extra: extra)
                updateMeeting(id) { $0.status = "ready"; $0.error = nil }
                refreshResults(id)
                if selection == id { tab = "summary" }
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func rememberOverviewDraft(_ text: String, meetingID: String, original: String, generatedAt: Double) {
        if text == original { overviewDrafts.removeValue(forKey: meetingID) }
        else { overviewDrafts[meetingID] = OverviewDraft(text: text, original: original, generatedAt: generatedAt) }
        overviewDraftsDirty = true
        _ = flushOverviewDrafts()
    }
    func discardOverviewDraft(_ meetingID: String) {
        overviewDrafts.removeValue(forKey: meetingID); overviewDraftsDirty = true
        _ = flushOverviewDrafts()
    }
    @discardableResult func flushOverviewDrafts() -> Bool {
        guard overviewDraftsDirty else { return true }
        do {
            try write(overviewDrafts, root.appendingPathComponent("overview-drafts.json"))
            overviewDraftsDirty = false
            return true
        } catch {
            self.error = LF("Не удалось сохранить черновик конспекта. Ваш текст остался в редакторе. {0}", arguments: [String(describing: error.localizedDescription)])
            return false
        }
    }
    @discardableResult
    func saveOverview(_ text: String, meetingID: String, expectedOverview: String, expectedGeneratedAt: Double) -> Bool {
        guard selection == meetingID else {
            error = L("Выбрана другая встреча. Откройте её конспект для редактирования.")
            return false
        }
        let overview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else { error = L("Краткий конспект не должен быть пустым."); return false }
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "summary-overview-save", arguments: [
                "meetingID": meetingID, "text": overview, "expectedOverview": expectedOverview,
                "expectedGeneratedAt": expectedGeneratedAt
            ])
            summary = try JSONDecoder().decode(Summary.self, from: data)
            notice = L("Краткий конспект сохранён.")
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func makeExample(_ card: Flashcard) {
        guard let id = selection else { return }
        enqueueExample(card, meetingID: id)
    }
    func rate(_ card: Flashcard, _ value: Int) {
        guard let id = selection, !busy, !isRecording else { return }
        beginJob(id: id); progressText = L("Сохраняю повторение…")
        Task {
            defer { endJob() }
            do {
                try await worker("review", id: id, extra: ["--card", card.id, "--rating", String(value)])
                refreshResults(id)
            } catch { reportJobFailure(error) }
        }
    }
    func installRuntime() {
        guard !busy, !isRecording else { return }
        guard jobs.activeCount == 0 else { error = L("Дождитесь фоновых задач перед обновлением компонентов распознавания."); return }
        let requestedASR = settings.speechMode == "local" ? asrSelectionIdentity : nil
        beginJob(id: nil); progressText = L("Подготавливаю распознавание и проверяю скачанные модели…")
        let generation = jobGeneration
        Task {
            defer { endJob() }
            do {
                let lease = try await localRuntimeLease.acquire { [weak self] in
                    guard let self else { return true }
                    return await self.runtimeWorkCancelled
                }
                defer { Task { await localRuntimeLease.release(lease) } }
                try write(settings, root.appendingPathComponent("settings.json"))
                try await runner.run(rustEngine,
                                     arguments: ["install-runtime", "--root", root.path, "--backend", backend.path]) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.busy, self.jobGeneration == generation, !self.cancellationRequested else { return }
                        if let message = event.message { self.progressText = message }
                    }
                }
                runtimeReady = true
                if let requestedASR { verifiedASRSelection = requestedASR }
                notice = L("Распознавание готово. Добавьте или выберите запись.")
            } catch { reportJobFailure(error) }
        }
    }
    func ollama(_ command: String) {
        guard !busy, !isRecording else { return }
        beginJob(id: nil)
        Task {
            defer { endJob() }
            do {
                let result = try await worker(command)
                localStatus = command == "pull" ? LF("Модель {0} готова", arguments: [String(describing: settings.localModel)]) : (result?.message ?? L("Локальный сервер доступен."))
            }
            catch { localStatus = error.localizedDescription }
        }
    }
    func prepareLocal() {
        guard !busy, !isRecording, runtimeReady, settings.localProvider == "managed" else { return }
        beginJob(id: nil)
        Task {
            defer { endJob() }
            do {
                let lease = try await localRuntimeLease.acquire { [weak self] in
                    guard let self else { return true }
                    return await self.runtimeWorkCancelled
                }
                defer { Task { await localRuntimeLease.release(lease) } }
                try await utilityWorker("install-local")
                try await localService.ensure(root: root, settings: settings, cancelled: { self.cancellationRequested || self.isTerminating })
                try await utilityWorker("pull")
                localStatus = L("Локальный ИИ готов. Интернет больше не требуется.")
            } catch { self.error = error.localizedDescription; localStatus = error.localizedDescription }
        }
    }
    func changeLocalProvider(_ provider: String) {
        guard !busy, !isRecording, provider != settings.localProvider else { return }
        modelsByProvider[settings.localProvider] = settings.localModel
        endpointsByProvider[settings.localProvider] = settings.localEndpoint
        if jobs.activeCount == 0 { localService.stop() }
        settings.localProvider = provider
        settings.localEndpoint = endpointsByProvider[provider] ?? ""
        settings.localModel = modelsByProvider[provider] ?? (provider == "managed" ? AppSettings.qualityLocalModel : "")
        installedLocalModels = []; localStatus = ""
        saveSettings()
    }
    func discoverLocalModels() {
        guard !busy, !isRecording else { return }
        beginJob(id: nil); progressText = L("Ищу установленные модели…")
        installedLocalModels = []
        Task {
            defer { endJob() }
            do {
                let result = try await worker("discover-local")
                localStatus = result?.message ?? (installedLocalModels.isEmpty ? L("Установленные модели не найдены.") : LF("Найдено моделей: {0}. Выберите модель из списка.", arguments: [String(describing: installedLocalModels.count)]))
            } catch { localStatus = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    func selectLocalModel(_ model: InstalledLocalModel) {
        settings.localModel = model.id
        if settings.localProvider != "managed" && !model.endpoint.isEmpty { settings.localEndpoint = model.endpoint }
        saveSettings()
    }
    func discoverGGUFModels() {
        guard !busy, !isRecording else { return }
        beginJob(id: nil); progressText = L("Ищу скачанные модели GGUF…")
        installedGGUFModels = []; ggufNotes = []
        Task {
            defer { endJob() }
            do {
                let result = try await worker("discover-gguf")
                ggufStatus = result?.message ?? (installedGGUFModels.isEmpty
                    ? L("Файлы GGUF не найдены. Можно выбрать скачанную модель вручную.")
                    : L("Найдены скачанные модели. Подключите нужную ниже."))
            } catch { ggufStatus = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    func chooseGGUFFile() {
        guard !busy, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.prompt = L("Подключить модель")
        panel.message = L("Выберите уже скачанный файл модели в формате GGUF, например Qwen.")
        if panel.runModal() == .OK, let url = panel.url { importGGUFModel(url) }
    }
    func importGGUFModel(_ url: URL) {
        guard !busy, !isRecording, settings.localProvider == "managed" else { return }
        guard runtimeReady else {
            error = L("Сначала подготовьте распознавание в настройках: эта среда нужна для локального движка. Затем подключите файл модели.")
            return
        }
        beginJob(id: nil); progressText = L("Подключаю скачанную модель…")
        Task {
            defer { endJob() }
            do {
                // Installs the owned inference engine, without pulling model weights.
                try await worker("install-local")
                let result = try await worker("import-gguf", extra: ["--path", url.path])
                guard let model = result?.model, !model.isEmpty else {
                    throw AppError.message(L("Локальный движок не подтвердил подключение модели. Исходный файл сохранён."))
                }
                settings.localModel = model
                saveSettings()
                localStatus = result?.message ?? L("Скачанная модель подключена и выбрана.")
                ggufStatus = localStatus
            } catch { ggufStatus = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    func discoverASRModels(path: URL? = nil) {
        guard !busy, !isRecording else { return }
        beginJob(id: nil); progressText = L("Ищу модели распознавания…")
        installedASRModels = []; asrNotes = []
        Task {
            defer { endJob() }
            do {
                let result = try await worker("discover-models", extra: path.map { ["--path", $0.path] } ?? [])
                if let path {
                    if let model = installedASRModels.first(where: { $0.compatible && URL(fileURLWithPath: $0.path).standardizedFileURL == path.standardizedFileURL })
                        ?? installedASRModels.first(where: { $0.compatible }) {
                        selectASRModel(model)
                        asrStatus = LF("Выбрана установленная модель {0}.", arguments: [String(describing: model.name)])
                    } else {
                        asrStatus = installedASRModels.first?.reason ?? result?.message ?? L("В этой папке не найдена совместимая модель Parakeet.")
                    }
                } else {
                    asrStatus = result?.message ?? (installedASRModels.isEmpty ? L("Модели не найдены. Можно выбрать папку вручную.") : L("Найдены модели. Выберите совместимую ниже."))
                }
            } catch { asrStatus = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    func chooseASRFolder() {
        guard !busy, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = L("Проверить модель")
        panel.message = L("Выберите папку с уже скачанной моделью распознавания. After проверит её формат.")
        if panel.runModal() == .OK, let url = panel.url { discoverASRModels(path: url) }
    }
    func selectASRModel(_ model: InstalledASRModel) {
        guard model.compatible else { return }
        settings.asrModelPath = model.path; settings.asrModelFormat = model.format
        saveSettings()
    }
    func useAutomaticASRModel() {
        settings.asrModelPath = ""; settings.asrModelFormat = "auto"
        saveSettings()
    }
    func togglePlayback() {
        guard let id = selection, loadedSelectionID == id, playbackURL(for: id) != nil, let player else { error = L("Аудиофайл не найден. Откройте папку данных встречи и проверьте MP3."); return }
        if isPlaying { pause() }
        else {
            if playbackTime >= playbackDuration - 0.2 { seek(0) }
            player.play(); isPlaying = true
        }
    }
    func pause() { player?.pause(); isPlaying = false }
    func seek(_ seconds: Double, play: Bool = false) {
        let value = min(max(seconds, 0), playbackDuration)
        player?.seek(to: value)
        playbackTime = value
        if play {
            guard let player else { error = L("Аудиофайл не найден. Исходный текст доступен в транскрипте."); return }
            player.play(); isPlaying = true
        }
    }
    /// Navigate to a precise source without starting playback unexpectedly.
    func openSegment(_ segmentID: Int, play: Bool = false) {
        guard let meetingID = selection, let segment = transcript?.segments.first(where: { $0.id == segmentID }) else {
            error = L("Исходная реплика больше недоступна. Откройте актуальный конспект.")
            return
        }
        transcriptSearch = ""; tab = "transcript"
        navigationTarget = NavigationTarget(meetingID: meetingID, kind: "transcript", segmentID: segmentID)
        seek(segment.start, play: play)
    }
    func expandCapturedNote(_ note: CapturedNote) async {
        guard !busy && !isRecording else { notes.error = L("Дождитесь завершения текущей обработки или записи."); return }
        guard let id = note.meetingID else { notes.error = L("Прикрепите заметку к встрече с транскриптом."); return }
        guard let _: Transcript = read(meetingDirectory(id).appendingPathComponent("transcript.json")) else {
            notes.error = L("Сначала распознайте запись этой встречи."); return
        }
        beginJob(id: id); progressText = L("Дополняю ваши пометки по записи…")
        defer { notes.reload(); endJob() }
        do {
            try await worker("expand-notes", extra: ["--note", note.id])
            notes.notice = L("Дополнение сохранено отдельно от вашей заметки")
        } catch { notes.error = error.localizedDescription }
    }
    func openMeeting(_ id: String, tab: String = "summary", segmentID: Int? = nil, timestamp: Double? = nil) {
        guard tab != "cards" || availableFeatures.cards else { openSettings("features"); return }
        guard let meeting: Meeting = read(meetingDirectory(id).appendingPathComponent("meta.json")) else {
            error = L("Встреча больше недоступна."); return
        }
        guard meeting.libraryKind != "cards" || availableFeatures.cards else { openSettings("features"); return }
        if folderSelection != nil, folderSelection != folderID(for: id) { folderSelection = folderID(for: id) }
        if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i] = meeting } else { meetings.insert(meeting, at: 0) }
        librarySection = "meetings"; libraryFilter = ""; selection = id; loadSelection(); self.tab = tab
        if let segmentID { openSegment(segmentID) }
        else if let timestamp {
            if let segment = transcript?.segments.last(where: { $0.start <= timestamp }) ?? transcript?.segments.first {
                openSegment(segment.id)
            }
            seek(timestamp)
        }
    }
    func applyDefaultNoteTemplate(to id: String) {
        guard !settings.defaultTemplateID.isEmpty,
              notes.context(for: id).revision == 0,
              let template = notes.templates.first(where: { $0.id == settings.defaultTemplateID }) else { return }
        guard notes.saveContext(MeetingContext(meetingID: id, templateID: template.id)) else { return }
        if !template.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = notes.capture(text: template.body, meetingID: id) }
        if !template.focus.isEmpty { updateMeeting(id) { $0.focus = template.focus } }
    }
    func exportManualNotes() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = L("Мои заметки — After.md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = L("# Мои заметки\n\n")
        for note in notes.notes.reversed() {
            let title = note.meetingID.flatMap { id in meetings.first { $0.id == id }?.title } ?? L("Входящие")
            text += "## \(title)\n\n\(note.text)\n\n"
            if let timestamp = note.timestamp { text += LF("Таймкод: {0}\n\n", arguments: [String(describing: Exporter.timestamp(timestamp))]) }
            if !note.sourceURL.isEmpty { text += LF("Источник: {0}\n\n", arguments: [String(describing: note.sourceURL)]) }
            for attachment in note.attachments {
                text += LF("Вложение: {0}\n\n", arguments: [String(describing: attachment.name)])
                if !attachment.extractedText.isEmpty { text += attachment.extractedText + "\n\n" }
            }
            if let expansion = note.expansion {
                text += L("### Дополнение ИИ\n\n") + expansion.statements.map { "- " + $0.text }.joined(separator: "\n") + "\n\n"
            }
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
    func openGlobalSearch() { showingSearch = true }

    func cancelSearch() {
        searchTask?.cancel(); searchTask = nil; searchGeneration = UUID(); searching = false; searchOpeningID = nil
    }
    func updateSearch(immediate: Bool = false) {
        cancelSearch()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = nil; searchWarnings = []; searchHits = []; searchTotal = 0; searchTruncated = false
        guard !query.isEmpty else { return }
        let generation = searchGeneration, root = self.root, scope = searchScope, searchFolderID = folderSelection
        searching = true
        searchTask = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(220)) }
                try Task.checkCancellation()
                let response = try await Task.detached(priority: .userInitiated) {
                    let data = try RustBridge.shared.get().request(root: root, command: "search", arguments: ["query": query, "scope": scope, "limit": 60, "folderID": searchFolderID as Any? ?? NSNull()])
                    return try JSONDecoder().decode(SearchResponse.self, from: data)
                }.value
                guard let self, !Task.isCancelled, self.searchGeneration == generation, self.showingSearch else { return }
                self.searchHits = response.hits.filter { ($0.kind != "card" || self.availableFeatures.cards) && ($0.noteKind != "task" || self.availableFeatures.tasks) }; self.searchTotal = response.total; self.searchTruncated = response.truncated
                self.searchWarnings = response.warnings; self.searching = false
            } catch is CancellationError {} catch {
                guard let self, self.searchGeneration == generation, self.showingSearch else { return }
                self.searchError = error.localizedDescription; self.searching = false
            }
        }
    }
    func openSearchHit(_ hit: SearchHit) {
        guard (hit.kind != "card" || availableFeatures.cards), (hit.noteKind != "task" || availableFeatures.tasks) else { openSettings("features"); return }
        guard searchOpeningID == nil else { return }
        let generation = searchGeneration, root = self.root
        searchOpeningID = hit.id; searchError = nil
        Task { [weak self] in
            do {
                let valid = try await Task.detached(priority: .userInitiated) {
                    struct Validation: Decodable { var valid: Bool }
                    let data: Data
                    if let noteID = hit.noteID, let revision = hit.noteRevision {
                        data = try RustBridge.shared.get().request(root: root, command: "note-search-validate", arguments: ["noteID": noteID, "revision": revision])
                    } else {
                        data = try RustBridge.shared.get().request(root: root, command: "search-validate",
                            arguments: ["meetingID": hit.meetingID, "sourceFingerprint": hit.sourceFingerprint])
                    }
                    return try JSONDecoder().decode(Validation.self, from: data).valid
                }.value
                guard let self, self.showingSearch, self.searchGeneration == generation else { return }
                self.searchOpeningID = nil
                guard valid else {
                    self.updateSearch(immediate: true)
                    self.searchError = L("Данные встречи изменились. Выберите актуальный фрагмент в обновлённых результатах.")
                    return
                }
                self.navigateToSearchHit(hit)
            } catch {
                guard let self, self.showingSearch, self.searchGeneration == generation else { return }
                self.searchOpeningID = nil; self.searchError = error.localizedDescription
            }
        }
    }
    private func navigateToSearchHit(_ hit: SearchHit) {
        guard (hit.kind != "card" || availableFeatures.cards), (hit.noteKind != "task" || availableFeatures.tasks) else { openSettings("features"); return }
        if let noteID = hit.noteID {
            notes.reload()
            guard let note = notes.workspace.notes.first(where: { $0.id == noteID && $0.revision == hit.noteRevision }) else {
                updateSearch(immediate: true); searchError = L("Заметка изменилась. Выберите актуальный результат."); return
            }
            guard note.kind != "task" || availableFeatures.tasks else { openSettings("features"); return }
            if let meetingID = note.meetingID, let meeting: Meeting = read(meetingDirectory(meetingID).appendingPathComponent("meta.json")), meeting.libraryKind != "cards" { openMeeting(meetingID, tab: "notes") }
            else { librarySection = "inbox"; pause() }
            notes.selectedNoteID = note.id; notes.highlightedNoteID = note.id
            showingSearch = false; cancelSearch(); return
        }
        let directory = meetingDirectory(hit.meetingID)
        guard let freshMeeting: Meeting = read(directory.appendingPathComponent("meta.json")) else {
            updateSearch(immediate: true); searchError = L("Встреча больше недоступна. Результаты обновляются."); return
        }
        guard freshMeeting.libraryKind != "cards" || availableFeatures.cards else { openSettings("features"); return }
        let freshTranscript: Transcript? = read(directory.appendingPathComponent("transcript.json"))
        let freshSummary: Summary? = read(directory.appendingPathComponent("summary.json"))
        let valid: Bool
        switch hit.kind {
        case "title": valid = freshMeeting.title == hit.text
        case "overview": valid = freshSummary?.overview == hit.text
        case "item":
            if let index = hit.itemIndex, let item = freshSummary?.items, item.indices.contains(index) {
                valid = item[index].text == hit.text && item[index].segmentIDs == hit.segmentIDs
            } else { valid = false }
        case "transcript":
            valid = hit.segmentIDs.count == 1 && freshTranscript?.segments.contains(where: { $0.id == hit.segmentIDs.first && $0.text == hit.text }) == true
        case "card":
            valid = freshSummary?.cards.contains(where: { $0.id == hit.cardID && Self.cardSearchText($0) == hit.text && $0.segmentIDs == hit.segmentIDs }) == true
        default: valid = false
        }
        let validSegments = Set(freshTranscript?.segments.map(\.id) ?? [])
        guard valid, hit.segmentIDs.allSatisfy(validSegments.contains) else {
            updateSearch(immediate: true)
            searchError = L("Данные встречи изменились. Выберите актуальный фрагмент в обновлённых результатах.")
            return
        }
        if let index = meetings.firstIndex(where: { $0.id == freshMeeting.id }) { meetings[index] = freshMeeting }
        else { meetings.insert(freshMeeting, at: 0) }
        libraryFilter = ""
        if folderSelection != nil, folderSelection != folderID(for: hit.meetingID) { folderSelection = folderID(for: hit.meetingID) }
        librarySection = "meetings"; selection = hit.meetingID; loadSelection()
        tab = hit.kind == "transcript" ? "transcript" : hit.kind == "card" ? "cards" : "summary"
        navigationTarget = NavigationTarget(meetingID: hit.meetingID, kind: hit.kind, segmentID: hit.segmentIDs.first,
                                            itemIndex: hit.itemIndex, cardID: hit.cardID)
        transcriptSearch = ""; showingSearch = false; cancelSearch()
    }
    private static func cardSearchText(_ card: Flashcard) -> String {
        [card.front, card.back, card.context].joined(separator: "\n")
    }
    @discardableResult
    func copyTranscriptMarkdown(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let meeting = selected, let transcript, !transcript.segments.isEmpty else { return false }
        let text = Exporter.transcriptMarkdown(meeting: meeting, transcript: transcript)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(text, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            error = L("Не удалось скопировать транскрипт. Попробуйте ещё раз.")
            return false
        }
        return true
    }
    func export(_ cards: Bool) {
        guard let meeting = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(cards ? "tsv" : "md")"
        panel.allowedContentTypes = cards ? [.tabSeparatedText] : [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let text = cards ? Exporter.anki(cards: summary?.cards ?? [], title: meeting.title)
                    : Exporter.markdown(meeting: meeting, transcript: transcript, summary: summary)
                try text.write(to: url, atomically: true, encoding: .utf8)
                notice = cards ? L("Карточки экспортированы. В Anki выберите «Импортировать файл».") : L("Конспект и транскрипция сохранены.")
            } catch { self.error = error.localizedDescription }
        }
    }
    func isMeetingMediaProtected(_ id: String) -> Bool {
        captureMeetingID == id || startingRecordingID == id || finalizingMeetingIDs.contains(id)
            || jobs.contains(objectID: id, kinds: ["finalize"])
    }
    func isMeetingSaving(_ id: String) -> Bool {
        (stoppingRecording && captureMeetingID == id) || finalizingMeetingIDs.contains(id)
            || jobs.contains(objectID: id, kinds: ["finalize"])
    }
    func canTrashMeeting(_ id: String) -> Bool {
        !isTerminating && !isMeetingMediaProtected(id) && !jobs.contains(objectID: id)
            && !(busy && processingID == id)
    }
    func playbackURL(for id: String) -> URL? {
        guard !isMeetingMediaProtected(id), !isMeetingSaving(id) else { return nil }
        return ["recording.mp3", "playback.mp3"].lazy.compactMap {
            MeetingMediaAccess.fileURL(root: self.root, meetingID: id, name: $0)
        }.first
    }
    func sourceMediaURL(for id: String) -> URL? {
        guard !isMeetingMediaProtected(id), !isMeetingSaving(id), let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: meeting.source).pathExtension),
              type.conforms(to: .audio) || type.conforms(to: .movie) else { return nil }
        return MeetingMediaAccess.fileURL(root: root, meetingID: id, name: meeting.source)
    }
    func openMeetingSource(_ id: String) {
        guard let url = sourceMediaURL(for: id) else { error = L("Медиафайл недоступен. Проверьте файлы встречи."); return }
        NSWorkspace.shared.open(url)
    }
    func showMeetingFiles(_ id: String) {
        guard let directory = MeetingMediaAccess.directoryURL(root: root, meetingID: id) else { return }
        NSWorkspace.shared.open(directory)
    }
    func openMeetingVideo(_ id: String) {
        guard !isMeetingMediaProtected(id), let url = MeetingMediaAccess.fileURL(root: root, meetingID: id, name: "video.mp4") else { return }
        NSWorkspace.shared.open(url)
    }
    func trashSelected() { if let id = selection { trashMeeting(id) } }
    func trashMeeting(_ id: String) {
        guard meetings.contains(where: { $0.id == id }), canTrashMeeting(id) else { return }
        do {
            let bridge = try RustBridge.shared.get()
            let snapshot = try bridge.request(root: root, command: "trash-snapshot", arguments: ["kind": "meeting", "id": id, "restore": false])
            struct Snapshot: Decodable { var fingerprint: String }
            let expected = try JSONDecoder().decode(Snapshot.self, from: snapshot)
            _ = try bridge.request(root: root, command: "trash-change", arguments: ["kind": "meeting", "id": id, "restore": false, "expectedFingerprint": expected.fingerprint, "operationID": UUID().uuidString.lowercased()])
            reloadLibrary()
            if selection == id { selection = filteredMeetings.first?.id; loadSelection() }
            notice = L("Встреча в Корзине. Её можно восстановить в течение 30 дней.")
        } catch { self.error = error.localizedDescription }
    }
    func exportAudio() { if let id = selection { exportMeetingAudio(id) } }
    func exportMeetingAudio(_ id: String, original: Bool = false) {
        guard let meeting = meetings.first(where: { $0.id == id }),
              let source = original ? sourceMediaURL(for: id) : playbackURL(for: id) else {
            error = L("Медиафайл недоступен. Проверьте файлы встречи."); return
        }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = meeting.title + "." + source.pathExtension
        if panel.runModal() == .OK, let destination = panel.url {
            guard !isMeetingMediaProtected(id) else { return }
            let exportRoot = root, name = source.lastPathComponent
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try MeetingMediaAccess.copy(root: exportRoot, meetingID: id, name: name, to: destination)
                    }.value
                    notice = original ? L("Исходная запись сохранена.") : L("Аудиозапись сохранена в MP3.")
                } catch { self.error = error.localizedDescription }
            }
        }
    }

}
