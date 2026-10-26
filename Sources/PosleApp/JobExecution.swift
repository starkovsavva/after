import Foundation
import CryptoKit
import PosleCore

extension AppStore {
    static let queuedCommands: Set<String> = ["transcribe", "diarize", "finalize", "dictate", "summarize", "example", "expand-notes", "voice-plan"]

    func queuedWorker(_ command: String, id: String?, extra: [String], input: Data?) async throws -> WorkerEvent? {
        guard !isTerminating else { throw CancellationError() }
        let configuration = JobConfiguration(command: command, meetingID: id, extra: extra, input: input, settings: settings)
        let speech = ["transcribe", "diarize", "finalize", "dictate"].contains(command)
        let cloud = speech ? ["transcribe", "dictate"].contains(command) && settings.speechMode == "cloud" : settings.mode == "cloud"
        let resource = ["finalize", "dictate", "diarize"].contains(command) || (command == "transcribe" && settings.diarization) ? "local-heavy" : cloud ? "cloud" : "local-heavy"
        let revision = try jobInputRevision(command: command, meetingID: id, input: input)
        let label: String
        switch command {
        case "transcribe": label = "Распознавание"
        case "diarize": label = "Собеседники"
        case "finalize": label = "Подготовка MP3"
        case "summarize": label = "Конспект"
        case "example": label = "Пример к карточке"
        case "voice-plan": label = "Голосовое поручение"
        case "dictate": label = "Диктовка поручения"
        default: label = "Дополнение заметки"
        }
        let title = id.flatMap { value in meetings.first(where: { $0.id == value })?.title }.map { "\(label) · \($0)" } ?? label
        return try await jobs.submit(configuration, resource: resource, revision: revision, title: title, paid: cloud)
    }

    func jobInputRevision(command: String, meetingID: String?, input: Data?) throws -> String {
        if let id = meetingID, command != "finalize" {
            let data = try RustBridge.shared.get().request(root: root, command: "meeting-content-snapshot", arguments: ["meetingID": id])
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let transcript = value["transcriptFingerprint"] as? String ?? ""
            let summary = value["summaryFingerprint"] as? String ?? ""
            return command == "transcribe" ? transcript : transcript + ":" + summary
        }
        return input.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
    }

    /// A snapshot belongs to the queued operation, including its provider/key scope.
    /// Changing Settings while it waits never redirects data to a different service.
    func executeBackgroundJob(_ job: BackgroundJob, cancellation: JobCancellation,
                              event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        let config = job.config
        guard Self.queuedCommands.contains(config.command) else { throw AppError.message("Неизвестная фоновая операция.") }
        guard !cancellation.isCancelled else { throw CancellationError() }
        try validateJobRevision(job)
        let snapshot = config.settings
        let usesLocalRuntime = job.resource == "local-heavy" || ["transcribe", "diarize", "finalize", "dictate"].contains(config.command)
        let lease = usesLocalRuntime ? try await localRuntimeLease.acquire { cancellation.isCancelled } : nil
        defer { if let lease { Task { await localRuntimeLease.release(lease) } } }
        guard !cancellation.isCancelled else { throw CancellationError() }
        try validateJobRevision(job)
        if ["transcribe", "diarize", "finalize"].contains(config.command), !runtimeReady {
            throw AppError.message("Запись сохранена. Подготовьте распознавание в настройках и повторите операцию.")
        }
        if snapshot.mode == "local", ["summarize", "example", "expand-notes", "voice-plan"].contains(config.command) {
            try await localService.ensure(root: root, settings: snapshot, cancelled: { cancellation.isCancelled })
        }
        guard !cancellation.isCancelled else { throw CancellationError() }
        // Preparation may suspend for model startup while the source is being edited.
        try validateJobRevision(job)
        var arguments = [config.command, "--root", root.path, "--backend", backend.path]
        if let id = config.meetingID { arguments += ["--meeting", meetingDirectory(id).path] }
        arguments += config.extra
        let settingsJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        var environment = ["PYTHONUNBUFFERED": "1", "HF_HOME": root.appendingPathComponent("cache/huggingface").path,
                           "HF_HUB_DISABLE_TELEMETRY": "1", "POSLE_OLLAMA_URL": localService.baseURL,
                           "POSLE_JOB_SETTINGS": settingsJSON]
        if snapshot.mode == "cloud", ["summarize", "example", "expand-notes", "voice-plan"].contains(config.command) {
            environment["POSLE_API_KEY"] = isPreview ? "" : Keychain.read(account: Keychain.account(for: snapshot))
        }
        if snapshot.speechMode == "cloud", config.command == "transcribe" {
            environment["POSLE_SPEECH_API_KEY"] = isPreview ? "" : Keychain.read(account: Keychain.speechAccount(for: snapshot))
        }
        let result: WorkerEvent?
        if config.command == "dictate" {
            guard let index = config.extra.firstIndex(of: "--audio"), config.extra.indices.contains(index + 1) else { throw AppError.message("Не выбрана запись поручения.") }
            embeddedSpeech.resetCancellation()
            try cancellation.attachEmbedded { [embeddedSpeech] in embeddedSpeech.cancel() }
            let value = try await embeddedSpeech.dictate(root: root, interpreter: python, backend: backend,
                audio: URL(fileURLWithPath: config.extra[index + 1]),
                apiKey: snapshot.speechMode == "cloud" && !isPreview ? Keychain.read(account: Keychain.speechAccount(for: snapshot)) : nil,
                settings: try JSONEncoder().encode(snapshot), event: event)
            var done = WorkerEvent(event: "done"); done.dictation = value; result = done
        } else if config.command == "diarize" || config.command == "finalize" || (config.command == "transcribe" && snapshot.speechMode == "local") {
            let index = config.extra.firstIndex(of: "--speakers")
            let speakers = index.flatMap { config.extra.indices.contains($0 + 1) ? Int(config.extra[$0 + 1]) : nil } ?? snapshot.speakerCount
            embeddedSpeech.resetCancellation()
            try cancellation.attachEmbedded { [embeddedSpeech] in embeddedSpeech.cancel() }
            result = try await embeddedSpeech.run(root: root, interpreter: python, backend: backend, command: config.command,
                meeting: config.meetingID.map { meetingDirectory($0) }, speakers: speakers,
                diarization: !config.extra.contains("--no-diarization") && snapshot.diarization,
                settings: try JSONEncoder().encode(snapshot), event: event)
        } else {
            result = try await cancellation.runner.run(rustEngine, arguments: arguments, environment: environment, input: config.input, event: event)
        }
        if let id = config.meetingID {
            if config.command == "summarize" { updateMeeting(id) { $0.status = "ready"; $0.error = nil } }
            else if config.command == "transcribe" { updateMeeting(id) { $0.status = "transcribed"; $0.error = nil } }
            refreshResults(id)
        }
        return result
    }

    private func validateJobRevision(_ job: BackgroundJob) throws {
        let config = job.config
        let current = try jobInputRevision(command: config.command, meetingID: config.meetingID, input: config.input)
        let followsTranscript = config.command == "summarize" && job.inputRevision.hasPrefix("dependency:") && job.dependencies.contains(String(job.inputRevision.dropFirst("dependency:".count)))
        guard current == job.inputRevision || followsTranscript else {
            throw AppError.message("Данные изменились после постановки в очередь. Запустите операцию заново из встречи или карточки.")
        }
    }

    func enqueueExample(_ card: Flashcard, meetingID: String) {
        Task {
            do { try await worker("example", id: meetingID, extra: ["--card", card.id]); refreshResults(meetingID) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
