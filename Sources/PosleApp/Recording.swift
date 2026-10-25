import AppKit
import AVFoundation
import ScreenCaptureKit

/// Uses the macOS capture APIs. No virtual audio driver or meeting bot.
final class MeetingRecorder: NSObject, SCStreamDelegate, @unchecked Sendable {
    var failed: (@Sendable (String) -> Void)?
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var microphone: AVAudioRecorder?

    func start(url: URL, systemAudio: Bool, video: Bool = false) async throws {
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        guard permission else {
            throw AppError.message("Разрешите микрофон: Системные настройки → Конфиденциальность и безопасность → Микрофон → После.")
        }
        if !systemAudio && !video {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000
            ])
            guard recorder.prepareToRecord(), recorder.record() else {
                throw AppError.message("Не удалось включить микрофон. Проверьте выбранный микрофон в системных настройках.")
            }
            microphone = recorder
            return
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch {
            throw AppError.message("Для звука звонка разрешите запись экрана и системного аудио в настройках конфиденциальности macOS, затем перезапустите После.")
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw AppError.message("Подключите дисплей для записи системного аудио.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1280.0 / Double(display.width), 720.0 / Double(display.height), 1.0)
        let width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        configuration.width = video ? width : 2; configuration.height = video ? height : 2
        configuration.minimumFrameInterval = video ? CMTime(value: 1, timescale: 30) : CMTime(seconds: 1, preferredTimescale: 600)
        configuration.showsCursor = video
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.capturesAudio = systemAudio
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        let sink = try CaptureSink(url: url, systemAudio: systemAudio, videoSize: video ? CGSize(width: width, height: height) : nil)
        sink.failed = { [weak self] message in self?.failed?(message) }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        if systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
        try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        self.sink = sink; self.stream = stream
        do { try await stream.startCapture() }
        catch {
            self.stream = nil; self.sink = nil
            throw AppError.message("Не удалось начать запись звука звонка: \(error.localizedDescription)")
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
    private var started = false
    private var ending = false
    private var reportedFailure = false

    init(url: URL, systemAudio: Bool = true, videoSize: CGSize? = nil) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000]
        system = systemAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: settings) : nil
        microphone = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        system?.expectsMediaDataInRealTime = true; microphone.expectsMediaDataInRealTime = true
        guard writer.canAdd(microphone) else {
            throw AppError.message("macOS не смогла создать звуковые дорожки.")
        }
        if let system { guard writer.canAdd(system) else { throw AppError.message("Не удалось создать системную аудиодорожку") }; writer.add(system) }
        writer.add(microphone)
        if let size = videoSize {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel]
            ])
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

    private func report() {
        guard !reportedFailure else { return }
        reportedFailure = true
        failed?(writer.error?.localizedDescription ?? "Не удалось записать аудиодорожку")
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ending = true
                guard self.started else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: AppError.message("В записи нет звука. Проверьте микрофон и звук звонка."))
                    return
                }
                self.system?.markAsFinished(); self.microphone.markAsFinished(); self.video?.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: self.writer.error ?? AppError.message("Не удалось завершить запись")) }
                }
            }
        }
    }
}
