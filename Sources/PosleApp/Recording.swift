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
final class MeetingRecorder: NSObject, SCStreamDelegate, @unchecked Sendable {
    var failed: (@Sendable (String) -> Void)?
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var microphone: AVAudioRecorder?

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

    private static func persistentDisplayID(_ id: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func start(url: URL, systemAudio: Bool, video: Bool = false,
               videoQuality: RecordingVideoQuality = .compact,
               audioQuality: RecordingAudioQuality = .standard,
               displayID: UInt32? = nil, expectedDisplayUUID: String? = nil) async throws {
        guard stream == nil, microphone == nil else {
            throw AppError.message("Запись уже идёт. Сначала остановите её.")
        }
        // Snapshot the target before a potentially long permission prompt. A display ID
        // can be reused after disconnect; compare its persistent identity after the await.
        let initialDisplayID = displayID ?? CGMainDisplayID()
        let initialDisplayUUID = video ? (expectedDisplayUUID ?? Self.persistentDisplayID(initialDisplayID)) : nil
        if video {
            guard CGDisplayIsActive(initialDisplayID) != 0 else {
                throw AppError.message("Выбранный экран отключён. Выберите подключённый экран перед записью.")
            }
            guard let initialDisplayUUID,
                  Self.persistentDisplayID(initialDisplayID) == initialDisplayUUID else {
                throw AppError.message("Выбранный экран изменился. Выберите экран повторно перед записью.")
            }
        }
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        guard permission else {
            throw AppError.message("Разрешите микрофон: Системные настройки → Конфиденциальность и безопасность → Микрофон → После.")
        }
        if !systemAudio && !video {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: audioQuality.bitRate
            ])
            guard recorder.prepareToRecord(), recorder.record() else {
                throw AppError.message("Не удалось включить микрофон. Проверьте выбранный микрофон в системных настройках.")
            }
            microphone = recorder
            return
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch {
            throw AppError.message("Для записи экрана или звука звонка разрешите запись экрана и системного аудио в настройках конфиденциальности macOS, затем перезапустите После.")
        }
        guard let selectedID = RecordingDisplaySelection.resolve(
            requested: video ? initialDisplayID : nil,
            available: content.displays.map(\.displayID), main: CGMainDisplayID()),
              let display = content.displays.first(where: { $0.displayID == selectedID }) else {
            throw AppError.message(video && displayID != nil
                ? "Выбранный экран отключён. Выберите подключённый экран перед записью."
                : "Основной экран недоступен. Проверьте подключение дисплея и повторите запись.")
        }
        if video, Self.persistentDisplayID(selectedID) != initialDisplayUUID {
            throw AppError.message("Выбранный экран отключён или заменён. Выберите экран повторно перед записью.")
        }
        // Empty exclusion list includes the entire selected display, including all windows.
        // Leave sourceRect unset: a source rectangle would crop the display.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = true
        guard let size = videoQuality.dimensions(width: filter.contentRect.width,
            height: filter.contentRect.height, scale: Double(filter.pointPixelScale)) else {
            throw AppError.message("Не удалось определить разрешение экрана. Повторно выберите экран для записи.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = video ? size.width : 2; configuration.height = video ? size.height : 2
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
        let sink = try CaptureSink(url: url, systemAudio: systemAudio,
            videoSize: video ? size : nil, videoQuality: videoQuality, audioQuality: audioQuality)
        sink.failed = { [weak self] message in self?.failed?(message) }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            if systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            self.sink = sink; self.stream = stream
            try await stream.startCapture()
        } catch {
            self.stream = nil; self.sink = nil
            await sink.cancel()
            let hint = video && videoQuality == .native ? " Попробуйте качество 1080p." : ""
            throw AppError.message("Не удалось начать запись: \(error.localizedDescription)\(hint)")
        }
    }

    func stop() async throws {
        microphone?.stop(); microphone = nil
        guard let stream else { return }
        var captureError: Error?
        do { try await stream.stopCapture() } catch { captureError = error }
        self.stream = nil
        if let sink {
            self.sink = nil
            try await sink.finish()
        } else if let captureError { throw captureError }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failed?(error.localizedDescription)
    }
}

private final class CaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.posle.capture", qos: .userInitiated)
    var failed: (@Sendable (String) -> Void)?
    private let writer: AVAssetWriter
    private let system: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput
    private let video: AVAssetWriterInput?
    private let nativeVideo: Bool
    private var started = false
    private var ending = false
    private var reportedFailure = false

    init(url: URL, systemAudio: Bool = true, videoSize: RecordingVideoDimensions? = nil,
         videoQuality: RecordingVideoQuality = .compact, audioQuality: RecordingAudioQuality = .standard) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        nativeVideo = videoSize != nil && videoQuality == .native
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioQuality.bitRate]
        system = systemAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: settings) : nil
        microphone = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        system?.expectsMediaDataInRealTime = true; microphone.expectsMediaDataInRealTime = true
        guard writer.canAdd(microphone) else {
            throw AppError.message("macOS не смогла создать звуковые дорожки.")
        }
        if let system { guard writer.canAdd(system) else { throw AppError.message("Не удалось создать системную аудиодорожку") }; writer.add(system) }
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
                throw AppError.message("macOS не поддерживает H.264 для разрешения \(size.width) × \(size.height). Выберите качество 1080p.")
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw AppError.message("Не удалось включить кодирование видео H.264") }
            writer.add(input); video = input
        } else { video = nil }
        // Fragmented QuickTime preserves completed fragments after an abnormal termination.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !ending, buffer.isValid, CMSampleBufferDataIsReady(buffer) else { return }
        let input: AVAssetWriterInput?
        if type == .screen {
            guard video != nil,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            input = video
        } else if type == .audio { input = system }
        else if type == .microphone { input = microphone }
        else { return }
        guard let input else { return }
        if !started {
            guard writer.startWriting() else { report(); return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            started = true
        }
        guard writer.status == .writing else { report(); return }
        if input.isReadyForMoreMediaData, !input.append(buffer) { report() }
    }

    private var writingError: Error {
        let message = writer.error?.localizedDescription ?? "Не удалось записать аудио или видео."
        return AppError.message(message + (nativeVideo ? " Попробуйте качество 1080p." : ""))
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
                continuation.resume()
            }
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ending = true
                guard self.writer.status != .failed else {
                    continuation.resume(throwing: self.writingError)
                    return
                }
                guard self.started else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: AppError.message("В записи нет звука. Проверьте микрофон и звук звонка."))
                    return
                }
                self.system?.markAsFinished(); self.microphone.markAsFinished(); self.video?.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: self.writingError) }
                }
            }
        }
    }
}
