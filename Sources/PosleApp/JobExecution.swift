import AppKit
import Foundation
import CryptoKit
import PosleCore

extension AppStore {
    private static let chatGPTAICommands = ["summarize", "example", "expand-notes", "voice-plan"]
    static let queuedCommands: Set<String> = ["transcribe", "diarize", "finalize", "dictate", "summarize", "example", "expand-notes", "voice-plan"]

    struct PreparedBackgroundJob {
        var configuration: JobConfiguration
        var resource: String
        var revision: String
        var title: String
        var paid: Bool
    }

    func queuedWorker(_ command: String, id: String?, extra: [String], input: Data?) async throws -> WorkerEvent? {
        try await submitPreparedJob(prepareBackgroundJob(command, id: id, extra: extra, input: input))
    }

    private func prepareBackgroundJob(_ command: String, id: String?, extra: [String], input: Data?, restartOfJobID: String? = nil) throws -> PreparedBackgroundJob {
        guard !isTerminating else { throw CancellationError() }
        // Model/account changes can arrive from the Settings catalog after its
        // last save. Commit this exact selection before Rust fingerprints the
        // profile; otherwise the durable job captures memory while its profile
        // describes the previous settings.json and every retry fails closed.
        try write(settings, root.appendingPathComponent("settings.json"))
        let scope = try jobProfileScope(meetingID: id, extra: extra, input: input, capturedFolderID: folderSelection, refresh: true)
        let (profile, profileData) = try folderProfile(for: scope.meetingID, folderID: scope.folderID)
        // The resolved profile owns current membership/overrides. A stale view
        // cache must not select a different model from the committed profile.
        let snapshot = profile.overrides.apply(to: settings)
        try validateOptionalJob(command, features: snapshot.features)
        if snapshot.mode == "cloud", snapshot.cloudProvider == "chatgpt", Self.chatGPTAICommands.contains(command),
           disconnectingChatGPTAccounts.contains(snapshot.chatGPTAccountID) {
            throw AppError.message(L("Выполняется выход из ChatGPT. Повторите после входа в нужный аккаунт."))
        }
        // EventKit evidence is permission-scoped and volatile. Persist only the
        // request; each execution attempt obtains its own authorized snapshot.
        let persistedInput = try Self.persistableJobInput(command: command, input: input)
        let restartOfJobID = try restartOfJobID ?? voiceRestartID(command: command, input: input)
        let configuration = JobConfiguration(command: command, meetingID: id, extra: extra, input: persistedInput, settings: snapshot, folderProfile: profileData, folderID: profile.folderID, profileMeetingID: scope.meetingID, restartOfJobID: restartOfJobID)
        let speech = ["transcribe", "diarize", "finalize", "dictate"].contains(command)
        let cloud = speech ? ["transcribe", "dictate"].contains(command) && snapshot.speechMode == "cloud" : snapshot.mode == "cloud"
        let resource = ["finalize", "dictate", "diarize"].contains(command) || (command == "transcribe" && snapshot.diarization) ? "local-heavy" : cloud ? "cloud" : "local-heavy"
        let revision = try jobInputRevision(command: command, meetingID: id, input: persistedInput, extra: extra)
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
        return PreparedBackgroundJob(configuration: configuration, resource: resource, revision: revision, title: title, paid: cloud)
    }

    func submitPreparedJob(_ prepared: PreparedBackgroundJob) async throws -> WorkerEvent? {
        let config = prepared.configuration
        guard !isTerminating else { throw CancellationError() }
        // Confirmation can run a nested event loop. Never accept a changed
        // profile/source between preparing the displayed route and admission.
        try validateJobProfile(config)
        guard try jobInputRevision(command: config.command, meetingID: config.meetingID, input: config.input, extra: config.extra) == prepared.revision else {
            throw AppError.message(L("Данные изменились после подготовки операции. Запустите её заново из встречи или карточки."))
        }
        return try await jobs.submit(config, resource: prepared.resource, revision: prepared.revision, title: prepared.title, paid: prepared.paid)
    }

    /// Explicit recovery captures the original source with today's canonical
    /// profile. It never mutates or silently retries the old frozen operation.
    func prepareRestartedJob(_ original: BackgroundJob) throws -> PreparedBackgroundJob {
        guard original.canRestartWithCurrentProfile else {
            throw AppError.message(L("Эту операцию нельзя запустить заново с текущим профилем."))
        }
        // Consent to replacing manual edits belongs to the source revision the
        // user originally reviewed. A historical failure cannot reuse it.
        let extra = original.config.extra.filter { $0 != "--replace-manual-summary" }
        return try prepareBackgroundJob(original.config.command, id: original.config.meetingID, extra: extra,
                                        input: original.config.input, restartOfJobID: original.id)
    }

    func restartProfileFailedJob(_ original: BackgroundJob) {
        do {
            let prepared = try prepareRestartedJob(original)
            let snapshot = prepared.configuration.settings
            let provider = snapshot.mode == "cloud" ? snapshot.cloudProviderTitle
                : snapshot.localProvider == "lmstudio" ? "LM Studio" : snapshot.localProvider == "ollama" ? "Ollama" : L("На этом Mac")
            let model = snapshot.mode == "cloud" ? snapshot.cloudModel : snapshot.localModel
            let alert = NSAlert()
            alert.messageText = L("Запустить заново с текущими настройками?")
            var explanation = LF("Новая операция: {0} · {1}. Предыдущая попытка останется в истории.", arguments: [provider, model])
            if prepared.paid {
                explanation += "\n\n" + (snapshot.cloudProvider == "chatgpt"
                    ? L("Новый запрос использует лимит подписки ChatGPT.")
                    : L("Новый запрос может оплачиваться выбранным сервисом."))
            }
            alert.informativeText = explanation
            alert.addButton(withTitle: L("Запустить заново")); alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            jobs.showing = false
            Task {
                do { _ = try await submitPreparedJob(prepared); jobs.error = nil }
                catch is CancellationError {} catch { jobs.error = error.localizedDescription }
            }
        } catch { jobs.error = error.localizedDescription }
    }

    func jobInputRevision(command: String, meetingID: String?, input: Data?, extra: [String] = []) throws -> String {
        if command == "expand-notes" {
            guard let index = extra.firstIndex(of: "--note"), extra.indices.contains(index + 1), !extra[index + 1].isEmpty else {
                throw AppError.message(L("Выберите заметку для дополнения."))
            }
            let noteID = extra[index + 1]
            let bridge = try RustBridge.shared.get()
            let workspace = try JSONDecoder().decode(NotesWorkspace.self, from: bridge.request(root: root, command: "notes-list"))
            guard let note = workspace.notes.first(where: { $0.id == noteID && $0.trashedAt == nil }) else {
                throw AppError.message(L("Заметка не найдена. Обновите библиотеку."))
            }
            // Independent note jobs have neither meetingID nor stdin input.
            // Bind confirmation and queued execution to the canonical source,
            // including attachment membership/extracted text and its revision.
            var source: [String: Any] = ["note": try JSONSerialization.jsonObject(with: JSONEncoder().encode(note))]
            if let sourceMeetingID = note.meetingID {
                let data = try bridge.request(root: root, command: "meeting-content-snapshot", arguments: ["meetingID": sourceMeetingID])
                let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                source["transcriptFingerprint"] = snapshot["transcriptFingerprint"] ?? ""
                let metadata = try JSONSerialization.jsonObject(with: bridge.read(root: root, url: meetingDirectory(sourceMeetingID).appendingPathComponent("meta.json"))) as? [String: Any] ?? [:]
                source["meetingTitle"] = metadata["title"] ?? ""
            }
            let data = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
            return "note-source-v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        if let id = meetingID, command != "finalize" {
            let data = try RustBridge.shared.get().request(root: root, command: "meeting-content-snapshot", arguments: ["meetingID": id])
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let transcript = value["transcriptFingerprint"] as? String ?? ""
            let summary = value["summaryFingerprint"] as? String ?? ""
            return command == "transcribe" ? transcript : transcript + ":" + summary
        }
        return input.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
    }

    static func persistableJobInput(command: String, input: Data?) throws -> Data? {
        guard command == "voice-plan", let input else { return input }
        guard var request = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw AppError.message(L("Не удалось прочитать запрос голосового поручения."))
        }
        request.removeValue(forKey: "restartOfJobID")
        request.removeValue(forKey: "calendar")
        request.removeValue(forKey: "embeddingAPIKey")
        request.removeValue(forKey: "embeddingConfigFingerprint")
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    private func voiceRestartID(command: String, input: Data?) throws -> String? {
        guard command == "voice-plan", let input,
              let request = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let id = request["restartOfJobID"] as? String else { return nil }
        struct Record: Decodable { var job: BackgroundJob }
        let data = try RustBridge.shared.get().request(root: root, command: "job-get", arguments: ["jobID": id])
        let previous = try JSONDecoder().decode(Record.self, from: data).job
        let source = previous.config.input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard previous.canReopenVoiceCommand, let sourceText = source?["text"] as? String,
              let text = request["text"] as? String, sourceText == text else {
            throw AppError.message(L("Исходное поручение изменилось. Откройте его заново из фоновых задач."))
        }
        return id
    }

    /// AppStore is MainActor-isolated. This runs after all suspending startup
    /// work, including credentials, for initial, resumed and historical retries.
    func executionJobInput(_ config: JobConfiguration) throws -> Data? {
        guard config.command == "voice-plan", let input = try Self.persistableJobInput(command: config.command, input: config.input) else {
            return config.input
        }
        guard var request = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw AppError.message(L("Не удалось прочитать запрос голосового поручения."))
        }
        if !isPreview, effectiveSettings(for: config.profileMeetingID, folderID: config.folderID).features.semanticSearch {
            struct SemanticSettings: Decodable { var config: SemanticSearchConfiguration; var fingerprint: String }
            let data = try RustBridge.shared.get().request(root: root, command: "semantic-config")
            let envelope = try JSONDecoder().decode(SemanticSettings.self, from: data)
            let semantic = envelope.config
            if semantic.enabled, let account = semantic.keyAccount {
                let key = try Keychain.readChecked(account: account)
                if !key.isEmpty { request["embeddingAPIKey"] = key; request["embeddingConfigFingerprint"] = envelope.fingerprint }
            }
        }
        if request["questionOnly"] as? Bool == true {
            guard let question = request["text"] as? String else {
                throw AppError.message(L("Нет вопроса помощнику."))
            }
            let now = Date()
            let resolved = (request["query"] as? String).map { question + "\n" + $0 } ?? question
            let snapshot = calendar.knowledgeSnapshot(question: resolved, now: now)
            request["now"] = now.timeIntervalSince1970
            request["timeZoneOffsetMinutes"] = TimeZone.current.secondsFromGMT(for: now) / 60
            request["calendar"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        }
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    /// A snapshot belongs to the queued operation, including its provider/key scope.
    /// Changing Settings while it waits never redirects data to a different service.
    func executeBackgroundJob(_ job: BackgroundJob, cancellation: JobCancellation,
                              event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        let config = job.config
        guard Self.queuedCommands.contains(config.command) else { throw AppError.message(L("Неизвестная фоновая операция.")) }
        guard !cancellation.isCancelled else { throw CancellationError() }
        try validateJobProfile(config)
        try validateOptionalJob(config.command, features: effectiveSettings(for: config.profileMeetingID ?? config.meetingID, folderID: config.folderID).features)
        try validateJobRevision(job)
        let snapshot = config.settings
        let usesLocalRuntime = job.resource == "local-heavy" || ["transcribe", "diarize", "finalize", "dictate"].contains(config.command)
        let lease = usesLocalRuntime ? try await localRuntimeLease.acquire { cancellation.isCancelled } : nil
        defer { if let lease { Task { await localRuntimeLease.release(lease) } } }
        guard !cancellation.isCancelled else { throw CancellationError() }
        try validateJobProfile(config)
        try validateOptionalJob(config.command, features: effectiveSettings(for: config.profileMeetingID ?? config.meetingID, folderID: config.folderID).features)
        try validateJobRevision(job)
        if ["transcribe", "diarize"].contains(config.command), !runtimeReady {
            throw AppError.message(L("Запись сохранена. Подготовьте распознавание в настройках и повторите операцию."))
        }
        if snapshot.mode == "local", ["summarize", "example", "expand-notes", "voice-plan"].contains(config.command) {
            try await localService.ensure(root: root, settings: snapshot, cancelled: { cancellation.isCancelled })
        }
        guard !cancellation.isCancelled else { throw CancellationError() }
        // Preparation may suspend for model startup while the source is being edited.
        try validateJobProfile(config)
        try validateOptionalJob(config.command, features: effectiveSettings(for: config.profileMeetingID ?? config.meetingID, folderID: config.folderID).features)
        try validateJobRevision(job)
        var arguments = [config.command, "--root", root.path, "--backend", backend.path]
        if let id = config.meetingID { arguments += ["--meeting", meetingDirectory(id).path] }
        arguments += config.extra
        let settingsJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        var environment = ["PYTHONUNBUFFERED": "1", "HF_HOME": root.appendingPathComponent("cache/huggingface").path,
                           "HF_HUB_DISABLE_TELEMETRY": "1", "POSLE_OLLAMA_URL": localService.baseURL,
                           "POSLE_JOB_SETTINGS": settingsJSON]
        if let profile = config.folderProfile { environment["POSLE_JOB_FOLDER_PROFILE"] = String(decoding: profile, as: UTF8.self) }
        if snapshot.mode == "cloud", ["summarize", "example", "expand-notes", "voice-plan"].contains(config.command) {
            environment["POSLE_API_KEY"] = try await cloudCredential(for: snapshot)
        }
        if snapshot.speechMode == "cloud", config.command == "transcribe" {
            environment["POSLE_SPEECH_API_KEY"] = isPreview ? "" : Keychain.read(account: Keychain.speechAccount(for: snapshot))
        }
        guard !cancellation.isCancelled, !isTerminating else { throw CancellationError() }
        let result: WorkerEvent?
        if config.command == "dictate" {
            guard let index = config.extra.firstIndex(of: "--audio"), config.extra.indices.contains(index + 1) else { throw AppError.message(L("Не выбрана запись поручения.")) }
            embeddedSpeech.resetCancellation()
            try cancellation.attachEmbedded { [embeddedSpeech] in embeddedSpeech.cancel() }
            let value = try await embeddedSpeech.dictate(root: root, interpreter: python, backend: backend,
                audio: URL(fileURLWithPath: config.extra[index + 1]),
                apiKey: snapshot.speechMode == "cloud" && !isPreview ? Keychain.read(account: Keychain.speechAccount(for: snapshot)) : nil,
                settings: try JSONEncoder().encode(snapshot), event: event)
            var done = WorkerEvent(event: "done"); done.dictation = value; result = done
        } else if config.command == "diarize" || (config.command == "transcribe" && snapshot.speechMode == "local") {
            let index = config.extra.firstIndex(of: "--speakers")
            let speakers = index.flatMap { config.extra.indices.contains($0 + 1) ? Int(config.extra[$0 + 1]) : nil } ?? snapshot.speakerCount
            embeddedSpeech.resetCancellation()
            try cancellation.attachEmbedded { [embeddedSpeech] in embeddedSpeech.cancel() }
            result = try await embeddedSpeech.run(root: root, interpreter: python, backend: backend, command: config.command,
                meeting: config.meetingID.map { meetingDirectory($0) }, speakers: speakers,
                diarization: !config.extra.contains("--no-diarization") && snapshot.diarization,
                settings: try JSONEncoder().encode(snapshot), event: event)
        } else {
            let executionInput = try executionJobInput(config)
            result = try await cancellation.runner.run(rustEngine, arguments: arguments, environment: environment, input: executionInput, event: event)
        }
        if let id = config.meetingID {
            if config.command == "summarize" { updateMeeting(id) { $0.status = "ready"; $0.error = nil } }
            else if config.command == "transcribe" { updateMeeting(id) { $0.status = "transcribed"; $0.error = nil } }
            refreshResults(id)
        }
        return result
    }

    func jobProfileScope(meetingID: String?, extra: [String], input: Data?, capturedFolderID: String? = nil, refresh: Bool = false) throws -> (meetingID: String?, folderID: String?) {
        if let meetingID { return (meetingID, nil) }
        let request = input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let id = request["meetingID"] as? String { return (id, nil) }
        let noteID = (request["noteID"] as? String) ?? extra.firstIndex(of: "--note").flatMap { index in extra.indices.contains(index + 1) ? extra[index + 1] : nil }
        let workspace: NotesWorkspace
        if refresh, noteID != nil || request["taskID"] != nil {
            workspace = try JSONDecoder().decode(NotesWorkspace.self, from: RustBridge.shared.get().request(root: root, command: "notes-list"))
        } else { workspace = notes.workspace }
        if let noteID, let note = workspace.notes.first(where: { $0.id == noteID }) {
            if let folderID = note.folderID { return (nil, folderID) }
            return (note.meetingID, nil)
        }
        if let taskID = request["taskID"] as? String {
            // Match Rust FeatureResolver: task-list is a view cache and can lag
            // a task just created/moved through MCP or an import. Stable task
            // IDs resolve directly to committed notes or their source meeting.
            if taskID.hasPrefix("summary:") {
                return (String(taskID.dropFirst("summary:".count).split(separator: ":", omittingEmptySubsequences: false).first ?? ""), nil)
            }
            let sourceID = taskID.hasPrefix("manual:") ? String(taskID.dropFirst("manual:".count)) : taskID
            if let note = workspace.notes.first(where: { $0.id == sourceID }) {
                if let folderID = note.folderID { return (nil, folderID) }
                return (note.meetingID, nil)
            }
            if let task = notes.tasks.first(where: { $0.id == taskID }) { return (task.meetingID, nil) }
        }
        // An explicit null is a captured base-library scope, not an invitation
        // to substitute a different sidebar folder after the command began.
        if request.keys.contains("folderID") { return (nil, request["folderID"] as? String) }
        return (nil, refresh ? capturedFolderID : folderSelection)
    }
    private func validateJobProfile(_ config: JobConfiguration) throws {
        guard Self.chatGPTAICommands.contains(config.command) else { return }
        let scope = try jobProfileScope(meetingID: config.meetingID, extra: config.extra, input: config.input, capturedFolderID: config.folderID, refresh: true)
        let (current, _) = try folderProfile(for: scope.meetingID, folderID: scope.folderID)
        if let captured = config.folderProfile {
            let expected = try JSONDecoder().decode(ResolvedFolderProfile.self, from: captured)
            guard expected.fingerprint == current.fingerprint else {
                throw AppError.message("Папка или её настройки изменились. Запустите обработку заново: сохранённые результаты не заменены.")
            }
        } else if current.folderID != nil {
            throw AppError.message("У встречи появилась папка. Запустите обработку заново с её настройками.")
        }
    }
    private func validateOptionalJob(_ command: String, features: AppFeatures) throws {
        let feature: AppFeature?
        switch command {
        case "voice-plan", "dictate": feature = .assistant
        case "example": feature = .cards
        default: feature = nil
        }
        if let feature, !features[feature] {
            throw AppError.message(LF("Включите «{0}» в настройках → Возможности.", arguments: [L(feature.title)]))
        }
    }

    private func validateJobRevision(_ job: BackgroundJob) throws {
        let config = job.config
        let current = try jobInputRevision(command: config.command, meetingID: config.meetingID, input: config.input, extra: config.extra)
        let followsTranscript = config.command == "summarize" && job.inputRevision.hasPrefix("dependency:") && job.dependencies.contains(String(job.inputRevision.dropFirst("dependency:".count)))
        if config.command == "expand-notes", current != job.inputRevision {
            // Old releases stored an empty revision for independent notes. It
            // cannot prove consent to today's content; explicit recovery takes
            // a fresh snapshot instead of grandfathering that missing guard.
            throw AppError.message(BackgroundJob.changedNoteSourceMessage)
        }
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
