import AppKit
import AVFoundation
import Combine
import Foundation
import PosleCore

struct VoiceTarget: Codable, Hashable {
    var kind: String
    var id: String
    var meetingID: String?
    var source: KnowledgeSource? = nil
}
struct VoiceCandidate: Codable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var reason: String? = nil
    var completed: Bool? = nil
    var selected: Bool? = nil
}
struct VoicePlan: Codable {
    var status: String
    var planID: String?
    var operationID: String?
    var title: String
    var detail: String
    var target: VoiceTarget?
    var candidates: [VoiceCandidate]?
    var action: String? = nil
    var reviewRequired: Bool? = nil
    var selectionMode: String? = nil
    var text: String? = nil
    var knowledgeAnswer: KnowledgeAnswer? = nil
    var query: String? = nil
}
struct VoiceResult: Codable {
    var operationID: String
    var title: String
    var detail: String
    var target: VoiceTarget
    var canUndo: Bool
    var undone: Bool? = nil
}

private struct VoiceDraftRecord: Codable {
    var text: String
    var contextLabel: String
    var meetingID: String?
    var noteID: String?
    var taskID: String?
    var planID: String?
    var operationID: String?
    var projectID: String? = nil
    var selectedTargetIDs: [String]? = nil
    var reviewText: String? = nil
    var previousQuestions: [String]? = nil
}

/// Short, explicit microphone sessions. Meeting recording owns its microphone
/// independently; this recorder never silently starts or captures system audio.
@MainActor
final class VoiceCapture: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var directory: URL?
    private var timer: Timer?
    var limitReached: (() -> Void)?
    var failed: ((String) -> Void)?
    func start(root: URL) async throws {
        guard recorder == nil else { throw AppError.message("Диктовка уже идёт.") }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw AppError.message("Разрешите доступ к микрофону в настройках macOS.") }
        try Task.checkCancellation()
        let base = root.appendingPathComponent("voice-inputs", isDirectory: true)
        try Self.validateDirectory(base, create: true)
        let directory = base.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        do {
            let audio = try AVAudioRecorder(url: directory.appendingPathComponent("input.m4a"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            audio.delegate = self
            guard audio.prepareToRecord(), audio.record() else { throw AppError.message("Не удалось включить микрофон.") }
            recorder = audio
            timer = Timer.scheduledTimer(withTimeInterval: 175, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.recorder === audio else { return }; self.limitReached?()
                }
            }
        } catch { discard(); throw error }
    }
    func stop() throws -> URL {
        guard let recorder else { throw AppError.message("Диктовка не начата.") }
        timer?.invalidate(); timer = nil
        recorder.stop(); self.recorder = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recorder.url.path)
        return recorder.url
    }
    func discard() {
        timer?.invalidate(); timer = nil; recorder?.stop(); recorder = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private static func validateDirectory(_ url: URL, create: Bool) throws {
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.message("Папка диктовки недоступна.") }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }; self.failed?("Не удалось сохранить диктовку. Повторите запись.")
        }
    }
}

@MainActor
final class VoiceCommandController: ObservableObject {
    enum Phase: String { case editing, authorizing, capturing, transcribing, planning, choosing, reviewing, applying, result }
    @Published var isPresented = false
    @Published var text = "" { didSet {
        guard !restoringDraft else { return }
        if text != oldValue && phase == .editing { knowledgeAnswer = nil; knowledgeOpeningID = nil; plan = nil; interruptedPlanID = nil; interruptedOperationID = nil }
        scheduleDraftSave()
    } }
    @Published private(set) var phase = Phase.editing { didSet { if !restoringDraft { _ = flushDraft() } } }
    @Published private(set) var message: String?
    @Published private(set) var plan: VoicePlan?
    @Published private(set) var result: VoiceResult?
    @Published private(set) var knowledgeAnswer: KnowledgeAnswer?
    @Published private(set) var knowledgeOpeningID: String?
    @Published var selectedTargetIDs: Set<String> = [] { didSet { if !restoringDraft { _ = flushDraft() } } }
    @Published var reviewText = "" { didSet { if !restoringDraft { scheduleDraftSave() } } }
    @Published private(set) var contextLabel = "Библиотека"
    private weak var store: AppStore?
    private let capture = VoiceCapture()
    private var task: Task<Void, Never>?
    private var context: [String: Any] = [:]
    private var forwarding: AnyCancellable?
    private var draftSaveTask: Task<Void, Never>?
    private var restoringDraft = false
    private var interruptedPlanID: String?
    private var interruptedOperationID: String?
    private var previousQuestions: [String] = []
    private var generation = UUID()
    #if DEBUG
    private var dictationStopFailureForChecks: Error?
    #endif
    var isWorking: Bool { [.authorizing, .capturing, .transcribing, .planning, .applying].contains(phase) }
    var hasDraft: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .result }
    var blocksRelaunch: Bool { isWorking || hasDraft }

    func connect(_ store: AppStore) {
        self.store = store
        forwarding = objectWillChange.sink { [weak store] _ in store?.objectWillChange.send() }
        capture.limitReached = { [weak self] in self?.finishDictation() }
        capture.failed = { [weak self] text in self?.cancelWork(); self?.message = text }
        if let draft: VoiceDraftRecord = store.read(store.root.appendingPathComponent("voice-draft.json")), !draft.text.isEmpty {
            restoringDraft = true
            defer { restoringDraft = false; _ = flushDraft() }
            contextLabel = draft.contextLabel
            if let id = draft.meetingID { context["meetingID"] = id }
            if let id = draft.noteID { context["noteID"] = id }
            if let id = draft.taskID { context["taskID"] = id }
            if let id = draft.projectID { context["projectID"] = id }
            previousQuestions = Self.retainedQuestions(draft.previousQuestions ?? [])
            text = draft.text
            if let planID = draft.planID, let operationID = draft.operationID {
                interruptedPlanID = planID; interruptedOperationID = operationID
                struct Inspection: Decodable { var plan: VoicePlan?; var result: VoiceResult? }
                do {
                    let data = try RustBridge.shared.get().request(root: store.root, command: "voice-inspect", arguments: ["planID": planID, "operationID": operationID])
                    let inspection = try JSONDecoder().decode(Inspection.self, from: data)
                    if let result = inspection.result {
                        if result.undone == true {
                            text = ""; self.plan = nil; interruptedPlanID = nil; interruptedOperationID = nil
                            message = "Изменение уже отменено."; phase = .editing
                        } else { self.result = result; phase = .result; isPresented = true }
                    }
                    else if let plan = inspection.plan {
                        self.plan = plan
                        if plan.status == "choose" { phase = .choosing }
                        else if plan.reviewRequired == true {
                            prepareReview(plan)
                            if let selected = draft.selectedTargetIDs {
                                selectedTargetIDs = Set(selected).intersection(Set((plan.candidates ?? []).map(\.id)))
                            }
                            if let edited = draft.reviewText { reviewText = edited }
                        }
                        message = plan.reviewRequired == true ? "Поручение прервалось. Проверьте изменения перед продолжением." : "Поручение прервалось. Нажмите «Выполнить», чтобы продолжить."
                    }
                } catch {
                    message = "Не удалось проверить результат прерванного поручения. Проверьте библиотеку перед повтором."
                }
            }
        }
    }
    func present(taskID: String? = nil, title: String? = nil, projectID: String? = nil) {
        guard let store else { return }
        guard store.settings.features.assistant else { store.openSettings("features"); return }
        if !hasDraft && !isWorking {
            generation = UUID(); knowledgeAnswer = nil; knowledgeOpeningID = nil
            previousQuestions = []
            text = ""; plan = nil; result = nil; phase = .editing; message = nil; context = [:]
            if let taskID { context["taskID"] = taskID; contextLabel = title ?? "Задача" }
            else if store.librarySection == "cards", let id = store.assistantCardMeetingID, let meeting = store.meetings.first(where: { $0.id == id }) {
                context["meetingID"] = id; contextLabel = meeting.title
            } else if store.librarySection == "meetings", let meeting = store.selected {
                context["meetingID"] = meeting.id; contextLabel = meeting.title
            } else if store.librarySection == "inbox", let id = store.notes.selectedNoteID,
                      let note = store.notes.notes.first(where: { $0.id == id }) {
                context["noteID"] = id; contextLabel = note.displayTitle
            } else { contextLabel = "Библиотека" }
            if let project = projectID ?? store.activeTaskProjectID {
                context["projectID"] = project
                if contextLabel == "Библиотека" { contextLabel = "Проект: \(project)" }
            }
        }
        isPresented = true
        NSApp.activate(ignoringOtherApps: true)
    }
    func dismiss() {
        guard phase != .applying else { return }
        if isWorking { cancelWork() }
        generation = UUID(); knowledgeAnswer = nil; knowledgeOpeningID = nil
        _ = flushDraft(); isPresented = false
    }
    func editCommand() {
        guard !isWorking else { return }; knowledgeAnswer = nil; knowledgeOpeningID = nil; phase = .editing; plan = nil; selectedTargetIDs = []; reviewText = ""; message = nil
    }
    func reset() {
        guard !isWorking else { return }
        knowledgeAnswer = nil; knowledgeOpeningID = nil
        previousQuestions = []
        text = ""; plan = nil; result = nil; interruptedPlanID = nil; interruptedOperationID = nil; phase = .editing; message = nil
        isPresented = false; present()
    }
    /// Keep only user topics. Answers and old calendar snapshots never become
    /// evidence on the next turn; Rust retrieves and verifies originals again.
    func continueQuestion() {
        guard !isWorking, knowledgeAnswer != nil else { return }
        let topic = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { previousQuestions.append(topic) }
        previousQuestions = Self.retainedQuestions(previousQuestions)
        context = [:]; contextLabel = "Продолжение разговора"
        knowledgeAnswer = nil; knowledgeOpeningID = nil; result = nil; plan = nil
        interruptedPlanID = nil; interruptedOperationID = nil
        phase = .editing; text = ""; message = nil; _ = flushDraft()
    }
    func continueCommand() {
        guard !isWorking, let result else { return }
        switch result.target.kind {
        case "cards" where plan?.action == "createCards":
            let id = result.target.meetingID ?? result.target.id
            context = ["meetingID": id]
            contextLabel = store?.meetings.first(where: { $0.id == id })?.title ?? "Созданные карточки"
        case "task": context = ["taskID": result.target.id]; contextLabel = result.title
        case "note": context = ["noteID": result.target.id]; contextLabel = result.title
        case "meeting": context["meetingID"] = result.target.meetingID ?? result.target.id
        default: break
        }
        let topic = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { previousQuestions.append(topic) }
        previousQuestions = Self.retainedQuestions(previousQuestions)
        self.result = nil; plan = nil; interruptedPlanID = nil; interruptedOperationID = nil
        phase = .editing; text = ""; message = nil; _ = flushDraft()
    }
    private static func retainedQuestions(_ questions: [String]) -> [String] {
        var result = questions.suffix(6).compactMap { question -> String? in
            var bytes = 0
            let prefix = question.prefix { character in
                let length = String(character).utf8.count
                guard bytes + length <= 1500 else { return false }
                bytes += length; return true
            }
            let bounded = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
            return bounded.isEmpty || bounded.contains("\0") ? nil : bounded
        }
        // Match the core's UTF-8 limits for Cyrillic, CJK and emoji as well as
        // ASCII. Drop older topics whole rather than cutting their meaning.
        while result.reduce(0, { $0 + $1.utf8.count }) > 5000 { result.removeFirst() }
        return result
    }
    func startDictation() {
        guard let store, !isWorking else { return }
        guard store.settings.features.assistant else { store.openSettings("features"); return }
        guard !store.isTerminating else { message = "Приложение завершает работу."; return }
        guard !store.startingRecording, !store.isRecording, !store.stoppingRecording else {
            message = "Во время записи встречи введите поручение текстом. Микрофон занят записью."; return
        }
        guard !store.busy else { message = "Дождитесь текущей обработки."; return }
        guard !store.isPreview else { message = "В режиме просмотра введите поручение текстом."; return }
        guard store.runtimeReady else { message = "Подготовьте распознавание в настройках."; return }
        if store.settings.speechMode == "cloud", !store.confirmVoiceUpload() { return }
        generation = UUID(); let current = generation
        store.beginJob(id: nil); store.progressText = "Диктовка…"
        phase = .authorizing; message = nil; plan = nil; result = nil; knowledgeAnswer = nil; knowledgeOpeningID = nil
        task = Task {
            do {
                try await capture.start(root: store.root)
                guard current == generation, !Task.isCancelled else { capture.discard(); return }
                phase = .capturing
            } catch {
                guard current == generation else { return }
                capture.discard(); phase = .editing; message = error.localizedDescription; store.endJob()
            }
        }
    }
    func finishDictation() {
        guard let store, phase == .capturing else { return }
        let current = generation
        do {
            #if DEBUG
            if let failure = dictationStopFailureForChecks { dictationStopFailureForChecks = nil; throw failure }
            #endif
            let audio = try capture.stop()
            phase = .transcribing; store.progressText = "Распознаю поручение…"
            task = Task {
                defer { capture.discard() }
                do {
                    store.endJob()
                    guard let value = try await store.worker("dictate", extra: ["--audio", audio.path])?.dictation else {
                        throw AppError.message("Распознавание не вернуло текст поручения.")
                    }
                    guard current == generation, !Task.isCancelled else { return }
                    let addition = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if addition.isEmpty { message = "Речь не найдена. Повторите диктовку или введите текст." }
                    else { text += (text.isEmpty ? "" : " ") + addition; message = value.warnings.first }
                    phase = .editing
                } catch {
                    guard current == generation else { return }
                    phase = .editing; message = error is CancellationError ? "Диктовка остановлена." : error.localizedDescription
                }
            }
        } catch {
            capture.discard(); phase = .editing
            message = error is CancellationError ? "Диктовка остановлена." : error.localizedDescription
            store.endJob()
        }
    }
    #if DEBUG
    /// Seeds only the controller's reservation, never a microphone or audio file.
    func beginSyntheticDictationForChecks(stopFailure: Error) {
        precondition(store?.isPreview == true)
        generation = UUID(); task?.cancel(); task = nil
        dictationStopFailureForChecks = stopFailure
        store?.beginJob(id: nil); phase = .capturing
    }
    #endif
    func perform() {
        guard let store, !isWorking, !store.busy, !store.stoppingRecording else { return }
        guard store.settings.features.assistant else { store.openSettings("features"); return }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 8_000 else { message = "Сократите поручение или разделите его на несколько."; return }
        if interruptedPlanID != nil && plan == nil {
            message = "Сначала проверьте результат прерванного поручения в библиотеке. Чтобы создать новое, измените текст или нажмите «Новое поручение»."; return
        }
        if let plan, plan.status == "ready", plan.reviewRequired == true {
            prepareReview(plan)
            return
        }
        if let plan, plan.status == "ready" {
            generation = UUID(); let current = generation
            phase = .applying; store.beginJob(id: nil); store.canCancelJob = false
            store.progressText = "Продолжаю поручение…"
            task = Task {
                defer { if current == generation { store.endJob() } }
                do { try await apply(plan, generation: current) }
                catch { phase = .editing; message = error.localizedDescription }
            }
            return
        }
        generation = UUID(); let current = generation
        var input = context
        input["previousQuestions"] = previousQuestions
        input["text"] = command; input["now"] = Date().timeIntervalSince1970
        input["timeZoneOffsetMinutes"] = TimeZone.current.secondsFromGMT() / 60
        phase = .planning; message = nil; result = nil; plan = nil; knowledgeAnswer = nil; knowledgeOpeningID = nil
        task = Task {
            do {
                let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                guard var planned = try await store.worker("voice-plan", input: data)?.voicePlan else {
                    throw AppError.message("Не удалось разобрать поручение.")
                }
                guard current == generation, !Task.isCancelled else { return }
                var calendarQuestion = command
                if planned.status == "question" {
                    // Classification may take minutes. Capture permission and
                    // visible events now, immediately before the read-only
                    // synthesis job; selected context never enters this input.
                    guard let query = planned.query else { throw AppError.message("Не удалось подготовить вопрос по библиотеке.") }
                    let clock = Date()
                    calendarQuestion = command + "\n" + query
                    let snapshot = store.calendar.knowledgeSnapshot(question: calendarQuestion, now: clock)
                    let question: [String: Any] = ["text": command, "query": query, "questionOnly": true,
                        "now": clock.timeIntervalSince1970, "timeZoneOffsetMinutes": TimeZone.current.secondsFromGMT(for: clock) / 60,
                        "calendar": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))]
                    let questionData = try JSONSerialization.data(withJSONObject: question, options: [.sortedKeys])
                    guard let answered = try await store.worker("voice-plan", input: questionData)?.voicePlan,
                          answered.status == "answered" else { throw AppError.message("Не удалось получить ответ по библиотеке.") }
                    guard current == generation, !Task.isCancelled else { return }
                    planned = answered
                }
                plan = planned
                if planned.status == "answered" {
                    guard let answer = planned.knowledgeAnswer else { throw AppError.message("Не удалось прочитать ответ по библиотеке.") }
                    let checked = try await validateCalendarAnswer(answer, question: calendarQuestion)
                    guard current == generation, !Task.isCancelled else { return }
                    knowledgeAnswer = checked; result = nil; plan = nil
                    interruptedPlanID = nil; interruptedOperationID = nil; phase = .result
                }
                else if planned.status == "choose" { phase = .choosing }
                else if planned.status == "ready", planned.reviewRequired == true { prepareReview(planned) }
                else if planned.status == "ready" { try await apply(planned, generation: current) }
                else { phase = .editing; message = planned.detail }
            } catch {
                guard current == generation else { return }
                phase = .editing; message = error is CancellationError ? "Поручение остановлено." : error.localizedDescription
            }
        }
    }
    func choose(_ candidate: VoiceCandidate) {
        guard let store, phase == .choosing, let planID = plan?.planID, !store.busy else { return }
        generation = UUID(); let current = generation; phase = .applying
        store.beginJob(id: nil); store.canCancelJob = false; store.progressText = "Сохраняю…"
        task = Task {
            defer { if current == generation { store.endJob() } }
            do {
                let root = store.root
                let data = try await Task.detached(priority: .userInitiated) {
                    try RustBridge.shared.get().request(root: root, command: "voice-choose", arguments: ["planID": planID, "targetID": candidate.id])
                }.value
                let chosen = try JSONDecoder().decode(VoicePlan.self, from: data)
                plan = chosen
                if chosen.reviewRequired == true { prepareReview(chosen) }
                else { try await apply(chosen, generation: current) }
            } catch { phase = .editing; message = error.localizedDescription }
        }
    }
    private func prepareReview(_ value: VoicePlan) {
        plan = value
        selectedTargetIDs = Set((value.candidates ?? []).filter { $0.selected == true }.map(\.id))
        reviewText = value.text ?? ""
        message = nil; phase = .reviewing
    }
    var canConfirmReview: Bool {
        guard phase == .reviewing, let plan else { return false }
        let needsText = ["appendTaskContext", "appendTaskContexts", "appendTask"].contains(plan.action ?? "")
        return !selectedTargetIDs.isEmpty && (!needsText || !reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && reviewText.utf8.count <= 20_000
    }
    func toggleReviewTarget(_ candidate: VoiceCandidate, selected: Bool) {
        guard phase == .reviewing, (plan?.candidates ?? []).contains(where: { $0.id == candidate.id }) else { return }
        if selected {
            if plan?.selectionMode == "single" { selectedTargetIDs = [candidate.id] }
            else { selectedTargetIDs.insert(candidate.id) }
        } else { selectedTargetIDs.remove(candidate.id) }
    }
    func confirmReview() {
        guard let store, let plan, canConfirmReview, !store.busy else { return }
        guard store.settings.features.assistant else { store.openSettings("features"); return }
        generation = UUID(); let current = generation
        phase = .applying; store.beginJob(id: nil); store.canCancelJob = false
        store.progressText = "Сохраняю поручение…"
        task = Task {
            defer { if current == generation { store.endJob() } }
            do { try await apply(plan, generation: current, confirmed: true) }
            catch {
                guard current == generation else { return }
                phase = .reviewing; message = error.localizedDescription
            }
        }
    }
    private func apply(_ plan: VoicePlan, generation current: UUID, confirmed: Bool = false) async throws {
        guard let store, let id = plan.planID, let operation = plan.operationID else { throw AppError.message("Поручение не готово к выполнению.") }
        guard store.settings.features.assistant else { throw AppError.message("Включите помощника в настройках → Возможности.") }
        phase = .applying; store.canCancelJob = false
        guard flushDraft() else { throw AppError.message("Не удалось сохранить состояние поручения. Повторите попытку.") }
        let root = store.root
        var arguments: [String: Any] = ["planID": id, "operationID": operation]
        if plan.reviewRequired == true {
            guard confirmed else { throw AppError.message("Сначала проверьте изменения и подтвердите их.") }
            arguments["confirmed"] = true
            arguments["selectedTargetIDs"] = selectedTargetIDs.sorted()
            arguments["text"] = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let request = arguments
        let data = try await Task.detached(priority: .userInitiated) {
            try RustBridge.shared.get().request(root: root, command: "voice-apply", arguments: request)
        }.value
        guard current == generation else { return }
        result = try JSONDecoder().decode(VoiceResult.self, from: data)
        phase = .result; refresh()
        if ["openTask", "openCard", "openNote", "openMeeting"].contains(plan.action ?? "") { openResult() }
    }
    func undo() {
        guard let store, let result, result.canUndo, !store.busy else { return }
        phase = .applying; store.beginJob(id: nil); store.canCancelJob = false
        store.progressText = "Отменяю изменение…"
        let root = store.root
        task = Task {
            defer { store.endJob() }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try RustBridge.shared.get().request(root: root, command: "voice-undo", arguments: ["operationID": result.operationID])
                }.value
                self.result = nil; plan = nil; interruptedPlanID = nil; interruptedOperationID = nil
                phase = .editing; message = "Изменение отменено."; refresh()
            } catch { phase = .result; message = error.localizedDescription }
        }
    }
    func openResult() {
        guard let store, !isWorking, let target = result?.target else { return }
        if target.kind == "librarySource", let source = target.source {
            openLibraryResult(source); return
        }
        switch target.kind {
        case "task": store.openTask(id: target.id)
        case "trash": store.librarySection = "trash"
        case "meeting": store.librarySection = "meetings"; store.selection = target.meetingID ?? target.id; store.loadSelection()
        case "cards": store.librarySection = "cards"; store.selection = target.meetingID ?? target.id; store.loadSelection()
        default:
            store.librarySection = "inbox"; store.notes.selectedNoteID = target.id; store.notes.highlightedNoteID = target.id
        }
        isPresented = false
    }
    private func openLibraryResult(_ source: KnowledgeSource) {
        guard let store, !isWorking, knowledgeOpeningID == nil else { return }
        let current = generation, root = store.root
        knowledgeOpeningID = source.id
        task = Task {
            do {
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
                let valid = try await Task.detached(priority: .userInitiated) {
                    struct Validation: Decodable { var valid: Bool }
                    let data = try RustBridge.shared.get().request(root: root, command: "knowledge-validate-source", arguments: ["source": value])
                    return try JSONDecoder().decode(Validation.self, from: data).valid
                }.value
                guard current == generation, isPresented else { return }
                knowledgeOpeningID = nil
                guard valid else { throw AppError.message("Источник изменился. Повторите поиск.") }
                try store.revealKnowledgeSource(source, calendar: nil)
                dismiss()
            } catch {
                guard current == generation, isPresented else { return }
                knowledgeOpeningID = nil; message = error.localizedDescription
            }
        }
    }

    /// The worker's calendar snapshot was taken before the model call. Re-read
    /// EventKit only after it finishes, before exposing any event-derived fact.
    private func validateCalendarAnswer(_ answer: KnowledgeAnswer, question: String) async throws -> KnowledgeAnswer {
        guard let store else { throw CancellationError() }
        let cited = Set(answer.paragraphs.flatMap(\.sourceIDs))
        let sources = answer.sources.filter { $0.kind == "calendar" && cited.contains($0.id) }
        guard !sources.isEmpty else { return answer }
        let snapshot = store.calendar.knowledgeSnapshot(question: question, includingEventIDs: Set(sources.compactMap(\.eventID))), root = store.root
        let invalid: Set<String> = try await Task.detached(priority: .userInitiated) {
            struct Validation: Decodable { var valid: Bool }
            let calendar = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
            var invalid = Set<String>()
            for source in sources {
                try Task.checkCancellation()
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
                // A revoked permission, changed event, or unavailable check is
                // insufficient evidence to display the old calendar claim.
                do {
                    let data = try RustBridge.shared.get().request(root: root, command: "knowledge-validate-source", arguments: ["source": value, "calendar": calendar])
                    let validation = try JSONDecoder().decode(Validation.self, from: data)
                    if !validation.valid { invalid.insert(source.id) }
                } catch { invalid.insert(source.id) }
            }
            return invalid
        }.value
        try Task.checkCancellation()
        guard !invalid.isEmpty else { return answer }
        var checked = answer
        checked.paragraphs.removeAll { !$0.sourceIDs.allSatisfy { !invalid.contains($0) } }
        let remaining = Set(checked.paragraphs.flatMap(\.sourceIDs))
        checked.sources.removeAll { !remaining.contains($0.id) }
        let warning = "События календаря изменились во время ответа. Устаревшие утверждения убраны; задайте вопрос ещё раз."
        if !checked.warnings.contains(warning) { checked.warnings.append(warning) }
        if checked.paragraphs.isEmpty {
            checked.title = "Источники изменились"
            checked.paragraphs = [KnowledgeParagraph(text: "Не удалось подтвердить ответ по актуальным событиям календаря.")]
        }
        return checked
    }

    /// Citation routing is allowed only for a source in the current answer,
    /// after Rust has checked its fingerprint against the current library.
    func openKnowledgeSource(_ source: KnowledgeSource) {
        guard let store, !isWorking, phase == .result, knowledgeOpeningID == nil,
              knowledgeAnswer?.sources.contains(source) == true else { return }
        let current = generation, root = store.root
        let calendar = source.kind == "calendar" ? store.calendar.knowledgeSnapshot(question: text, includingEventIDs: Set([source.eventID].compactMap { $0 })) : nil
        knowledgeOpeningID = source.id; message = nil
        task = Task {
            do {
                var arguments: [String: Any] = ["source": try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))]
                if let calendar { arguments["calendar"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(calendar)) }
                let request = arguments
                let valid = try await Task.detached(priority: .userInitiated) {
                    struct Validation: Decodable { var valid: Bool }
                    let data = try RustBridge.shared.get().request(root: root, command: "knowledge-validate-source", arguments: request)
                    return try JSONDecoder().decode(Validation.self, from: data).valid
                }.value
                guard current == generation, isPresented, knowledgeAnswer?.sources.contains(source) == true else { return }
                knowledgeOpeningID = nil
                guard valid else { message = "Источник изменился или больше недоступен. Задайте вопрос ещё раз."; return }
                try store.revealKnowledgeSource(source, calendar: calendar)
                dismiss()
            } catch {
                guard current == generation, isPresented else { return }
                knowledgeOpeningID = nil; message = error.localizedDescription
            }
        }
    }

    func cancelWork() {
        guard let store, isWorking else { return }
        // Applying is a short atomic mutation. Do not announce cancellation
        // while a committed operation may already exist; it remains undoable.
        guard phase != .applying else { return }
        #if DEBUG
        dictationStopFailureForChecks = nil
        #endif
        let previousPhase = phase
        generation = UUID(); task?.cancel(); phase = .editing; knowledgeAnswer = nil; knowledgeOpeningID = nil
        if [.authorizing, .capturing].contains(previousPhase) { store.cancelJob() }
        if previousPhase == .capturing { capture.discard() }
        message = "Остановлено. Текст поручения сохранён."
        // Keep the global reservation until the underlying service exits.
        let pending = task
        task = Task {
            await pending?.value; capture.discard()
            if [.authorizing, .capturing].contains(previousPhase) { store.endJob() }
        }
    }
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = self?.flushDraft()
        }
    }
    @discardableResult func flushDraft() -> Bool {
        draftSaveTask?.cancel(); draftSaveTask = nil
        guard let store else { return true }
        let value = VoiceDraftRecord(text: phase == .result ? "" : text, contextLabel: contextLabel,
            meetingID: context["meetingID"] as? String, noteID: context["noteID"] as? String, taskID: context["taskID"] as? String,
            planID: plan?.planID ?? interruptedPlanID, operationID: plan?.operationID ?? interruptedOperationID,
            projectID: context["projectID"] as? String, selectedTargetIDs: phase == .reviewing || phase == .applying ? selectedTargetIDs.sorted() : nil,
            reviewText: phase == .reviewing || phase == .applying ? reviewText : nil,
            previousQuestions: previousQuestions.isEmpty ? nil : previousQuestions)
        do { try store.write(value, store.root.appendingPathComponent("voice-draft.json")); return true }
        catch { message = "Не удалось сохранить поручение. Оставьте панель открытой и повторите сохранение."; return false }
    }
    #if DEBUG
    var selectedContextForChecks: [String: String] { context.compactMapValues { $0 as? String } }
    func seedPreview(_ state: String) {
        contextLabel = "Пилот для отдела закупок"; isPresented = true
        text = "К задаче про договор добавь: проверить условия оплаты"
        knowledgeAnswer = nil; result = nil; plan = nil
        if state == "voice-answer" {
            text = "Что нужно подготовить к запуску пилота?"; contextLabel = "Вся библиотека"
            knowledgeAnswer = KnowledgeAnswer(title: "Подготовка к пилоту", paragraphs: [
                KnowledgeParagraph(text: "Проверить условия оплаты и согласовать договор с закупками.", sourceIDs: ["task-contract"]),
                KnowledgeParagraph(text: "До запуска нужен доступ к тестовому стенду. На обсуждении отдельно договорились проверить права на выгрузку.", sourceIDs: ["note-access"]),
                KnowledgeParagraph(text: "Промежуточные результаты обсудим в четверг в 10:00.", sourceIDs: ["calendar-review"])
            ], sources: [
                KnowledgeSource(id: "task-contract", kind: "task", title: "Согласовать договор", excerpt: "Проверить условия оплаты и согласовать договор с закупками.", taskID: "preview-task", sourceFingerprint: "preview"),
                KnowledgeSource(id: "note-access", kind: "note", title: "Доступ к стенду", excerpt: "Для пилота нужен доступ к тестовому стенду. Проверить права на выгрузку.", noteID: "preview-note", sourceFingerprint: "preview"),
                KnowledgeSource(id: "calendar-review", kind: "calendar", title: "Промежуточные результаты", excerpt: "Четверг, 10:00–11:00 · Рабочий", eventID: "project-checkpoint", sourceFingerprint: "preview")
            ])
            phase = .result
        }
        else if state == "voice-result" {
            result = VoiceResult(operationID: "preview", title: "Дополнена задача «Согласовать договор»", detail: "Проверить условия оплаты.", target: VoiceTarget(kind: "task", id: "preview-task"), canUndo: true)
            phase = .result
        }
    }
    #endif
    private func refresh() {
        guard let store else { return }
        store.notes.reload(); store.notes.loadTasks(); store.reloadLibrary()
        if let id = store.selection { store.refreshResults(id) }
    }
}

extension AppStore {
    func presentVoice() { voice.present() }
    func confirmVoiceUpload() -> Bool {
        guard !isPreview else { return false }
        let alert = NSAlert(); alert.messageText = "Распознать диктовку в облаке?"
        alert.informativeText = "Аудио поручения будет отправлено на \(settings.resolvedSpeechEndpoint)\nМодель: \(settings.speechCloudModel)"
        alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
