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
final class MeetingRecorder: NSObject, MeetingRecordingBackend, SCStreamDelegate, AVAudioRecorderDelegate, @unchecked Sendable {
    var failed: (@Sendable (RecordingFailure) -> Void)?
    private var stream: SCStream?
    private var contentPicker: SystemCapturePicker?
    private let startLock = NSLock()
    private var starting = false
    private var startCancelled = false
    private var permissionRequest: RecordingPermissionRequest?
    private let requestMicrophonePermission: RecordingPermissionRequest.Request
    private let failureLock = NSLock()
    private var streamFailure: (stream: ObjectIdentifier, sessionID: String)?
    private var microphoneFailure: (recorder: ObjectIdentifier, sessionID: String)?
    private var microphoneFailureReported = false
    private var startupFailure: RecordingFailure?
    private var sink: CaptureSink?
    private var microphone: AVAudioRecorder?
    var levels: (@Sendable (Double?, Double?) -> Void)?
    private var meterTask: Task<Void, Never>?

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
            message = L("macOS не разрешила запись выбранного экрана или звука. Повторите запись и подтвердите выбор в окне macOS; если отказ повторяется, завершите и снова откройте «После».")
        } else if value.domain == SCStreamErrorDomain,
                  [SCStreamError.Code.noDisplayList.rawValue, SCStreamError.Code.noCaptureSource.rawValue].contains(code) {
            message = L("macOS не нашла доступный экран. Проверьте подключение дисплея и повторите запись.")
        } else if value.domain == SCStreamErrorDomain, code == SCStreamError.Code.failedNoMatchingApplicationContext.rawValue {
            message = L("macOS потеряла подключение к этой копии «После». Завершите приложение и откройте установленную копию снова.")
        } else {
            message = L("macOS не смогла получить доступные экраны и звук. Повторите попытку; если ошибка сохранится, перезапустите «После».")
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
            throw AppError.message(L("Разрешите микрофон: Системные настройки → Конфиденциальность и безопасность → Микрофон → После."))
        }
        if !systemAudio && !video {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: audioQuality.bitRate
            ])
            recorder.delegate = self
            microphone = recorder
            bindMicrophoneFailure(recorder, sessionID: url.deletingLastPathComponent().lastPathComponent)
            guard recorder.prepareToRecord(), recorder.record() else {
                throw AppError.message(L("Не удалось включить микрофон. Проверьте выбранный микрофон в системных настройках."))
            }
            recorder.isMeteringEnabled = true
            try checkStartCancellation()
            if let failure = failureDuringMicrophoneStart(recorder) { throw AppError.message(failure.message) }
            meterTask = Task { @MainActor [weak self] in
                while !Task.isCancelled, recorder.isRecording {
                    recorder.updateMeters()
                    let value = pow(10.0, Double(recorder.averagePower(forChannel: 0)) / 20.0)
                    self?.levels?(min(1, max(0, value)), nil)
                    try? await Task.sleep(for: .milliseconds(100))
                }
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
        // Use the authorized filter directly. Re-querying SCShareableContent here
        // would require broad Screen Recording access and recreate the TCC loop.
        filter.includeMenuBar = true
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
        configuration.captureMicrophone = true
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
        // Bind errors to this capture, even if an old writer reports after the next start.
        sink.failed = { [weak self] message in
            let failure = RecordingFailure(sessionID: sessionID, message: message)
            self?.rememberFailure(failure)
            reportFailure?(failure)
        }
        sink.levels = { [weak self] microphone, system in self?.levels?(microphone, system) }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            if systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
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
            if let failure = failureDuringStart(stream) {
                if failure.userInitiated { throw CancellationError() }
                throw AppError.message(failure.message)
            }
        } catch {
            bindFailure(stream: nil, sessionID: nil)
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
        markStartCancelled()
        await contentPicker?.cancelPendingSelection()
    }

    private func markStartCancelled() {
        startLock.lock()
        let pending = starting ? permissionRequest : nil
        if starting { startCancelled = true }
        startLock.unlock()
        pending?.cancel()
    }

    func stop() async throws {
        // AVAudioRecorder sends its completion delegate for an ordinary Stop
        // too. Clear this session before stopping so only unexpected exits fail.
        bindMicrophoneFailure(nil, sessionID: nil)
        meterTask?.cancel(); meterTask = nil
        microphone?.stop(); microphone = nil
        guard let stream else {
            await contentPicker?.cancelPendingSelection()
            return
        }
        bindFailure(stream: nil, sessionID: nil)
        var captureError: Error?
        do { try await stream.stopCapture() } catch { captureError = error }
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
        guard !starting, stream == nil, microphone == nil else {
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
        guard streamFailure?.sessionID == failure.sessionID || microphoneFailure?.sessionID == failure.sessionID else { return }
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

    private func bindMicrophoneFailure(_ recorder: AnyObject?, sessionID: String?) {
        failureLock.lock(); defer { failureLock.unlock() }
        microphoneFailure = recorder.flatMap { value in sessionID.map { (ObjectIdentifier(value), $0) } }
        microphoneFailureReported = false
        startupFailure = nil
    }

    private func failureDuringMicrophoneStart(_ recorder: AnyObject) -> RecordingFailure? {
        failureLock.lock(); defer { failureLock.unlock() }
        return microphoneFailure?.recorder == ObjectIdentifier(recorder) ? startupFailure : nil
    }

    private func reportMicrophoneFailure(_ recorder: AnyObject, error: Error?) {
        failureLock.lock()
        guard let identity = microphoneFailure, identity.recorder == ObjectIdentifier(recorder), !microphoneFailureReported else {
            failureLock.unlock()
            return
        }
        microphoneFailureReported = true
        let failure = RecordingFailure(sessionID: identity.sessionID,
            message: error?.localizedDescription ?? L("Запись с микрофона неожиданно завершилась. Проверьте микрофон и свободное место на диске."))
        startupFailure = failure
        failureLock.unlock()
        failed?(failure)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        reportMicrophoneFailure(recorder, error: error)
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        reportMicrophoneFailure(recorder, error: nil)
    }

    #if DEBUG
    /// Feed the exact identity/error path without creating an AVAudioRecorder,
    /// asking for access, or opening an input device.
    func bindSyntheticMicrophoneForChecks(_ recorder: AnyObject, sessionID: String) {
        bindMicrophoneFailure(recorder, sessionID: sessionID)
    }
    func reportSyntheticMicrophoneFailureForChecks(_ recorder: AnyObject, error: Error? = nil) {
        reportMicrophoneFailure(recorder, error: error)
    }
    #endif
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
    // Retain one surface so a static screen can last until the capture ends.
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
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        consume(buffer, type: type)
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
                latestVideoFrame = buffer
                pendingVideoFrame = true
            case .idle:
                observeEnd(buffer, videoFrame: true)
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
        guard let input, CMSampleBufferDataIsReady(buffer) else { return }
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
        if type == .screen { flushVideoFrame() }
        else {
            if input.isReadyForMoreMediaData, !input.append(buffer) { report() }
            // Retry a back-pressured first/last screen frame even while the
            // display is static and only audio callbacks continue to arrive.
            flushVideoFrame()
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

    private func report() {
        guard !reportedFailure else { return }
        reportedFailure = true
        failed?(writingError.localizedDescription)
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.ending = true
                self.writer.cancelWriting()
                self.latestVideoFrame = nil
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
        var finishingError: Error?
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
