#if DEBUG
import Foundation
import PosleCore

@MainActor
enum FolderJobNativeChecks {
    private actor Capture {
        var latest: BackgroundJob?
        var history: [BackgroundJob] = []
        func execute(_ job: BackgroundJob) throws -> WorkerEvent? {
            latest = job; history.append(job)
            if job.config.settings.cloudModel == "legacy-frozen-profile" {
                throw AppError.message("Настройки модели не совпадают с сохранённым профилем операции. Запустите обработку заново.")
            }
            var event = WorkerEvent(event: "done")
            if job.config.command == "voice-plan" {
                let input = job.config.input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                if input["questionOnly"] as? Bool == true {
                    event.voicePlan = VoicePlan(status: "answered", title: "Ответ", detail: "Синтетический ответ без источников", target: nil,
                        knowledgeAnswer: KnowledgeAnswer(title: "Ответ", paragraphs: [KnowledgeParagraph(text: "Синтетический ответ")], sources: []))
                } else { event.voicePlan = VoicePlan(status: "question", title: "Вопрос", detail: "", target: nil, query: "следующее занятие") }
            }
            return event
        }
        func read() -> BackgroundJob? { latest }
        func voiceJobs() -> [BackgroundJob] { history.filter { $0.config.command == "voice-plan" } }
    }
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Disposable folder job fixture required")
        }
        let capture = Capture()
        let app = AppStore(preview: true) { job, _, _ in try await capture.execute(job) }
        app.settings.mode = "local"; app.saveSettings()
        var overrides = FolderOverrides()
        overrides.mode = "cloud"; overrides.cloudProvider = "custom"
        overrides.cloudEndpoint = "http://127.0.0.1:9/v1"; overrides.cloudModel = "folder-provider-canary"
        overrides.features = FolderFeatureOverrides(); overrides.features?.cards = true; overrides.generateCards = true
        guard let english = app.notes.saveFolder(LibraryFolder(name: "Английский", overrides: overrides)),
              let work = app.notes.saveFolder(LibraryFolder(name: "Рабочие синки")) else { throw AppError.message(app.notes.error ?? "Folder fixture failed") }
        let meeting = Meeting(title: "Первый урок", source: "source.wav", status: "transcribed")
        try FileManager.default.createDirectory(at: app.meetingDirectory(meeting.id), withIntermediateDirectories: true)
        try app.write(meeting, app.meetingDirectory(meeting.id).appendingPathComponent("meta.json"))
        try app.write(Transcript(duration: 2, segments: [Segment(id: 0, start: 0, end: 2, speaker: "speaker_1", text: "Please follow up tomorrow.")], warnings: [], model: "synthetic"), app.meetingDirectory(meeting.id).appendingPathComponent("transcript.json"))
        guard app.notes.assignMeetingFolder(meeting.id, folderID: english.id) else { throw AppError.message("Meeting assignment failed") }
        _ = try await app.queuedWorker("summarize", id: meeting.id, extra: [], input: nil)
        guard let captured = await capture.read() else { throw AppError.message("Durable job was not captured") }
        try expect(captured.config.settings.mode == "cloud" && captured.config.settings.cloudModel == "folder-provider-canary", "Queued job must use folder model instead of global local model")
        try expect(captured.config.folderID == english.id && captured.config.folderProfile != nil && app.settings.mode == "local", "Queued provider scope persists without changing global settings")
        try expect(app.generatesCards(for: meeting), "A meeting with no card override inherits folder generation")
        print("PASS: actual durable queue captures folder model, provider and profile while global settings remain unchanged")

        // Old releases could persist a current profile beside a different
        // in-memory model. Retrying that frozen row can never repair it.
        var legacy = captured.config; legacy.settings.cloudModel = "legacy-frozen-profile"
        legacy.extra = ["--replace-manual-summary"]
        do {
            _ = try await app.jobs.submit(legacy, resource: "cloud", revision: captured.inputRevision, title: "Legacy summary profile", paid: true)
            throw AppError.message("The legacy mismatched summary unexpectedly succeeded")
        } catch {
            try expect(error.localizedDescription.hasPrefix("Настройки модели не совпадают"), "The synthetic legacy row must fail with the exact production classification")
        }
        try await waitUntil { app.jobs.jobs.contains { $0.title == "Legacy summary profile" && $0.state == "failed" } }
        guard let failed = app.jobs.jobs.first(where: { $0.title == "Legacy summary profile" }) else { throw AppError.message("Legacy summary failure missing") }
        try expect(failed.canRestartWithCurrentProfile && !failed.canReopenVoiceCommand && failed.retryTitle == L("Запустить заново…"), "Known summary profile failures need explicit current-settings recovery")
        var ordinaryFailure = failed; ordinaryFailure.message = "Synthetic provider timeout"
        try expect(!ordinaryFailure.canRestartWithCurrentProfile && ordinaryFailure.retryTitle == L("Повторить"), "Provider failures must retain their frozen retry semantics")
        let previousRecovery = app.jobs.restartWithCurrentProfile
        var recoveryRequested = false
        app.jobs.restartWithCurrentProfile = { selected in recoveryRequested = selected.id == failed.id }
        app.jobs.retry(failed)
        app.jobs.restartWithCurrentProfile = previousRecovery
        try expect(recoveryRequested && app.jobs.jobs.first { $0.id == failed.id }?.attempt == failed.attempt, "The recovery action must not retry or charge the frozen row")
        app.settings.localModel = "base-model-after-update"; app.settings.cloudReasoning = "auto"
        let beforePreparation = app.jobs.jobs.count
        let replacement = try app.prepareRestartedJob(failed)
        try expect(app.jobs.jobs.count == beforePreparation, "Preparing a displayed route must not enqueue or issue a request")
        try expect(replacement.configuration.restartOfJobID == failed.id && replacement.configuration.folderID == english.id
            && replacement.configuration.settings.cloudModel == "folder-provider-canary" && replacement.configuration.settings.localModel == "base-model-after-update"
            && replacement.configuration.settings.cloudReasoning == "auto", "Recovery must resolve current defaults and committed folder overrides rather than copy the historical settings")
        try expect(replacement.paid && replacement.resource == "cloud" && !replacement.configuration.extra.contains("--replace-manual-summary"), "Recovery must describe its new billing route and require renewed consent for manual summary edits")
        _ = try await app.submitPreparedJob(replacement)
        try await waitUntil { app.jobs.jobs.contains { $0.config.restartOfJobID == failed.id && $0.state == "succeeded" } }
        try expect(app.jobs.jobs.first { $0.id == failed.id }?.state == "failed" && !app.jobs.latestAttemptIDs.contains(failed.id), "Fresh success must leave the failed attempt in history without an unresolved error")
        var exampleFailure = failed; exampleFailure.kind = "example"; exampleFailure.config.command = "example"; exampleFailure.config.extra = ["--card", "synthetic-card"]
        let exampleReplacement = try app.prepareRestartedJob(exampleFailure)
        try expect(exampleReplacement.configuration.extra == ["--card", "synthetic-card"] && exampleReplacement.configuration.meetingID == meeting.id, "Example recovery must keep its exact source card and meeting")
        print("PASS: profile-failed summaries/examples explicitly create current-settings operations, keep history, preserve card identity and renew manual-edit consent")
        guard app.notes.assignMeetingFolder(meeting.id, folderID: work.id) else { throw AppError.message("Moving meeting failed") }
        try await rejectBeforeExecution(app, job: captured)
        print("PASS: moving a meeting rejects its previous job before local startup or cloud credentials")
        var note = CapturedNote(text: "Practice follow up tomorrow."); note.meetingID = meeting.id; note.folderID = english.id
        guard let saved = app.notes.save(note) else { throw AppError.message("Note fixture failed") }
        _ = try await app.queuedWorker("expand-notes", id: nil, extra: ["--note", saved.id], input: nil)
        guard let noteJob = await capture.read() else { throw AppError.message("Note job missing") }
        try expect(noteJob.config.settings.cloudModel == "folder-provider-canary", "Independent note profile takes priority over meeting membership")
        var noteFailure = noteJob; noteFailure.state = "failed"
        noteFailure.message = "Настройки модели не совпадают с сохранённым профилем операции. Запустите обработку заново."
        let noteReplacement = try app.prepareRestartedJob(noteFailure)
        try expect(noteReplacement.configuration.extra == ["--note", saved.id] && noteReplacement.configuration.folderID == english.id, "Note recovery must preserve the exact note and its canonical folder")

        var confirmationDraft = CapturedNote(text: "Original confirmation source")
        confirmationDraft.meetingID = meeting.id; confirmationDraft.folderID = english.id
        guard var confirmationNote = app.notes.save(confirmationDraft) else { throw AppError.message("Confirmation note fixture failed") }
        var confirmationFailure = noteFailure; confirmationFailure.config.extra = ["--note", confirmationNote.id]
        let beforeTextChange = try app.prepareRestartedJob(confirmationFailure)
        try expect(beforeTextChange.revision.hasPrefix("note-source-v1:") && beforeTextChange.configuration.meetingID == nil && beforeTextChange.configuration.input == nil,
            "Independent note jobs must capture a canonical source revision even with no meeting argument or stdin")
        confirmationNote.text = "Edited while the current-route confirmation was open"
        guard let editedConfirmation = app.notes.save(confirmationNote) else { throw AppError.message("Changing confirmation note failed") }
        confirmationNote = editedConfirmation
        try await rejectChangedPreparedSource(app, prepared: beforeTextChange)
        var queuedBeforeEdit = confirmationFailure
        queuedBeforeEdit.config = beforeTextChange.configuration; queuedBeforeEdit.inputRevision = beforeTextChange.revision
        do {
            _ = try await app.executeBackgroundJob(queuedBeforeEdit, cancellation: JobCancellation(), event: { _ in })
            throw AppError.message("Changed queued note source unexpectedly reached credentials or inference")
        } catch {
            try expect(error.localizedDescription == BackgroundJob.changedNoteSourceMessage, "Queued note revisions must also reject changed content before credentials or inference")
        }
        let beforeAttachment = try app.prepareRestartedJob(confirmationFailure)
        let attachmentURL = app.root.appendingPathComponent("confirmation-source.txt")
        try Data("Synthetic attachment source".utf8).write(to: attachmentURL)
        let bridge = try RustBridge.shared.get()
        let attachedData = try bridge.request(root: app.root, command: "note-attach", arguments: ["noteID": confirmationNote.id, "revision": confirmationNote.revision, "path": attachmentURL.path])
        confirmationNote = try JSONDecoder().decode(CapturedNote.self, from: attachedData)
        try await rejectChangedPreparedSource(app, prepared: beforeAttachment)
        let beforeExtractedText = try app.prepareRestartedJob(confirmationFailure)
        guard let attachment = confirmationNote.attachments.first else { throw AppError.message("Confirmation attachment missing") }
        _ = try bridge.request(root: app.root, command: "attachment-text", arguments: ["noteID": confirmationNote.id, "revision": confirmationNote.revision, "attachmentID": attachment.id, "text": "Changed attachment extraction while confirming"])
        try await rejectChangedPreparedSource(app, prepared: beforeExtractedText)
        var legacyIndependentNote = noteFailure; legacyIndependentNote.inputRevision = ""
        do {
            _ = try await app.executeBackgroundJob(legacyIndependentNote, cancellation: JobCancellation(), event: { _ in })
            throw AppError.message("An unversioned legacy note snapshot unexpectedly reached inference")
        } catch {
            try expect(error.localizedDescription == BackgroundJob.changedNoteSourceMessage, "Legacy empty note revisions must require explicit fresh-source recovery")
        }
        legacyIndependentNote.state = "failed"; legacyIndependentNote.message = BackgroundJob.changedNoteSourceMessage
        try expect(legacyIndependentNote.canRestartWithCurrentProfile && (try app.prepareRestartedJob(legacyIndependentNote)).revision.hasPrefix("note-source-v1:"),
            "Legacy source failures must offer a fresh versioned source snapshot instead of a frozen retry loop")
        print("PASS: note recovery binds confirmation and queued execution to canonical text, attachments and extraction; legacy empty revisions require explicit fresh-source recovery")
        var changedProfile = app.notes.workspace.folders.first { $0.id == english.id }!
        changedProfile.overrides.cloudModel = "current-folder-model"
        guard app.notes.saveFolder(changedProfile) != nil else { throw AppError.message("Changing prepared profile failed") }
        do {
            _ = try await app.submitPreparedJob(noteReplacement)
            throw AppError.message("A profile changed during confirmation unexpectedly entered the queue")
        } catch {
            try expect(error.localizedDescription.contains("Папка или её настройки изменились"), "A displayed route must be revalidated after confirmation")
        }
        changedProfile = app.notes.workspace.folders.first { $0.id == english.id }!
        changedProfile.overrides.cloudModel = "folder-provider-canary"
        guard app.notes.saveFolder(changedProfile) != nil else { throw AppError.message("Restoring prepared profile failed") }
        _ = try await app.queuedWorker("expand-notes", id: nil, extra: ["--note", saved.id], input: nil)
        guard let currentNoteJob = await capture.read() else { throw AppError.message("Current note profile fixture missing") }
        var moved = saved; moved.folderID = work.id
        guard app.notes.save(moved) != nil else { throw AppError.message("Moving note failed") }
        try await rejectBeforeExecution(app, job: currentNoteJob)
        print("PASS: moving a note rejects its frozen provider before execution and preserves both content and global defaults")
        var enabledEnglish = app.notes.workspace.folders.first { $0.id == english.id }!
        enabledEnglish.overrides.features?.assistant = true
        guard app.notes.saveFolder(enabledEnglish) != nil,
              app.notes.assignMeetingFolder(meeting.id, folderID: english.id) else { throw AppError.message("Voice folder fixture failed") }
        app.settings.features.assistant = false; app.saveSettings()
        app.reloadLibrary(); app.folderSelection = nil; app.librarySection = "meetings"; app.selection = meeting.id; app.loadSelection()
        let voice = app.voice
        voice.present(); voice.text = "Что у меня по этому занятию?"; voice.perform()
        try await waitUntil { !voice.isWorking && !app.busy }
        try expect(voice.knowledgeAnswer != nil, "A selected folder meeting must answer when the global assistant is disabled: \(voice.message ?? "")")
        var voiceJobs = await capture.voiceJobs()
        try expect(voiceJobs.count == 2 && voiceJobs.allSatisfy { $0.config.folderID == english.id && $0.config.settings.cloudModel == "folder-provider-canary" }, "Classification and question-only synthesis must share the canonical folder/provider")
        let question = try JSONSerialization.jsonObject(with: voiceJobs[1].config.input!) as! [String: Any]
        try expect(question["questionOnly"] as? Bool == true && question["folderID"] as? String == english.id && question["meetingID"] == nil && question["noteID"] == nil && question["taskID"] == nil, "Question synthesis must retain only folder scope, without stale selected objects")
        voice.continueQuestion(); app.folderSelection = work.id
        voice.text = "А что делать дальше?"; voice.perform()
        try await waitUntil { !voice.isWorking && !app.busy }
        voiceJobs = await capture.voiceJobs()
        try expect(voice.knowledgeAnswer != nil && voiceJobs.count == 4 && voiceJobs.suffix(2).allSatisfy { $0.config.folderID == english.id }, "A follow-up must retain the conversation folder when the sidebar changes")
        print("PASS: selected-meeting questions and follow-ups preserve canonical folder/provider across both queue phases and sidebar changes")
        voice.continueQuestion(); voice.text = "Ещё один вопрос"; try expect(voice.flushDraft(), "Scoped draft could not be saved")
        let restored = VoiceCommandController(); restored.connect(app)
        try expect(restored.selectedContextForChecks["folderID"] == english.id, "Restoring a conversation draft must preserve its folder scope")
        let base = Meeting(title: "Общий синк", source: "source.wav", status: "transcribed")
        try FileManager.default.createDirectory(at: app.meetingDirectory(base.id), withIntermediateDirectories: true)
        try app.write(base, app.meetingDirectory(base.id).appendingPathComponent("meta.json"))
        app.settings.features.assistant = true; app.saveSettings()
        app.reloadLibrary(); app.folderSelection = nil; app.selection = base.id; app.loadSelection()
        voice.reset(); voice.text = "Что у меня в общей библиотеке?"; voice.perform()
        try await waitUntil { !voice.isWorking && !app.busy }
        voice.continueQuestion(); app.folderSelection = english.id
        voice.text = "А что потом?"; voice.perform()
        try await waitUntil { !voice.isWorking && !app.busy }
        voiceJobs = await capture.voiceJobs()
        try expect(voice.knowledgeAnswer != nil && voiceJobs.count == 8 && voiceJobs.suffix(4).allSatisfy { $0.config.folderID == nil && $0.config.settings.mode == "local" }, "An explicit base-library scope must not inherit a newly selected folder")
        voice.continueQuestion(); voice.text = "Вопрос в общей библиотеке"; try expect(voice.flushDraft(), "Base draft could not be saved")
        let baseRestored = VoiceCommandController(); baseRestored.connect(app)
        let draft = try JSONSerialization.jsonObject(with: Data(contentsOf: app.root.appendingPathComponent("voice-draft.json"))) as! [String: Any]
        try expect(draft["folderScopeCaptured"] as? Bool == true && baseRestored.selectedContextForChecks["folderID"] == nil, "Base-library draft must retain the explicit null scope")
        let scope = try app.jobProfileScope(meetingID: nil, extra: [], input: Data("{\"folderID\":null}".utf8), refresh: true)
        try expect(scope.folderID == nil && scope.meetingID == nil, "Explicit base scope must win over current folder selection")
        print("PASS: explicit base-library question scope and restored drafts remain global when sidebar folders change")
    }
    private static func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw AppError.message("Voice folder queue regression timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private static func rejectChangedPreparedSource(_ app: AppStore, prepared: AppStore.PreparedBackgroundJob) async throws {
        let jobsBefore = app.jobs.jobs.count
        do {
            _ = try await app.submitPreparedJob(prepared)
            throw AppError.message("Changed note content unexpectedly entered the durable queue")
        } catch {
            try expect(error.localizedDescription == L("Данные изменились после подготовки операции. Запустите её заново из встречи или карточки."), "Changed note content must fail before queue admission and any provider request")
        }
        try expect(app.jobs.jobs.count == jobsBefore, "A rejected note confirmation must not create an operation")
    }

    private static func rejectBeforeExecution(_ app: AppStore, job: BackgroundJob) async throws {
        do {
            _ = try await app.executeBackgroundJob(job, cancellation: JobCancellation(), event: { _ in })
            throw AppError.message("A stale profile unexpectedly started execution")
        } catch {
            guard error.localizedDescription.contains("Папка или её настройки изменились") else { throw error }
        }
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}
#endif
