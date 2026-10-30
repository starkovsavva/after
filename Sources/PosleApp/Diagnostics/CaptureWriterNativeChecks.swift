#if DEBUG
import AppKit
import AVFoundation
import PosleCore
import ScreenCaptureKit

private final class CaptureIngressFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
}

/// Feeds generated PCM and NV12 buffers through the actual writer. These checks
/// never create an SCStream, enumerate displays, or request recording access.
@MainActor
enum CaptureWriterNativeChecks {
    static func run(root: URL) async throws {
        let directory = root.appendingPathComponent("capture-writer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await incomingControlEvents(directory: directory)
        let cases: [(String, Int, [Int: UInt8])] = [
            ("static", 100, [0: 80, 20: 180]),
            ("single", 100, [0: 180]),
            ("short", 2, [0: 180]),
            ("fractional", 101, [0: 80, 20: 180])
        ]
        for (name, buffers, changes) in cases {
            let fixture = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let source = fixture.appendingPathComponent("recording.mov")
            let sink = try CaptureSink(url: source, systemAudio: false,
                videoSize: .init(width: 320, height: 200))
            try await feed(sink, frameChanges: changes, inactiveStatus: .idle, audioBuffers: buffers)
            try await sink.finish()
            let asset = AVURLAsset(url: source)
            let video = try await requiredTrack(asset, .video)
            let range = try await video.load(.timeRange)
            let duration = Double(buffers) * 0.01
            let videoDuration = max(duration, 1.0 / 30.0)
            try expect(abs(CMTimeGetSeconds(range.end) - videoDuration) < 0.003,
                       "Static screen ended before audio or acquired an extra final frame: " + name)
            let audio = try await requiredTrack(asset, .audio)
            let audioRange = try await audio.load(.timeRange)
            try expect(abs(CMTimeGetSeconds(audioRange.end) - duration) < 0.003,
                       "Synthetic full-length audio was lost: " + name)
            try expect(try decodedLastLuma(asset: asset, track: video) > 150,
                       "The final held frame did not retain the latest screen pixels: " + name)
            let metadata: [String: Any] = ["id": name, "title": "Synthetic static screen",
                "source": "recording.mov", "hasVideo": true, "recordingTracks": false]
            try JSONSerialization.data(withJSONObject: metadata).write(to: fixture.appendingPathComponent("meta.json"))
            let expected: [String: Any] = ["duration": videoDuration, "audioDuration": duration,
                "firstLuma": Int(changes[0] ?? 0), "lastLuma": 180]
            try JSONSerialization.data(withJSONObject: expected).write(to: fixture.appendingPathComponent("capture-expected.json"))
        }
        print("PASS: actual capture writer preserves static and changed frames for full, short and fractional audio timelines")
        try copierPixelContract(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 322, height: 202)
        try copierPixelContract(format: kCVPixelFormatType_32BGRA, width: 326, height: 198)
        print("PASS: padded NV12/BGRA copies preserve active rows, color attachment modes, sample timing and matching owned format without sharing pixels")
        try copierPoolContract()
        print("PASS: eight retained owned frames bound the copy pool; saturation releases the producer surface and copying recovers after owned frames release")
        try await sourcePoolReuse(directory: directory)
        try await animatedSourcePool(directory: directory)

        for status in [SCFrameStatus.blank, .suspended] {
            let blankURL = directory.appendingPathComponent("unavailable-\(status.rawValue).mov")
            let blank = try CaptureSink(url: blankURL, systemAudio: false,
                videoSize: .init(width: 320, height: 200))
            try await feed(blank, frameChanges: [0: 80, 20: 180], inactiveStatus: status)
            try await blank.finish()
            let blankAsset = AVURLAsset(url: blankURL)
            let blankTrack = try await requiredTrack(blankAsset, .video)
            let blankRange = try await blankTrack.load(.timeRange)
            try expect(CMTimeGetSeconds(blankRange.end) < 0.5,
                       "A protected or blank display incorrectly extended its previous desktop image")
        }
        print("PASS: capture ending with blank/suspended screen never extends its previous desktop image")

        let missingURL = directory.appendingPathComponent("missing-video.mov")
        let missing = try CaptureSink(url: missingURL, systemAudio: false,
            videoSize: .init(width: 320, height: 200))
        try await feed(missing, frameChanges: [:], inactiveStatus: .idle)
        do { try await missing.finish(); throw AppError.message("Audio-only capture incorrectly reported a successful video") }
        catch {
            try expect(error.localizedDescription.contains("ни одного видеокадра"),
                       "Missing-video failure did not identify the real problem")
        }
        try expect(FileManager.default.fileExists(atPath: missingURL.path), "Missing video removed recoverable audio")
        let recovered = AVURLAsset(url: missingURL)
        let recoveredAudio = try await requiredTrack(recovered, .audio)
        let recoveredRange = try await recoveredAudio.load(.timeRange)
        try expect(CMTimeGetSeconds(recoveredRange.end) >= 0.99,
                   "Missing-video failure discarded the captured audio")
        print("PASS: capture without video frames fails explicitly while finalizing recoverable original audio")

        for (code, expected, forbidden) in [
            (-3801, "подтвердите выбор", "не нашла доступный экран"),
            (-3814, "не нашла доступный экран", "Разрешите доступ"),
            (-3806, "потеряла подключение", "Разрешите доступ"),
            (-3811, "получить доступные экраны", "Разрешите доступ")
        ] {
            let error = NSError(domain: SCStreamErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "private-window-title"])
            let message = MeetingRecorder.shareableContentError(error).localizedDescription
            try expect(message.contains(expected) && !message.contains(forbidden)
                       && message.contains("код \(code)") && !message.contains("private-window-title"),
                       "ScreenCaptureKit error classification discarded the code or exposed raw diagnostics")
        }
        let userStopped = MeetingRecorder.captureFailure(NSError(domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userStopped.rawValue, userInfo: [NSLocalizedDescriptionKey: "private-window-title"]),
            sessionID: "synthetic-session")
        let denied = MeetingRecorder.captureFailure(NSError(domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue), sessionID: "synthetic-session")
        try expect(userStopped.userInitiated && !denied.userInitiated &&
                   userStopped.sessionID == "synthetic-session" && !userStopped.message.contains("private-window-title"),
                   "macOS user Stop must preserve session identity and be distinct from permission failure")
        print("PASS: recording permission, display, application-context and internal errors keep distinct safe diagnostics; macOS Stop is user-initiated")
    }

    private static func incomingControlEvents(directory: URL) async throws {
        for status in [SCFrameStatus.idle, .blank, .suspended] {
            let source = directory.appendingPathComponent("incoming-\(status.rawValue).mov")
            let sink = try CaptureSink(url: source, systemAudio: false, videoSize: .init(width: 320, height: 200))
            let failures = CaptureIngressFailures()
            sink.failed = { failures.append($0) }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    sink.queue.async {
                        do {
                            let clock = CMClockGetHostTimeClock()
                            sink.consume(try audio(1000), type: .microphone)
                            sink.consumeIncoming(try screen(1000, luma: 180, status: .complete), type: .screen, clock: clock)
                            sink.consumeIncoming(try screen(1000.2, luma: 0, status: status), type: .screen, clock: nil)
                            if status == .idle {
                                let event = try emptyControl(1000.5)
                                guard CMSampleBufferGetNumSamples(event) == 0 else { throw AppError.message("Idle fixture must contain zero media samples") }
                                // A zero-sample event has no sample-attachment
                                // dictionary, so exercise the actual idle handler directly.
                                sink.consumeIdle(event, clock: clock)
                            } else {
                                sink.consume(try audio(1000.8), type: .microphone)
                            }
                            for ignored in [SCFrameStatus.started, .stopped] {
                                sink.consumeIncoming(try screen(1000.9, luma: 0, status: ignored), type: .screen, clock: nil)
                            }
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                try await sink.finish()
            } catch { await sink.cancel(); throw error }
            try expect(failures.count == 0, "Clockless screen control events incorrectly reported a recording failure")
            let asset = AVURLAsset(url: source)
            let video = try await requiredTrack(asset, .video)
            let range = try await video.load(.timeRange)
            if status == .idle {
                let luma = try decodedLastLuma(asset: asset, track: video)
                try expect(range.end.seconds > 0.5 && range.end.seconds < 0.54 &&
                           luma > 150,
                           "Zero-sample idle lost its host-timed static-video tail")
            } else {
                try expect(range.end.seconds < 0.1,
                           "A clockless blank/suspended event retained the last visible frame as a long tail")
            }
        }
        print("PASS: real SCK ingress ignores clockless control events; zero-sample idle preserves static duration while blank/suspended clear the held frame")

        let audioOnly = try CaptureSink(url: directory.appendingPathComponent("incoming-audio-only.mov"), systemAudio: true)
        let failures = CaptureIngressFailures()
        audioOnly.failed = { failures.append($0) }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioOnly.queue.async {
                    do {
                        audioOnly.consumeIncoming(try emptyControl(1000), type: .audio, clock: nil)
                        audioOnly.consumeIncoming(try unreadyAudio(1000), type: .audio, clock: nil)
                        audioOnly.consumeIncoming(try screen(1000, luma: 180, status: .complete), type: .screen, clock: nil)
                        audioOnly.consumeIncoming(try screen(1000.5, luma: 0, status: .blank), type: .screen, clock: nil)
                        audioOnly.consumeIncoming(try audio(1000), type: .audio, clock: CMClockGetHostTimeClock())
                        audioOnly.consume(try audio(1000), type: .microphone)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try await audioOnly.finish()
        } catch { await audioOnly.cancel(); throw error }
        try expect(failures.count == 0, "Audio-only capture tried to retime empty/unready audio or unwanted screen events")
        let missingClock = try CaptureSink(url: directory.appendingPathComponent("incoming-missing-clock.mov"), systemAudio: false,
                                          videoSize: .init(width: 320, height: 200))
        let clockFailures = CaptureIngressFailures()
        missingClock.failed = { clockFailures.append($0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            missingClock.queue.async {
                do {
                    missingClock.consumeIncoming(try screen(1000, luma: 80, status: .complete), type: .screen, clock: nil)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        await missingClock.cancel()
        try expect(clockFailures.count == 1, "A complete media frame without a synchronization clock must still fail explicitly")
        print("PASS: audio-only ingress ignores empty/unready PCM and unwanted screen events; a real complete frame still requires its source clock")
    }

    nonisolated private static func emptyControl(_ time: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else {
            throw AppError.message("Cannot create zero-sample generated capture event")
        }
        return sample
    }

    nonisolated private static func unreadyAudio(_ time: Double) throws -> CMSampleBuffer {
        let reference = try audio(time)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: CMSampleBufferGetFormatDescription(reference),
            sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else {
            throw AppError.message("Cannot create unready generated PCM")
        }
        return sample
    }

    private static func copierPixelContract(format: OSType, width: Int, height: Int) throws {
        var source: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferBytesPerRowAlignmentKey as String: 256,
             kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &source)
        guard result == kCVReturnSuccess, let source else { throw AppError.message("Cannot create padded source image") }
        try writePixelPattern(source)
        let expected = try activePixelBytes(source)
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldNotPropagate)
        let original = try screen(1000, pixel: source, status: .complete)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1001, timescale: 30000),
            presentationTimeStamp: CMTime(value: 60000001, timescale: 60000),
            decodeTimeStamp: CMTime(value: 59997999, timescale: 60000))
        var timed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: original,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &timed) == noErr, let timed,
              let copied = try CaptureVideoFrameCopier().copy(timed),
              let image = CMSampleBufferGetImageBuffer(copied), let description = CMSampleBufferGetFormatDescription(copied) else {
            throw AppError.message("Cannot copy padded generated sample")
        }
        let sourceStride = CVPixelBufferIsPlanar(source) ? CVPixelBufferGetBytesPerRowOfPlane(source, 0) : CVPixelBufferGetBytesPerRow(source)
        let ownedStride = CVPixelBufferIsPlanar(image) ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
        try expect(sourceStride != ownedStride, "Padded source must exercise different source/destination row strides")
        try expect(try activePixelBytes(image) == expected, "A padded copy shifted rows or changed active NV12/BGRA pixels")
        try expect(CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: image),
            "Copied image still uses a format description bound to the source layout")
        var copiedTiming = CMSampleTimingInfo()
        try expect(CMSampleBufferGetSampleTimingInfo(copied, at: 0, timingInfoOut: &copiedTiming) == noErr
            && CMTimeCompare(copiedTiming.presentationTimeStamp, timing.presentationTimeStamp) == 0
            && CMTimeCompare(copiedTiming.decodeTimeStamp, timing.decodeTimeStamp) == 0
            && CMTimeCompare(copiedTiming.duration, timing.duration) == 0,
            "Copying pixels changed PTS, DTS or sample duration")
        for (key, expectedValue, expectedMode) in [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, CVAttachmentMode.shouldPropagate),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldNotPropagate)
        ] {
            var mode = CVAttachmentMode.shouldPropagate
            let value = CVBufferGetAttachment(image, key, &mode)?.takeUnretainedValue()
            try expect(value.map { CFEqual($0, expectedValue) } == true && mode == expectedMode,
                "A copied frame lost a color attachment or its propagation mode")
        }
        try overwritePixelBytes(image, byte: 0xA5)
        try expect(try activePixelBytes(source) == expected, "Mutating an owned frame changed the producer's original pixels")
        try overwritePixelBytes(source, byte: 0x17)
        try expect(try activePixelBytes(image).allSatisfy { $0 == 0xA5 }, "Mutating the producer's returned surface changed the owned pixels")
    }

    private static func copierPoolContract() throws {
        let copier = CaptureVideoFrameCopier(), pool = try sourcePool(capacity: 1)
        var held: [CMSampleBuffer] = []
        for index in 0..<8 {
            try autoreleasepool {
                let source = try pooledPixel(pool, capacity: 1)
                try fill(source, luma: UInt8(60 + index))
                let sample = try screen(1000 + Double(index) / 30, pixel: source, status: .complete)
                guard let owned = try copier.copy(sample) else { throw AppError.message("Owned frame budget exhausted before eight frames") }
                held.append(owned)
            }
        }
        try autoreleasepool {
            let source = try pooledPixel(pool, capacity: 1)
            let sample = try screen(1001, pixel: source, status: .complete)
            if let _ = try copier.copy(sample) { throw AppError.message("A saturated copier allocated beyond its eight-frame budget") }
        }
        try autoreleasepool {
            // A nil result must not stash a borrowed frame for a later retry.
            _ = try pooledPixel(pool, capacity: 1)
        }
        held.removeAll()
        try autoreleasepool {
            let source = try pooledPixel(pool, capacity: 1)
            try fill(source, luma: 120)
            let sample = try screen(1002, pixel: source, status: .complete)
            guard let recovered = try copier.copy(sample), let image = CMSampleBufferGetImageBuffer(recovered) else {
                throw AppError.message("Owned frame pool did not recover after its retained samples were released")
            }
            try expect(try activePixelBytes(image) == activePixelBytes(source), "A recovered copier slot contained stale pixels")
        }
    }

    nonisolated private static func pixelRows(_ image: CVPixelBuffer, flags: CVPixelBufferLockFlags,
                                            _ body: (UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void) throws {
        guard CVPixelBufferLockBaseAddress(image, flags) == kCVReturnSuccess else { throw AppError.message("Cannot inspect generated image rows") }
        defer { CVPixelBufferUnlockBaseAddress(image, flags) }
        let planes = CVPixelBufferGetPlaneCount(image)
        for plane in 0..<max(planes, 1) {
            let base = planes == 0 ? CVPixelBufferGetBaseAddress(image) : CVPixelBufferGetBaseAddressOfPlane(image, plane)
            let stride = planes == 0 ? CVPixelBufferGetBytesPerRow(image) : CVPixelBufferGetBytesPerRowOfPlane(image, plane)
            let rows = planes == 0 ? CVPixelBufferGetHeight(image) : CVPixelBufferGetHeightOfPlane(image, plane)
            let width = planes == 0 ? CVPixelBufferGetWidth(image) : CVPixelBufferGetWidthOfPlane(image, plane)
            let activeBytes = width * (planes == 0 ? 4 : plane == 0 ? 1 : 2)
            guard let base, activeBytes <= stride else { throw AppError.message("Invalid generated image plane layout") }
            for row in 0..<rows { body(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), activeBytes, row, plane) }
        }
    }

    nonisolated private static func writePixelPattern(_ image: CVPixelBuffer) throws {
        try pixelRows(image, flags: []) { row, activeBytes, index, plane in
            for column in 0..<activeBytes { row[column] = UInt8(truncatingIfNeeded: index * 17 + column * 13 + plane * 71) }
        }
    }

    nonisolated private static func activePixelBytes(_ image: CVPixelBuffer) throws -> [UInt8] {
        var bytes: [UInt8] = []
        try pixelRows(image, flags: .readOnly) { row, activeBytes, _, _ in
            bytes.append(contentsOf: UnsafeBufferPointer(start: row, count: activeBytes))
        }
        return bytes
    }

    nonisolated private static func overwritePixelBytes(_ image: CVPixelBuffer, byte: UInt8) throws {
        try pixelRows(image, flags: []) { row, activeBytes, _, _ in _ = memset(row, Int32(byte), activeBytes) }
    }

    private static func sourcePoolReuse(directory: URL) async throws {
        let source = directory.appendingPathComponent("source-pool-reuse.mov")
        let sink = try CaptureSink(url: source, systemAudio: false, videoSize: .init(width: 320, height: 200))
        let pool = try sourcePool(capacity: 1)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.queue.async {
                    do {
                        sink.consume(try audio(1000), type: .microphone)
                        try deliverPooledScreen(sink, pool: pool, capacity: 1, time: 1000, luma: 80)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            // A separate FIFO block starts only after all producer locals and
            // autoreleased callback objects from delivery have been destroyed.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.queue.async {
                    do {
                        try autoreleasepool {
                            let recycled = try pooledPixel(pool, capacity: 1)
                            // A capture producer can overwrite its returned surface
                            // before another callback. The saved image must own its pixels.
                            try fill(recycled, luma: 210)
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            for index in 1..<100 {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    sink.queue.async {
                        do {
                            sink.consume(try audio(1000 + Double(index) * 0.01), type: .microphone)
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                try await Task.sleep(for: .milliseconds(3))
            }
            try await sink.finish()
        } catch { await sink.cancel(); throw error }
        let asset = AVURLAsset(url: source)
        let video = try await requiredTrack(asset, .video)
        let range = try await video.load(.timeRange)
        let lumas = try decodedLumas(asset: asset, track: video)
        try expect(abs(CMTimeGetSeconds(range.end) - 1) < 0.003 && !lumas.isEmpty
            && lumas.allSatisfy { abs($0 - 80) <= 8 },
            "Recycling the capture producer's surface changed the writer-owned first or final image")
        print("PASS: one-surface source pool is reusable immediately after callback; later producer writes cannot alter saved static pixels")
    }

    private static func animatedSourcePool(directory: URL) async throws {
        let source = directory.appendingPathComponent("source-pool-animation.mov")
        let sink = try CaptureSink(url: source, systemAudio: false, videoSize: .init(width: 320, height: 200))
        let pool = try sourcePool(capacity: 3)
        let levels: [UInt8] = [60, 100, 140, 180, 210]
        do {
            for index in 0..<160 {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    sink.queue.async {
                        do {
                            let time = 1000 + Double(index) * 0.01
                            sink.consume(try audio(time), type: .microphone)
                            if index.isMultiple(of: 4) {
                                try deliverPooledScreen(sink, pool: pool, capacity: 3, time: time, luma: levels[index / 32])
                            }
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                try await Task.sleep(for: .milliseconds(3))
            }
            try await sink.finish()
        } catch { await sink.cancel(); throw error }
        let asset = AVURLAsset(url: source)
        let video = try await requiredTrack(asset, .video), audioTrack = try await requiredTrack(asset, .audio)
        let videoRange = try await video.load(.timeRange), audioRange = try await audioTrack.load(.timeRange)
        let lumas = try decodedLumas(asset: asset, track: video)
        try expect(lumas.count >= 20,
            "A bounded three-surface source pool stalled animated capture or lost most delivered frames")
        try expect(abs(CMTimeGetSeconds(videoRange.end) - 1.6) < 0.003
            && abs(CMTimeGetSeconds(audioRange.end) - 1.6) < 0.003,
            "Animated pooled capture lost the full shared video/audio timeline")
        let stages = lumas.map { value in levels.indices.min { abs(value - Int(levels[$0])) < abs(value - Int(levels[$1])) }! }
        try expect(Set(stages) == Set(levels.indices) && stages == stages.sorted()
            && lumas.allSatisfy { value in levels.contains { abs(value - Int($0)) <= 8 } },
            "Animated pooled capture froze or reordered generated screen changes while audio continued")
        print("PASS: bounded three-surface source pool preserves five changing screen images, frame progression and full video/audio duration")
    }

    nonisolated private static func sourcePool(capacity: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: capacity] as CFDictionary,
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200,
             kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pool)
        guard result == kCVReturnSuccess, let pool else { throw AppError.message("Cannot create bounded generated capture source pool") }
        return pool
    }

    nonisolated private static func pooledPixel(_ pool: CVPixelBufferPool, capacity: Int) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: capacity] as CFDictionary, &pixel)
        guard result == kCVReturnSuccess, let pixel else {
            throw AppError.message("Capture retained a source surface after its callback: pool capacity \(capacity), allocation status \(result)")
        }
        return pixel
    }

    nonisolated private static func deliverPooledScreen(_ sink: CaptureSink, pool: CVPixelBufferPool, capacity: Int,
                                                       time: Double, luma: UInt8) throws {
        try autoreleasepool {
            let pixel = try pooledPixel(pool, capacity: capacity)
            try fill(pixel, luma: luma)
            sink.consume(try screen(time, pixel: pixel, status: .complete), type: .screen)
        }
    }

    private static func feed(_ sink: CaptureSink, frameChanges: [Int: UInt8], inactiveStatus: SCFrameStatus, audioBuffers: Int = 100) async throws {
        for index in 0..<audioBuffers {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.queue.async {
                    do {
                        let time = 1000 + Double(index) * 0.01
                        sink.consume(try audio(time), type: .microphone)
                        if let luma = frameChanges[index] {
                            sink.consume(try screen(time, luma: luma, status: .complete), type: .screen)
                        } else if index == 30 && !frameChanges.isEmpty {
                            sink.consume(try screen(time, luma: 0, status: inactiveStatus), type: .screen)
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            // Gives the actual AAC/H.264 encoders time to drain without busy
            // waiting; the generated media timeline stays independent of wall time.
            try await Task.sleep(for: .milliseconds(3))
        }
    }

    nonisolated private static func screen(_ time: Double, luma: UInt8, status: SCFrameStatus) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 320, 200,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel)
        guard result == kCVReturnSuccess, let pixel else { throw AppError.message("Cannot create generated NV12 frame") }
        try fill(pixel, luma: luma)
        return try screen(time, pixel: pixel, status: status)
    }

    nonisolated private static func fill(_ pixel: CVPixelBuffer, luma: UInt8) throws {
        guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw AppError.message("Cannot fill generated NV12 source surface") }
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), plane == 0 ? Int32(luma) : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
        }
    }

    nonisolated private static func screen(_ time: Double, pixel: CVPixelBuffer, status: SCFrameStatus) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else {
            throw AppError.message("Cannot describe generated video")
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            throw AppError.message("Cannot create generated screen sample")
        }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
            Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(),
            Unmanaged.passUnretained(NSNumber(value: status.rawValue)).toOpaque())
        return sample
    }

    nonisolated private static func audio(_ time: Double) throws -> CMSampleBuffer {
        let frames = 480, bytesPerFrame = 8
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw AppError.message("Cannot describe generated PCM")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * bytesPerFrame, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * bytesPerFrame, flags: 0, blockBufferOut: &block) == noErr,
            let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: frames * bytesPerFrame) == noErr else {
            throw AppError.message("Cannot allocate generated PCM")
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var size = bytesPerFrame
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else {
            throw AppError.message("Cannot create generated audio sample")
        }
        return sample
    }

    private static func requiredTrack(_ asset: AVAsset, _ type: AVMediaType) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: type).first else {
            throw AppError.message("Generated capture is missing \(type.rawValue)")
        }
        return track
    }

    private static func decodedLastLuma(asset: AVAsset, track: AVAssetTrack) throws -> Int {
        try decodedLumas(asset: asset, track: track).last ?? 0
    }

    private static func decodedLumas(asset: AVAsset, track: AVAssetTrack) throws -> [Int] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading() else { throw AppError.message("Cannot decode generated capture") }
        var frames: [(time: CMTime, luma: Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            if let image = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) {
                    frames.append((CMSampleBufferGetPresentationTimeStamp(sample), Int(base.load(as: UInt8.self))))
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? AppError.message("Generated capture decode failed") }
        return frames.sorted { CMTimeCompare($0.time, $1.time) < 0 }.map(\.luma)
    }

    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
}
#endif
