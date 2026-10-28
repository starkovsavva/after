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
            error = "Завершите диктовку поручения перед записью встречи."
            return
        }
        if let folderID = destination.folderID, notes.folder(folderID) == nil {
            error = "Папка удалена. Выберите другую папку перед записью."
            return
        }
        startingRecording = true
        defer { startingRecording = false }
        // Snapshot before any permission prompt. Finalization must use this meeting's
        // quality even if the default settings change before an interrupted job resumes.
        let audioQuality = settings.recordAudioQuality
        let videoQuality = settings.recordVideoQuality
        let requestedDisplay = settings.recordDisplayUUID
        let displays = video ? RecordingDisplay.choices(preview: isPreview) : []
        let selectedDisplay = requestedDisplay.isEmpty
            ? displays.first(where: \.isMain)
            : displays.first(where: { $0.persistentID == requestedDisplay })
        if video && selectedDisplay == nil {
            error = "Выбранный экран недоступен. Выберите подключённый экран перед записью."
            return
        }
        pause(); error = nil; audioLevels.clear()
        processAfterRecording = true
        var meeting = Meeting(title: title.isEmpty ? "Встреча \(Date().formatted(date: .abbreviated, time: .shortened))" : title,
                              source: systemAudio || video ? "recording.mov" : "recording.m4a", status: "recording", focus: "")
        meeting.recordingTracks = systemAudio; meeting.speakerNames["self"] = "Вы"
        meeting.hasVideo = video
        meeting.recordingAudioQuality = audioQuality.rawValue
        meeting.recordingVideoQuality = video ? videoQuality.rawValue : nil
        meeting.recordingDisplayUUID = selectedDisplay?.persistentID
        meeting.generateCards = destination.generateCards
        let destinationFolderID = destination.folderID
        let directory = meetingDirectory(meeting.id)
        // Capture is independent of model preparation and generation.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try await recorder.start(url: directory.appendingPathComponent(meeting.source), systemAudio: systemAudio, video: video,
                                     videoQuality: videoQuality, audioQuality: audioQuality,
                                     displayID: selectedDisplay?.id, expectedDisplayUUID: selectedDisplay?.persistentID)
            try write(meeting, directory.appendingPathComponent("meta.json"))
            if let destinationFolderID, !notes.assignMeetingFolder(meeting.id, folderID: destinationFolderID) {
                recordingFolderFailures.insert(meeting.id)
                self.error = "Запись началась без папки. Выберите папку после сохранения встречи."
            }
            isRecording = true; recordingID = meeting.id; recordingDate = Date()
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), "После записывает встречу" as CFString, &recordingAssertion)
            jobs.setRecording(true)
            // Start already opens this meeting; its sidebar must describe the same destination.
            folderSelection = notes.context(for: meeting.id).folderID; libraryFilter = ""
            reloadLibrary(); librarySection = "meetings"; selection = meeting.id; tab = "notes"; loadSelection(); applyDefaultNoteTemplate(to: meeting.id); showingRecord = false
        } catch {
            try? await recorder.stop()
            self.error = error.localizedDescription
        }
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
            error = "Запись остановлена. Проверьте сохранённые дорожки: \(captureError.localizedDescription)"
            return
        }
        guard finalize, !isTerminating else {
            notice = "Исходная запись сохранена. Обработку можно запустить после открытия приложения."
            return
        }
        do {
            try await worker("finalize", id: id)
            if let fresh: Meeting = read(meetingDirectory(id).appendingPathComponent("meta.json")),
               let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = fresh }
            if transcribeAfterSave && runtimeReady { await processMeeting(id) }
            else { notice = runtimeReady ? "Встреча записана и сохранена в MP3." : "Встреча сохранена в MP3. Для транскрипции подготовьте распознавание в настройках." }
        } catch is CancellationError {
            notice = Self.stoppedProcessingMessage
        } catch {
            self.error = "Исходная запись сохранена. Преобразование в MP3: \(error.localizedDescription)"
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
        // A permission prompt may still be resolving. Once capture has started,
        // flush only its original tracks; encoding and inference can resume later.
        while startingRecording || stoppingRecording { try? await Task.sleep(for: .milliseconds(25)) }
        if isRecording { await stopRecording(finalize: false) }
        await queueShutdown.value
        while busy || voice.isWorking { try? await Task.sleep(for: .milliseconds(25)) }
    }

}
