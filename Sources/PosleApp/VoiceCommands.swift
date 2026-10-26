import AppKit
import AVFoundation
import Combine
import Foundation
import PosleCore

struct VoiceTarget: Codable, Hashable {
    var kind: String
    var id: String
    var meetingID: String?
}
struct VoiceCandidate: Codable, Identifiable {
    var id: String
    var title: String
    var detail: String
}
struct VoicePlan: Codable {
    var status: String
    var planID: String?
    var operationID: String?
    var title: String
    var detail: String
    var target: VoiceTarget?
    var candidates: [VoiceCandidate]?
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
    enum Phase: String { case editing, authorizing, capturing, transcribing, planning, choosing, applying, result }
    @Published var isPresented = false
    @Published var text = "" { didSet {
        guard !restoringDraft else { return }
        if text != oldValue && phase == .editing { plan = nil; interruptedPlanID = nil; interruptedOperationID = nil }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = self?.flushDraft()
        }
    } }
    @Published private(set) var phase = Phase.editing { didSet { if !restoringDraft { _ = flushDraft() } } }
    @Published private(set) var message: String?
    @Published private(set) var plan: VoicePlan?
    @Published private(set) var result: VoiceResult?
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
    private var generation = UUID()
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
                        message = "Поручение прервалось. Нажмите «Выполнить», чтобы продолжить."
                    }
                } catch {
                    message = "Не удалось проверить результат прерванного поручения. Проверьте библиотеку перед повтором."
                }
            }
        }
    }
    func present(taskID: String? = nil, title: String? = nil) {
        guard let store else { return }
        if !hasDraft && !isWorking {
            text = ""; plan = nil; result = nil; phase = .editing; message = nil; context = [:]
            if let taskID { context["taskID"] = taskID; contextLabel = title ?? "Задача" }
            else if store.librarySection == "meetings", let meeting = store.selected, meeting.libraryKind != "cards" {
                context["meetingID"] = meeting.id; contextLabel = meeting.title
            } else if store.librarySection == "inbox", let id = store.notes.selectedNoteID,
                      let note = store.notes.notes.first(where: { $0.id == id }) {
                context["noteID"] = id; contextLabel = note.displayTitle
            } else { contextLabel = "Библиотека" }
        }
        isPresented = true
        NSApp.activate(ignoringOtherApps: true)
    }
    func dismiss() {
        guard phase != .applying else { return }
        if isWorking { cancelWork() }
        _ = flushDraft(); isPresented = false
    }
    func editCommand() {
        guard !isWorking else { return }; phase = .editing; plan = nil; message = nil
    }
    func reset() {
        guard !isWorking else { return }
        text = ""; plan = nil; result = nil; interruptedPlanID = nil; interruptedOperationID = nil; phase = .editing; message = nil
        isPresented = false; present()
    }
    func startDictation() {
        guard let store, !isWorking else { return }
        guard !store.busy, !store.isRecording else {
            message = store.isRecording ? "Во время записи встречи введите поручение текстом. Микрофон занят записью." : "Дождитесь текущей обработки."; return
        }
        guard !store.isPreview else { message = "В режиме просмотра введите поручение текстом."; return }
        guard store.runtimeReady else { message = "Подготовьте распознавание в настройках."; return }
        if store.settings.speechMode == "cloud", !store.confirmVoiceUpload() { return }
        generation = UUID(); let current = generation
        store.beginJob(id: nil); store.progressText = "Диктовка…"
        phase = .authorizing; message = nil; plan = nil; result = nil
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
            let audio = try capture.stop()
            phase = .transcribing; store.progressText = "Распознаю поручение…"
            task = Task {
                defer { capture.discard() }
                do {
                    try store.write(store.settings, store.root.appendingPathComponent("settings.json"))
                    let key = store.settings.speechMode == "cloud" && !store.isPreview
                        ? Keychain.read(account: Keychain.speechAccount(for: store.settings)) : nil
                    let value = try await store.embeddedSpeech.dictate(root: store.root, interpreter: store.python,
                        backend: store.backend, audio: audio, apiKey: key, event: { _ in })
                    guard current == generation, !Task.isCancelled else { return }
                    let addition = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if addition.isEmpty { message = "Речь не найдена. Повторите диктовку или введите текст." }
                    else { text += (text.isEmpty ? "" : " ") + addition; message = value.warnings.first }
                    phase = .editing; store.endJob()
                } catch {
                    guard current == generation else { return }
                    phase = .editing; message = error is CancellationError ? "Диктовка остановлена." : error.localizedDescription; store.endJob()
                }
            }
        } catch { capture.discard(); phase = .editing; message = error.localizedDescription; store.endJob() }
    }
    func perform() {
        guard let store, !isWorking, !store.busy, !store.stoppingRecording else { return }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.utf8.count <= 8_000 else { message = "Сократите поручение или разделите его на несколько."; return }
        if interruptedPlanID != nil && plan == nil {
            message = "Сначала проверьте результат прерванного поручения в библиотеке. Чтобы создать новое, измените текст или нажмите «Новое поручение»."; return
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
        input["text"] = command; input["now"] = Date().timeIntervalSince1970
        input["timeZoneOffsetMinutes"] = TimeZone.current.secondsFromGMT() / 60
        phase = .planning; message = nil; result = nil; plan = nil
        store.beginJob(id: nil); store.progressText = "Разбираю поручение…"
        task = Task {
            defer { if current == generation { store.endJob() } }
            do {
                let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                guard let planned = try await store.worker("voice-plan", input: data)?.voicePlan else {
                    throw AppError.message("Не удалось разобрать поручение.")
                }
                guard current == generation, !Task.isCancelled else { return }
                plan = planned
                if planned.status == "choose" { phase = .choosing }
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
                plan = chosen; try await apply(chosen, generation: current)
            } catch { phase = .editing; message = error.localizedDescription }
        }
    }
    private func apply(_ plan: VoicePlan, generation current: UUID) async throws {
        guard let store, let id = plan.planID, let operation = plan.operationID else { throw AppError.message("Поручение не готово к выполнению.") }
        phase = .applying; store.canCancelJob = false
        guard flushDraft() else { throw AppError.message("Не удалось сохранить состояние поручения. Повторите попытку.") }
        let root = store.root
        let data = try await Task.detached(priority: .userInitiated) {
            try RustBridge.shared.get().request(root: root, command: "voice-apply", arguments: ["planID": id, "operationID": operation])
        }.value
        guard current == generation else { return }
        result = try JSONDecoder().decode(VoiceResult.self, from: data)
        phase = .result; refresh()
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
        switch target.kind {
        case "task": store.librarySection = "tasks"; store.notes.selectedTaskID = "manual:\(target.id)"
        case "cards": store.librarySection = "cards"; store.selection = target.meetingID ?? target.id; store.loadSelection()
        default:
            store.librarySection = "inbox"; store.notes.selectedNoteID = target.id; store.notes.highlightedNoteID = target.id
        }
        isPresented = false
    }
    func cancelWork() {
        guard let store, isWorking else { return }
        // Applying is a short atomic mutation. Do not announce cancellation
        // while a committed operation may already exist; it remains undoable.
        guard phase != .applying else { return }
        let previousPhase = phase
        generation = UUID(); task?.cancel(); phase = .editing; store.cancelJob()
        if previousPhase == .capturing { capture.discard() }
        message = "Остановлено. Текст поручения сохранён."
        // Keep the global reservation until the underlying service exits.
        let pending = task
        task = Task { await pending?.value; capture.discard(); store.endJob() }
    }
    @discardableResult func flushDraft() -> Bool {
        draftSaveTask?.cancel(); draftSaveTask = nil
        guard let store else { return true }
        let value = VoiceDraftRecord(text: phase == .result ? "" : text, contextLabel: contextLabel,
            meetingID: context["meetingID"] as? String, noteID: context["noteID"] as? String, taskID: context["taskID"] as? String, planID: plan?.planID ?? interruptedPlanID, operationID: plan?.operationID ?? interruptedOperationID)
        do { try store.write(value, store.root.appendingPathComponent("voice-draft.json")); return true }
        catch { message = "Не удалось сохранить поручение. Оставьте панель открытой и повторите сохранение."; return false }
    }
    #if DEBUG
    func seedPreview(_ state: String) {
        contextLabel = "Пилот для отдела закупок"; isPresented = true
        text = "К задаче про договор добавь: проверить условия оплаты"
        if state == "voice-result" {
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
