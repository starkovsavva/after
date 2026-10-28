#if DEBUG
import AppKit
import AVFoundation
import PosleCore
import ScreenCaptureKit

/// Feeds generated PCM and NV12 buffers through the actual writer. These checks
/// never create an SCStream, enumerate displays, or request recording access.
@MainActor
enum CaptureWriterNativeChecks {
    static func run(root: URL) async throws {
        let directory = root.appendingPathComponent("capture-writer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), plane == 0 ? Int32(luma) : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
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
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        guard reader.startReading() else { throw AppError.message("Cannot decode generated capture") }
        var last = 0
        while let sample = output.copyNextSampleBuffer() {
            if let image = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) {
                    last = Int(base.load(as: UInt8.self))
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? AppError.message("Generated capture decode failed") }
        return last
    }

    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
}
#endif
