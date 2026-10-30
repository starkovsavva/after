import AppKit
import AVFoundation
import ScreenCaptureKit
import PosleCore
import ColorSync

struct RecordingDisplay: Identifiable, Equatable, Sendable {
    let id: UInt32
    let title: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isMain: Bool
    let persistentID: String

    init(id: UInt32, title: String, pixelWidth: Int, pixelHeight: Int, isMain: Bool,
         persistentID: String? = nil) {
        self.id = id; self.title = title; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.isMain = isMain
        self.persistentID = persistentID ?? "synthetic:\(id)"
    }
}

/// Uses the macOS capture APIs. No virtual audio driver or meeting bot.
final class MeetingRecorder: NSObject, MeetingRecordingBackend, SCStreamDelegate, @unchecked Sendable {
    var failed: (@Sendable (RecordingFailure) -> Void)?
    var microphoneStatus: (@Sendable (RecordingMicrophoneUpdate) -> Void)?
    // Cancel can read capture ownership while asynchronous Start is suspended.
    // Keep strong-reference loads/stores synchronized with that cancellation.
    private let captureLock = NSLock()
    private var storedStream: SCStream?
    private var storedPicker: SystemCapturePicker?
    private var storedSink: CaptureSink?
    private var storedMicrophone: MicrophoneCapture?
    private var stream: SCStream? {
        get { captureLock.withLock { storedStream } }
        set { captureLock.withLock { storedStream = newValue } }
    }
    private var contentPicker: SystemCapturePicker? {
        get { captureLock.withLock { storedPicker } }
        set { captureLock.withLock { storedPicker = newValue } }
    }
    private var sink: CaptureSink? {
        get { captureLock.withLock { storedSink } }
        set { captureLock.withLock { storedSink = newValue } }
    }
    private var microphone: MicrophoneCapture? {
        get { captureLock.withLock { storedMicrophone } }
        set { captureLock.withLock { storedMicrophone = newValue } }
    }
    private let startLock = NSLock()
    private var starting = false
    private var startCancelled = false
    private var permissionRequest: RecordingPermissionRequest?
    private let requestMicrophonePermission: RecordingPermissionRequest.Request
    private let failureLock = NSLock()
    private var streamFailure: (stream: ObjectIdentifier, sessionID: String)?
    private var recordingSessionID: String?
    private var startupFailure: RecordingFailure?
    var levels: (@Sendable (Double?, Double?) -> Void)?

    init(requestMicrophonePermission: @escaping RecordingPermissionRequest.Request = {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
    }) {
        self.requestMicrophonePermission = requestMicrophonePermission
        super.init()
    }

    /// NSScreen/Core Graphics enumerate devices without asking for Screen Recording access.
    @MainActor static func availableDisplays() -> [RecordingDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            // Do not persist a transient CGDisplayID: macOS can reuse it for another monitor.
            guard let persistentID = persistentDisplayID(id) else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            return RecordingDisplay(id: id, title: screen.localizedName,
                pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor),
                isMain: id == CGMainDisplayID(), persistentID: persistentID)
        }
    }

    static func shareableContentError(_ error: Error) -> AppError {
        let value = error as NSError
        let code = value.code
        let diagnostic = value.domain == SCStreamErrorDomain ? LF("ScreenCaptureKit, код {0}", arguments: [String(describing: code)]) : LF("код {0}", arguments: [String(describing: code)])
        let message: String
        if value.domain == SCStreamErrorDomain, code == SCStreamError.Code.userDeclined.rawValue {
            message = L("macOS не разрешила запись выбранного экрана или звука. Повторите запись и подтвердите выбор в окне macOS. Если доступ уже включён, завершите «After», удалите старую запись приложения кнопкой «−» в настройках записи экрана и снова откройте установленное приложение, чтобы дать доступ этой копии.")
        } else if value.domain == SCStreamErrorDomain,
                  [SCStreamError.Code.noDisplayList.rawValue, SCStreamError.Code.noCaptureSource.rawValue].contains(code) {
            message = L("macOS не нашла доступный экран. Проверьте подключение дисплея и повторите запись.")
        } else if value.domain == SCStreamErrorDomain, code == SCStreamError.Code.failedNoMatchingApplicationContext.rawValue {
            message = L("macOS потеряла подключение к этой копии «After». Завершите приложение и откройте установленную копию снова.")
        } else {
            message = L("macOS не смогла получить доступные экраны и звук. Повторите попытку; если ошибка сохранится, перезапустите «After».")
        }
        return .message("\(message) (\(diagnostic))")
    }

    static func captureFailure(_ error: Error, sessionID: String) -> RecordingFailure {
        let value = error as NSError
        let userStopped = value.domain == SCStreamErrorDomain && value.code == SCStreamError.Code.userStopped.rawValue
        return RecordingFailure(sessionID: sessionID,
            message: userStopped ? L("Запись завершена в macOS.") : shareableContentError(error).localizedDescription,
            userInitiated: userStopped)
    }

    private static func persistentDisplayID(_ id: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func start(url: URL, systemAudio: Bool, video: Bool = false,
               videoQuality: RecordingVideoQuality = .compact,
               audioQuality: RecordingAudioQuality = .standard,
               displayID: UInt32? = nil, expectedDisplayUUID: String? = nil) async throws {
        let permissionRequest = try reserveStart()
        defer { releaseStart() }
        try checkStartCancellation()
        // The macOS picker is the source of truth for this recording. Previously
        // selected display IDs remain accepted for backend compatibility only.
        let permission = try await permissionRequest.wait(request: requestMicrophonePermission)
        try checkStartCancellation()
        guard permission else {
            throw AppError.message(L("Разрешите микрофон: Системные настройки → Конфиденциальность и безопасность → Микрофон → After."))
        }
        if !systemAudio && !video {
            let sink = try CaptureSink(url: url, systemAudio: false, audioQuality: audioQuality)
            let sessionID = url.deletingLastPathComponent().lastPathComponent
            bindSink(sink, sessionID: sessionID)
            let microphone = makeMicrophone(sink: sink, sessionID: sessionID)
            self.sink = sink; self.microphone = microphone
            do {
                try checkStartCancellation()
                try await microphone.start()
                try checkStartCancellation()
                if let failure = failureForSession(sessionID) { throw AppError.message(failure.message) }
            } catch {
                await microphone.stop(); await sink.cancel()
                self.microphone = nil; self.sink = nil
                bindSession(nil)
                throw error
            }
            return
        }
        let picker = await MainActor.run { SystemCapturePicker() }
        contentPicker = picker
        let filter: SCContentFilter
        do {
            try checkStartCancellation()
            filter = try await picker.selectDisplay()
        }
        catch {
            await picker.close()
            contentPicker = nil
            throw error
        }
        // Use the exact filter selected by macOS, including its menu-bar policy.
        // Do not expand it or re-query SCShareableContent for broader access.
        let size = videoQuality.dimensions(width: filter.contentRect.width,
            height: filter.contentRect.height, scale: Double(filter.pointPixelScale))
        guard !video || size != nil else {
            await picker.close()
            contentPicker = nil
            throw AppError.message(L("Не удалось определить разрешение экрана. Повторно выберите экран для записи."))
        }
        let configuration = SCStreamConfiguration()
        configuration.width = video ? size!.width : 2; configuration.height = video ? size!.height : 2
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = true
        configuration.captureResolution = video ? .best : .nominal
        configuration.minimumFrameInterval = video ? CMTime(value: 1, timescale: Int32(videoQuality.frameRate)) : CMTime(seconds: 1, preferredTimescale: 600)
        configuration.showsCursor = video
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.capturesAudio = systemAudio
        // Microphone has its own capture session, so a route change cannot
        // restart or invalidate the selected screen and system-audio stream.
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        let sink: CaptureSink
        do {
            try checkStartCancellation()
            sink = try CaptureSink(url: url, systemAudio: systemAudio,
                videoSize: video ? size : nil, videoQuality: videoQuality, audioQuality: audioQuality)
        } catch {
            await picker.close()
            contentPicker = nil
            throw error
        }
        let sessionID = url.deletingLastPathComponent().lastPathComponent
        let reportFailure = failed
        bindSink(sink, sessionID: sessionID)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            if systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            self.sink = sink; self.stream = stream
            bindFailure(stream: stream, sessionID: sessionID)
            await picker.bind(stream)
            await MainActor.run {
                picker.selectionChanged = { [weak self] in
                    let failure = RecordingFailure(sessionID: sessionID,
                        message: L("Выбор экрана изменён в macOS. Исходная запись сохранена; начните новую запись для другого экрана."),
                        userInitiated: true)
                    self?.rememberFailure(failure)
                    reportFailure?(failure)
                }
            }
            try checkStartCancellation()
            try await stream.startCapture()
            try checkStartCancellation()
            let microphone = makeMicrophone(sink: sink, sessionID: sessionID)
            self.microphone = microphone
            try await microphone.start()
            try checkStartCancellation()
            if let failure = failureDuringStart(stream) {
                if failure.userInitiated { throw CancellationError() }
                throw AppError.message(failure.message)
            }
        } catch {
            bindFailure(stream: nil, sessionID: nil)
            bindSession(nil)
            await microphone?.stop(); microphone = nil
            try? await stream.stopCapture()
            self.stream = nil; self.sink = nil
            await sink.cancel()
            await picker.close()
            contentPicker = nil
            if error is CancellationError { throw error }
            if let appError = error as? AppError { throw appError }
            let hint = video && videoQuality == .native ? L(" Попробуйте качество 1080p.") : ""
            throw AppError.message(LF("Не удалось начать запись: {0}{1}", arguments: [Self.shareableContentError(error).localizedDescription, String(describing: hint)]))
        }
    }

    func cancelPendingStart() async {
        guard markStartCancelled() else { return }
        await contentPicker?.cancelPendingSelection()
        await microphone?.stop()
    }

    private func markStartCancelled() -> Bool {
        startLock.lock()
        let pending = starting ? permissionRequest : nil
        if starting { startCancelled = true }
        startLock.unlock()
        pending?.cancel()
        return pending != nil
    }

    func stop() async throws {
        bindSession(nil)
        bindFailure(stream: nil, sessionID: nil)
        await microphone?.stop(); microphone = nil
        var captureError: Error?
        if let stream {
            do { try await stream.stopCapture() } catch { captureError = error }
        } else { await contentPicker?.cancelPendingSelection() }
        self.stream = nil
        let picker = contentPicker
        contentPicker = nil
        await picker?.close()
        if let sink {
            self.sink = nil
            try await sink.finish()
        } else if let captureError { throw captureError }
    }

    private func reserveStart() throws -> RecordingPermissionRequest {
        startLock.lock(); defer { startLock.unlock() }
        guard !starting, stream == nil, microphone == nil, sink == nil else {
            throw AppError.message(L("Запись уже идёт. Сначала остановите её."))
        }
        starting = true
        startCancelled = false
        let request = RecordingPermissionRequest()
        permissionRequest = request
        return request
    }

    private func checkStartCancellation() throws {
        try Task.checkCancellation()
        startLock.lock(); defer { startLock.unlock() }
        if startCancelled { throw CancellationError() }
    }

    private func releaseStart() {
        startLock.lock(); defer { startLock.unlock() }
        starting = false
        permissionRequest = nil
    }

    private func bindFailure(stream: SCStream?, sessionID: String?) {
        failureLock.lock(); defer { failureLock.unlock() }
        streamFailure = stream.flatMap { value in sessionID.map { (ObjectIdentifier(value), $0) } }
        startupFailure = nil
    }

    private func rememberFailure(_ failure: RecordingFailure) {
        failureLock.lock(); defer { failureLock.unlock() }
        guard recordingSessionID == failure.sessionID else { return }
        startupFailure = failure
    }

    private func failureDuringStart(_ stream: SCStream) -> RecordingFailure? {
        failureLock.lock(); defer { failureLock.unlock() }
        return streamFailure?.stream == ObjectIdentifier(stream) ? startupFailure : nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failureLock.lock()
        let identity = streamFailure
        failureLock.unlock()
        guard let identity, identity.stream == ObjectIdentifier(stream) else { return }
        let failure = Self.captureFailure(error, sessionID: identity.sessionID)
        rememberFailure(failure)
        failed?(failure)
    }

    private func bindSession(_ sessionID: String?) {
        failureLock.lock(); defer { failureLock.unlock() }
        recordingSessionID = sessionID; startupFailure = nil
    }

    private func failureForSession(_ sessionID: String) -> RecordingFailure? {
        failureLock.lock(); defer { failureLock.unlock() }
        return recordingSessionID == sessionID ? startupFailure : nil
    }

    private func bindSink(_ sink: CaptureSink, sessionID: String) {
        bindSession(sessionID)
        let reportFailure = failed
        sink.failed = { [weak self] message in
            let failure = RecordingFailure(sessionID: sessionID, message: message)
            self?.rememberFailure(failure); reportFailure?(failure)
        }
        sink.levels = { [weak self] microphone, system in self?.levels?(microphone, system) }
    }

    private func makeMicrophone(sink: CaptureSink, sessionID: String) -> MicrophoneCapture {
        let update = microphoneStatus
        return MicrophoneCapture(deliveryQueue: sink.queue,
            deliver: { [weak sink] sample in sink?.consume(sample, type: .microphone) },
            silence: { [weak sink] time in sink?.advanceMicrophone(to: time) },
            status: { state in update?(RecordingMicrophoneUpdate(sessionID: sessionID, state: state)) })
    }

}

final class CaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.posle.capture", qos: .userInitiated)
    var failed: (@Sendable (String) -> Void)?
    var levels: (@Sendable (Double?, Double?) -> Void)?
    private var lastMicrophoneMeter = CMTime.invalid
    private var lastSystemMeter = CMTime.invalid
    private let writer: AVAssetWriter
    private let system: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput
    private let video: AVAssetWriterInput?
    private let nativeVideo: Bool
    private let frameDuration: CMTime
    // ScreenCaptureKit emits complete frames only when the display changes.
    // Keep an owned copy so the static tail and H.264 encoder cannot exhaust
    // ScreenCaptureKit's small pool and freeze video while audio continues.
    private let videoFrameCopier = CaptureVideoFrameCopier()
    private let microphoneNormalizer = CaptureAudioNormalizer()
    private let systemNormalizer = CaptureAudioNormalizer()
    private var microphonePending: [CaptureAudioPacket] = []
    private var systemPending: [CaptureAudioPacket] = []
    private var audioFinished = false
    private var finishingError: Error?
    private var latestVideoFrame: CMSampleBuffer?
    private var pendingVideoFrame = false
    private var lastWrittenVideoTime = CMTime.invalid
    private var captureEndTime = CMTime.invalid
    private var writtenVideoFrames = 0
    private var started = false
    private var ending = false
    private var reportedFailure = false

    init(url: URL, systemAudio: Bool = true, videoSize: RecordingVideoDimensions? = nil,
         videoQuality: RecordingVideoQuality = .compact, audioQuality: RecordingAudioQuality = .standard) throws {
        let audioOnly = url.pathExtension.lowercased() == "m4a"
        writer = try AVAssetWriter(outputURL: url, fileType: audioOnly ? .m4a : .mov)
        nativeVideo = videoSize != nil && videoQuality == .native
        frameDuration = CMTime(value: 1, timescale: Int32(videoQuality.frameRate))
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioQuality.bitRate]
        system = systemAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: settings) : nil
        microphone = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        system?.expectsMediaDataInRealTime = true; microphone.expectsMediaDataInRealTime = true
        guard writer.canAdd(microphone) else {
            throw AppError.message(L("macOS не смогла создать звуковые дорожки."))
        }
        if let system { guard writer.canAdd(system) else { throw AppError.message(L("Не удалось создать системную аудиодорожку")) }; writer.add(system) }
        writer.add(microphone)
        if let size = videoSize {
            let outputSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoQuality.bitRate(for: size),
                    AVVideoExpectedSourceFrameRateKey: videoQuality.frameRate, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
            ]
            guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
                throw AppError.message(LF("macOS не поддерживает H.264 для разрешения {0} × {1}. Выберите качество 1080p.", arguments: [String(describing: size.width), String(describing: size.height)]))
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw AppError.message(L("Не удалось включить кодирование видео H.264")) }
            writer.add(input); video = input
        } else { video = nil }
        // Fragmented QuickTime preserves completed fragments after an abnormal termination.
        if !audioOnly { writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600) }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        consumeIncoming(buffer, type: type, clock: stream.synchronizationClock)
    }

    /// SCK also sends control events with no media samples or usable clock.
    /// Classify those before applying the strict media-buffer clock conversion.
    func consumeIncoming(_ buffer: CMSampleBuffer, type: SCStreamOutputType, clock: CMClock?) {
        guard !ending, buffer.isValid else { return }
        if type == .screen {
            guard video != nil,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw) else { return }
            switch status {
            case .idle:
                consumeIdle(buffer, clock: clock)
                return
            case .blank, .suspended:
                // Even without a timestamp, discard the last visible surface:
                // it must not become a tail through protected/suspended capture.
                latestVideoFrame = nil; pendingVideoFrame = false
                return
            case .started, .stopped:
                return
            case .complete:
                guard CMSampleBufferGetImageBuffer(buffer) != nil else { return }
            @unknown default:
                return
            }
        } else if type == .audio {
            guard system != nil else { return }
        } else if type != .microphone { return }
        guard CMSampleBufferGetNumSamples(buffer) > 0, CMSampleBufferDataIsReady(buffer) else { return }
        guard let clock else {
            report(AppError.message(L("Не удалось синхронизировать звук и видео. Исходная запись сохранена."))); return
        }
        do { consume(try CaptureSampleClock.hostTimed(buffer, clock: clock), type: type) }
        catch { report(error) }
    }

    /// Idle has no new image to copy. Its timestamp can still extend the last
    /// owned static frame and drain encoder pressure, even in a zero-sample event.
    func consumeIdle(_ buffer: CMSampleBuffer, clock: CMClock?) {
        guard !ending, video != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if let clock, pts.isValid, pts.isNumeric {
            let host = CMClockGetHostTimeClock()
            let time = CMSyncConvertTime(pts, from: clock, to: host)
            if time.isValid, time.isNumeric {
                let duration = CMSampleBufferGetDuration(buffer)
                let end = duration.isValid && duration.isNumeric && duration > .zero
                    ? CMSyncConvertTime(pts + duration, from: clock, to: host) : time + frameDuration
                if end.isValid, end.isNumeric, !captureEndTime.isValid || end > captureEndTime { captureEndTime = end }
            }
        }
        if started { do { try flushAudioFrames() } catch { report(error) } }
        flushVideoFrame()
    }

    /// Advances a missing microphone in the same host-clock timeline. Long
    /// absences are written incrementally instead of accumulating PCM in RAM.
    func advanceMicrophone(to time: CMTime) {
        guard !ending, started, time.isValid, time.isNumeric else { return }
        do {
            microphonePending += try microphoneNormalizer.fillSilence(until: time)
            try flushAudioFrames()
            if !captureEndTime.isValid || time > captureEndTime { captureEndTime = time }
        } catch { report(error) }
    }

    /// Runs on `queue`; diagnostics feed generated buffers through the same path.
    func consume(_ buffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard !ending, buffer.isValid else { return }
        let input: AVAssetWriterInput?
        if type == .screen {
            guard video != nil,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw) else { return }
            switch status {
            case .complete:
                guard CMSampleBufferDataIsReady(buffer), CMSampleBufferGetImageBuffer(buffer) != nil,
                      CMSampleBufferGetPresentationTimeStamp(buffer).isValid,
                      CMSampleBufferGetPresentationTimeStamp(buffer).isNumeric else { return }
                do {
                    guard let owned = try videoFrameCopier.copy(buffer) else {
                        observeEnd(buffer, videoFrame: true)
                        flushVideoFrame()
                        return
                    }
                    latestVideoFrame = owned
                    pendingVideoFrame = true
                } catch { report(error); return }
            case .idle:
                observeEnd(buffer, videoFrame: true)
                if started { do { try flushAudioFrames() } catch { report(error) } }
                flushVideoFrame()
                return
            case .blank, .suspended:
                // A protected, sleeping or suspended display is not a static
                // desktop. Do not use its previous image as the final tail.
                latestVideoFrame = nil
                pendingVideoFrame = false
                observeEnd(buffer, videoFrame: true)
                return
            case .started, .stopped:
                return
            @unknown default:
                return
            }
            input = video
        } else if type == .audio { input = system }
        else if type == .microphone { input = microphone }
        else { return }
        guard input != nil, CMSampleBufferDataIsReady(buffer) else { return }
        let now = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard now.isValid, now.isNumeric else { return }
        observeEnd(buffer, videoFrame: type == .screen)
        if type == .audio || type == .microphone {
            let last = type == .audio ? lastSystemMeter : lastMicrophoneMeter
            if !last.isValid || CMTimeGetSeconds(now - last) >= 0.1 {
                if type == .audio { lastSystemMeter = now } else { lastMicrophoneMeter = now }
                if let value = Self.level(buffer) { levels?(type == .microphone ? value : nil, type == .audio ? value : nil) }
            }
        }
        if !started {
            guard writer.startWriting() else { report(); return }
            writer.startSession(atSourceTime: now)
            started = true
        }
        guard writer.status == .writing else { report(); return }
        do { try flushAudioFrames() } catch { report(error); return }
        if type == .screen { flushVideoFrame() }
        else {
            do {
                let normalizer = type == .audio ? systemNormalizer : microphoneNormalizer
                let samples = try normalizer.normalize(buffer)
                if type == .audio { systemPending += samples }
                else { microphonePending += samples }
                try flushAudioFrames()
            } catch { report(error); return }
            // Retry a back-pressured first/last screen frame even while the
            // display is static and only audio callbacks continue to arrive.
            flushVideoFrame()
        }
    }

    private func flushAudioFrames() throws {
        if let system { try flushAudioFrames(&systemPending, to: system) }
        try flushAudioFrames(&microphonePending, to: microphone)
    }

    private func flushAudioFrames(_ pending: inout [CaptureAudioPacket], to input: AVAssetWriterInput) throws {
        while !pending.isEmpty, input.isReadyForMoreMediaData {
            switch pending[0] {
            case let .sample(sample):
                guard input.append(sample) else { throw writingError }
                pending.removeFirst()
            case let .silence(start, frames):
                let count = min(frames, 4096)
                let sample = try CaptureAudioNormalizer.silence(at: start, frames: Int(count))
                guard input.append(sample) else { throw writingError }
                if count == frames { pending.removeFirst() }
                else { pending[0] = .silence(start: start + CMTime(value: count, timescale: 48000), frames: frames - count) }
            }
        }
        // At most two seconds of pending PCM per track. Report sustained
        // encoder pressure instead of silently discarding audio samples.
        guard pending.count <= 512, pending.reduce(0, { $0 + $1.bufferedFrames }) <= 96_000 else {
            throw AppError.message(L("Кодировщик не успевает сохранять звук. Исходная запись сохранена."))
        }
    }

    private func observeEnd(_ buffer: CMSampleBuffer, videoFrame: Bool) {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard time.isValid, time.isNumeric else { return }
        let duration = CMSampleBufferGetDuration(buffer)
        let end = time + (duration.isValid && duration.isNumeric && duration > .zero
            ? duration : (videoFrame ? frameDuration : .zero))
        if !captureEndTime.isValid || end > captureEndTime { captureEndTime = end }
    }

    private func flushVideoFrame() {
        guard started, writer.status == .writing, pendingVideoFrame,
              let frame = latestVideoFrame, let video, video.isReadyForMoreMediaData else { return }
        guard video.append(frame) else { report(); return }
        pendingVideoFrame = false
        lastWrittenVideoTime = CMSampleBufferGetPresentationTimeStamp(frame)
        writtenVideoFrames += 1
    }

    private static func level(_ sample: CMSampleBuffer) -> Double? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let size = CMBlockBufferGetDataLength(block)
        guard size > 0, size <= 4_194_304 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == kCMBlockBufferNoErr else { return nil }
        let sum: Double
        let count: Int
        if description.mFormatFlags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32 {
            let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            count = values.count; sum = values.reduce(0) { $0 + ( $1.isFinite ? Double($1 * $1) : 0) }
        } else if description.mBitsPerChannel == 16 {
            let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            count = values.count; sum = values.reduce(0) { $0 + pow(Double($1) / 32768.0, 2) }
        } else { return nil }
        return count == 0 ? nil : min(1, sqrt(sum / Double(count)))
    }

    private var writingError: Error {
        let message = writer.error?.localizedDescription ?? L("Не удалось записать аудио или видео.")
        return AppError.message(message + (nativeVideo ? L(" Попробуйте качество 1080p.") : ""))
    }

    private func report(_ error: Error? = nil) {
        guard !reportedFailure else { return }
        reportedFailure = true
        failed?((error ?? writingError).localizedDescription)
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.ending = true
                self.writer.cancelWriting()
                self.latestVideoFrame = nil
                self.microphonePending.removeAll(); self.systemPending.removeAll()
                continuation.resume()
            }
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ending = true
                self.finish(continuation, deadline: .now() + 2)
            }
        }
    }

    private func finish(_ continuation: CheckedContinuation<Void, Error>, deadline: DispatchTime) {
        guard writer.status != .failed else {
            continuation.resume(throwing: writingError)
            return
        }
        if !audioFinished {
            audioFinished = true
            do { systemPending += try systemNormalizer.finish() }
            catch { finishingError = finishingError ?? error }
            do { microphonePending += try microphoneNormalizer.finish() }
            catch { finishingError = finishingError ?? error }
        }
        if started {
            do { try flushAudioFrames() }
            catch { finishingError = finishingError ?? error }
        }
        guard started else {
            writer.cancelWriting()
            continuation.resume(throwing: AppError.message(L("В записи нет звука. Проверьте микрофон и звук звонка.")))
            return
        }
        flushVideoFrame()
        guard writer.status == .writing else {
            continuation.resume(throwing: writingError)
            return
        }
        if !systemPending.isEmpty || !microphonePending.isEmpty {
            if DispatchTime.now() < deadline {
                queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                    self.finish(continuation, deadline: deadline)
                }
                return
            }
            finishingError = AppError.message(L("Не удалось сохранить весь звук. Исходная запись сохранена."))
        }
        let tailTime = captureEndTime - frameDuration
        if let video, let frame = latestVideoFrame,
           captureEndTime.isValid,
           pendingVideoFrame || !lastWrittenVideoTime.isValid || tailTime > lastWrittenVideoTime {
            if pendingVideoFrame || !video.isReadyForMoreMediaData {
                if DispatchTime.now() < deadline {
                    queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                        self.finish(continuation, deadline: deadline)
                    }
                    return
                }
                finishingError = AppError.message(L("Не удалось сохранить последний видеокадр. Исходная запись со звуком сохранена."))
            } else {
                var timing = CMSampleTimingInfo(duration: frameDuration,
                    presentationTimeStamp: tailTime, decodeTimeStamp: .invalid)
                var tail: CMSampleBuffer?
                let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                    sampleBuffer: frame, sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing, sampleBufferOut: &tail)
                if status == noErr, let tail {
                    if !video.append(tail) { finishingError = writingError }
                } else {
                    finishingError = AppError.message(L("Не удалось завершить видеодорожку. Исходная запись со звуком сохранена."))
                }
            }
        }
        guard writer.status == .writing else {
            continuation.resume(throwing: writingError)
            return
        }
        if video != nil && writtenVideoFrames == 0 {
            finishingError = AppError.message(L("macOS не передала ни одного видеокадра. Исходная запись со звуком сохранена. Проверьте доступ к записи экрана и повторите попытку."))
        }
        if captureEndTime.isValid { writer.endSession(atSourceTime: captureEndTime) }
        system?.markAsFinished(); microphone.markAsFinished(); video?.markAsFinished()
        latestVideoFrame = nil
        let resultError = finishingError
        writer.finishWriting {
            if self.writer.status == .completed {
                if let resultError { continuation.resume(throwing: resultError) }
                else { continuation.resume() }
            } else { continuation.resume(throwing: self.writingError) }
        }
    }
}
