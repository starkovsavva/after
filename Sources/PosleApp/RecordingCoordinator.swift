import AppKit
import Foundation
import IOKit.pwr_mgt
import PosleCore

/// Destination and per-meeting choices are captured before audio checks or permission sheets.
/// A nil folder explicitly means the base library, even if sidebar selection changes.
struct RecordingDestination: Equatable {
    var folderID: String?
    var generateCards: Bool? = nil
}

extension AppStore {
    func startRecording(systemAudio: Bool, video: Bool = false, title: String) async {
        await startRecording(systemAudio: systemAudio, video: video, title: title,
                             destination: RecordingDestination(folderID: folderSelection))
    }
    func startRecording(systemAudio: Bool, video: Bool = false, title: String, destination: RecordingDestination) async {
        guard !isTerminating, !startingRecording, !isRecording else { return }
        guard ![.authorizing, .capturing].contains(voice.phase) else {
            error = L("Завершите диктовку поручения перед записью встречи.")
            return
        }
        if let folderID = destination.folderID, notes.folder(folderID) == nil {
            error = L("Папка удалена. Выберите другую папку перед записью.")
            return
        }
        startingRecording = true
        defer { startingRecording = false; startingRecordingID = nil; recordingStartTask = nil; pendingRecordingFailure = nil }
        // Snapshot before any permission prompt. Finalization must use this meeting's
        // quality even if the default settings change before an interrupted job resumes.
        let audioQuality = settings.recordAudioQuality
        let videoQuality = settings.recordVideoQuality
        pause(); error = nil; audioLevels.clear()
        processAfterRecording = true
        var meeting = Meeting(title: title.isEmpty ? LF("Встреча {0}", arguments: [String(describing: Date().formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(UILocale())))]) : title,
                              source: systemAudio || video ? "recording.mov" : "recording.m4a", status: "recording", focus: "")
        meeting.recordingTracks = systemAudio; meeting.speakerNames["self"] = L("Вы")
        meeting.hasVideo = video
        meeting.recordingAudioQuality = audioQuality.rawValue
        meeting.recordingVideoQuality = video ? videoQuality.rawValue : nil
        meeting.recordingDisplayUUID = nil
        meeting.generateCards = destination.generateCards
        let destinationFolderID = destination.folderID
        let directory = meetingDirectory(meeting.id)
        // Capture is independent of model preparation and generation.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            startingRecordingID = meeting.id
            pendingRecordingFailure = nil
            // Own cancellation before the backend's first executor hop. The
            // backend may not have reserved its permission/picker state yet.
            let sourceURL = directory.appendingPathComponent(meeting.source)
            let start = Task { [recorder] in
                try await recorder.start(url: sourceURL, systemAudio: systemAudio, video: video,
                                         videoQuality: videoQuality, audioQuality: audioQuality,
                                         displayID: nil, expectedDisplayUUID: nil)
            }
            recordingStartTask = start
            try await withTaskCancellationHandler { try await start.value }
                onCancel: { start.cancel() }
            // A backend can finish just before Cancel reaches this actor. Its
            // completed value is still a success, but this start was canceled.
            guard !start.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            guard !isTerminating else { throw CancellationError() }
            if let failure = pendingRecordingFailure {
                if failure.userInitiated { throw CancellationError() }
                throw AppError.message(failure.message)
            }
            try write(meeting, directory.appendingPathComponent("meta.json"))
            if let destinationFolderID, !notes.assignMeetingFolder(meeting.id, folderID: destinationFolderID) {
                recordingFolderFailures.insert(meeting.id)
                self.error = L("Запись началась без папки. Выберите папку после сохранения встречи.")
            }
            isRecording = true; recordingID = meeting.id; recordingDate = Date()
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), L("После записывает встречу") as CFString, &recordingAssertion)
            jobs.setRecording(true)
            // Start already opens this meeting; its sidebar must describe the same destination.
            folderSelection = notes.context(for: meeting.id).folderID; libraryFilter = ""
            reloadLibrary(); librarySection = "meetings"; selection = meeting.id; tab = "notes"; loadSelection(); applyDefaultNoteTemplate(to: meeting.id); showingRecord = false
        } catch is CancellationError {
            try? await recorder.stop()
            // This directory belongs to this uncommitted start, never an existing meeting.
            try? FileManager.default.removeItem(at: directory)
            self.error = nil
        } catch {
            try? await recorder.stop()
            // A denied permission or unavailable device can fail before any
            // source exists. Keep actual tracks, but do not leave empty starts.
            if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), contents.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
            self.error = error.localizedDescription
        }
    }
    func cancelRecordingStart() async {
        guard startingRecording else { return }
        recordingStartTask?.cancel()
        await recorder.cancelPendingStart()
    }
    func stopRecording(finalize: Bool = true) async {
        guard let id = recordingID, isRecording, !stoppingRecording else { return }
        let duration = Date().timeIntervalSince(recordingDate ?? Date())
        let folderAssignmentFailed = recordingFolderFailures.remove(id) != nil
        let transcribeAfterSave = processAfterRecording && !folderAssignmentFailed
        stoppingRecording = true
        var captureError: Error?
        do { try await recorder.stop() } catch { captureError = error }
        // Release this capture exactly once, before any queued work awaits.
        // An older finalization must never clear the next meeting's recorder.
        isRecording = false; recordingID = nil; recordingDate = nil; stoppingRecording = false
        jobs.setRecording(false)
        if recordingAssertion != 0 { IOPMAssertionRelease(recordingAssertion); recordingAssertion = 0 }
        updateMeeting(id) { $0.status = "imported"; $0.duration = duration }
        if let captureError {
            error = LF("Запись остановлена. Проверьте сохранённые дорожки: {0}", arguments: [String(describing: captureError.localizedDescription)])
            return
        }
        guard finalize, !isTerminating else {
            notice = L("Исходная запись сохранена. Обработку можно запустить после открытия приложения.")
            return
        }
        do {
            try await worker("finalize", id: id)
            if let fresh: Meeting = read(meetingDirectory(id).appendingPathComponent("meta.json")),
               let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = fresh }
            if transcribeAfterSave && runtimeReady { await processMeeting(id) }
            else { notice = runtimeReady ? L("Встреча записана и сохранена в MP3.") : L("Встреча сохранена в MP3. Для транскрипции подготовьте распознавание в настройках.") }
        } catch is CancellationError {
            notice = Self.stoppedProcessingMessage
        } catch {
            self.error = LF("Исходная запись сохранена. Преобразование в MP3: {0}", arguments: [String(describing: error.localizedDescription)])
        }
    }
    func prepareForTermination() async {
        guard !isTerminating else { return }
        isTerminating = true
        SemanticIndexController.shared.stop()
        trackerSync.stop()
        processAfterRecording = false
        cancellationRequested = true
        runner.cancel()
        voice.cancelWork()
        let queueShutdown = Task { await jobs.shutdown() }
        recordingStartTask?.cancel()
        await recorder.cancelPendingStart()
        // A permission prompt may still be resolving. Once capture has started,
        // flush only its original tracks; encoding and inference can resume later.
        while startingRecording || stoppingRecording { try? await Task.sleep(for: .milliseconds(25)) }
        if isRecording { await stopRecording(finalize: false) }
        await queueShutdown.value
        while busy || voice.isWorking { try? await Task.sleep(for: .milliseconds(25)) }
    }

}
