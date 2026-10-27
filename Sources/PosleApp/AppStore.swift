import AppKit
import AVFoundation
import Combine
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var librarySection = "meetings"
    let notes: NotesStore
    let calendar: CalendarStore
    let trackerSync: TrackerSyncCoordinator
    let updates = AppUpdateController()
    let voice = VoiceCommandController()
    var assistantCardMeetingID: String?
    let jobs: BackgroundJobsController
    private var jobsSubscription: AnyCancellable?
    @Published var startingRecording = false
    @Published var isTerminating = false
    var isPreview: Bool { preview }
    var quickCaptureAction: (() -> Void)?
    var bookmarkAction: (() -> Void)?
    var captureMeetingID: String? { isRecording ? recordingID : nil }
    @Published var selection: String?
    @Published var transcript: Transcript?
    @Published var summary: Summary?
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
    @Published var settingsSection = "general"
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
    var processAfterRecording = true
    @Published var recordingDate: Date?

    let root: URL
    let runner = ProcessRunner()
    let embeddedSpeech = EmbeddedSpeechService()
    let recorder: any MeetingRecordingBackend
    let audioLevels = AudioLevels()
    let localService = LocalModelService()
    let localRuntimeLease = LocalRuntimeLease()
    private var player: AVPlayer?
    private var playerObserver: Any?
    var recordingID: String?
    var assertions: IOPMAssertionID = 0
    var recordingAssertion: IOPMAssertionID = 0
    var cancellationRequested = false
    private var jobGeneration = UUID()
    private var confirmingCloudSpeech = false
    static let stoppedProcessingMessage = "Обработка остановлена. Запись сохранена."
    private var preview: Bool
    private var featureLifecycleReady = false

    var selected: Meeting? { meetings.first { $0.id == selection } }
    var selectedDirectory: URL? { selection.map { meetingDirectory($0) } }
    var filteredMeetings: [Meeting] {
        meetings.filter { $0.libraryKind != "cards" && (libraryFilter.isEmpty || $0.title.localizedCaseInsensitiveContains(libraryFilter)) }
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
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/После Обработка.app/Contents/MacOS/После Обработка")
        if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/posle-engine")
    }

    init(preview: Bool = false, recorder: any MeetingRecordingBackend = MeetingRecorder(),
         executor: JobCoordinator.Executor? = nil) {
        self.preview = preview; self.recorder = recorder
        let dataRoot: URL
        if let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] { dataRoot = URL(fileURLWithPath: path) }
        else {
            dataRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(preview ? "PoslePreview" : "Posle")
        }
        root = dataRoot
        jobs = BackgroundJobsController(root: dataRoot)
        notes = NotesStore(root: dataRoot)
        let initialSettings = (try? Data(contentsOf: dataRoot.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        calendar = CalendarStore(root: dataRoot, preview: preview, featureEnabled: initialSettings.features.calendar, tasksEnabled: initialSettings.features.tasks)
        trackerSync = TrackerSyncCoordinator(root: dataRoot)
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            if let saved: AppSettings = read(root.appendingPathComponent("settings.json")) { settings = saved }
            overviewDrafts = read(root.appendingPathComponent("overview-drafts.json")) ?? [:]
            // Finish only previously committed, explicitly authorized operations.
            do { _ = try RustBridge.shared.get().request(root: root, command: "voice-recover") }
            catch { self.error = "Не удалось завершить прерванное поручение: \(error.localizedDescription)" }
            librarySection = ["meetings", "inbox", "tasks", "cards"].contains(settings.startSection) && settings.allowsSection(settings.startSection) ? settings.startSection : "meetings"
            runtimeReady = FileManager.default.isExecutableFile(atPath: python.path)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/ready-v2").path)
            reloadLibrary()
            selection = meetings.first?.id
            loadSelection()
        } catch { self.error = error.localizedDescription }
        calendar.bindNotes(notes)
        voice.connect(self)
        jobsSubscription = jobs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let executor { jobs.connect(executor) }
        else {
            jobs.connect { [weak self] job, cancellation, event in
                guard let self else { throw CancellationError() }
                return try await self.executeBackgroundJob(job, cancellation: cancellation, event: event)
            }
        }
        featureLifecycleReady = true
        applyFeatureChanges()
        recorder.levels = { [weak self] microphone, system in
            Task { @MainActor in self?.audioLevels.receive(microphone: microphone, system: system) }
        }
        recorder.failed = { [weak self] failure in
            Task { @MainActor in
                guard let self, self.isRecording, self.recordingID == failure.sessionID else { return }
                self.error = "Запись прервалась: \(failure.message). Завершаю сохранение доступного аудио."
                await self.stopRecording()
            }
        }
    }

    private func applyFeatureChanges(previous: AppFeatures? = nil) {
        if !settings.allowsSection(librarySection) { librarySection = "meetings" }
        if !settings.features.cards, tab == "cards" { tab = "summary" }
        if !settings.features.assistant { voice.dismiss() }
        calendar.setFeatureEnabled(settings.features.calendar, tasksEnabled: settings.features.tasks)
        if !preview, settings.features.semanticSearch {
            SemanticIndexController.shared.connect(self)
            SemanticIndexController.shared.requestRefresh()
        } else if !preview { SemanticIndexController.shared.stop() }
        if previous?.tasks != settings.features.tasks {
            trackerSync.stop()
            if !preview, settings.features.tasks {
                trackerSync.start(isIdle: { [weak self] in
                    guard let self else { return false }
                    return self.settings.features.tasks && !self.isTerminating && !self.startingRecording && !self.isRecording && !self.stoppingRecording && !self.busy && self.jobs.activeCount == 0
                }, onChange: { [weak self] in
                    self?.notes.reload(); self?.notes.loadTasks(); self?.notes.loadTaskWorkspaces()
                })
            }
        }
        if showingSearch { updateSearch(immediate: true) }
    }

    func meetingDirectory(_ id: String) -> URL { root.appendingPathComponent("meetings/\(id)") }
    func read<T: Decodable>(_ url: URL) -> T? {
        guard let bridge = try? RustBridge.shared.get(), let data = try? bridge.read(root: root, url: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try RustBridge.shared.get().write(root: root, url: url, value: value)
    }
    func openSettings(_ section: String = "general") {
        settingsSection = section
        showingSettings = true
    }
    func saveSettings() {
        do { try write(settings, root.appendingPathComponent("settings.json")); NotificationCenter.default.post(name: Notification.Name("PosleShortcutsChanged"), object: nil) }
        catch { self.error = error.localizedDescription }
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
            meetings[i].error = "Предыдущая обработка прервалась. Можно продолжить."
            try? write(meetings[i], meetingDirectory(meetings[i].id).appendingPathComponent("meta.json"))
        }
    }
    func selectionDidChange() {
        if loadedSelectionID != selection { loadSelection() }
    }
    func loadSelection() {
        loadedSelectionID = selection
        if selected?.libraryKind == "cards", settings.features.cards { tab = "cards" }
        navigationTarget = nil
        pause()
        if let observer = playerObserver { player?.removeTimeObserver(observer) }; playerObserver = nil
        player = nil; playbackTime = 0
        transcriptSearch = ""
        guard let directory = selectedDirectory else { transcript = nil; summary = nil; return }
        transcript = read(directory.appendingPathComponent("transcript.json"))
        summary = read(directory.appendingPathComponent("summary.json"))
        examples = read(directory.appendingPathComponent("examples.json")) ?? [:]
        reviews = read(directory.appendingPathComponent("review-state.json")) ?? [:]
        playbackDuration = max(transcript?.duration ?? selected?.duration ?? 1, 1)
        let recording = directory.appendingPathComponent("recording.mp3")
        let playback = FileManager.default.fileExists(atPath: recording.path) ? recording : directory.appendingPathComponent("playback.mp3")
        if FileManager.default.fileExists(atPath: playback.path) {
            player = AVPlayer(url: playback)
            playbackDuration = max(transcript?.duration ?? selected?.duration ?? 1, 1)
            playerObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    self?.playbackTime = time.seconds.isFinite ? time.seconds : 0
                    if let self, self.playbackTime >= self.playbackDuration - 0.2 { self.isPlaying = false }
                }
            }
        }
    }
    func refreshResults(_ id: String) {
        if selection == id {
            navigationTarget = nil
            let directory = meetingDirectory(id)
            transcript = read(directory.appendingPathComponent("transcript.json"))
            summary = read(directory.appendingPathComponent("summary.json"))
            examples = read(directory.appendingPathComponent("examples.json")) ?? [:]
            reviews = read(directory.appendingPathComponent("review-state.json")) ?? [:]
        }
    }
    func updateMeeting(_ id: String, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let url = meetingDirectory(id).appendingPathComponent("meta.json")
        // Finalization can replace a temporary MOV with MP3 in the worker.
        // Always patch its latest metadata, including after cancellation/error.
        guard var current: Meeting = read(url) else {
            error = "Не удалось прочитать данные встречи. Откройте её заново."
            return
        }
        let original = current
        change(&current)
        do {
            let encoder = JSONEncoder()
            guard let before = try JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any],
                  let after = try JSONSerialization.jsonObject(with: encoder.encode(current)) as? [String: Any] else {
                throw AppError.message("Не удалось подготовить изменения встречи.")
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
        guard settings.features.tasks else { openSettings("features"); return }
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
        panel.message = "Добавьте запись встречи на русском или английском"
        if panel.runModal() == .OK, let url = panel.url { importFile(url) }
    }
    func importFile(_ source: URL) {
        guard !isTerminating else { return }
        guard !busy, !startingRecording else { error = "Дождитесь сохранения файла или завершения настройки компонентов."; return }
        let ext = source.pathExtension.lowercased()
        guard ["mp4", "mov", "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "webm", "mkv", "aac"].contains(ext) else {
            error = "Добавьте аудио или видео: MP4, MOV, M4A, MP3, WAV, FLAC или WebM."; return
        }
        canCancelJob = false
        busy = true; progress = -1; progressText = "Сохраняю запись…"; error = nil
        let focus = settings.focus
        let root = self.root
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    return try RustBridge.shared.get().request(root: root, command: "import", arguments: ["source": source.path, "focus": focus])
                }.value
                let meeting = try JSONDecoder().decode(Meeting.self, from: data)
                busy = false; reloadLibrary(); librarySection = "meetings"; selection = meeting.id; tab = "transcript"; loadSelection(); applyDefaultNoteTemplate(to: meeting.id)
                if runtimeReady { await processMeeting(meeting.id) }
                else { notice = "Запись сохранена. Установите модели один раз, чтобы начать распознавание."; showingSettings = true }
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
        return try await legacyWorker(command, id: id, extra: extra, input: input)
    }

    @discardableResult
    private func legacyWorker(_ command: String, id: String? = nil, extra: [String] = [], input: Data? = nil) async throws -> WorkerEvent? {
        guard !cancellationRequested, !isTerminating else { throw CancellationError() }
        let configuration = settings
        if ["transcribe", "install-local", "import-gguf"].contains(command) && !runtimeReady {
            throw AppError.message("Сначала подготовьте распознавание в настройках.")
        }
        if command == "pull" && configuration.localProvider != "managed" {
            throw AppError.message("Выберите установленную модель в настройках. Для Ollama и LM Studio скачивание выполняется в самом приложении.")
        }
        let requestedASR = asrSelectionIdentity
        let requestedLocalASR = command == "transcribe" && configuration.speechMode == "local"
        try write(configuration, root.appendingPathComponent("settings.json"))
        if ["check", "pull", "discover-local", "import-gguf"].contains(command) || (configuration.mode == "local" && ["summarize", "example", "expand-notes", "voice-plan"].contains(command)) {
            try await localService.ensure(root: root, settings: configuration, cancelled: { self.cancellationRequested })
        }
        guard !cancellationRequested else { throw AppError.message("Обработка остановлена. Запись сохранена.") }
        var arguments = [command, "--root", root.path, "--backend", backend.path]
        if let id { arguments += ["--meeting", meetingDirectory(id).path] }
        arguments += extra
        // Secrets live only in Keychain and the short-lived child environment, never argv/files.
        var environment = ["PYTHONUNBUFFERED": "1", "HF_HOME": root.appendingPathComponent("cache/huggingface").path,
                           "HF_HUB_DISABLE_TELEMETRY": "1", "POSLE_OLLAMA_URL": localService.baseURL,
                           "POSLE_JOB_SETTINGS": String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)]
        if configuration.mode == "cloud" && ["summarize", "example", "expand-notes", "check-cloud", "voice-plan"].contains(command) {
            environment["POSLE_API_KEY"] = try await cloudCredential(for: configuration)
        }
        if configuration.speechMode == "cloud" && command == "transcribe" {
            environment["POSLE_SPEECH_API_KEY"] = preview ? "" : Keychain.read(account: Keychain.speechAccount(for: configuration))
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
        let result: WorkerEvent?
        if command == "diarize" || (command == "transcribe" && configuration.speechMode == "local") {
            let speakerIndex = extra.firstIndex(of: "--speakers")
            let speakers = speakerIndex.flatMap { extra.indices.contains($0 + 1) ? Int(extra[$0 + 1]) : nil } ?? configuration.speakerCount
            result = try await embeddedSpeech.run(root: root, interpreter: python, backend: backend, command: command,
                                                   meeting: id.map { meetingDirectory($0) }, speakers: speakers,
                                                   diarization: !extra.contains("--no-diarization") && configuration.diarization, event: receive)
        } else {
            result = try await runner.run(rustEngine, arguments: arguments, environment: environment, input: input, event: receive)
        }
        if requestedLocalASR { verifiedASRSelection = requestedASR }
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
        beginJob(id: nil); progressText = "Проверяю подключение…"
        clearCloudConnectionResult()
        let configuration = settings
        cloudCheckAccountID = configuration.cloudProvider == "chatgpt" ? configuration.chatGPTAccountID : nil
        Task {
            defer { cloudCheckAccountID = nil; endJob() }
            do {
                try await worker("check-cloud")
                guard Self.sameCloudCheckConfiguration(settings, configuration) else { return }
                cloudConnectionStatus = "Подключение работает"
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
        busy = true; processingID = id; progress = -1; progressText = "Начинаю обработку…"; error = nil; notice = nil
        if assertions == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), "После обрабатывает встречу" as CFString, &assertions)
        }
    }
    func endJob() {
        jobGeneration = UUID()
        cancellationRequested = false
        canCancelJob = false
        busy = false; processingID = nil; progress = -1
        if assertions != 0 { IOPMAssertionRelease(assertions); assertions = 0 }
    }
    func cancelJob() {
        guard canCancelJob else { return }
        if voice.isWorking { voice.cancelWork(); return }
        cancellationRequested = true; runner.cancel()
        progressText = "Останавливаю обработку…"
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
            error = "Укажите корректное имя модели распознавания в настройках."; return false
        }
        guard ["openai", "custom"].contains(provider), let destination = URLComponents(string: endpoint),
              let host = destination.host?.lowercased(), !host.isEmpty,
              destination.user == nil, destination.password == nil, destination.query == nil, destination.fragment == nil,
              destination.scheme?.lowercased() == "https" ||
                (destination.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            error = "Укажите HTTPS-адрес API распознавания без логина, пароля и параметров. HTTP доступен только на этом Mac."; return false
        }
        let title = meetings.first(where: { $0.id == id })?.title ?? "Встреча"
        let service = provider == "openai" ? "OpenAI" : settings.speechDestinationLabel
        confirmingCloudSpeech = true
        defer { confirmingCloudSpeech = false }
        let alert = NSAlert()
        alert.messageText = "Отправить запись в облако?"
        alert.informativeText = "«\(title)»\n\nСервис: \(service)\nАдрес API: \(endpoint)\nМодель: \(model)\n\nАудиозапись этой встречи будет отправлена выбранному сервису для распознавания. Запрос оплачивается по его тарифам."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Отправить и распознать")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            self.error = nil; notice = Self.stoppedProcessingMessage
            return false
        }
        guard settings.speechMode == "cloud", settings.speechCloudProvider == provider,
              settings.resolvedSpeechEndpoint == endpoint,
              settings.speechCloudModel.trimmingCharacters(in: .whitespacesAndNewlines) == model else {
            notice = "Настройки распознавания изменились. Запустите обработку ещё раз."
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
        guard !confirmingCloudSpeech, !jobs.contains(objectID: id, kinds: ["transcribe"]) else { return }
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
            if settings.mode == "cloud" {
                notice = "Транскрипция готова. Создайте конспект через \(settings.cloudProviderTitle)."
            } else if settings.autoSummary {
                notice = "Транскрипция готова. Конспект поставлен в очередь."
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
            notice = "Собеседники пересчитаны. Проверьте реплики и задайте имена голосам. Предыдущая версия сохранена в истории."
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
            alert.messageText = "Обновить конспект с ручными правками?"
            alert.informativeText = "Новый конспект заменит исправленные пункты. Предыдущая версия сохранится в истории; ваши карточки сохранятся."
            alert.addButton(withTitle: "Обновить"); alert.addButton(withTitle: "Отмена")
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
            self.error = "Не удалось сохранить черновик конспекта. Ваш текст остался в редакторе. \(error.localizedDescription)"
            return false
        }
    }
    @discardableResult
    func saveOverview(_ text: String, meetingID: String, expectedOverview: String, expectedGeneratedAt: Double) -> Bool {
        guard selection == meetingID else {
            error = "Выбрана другая встреча. Откройте её конспект для редактирования."
            return false
        }
        let overview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else { error = "Краткий конспект не должен быть пустым."; return false }
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "summary-overview-save", arguments: [
                "meetingID": meetingID, "text": overview, "expectedOverview": expectedOverview,
                "expectedGeneratedAt": expectedGeneratedAt
            ])
            summary = try JSONDecoder().decode(Summary.self, from: data)
            notice = "Краткий конспект сохранён."
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
        beginJob(id: id); progressText = "Сохраняю повторение…"
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
        guard jobs.activeCount == 0 else { error = "Дождитесь фоновых задач перед обновлением компонентов распознавания."; return }
        let requestedASR = settings.speechMode == "local" ? asrSelectionIdentity : nil
        beginJob(id: nil); progressText = "Подготавливаю распознавание и проверяю скачанные модели…"
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
                notice = "Распознавание готово. Добавьте или выберите запись."
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
                localStatus = command == "pull" ? "Модель \(settings.localModel) готова" : (result?.message ?? "Локальный сервер доступен.")
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
                try await legacyWorker("install-local")
                try await localService.ensure(root: root, settings: settings, cancelled: { self.cancellationRequested || self.isTerminating })
                try await legacyWorker("pull")
                localStatus = "Локальный ИИ готов. Интернет больше не требуется."
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
        beginJob(id: nil); progressText = "Ищу установленные модели…"
        installedLocalModels = []
        Task {
            defer { endJob() }
            do {
                let result = try await worker("discover-local")
                localStatus = result?.message ?? (installedLocalModels.isEmpty ? "Установленные модели не найдены." : "Найдено моделей: \(installedLocalModels.count). Выберите модель из списка.")
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
        beginJob(id: nil); progressText = "Ищу скачанные модели GGUF…"
        installedGGUFModels = []; ggufNotes = []
        Task {
            defer { endJob() }
            do {
                let result = try await worker("discover-gguf")
                ggufStatus = result?.message ?? (installedGGUFModels.isEmpty
                    ? "Файлы GGUF не найдены. Можно выбрать скачанную модель вручную."
                    : "Найдены скачанные модели. Подключите нужную ниже.")
            } catch { ggufStatus = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    func chooseGGUFFile() {
        guard !busy, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.prompt = "Подключить модель"
        panel.message = "Выберите уже скачанный файл модели в формате GGUF, например Qwen."
        if panel.runModal() == .OK, let url = panel.url { importGGUFModel(url) }
    }
    func importGGUFModel(_ url: URL) {
        guard !busy, !isRecording, settings.localProvider == "managed" else { return }
        guard runtimeReady else {
            error = "Сначала подготовьте распознавание в настройках: эта среда нужна для локального движка. Затем подключите файл модели."
            return
        }
        beginJob(id: nil); progressText = "Подключаю скачанную модель…"
        Task {
            defer { endJob() }
            do {
                // Installs the owned inference engine, without pulling model weights.
                try await worker("install-local")
                let result = try await worker("import-gguf", extra: ["--path", url.path])
                guard let model = result?.model, !model.isEmpty else {
                    throw AppError.message("Локальный движок не подтвердил подключение модели. Исходный файл сохранён.")
                }
                settings.localModel = model
                saveSettings()
                localStatus = result?.message ?? "Скачанная модель подключена и выбрана."
                ggufStatus = localStatus
            } catch { ggufStatus = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    func discoverASRModels(path: URL? = nil) {
        guard !busy, !isRecording else { return }
        beginJob(id: nil); progressText = "Ищу модели распознавания…"
        installedASRModels = []; asrNotes = []
        Task {
            defer { endJob() }
            do {
                let result = try await worker("discover-models", extra: path.map { ["--path", $0.path] } ?? [])
                if let path {
                    if let model = installedASRModels.first(where: { $0.compatible && URL(fileURLWithPath: $0.path).standardizedFileURL == path.standardizedFileURL })
                        ?? installedASRModels.first(where: { $0.compatible }) {
                        selectASRModel(model)
                        asrStatus = "Выбрана установленная модель \(model.name)."
                    } else {
                        asrStatus = installedASRModels.first?.reason ?? result?.message ?? "В этой папке не найдена совместимая модель Parakeet."
                    }
                } else {
                    asrStatus = result?.message ?? (installedASRModels.isEmpty ? "Модели не найдены. Можно выбрать папку вручную." : "Найдены модели. Выберите совместимую ниже.")
                }
            } catch { asrStatus = error.localizedDescription; self.error = error.localizedDescription }
        }
    }
    func chooseASRFolder() {
        guard !busy, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Проверить модель"
        panel.message = "Выберите папку с уже скачанной моделью распознавания. После проверит её формат."
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
        guard let player else { error = "Аудиофайл не найден. Откройте папку данных встречи и проверьте MP3."; return }
        if isPlaying { pause() }
        else {
            if playbackTime >= playbackDuration - 0.2 { seek(0) }
            player.play(); isPlaying = true
        }
    }
    func pause() { player?.pause(); isPlaying = false }
    func seek(_ seconds: Double, play: Bool = false) {
        let value = min(max(seconds, 0), playbackDuration)
        player?.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = value
        if play {
            guard let player else { error = "Аудиофайл не найден. Исходный текст доступен в транскрипте."; return }
            player.play(); isPlaying = true
        }
    }
    /// Navigate to a precise source without starting playback unexpectedly.
    func openSegment(_ segmentID: Int, play: Bool = false) {
        guard let meetingID = selection, let segment = transcript?.segments.first(where: { $0.id == segmentID }) else {
            error = "Исходная реплика больше недоступна. Откройте актуальный конспект."
            return
        }
        transcriptSearch = ""; tab = "transcript"
        navigationTarget = NavigationTarget(meetingID: meetingID, kind: "transcript", segmentID: segmentID)
        seek(segment.start, play: play)
    }
    func expandCapturedNote(_ note: CapturedNote) async {
        guard !busy && !isRecording else { notes.error = "Дождитесь завершения текущей обработки или записи."; return }
        guard let id = note.meetingID else { notes.error = "Прикрепите заметку к встрече с транскриптом."; return }
        guard let _: Transcript = read(meetingDirectory(id).appendingPathComponent("transcript.json")) else {
            notes.error = "Сначала распознайте запись этой встречи."; return
        }
        beginJob(id: id); progressText = "Дополняю ваши пометки по записи…"
        defer { notes.reload(); endJob() }
        do {
            try await worker("expand-notes", extra: ["--note", note.id])
            notes.notice = "Дополнение сохранено отдельно от вашей заметки"
        } catch { notes.error = error.localizedDescription }
    }
    func openMeeting(_ id: String, tab: String = "summary", segmentID: Int? = nil, timestamp: Double? = nil) {
        guard tab != "cards" || settings.features.cards else { openSettings("features"); return }
        guard let meeting: Meeting = read(meetingDirectory(id).appendingPathComponent("meta.json")) else {
            error = "Встреча больше недоступна."; return
        }
        guard meeting.libraryKind != "cards" || settings.features.cards else { openSettings("features"); return }
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Мои заметки — После.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "# Мои заметки\n\n"
        for note in notes.notes.reversed() {
            let title = note.meetingID.flatMap { id in meetings.first { $0.id == id }?.title } ?? "Входящие"
            text += "## \(title)\n\n\(note.text)\n\n"
            if let timestamp = note.timestamp { text += "Таймкод: \(Exporter.timestamp(timestamp))\n\n" }
            if !note.sourceURL.isEmpty { text += "Источник: \(note.sourceURL)\n\n" }
            for attachment in note.attachments {
                text += "Вложение: \(attachment.name)\n\n"
                if !attachment.extractedText.isEmpty { text += attachment.extractedText + "\n\n" }
            }
            if let expansion = note.expansion {
                text += "### Дополнение ИИ\n\n" + expansion.statements.map { "- " + $0.text }.joined(separator: "\n") + "\n\n"
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
        let generation = searchGeneration, root = self.root, scope = searchScope
        searching = true
        searchTask = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(220)) }
                try Task.checkCancellation()
                let response = try await Task.detached(priority: .userInitiated) {
                    let data = try RustBridge.shared.get().request(root: root, command: "search", arguments: ["query": query, "scope": scope, "limit": 60])
                    return try JSONDecoder().decode(SearchResponse.self, from: data)
                }.value
                guard let self, !Task.isCancelled, self.searchGeneration == generation, self.showingSearch else { return }
                self.searchHits = response.hits.filter { ($0.kind != "card" || self.settings.features.cards) && ($0.noteKind != "task" || self.settings.features.tasks) }; self.searchTotal = response.total; self.searchTruncated = response.truncated
                self.searchWarnings = response.warnings; self.searching = false
            } catch is CancellationError {} catch {
                guard let self, self.searchGeneration == generation, self.showingSearch else { return }
                self.searchError = error.localizedDescription; self.searching = false
            }
        }
    }
    func openSearchHit(_ hit: SearchHit) {
        guard (hit.kind != "card" || settings.features.cards), (hit.noteKind != "task" || settings.features.tasks) else { openSettings("features"); return }
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
                    self.searchError = "Данные встречи изменились. Выберите актуальный фрагмент в обновлённых результатах."
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
        guard (hit.kind != "card" || settings.features.cards), (hit.noteKind != "task" || settings.features.tasks) else { openSettings("features"); return }
        if let noteID = hit.noteID {
            notes.reload()
            guard let note = notes.workspace.notes.first(where: { $0.id == noteID && $0.revision == hit.noteRevision }) else {
                updateSearch(immediate: true); searchError = "Заметка изменилась. Выберите актуальный результат."; return
            }
            guard note.kind != "task" || settings.features.tasks else { openSettings("features"); return }
            if let meetingID = note.meetingID, let meeting: Meeting = read(meetingDirectory(meetingID).appendingPathComponent("meta.json")), meeting.libraryKind != "cards" { openMeeting(meetingID, tab: "notes") }
            else { librarySection = "inbox"; pause() }
            notes.selectedNoteID = note.id; notes.highlightedNoteID = note.id
            showingSearch = false; cancelSearch(); return
        }
        let directory = meetingDirectory(hit.meetingID)
        guard let freshMeeting: Meeting = read(directory.appendingPathComponent("meta.json")) else {
            updateSearch(immediate: true); searchError = "Встреча больше недоступна. Результаты обновляются."; return
        }
        guard freshMeeting.libraryKind != "cards" || settings.features.cards else { openSettings("features"); return }
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
            searchError = "Данные встречи изменились. Выберите актуальный фрагмент в обновлённых результатах."
            return
        }
        if let index = meetings.firstIndex(where: { $0.id == freshMeeting.id }) { meetings[index] = freshMeeting }
        else { meetings.insert(freshMeeting, at: 0) }
        libraryFilter = ""
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
            error = "Не удалось скопировать транскрипт. Попробуйте ещё раз."
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
                notice = cards ? "Карточки экспортированы. В Anki выберите «Импортировать файл»." : "Конспект и транскрипция сохранены."
            } catch { self.error = error.localizedDescription }
        }
    }
    func trashSelected() {
        guard let meeting = selected, !busy, !isRecording else { return }
        do {
            let bridge = try RustBridge.shared.get()
            let snapshot = try bridge.request(root: root, command: "trash-snapshot", arguments: ["kind": "meeting", "id": meeting.id, "restore": false])
            struct Snapshot: Decodable { var fingerprint: String }
            let expected = try JSONDecoder().decode(Snapshot.self, from: snapshot)
            _ = try bridge.request(root: root, command: "trash-change", arguments: ["kind": "meeting", "id": meeting.id, "restore": false, "expectedFingerprint": expected.fingerprint, "operationID": UUID().uuidString.lowercased()])
            reloadLibrary(); selection = meetings.first?.id; loadSelection()
            notice = "Встреча в Корзине. Её можно восстановить в течение 30 дней."
        } catch { self.error = error.localizedDescription }
    }
    func exportAudio() {
        guard let meeting = selected, let directory = selectedDirectory else { return }
        let recording = directory.appendingPathComponent("recording.mp3")
        let source = FileManager.default.fileExists(atPath: recording.path) ? recording : directory.appendingPathComponent("playback.mp3")
        guard FileManager.default.fileExists(atPath: source.path) else { error = "Сначала завершите обработку аудио."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mp3]; panel.nameFieldStringValue = "\(meeting.title).mp3"
        if panel.runModal() == .OK, let destination = panel.url {
            do { try Data(contentsOf: source).write(to: destination, options: .atomic); notice = "Аудиозапись сохранена в MP3." }
            catch { self.error = error.localizedDescription }
        }
    }

}

import IOKit.pwr_mgt
