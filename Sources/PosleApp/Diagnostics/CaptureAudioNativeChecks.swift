#if DEBUG
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Generated PCM enters the actual CaptureSink and AAC encoder. No device,
/// SCStream, microphone permission, or audio route is opened or changed.
@MainActor
enum CaptureAudioNativeChecks {
    private struct Stage {
        var rate: Double
        var channels: AVAudioChannelCount
        var common: AVAudioCommonFormat = .pcmFormatFloat32
        var interleaved = true
    }
    private struct Decoded {
        var channels: [[Float]]
        var coverage: [Bool]
        var covered: Int { coverage.filter { $0 }.count }
    }
    private struct Packet {
        var time: CMTime
        var frames: Int
        var stage: Stage
        var system = false
    }
    private struct Fixture {
        var name: String
        var microphone: [Packet]
        var seconds = 1.0
        var gap: Range<Double>? = nil
    }

    static func run(root: URL) async throws {
        let owned = root.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(owned.deletingLastPathComponent().path)
            && owned.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable capture-audio root required")
        try normalizerClockAndOverlap()
        let directory = root.appendingPathComponent("capture-audio")
        let baseline = Stage(rate: 48000, channels: 2)
        let switched = [baseline, Stage(rate: 16000, channels: 1),
            Stage(rate: 44100, channels: 2), Stage(rate: 48000, channels: 1)]
        let layouts = [Stage(rate: 48000, channels: 2, interleaved: false),
                Stage(rate: 16000, channels: 1, common: .pcmFormatInt16),
                Stage(rate: 44100, channels: 2, common: .pcmFormatInt16, interleaved: false),
                Stage(rate: 48000, channels: 1, common: .pcmFormatInt16)]
        let eightK = Stage(rate: 8000, channels: 1)
        let fortyFourK = Stage(rate: 44100, channels: 2, interleaved: false)
        let cases: [Fixture] = [
            Fixture(name: "stable-48k-stereo", microphone: quarters(Array(repeating: baseline, count: 4))),
            Fixture(name: "native-format-switch", microphone: quarters(switched)),
            Fixture(name: "planar-and-int16-switch", microphone: quarters(layouts)),
            Fixture(name: "8k-1024-packets", microphone: packets(stage: eightK, frames: 8000, maximum: 1024)),
            Fixture(name: "44100-4096-packets", microphone: packets(stage: fortyFourK, frames: 44100, maximum: 4096)),
            Fixture(name: "4k-512-packets", microphone: packets(stage: Stage(rate: 4000, channels: 1), frames: 4000, maximum: 512)),
            Fixture(name: "384k-4096-packets", microphone: packets(stage: Stage(rate: 384000, channels: 2), frames: 384000, maximum: 4096)),
            Fixture(name: "tiny-single-packet", microphone: packets(stage: eightK, frames: 32, maximum: 32), seconds: 32.0 / 8000),
            Fixture(name: "tiny-two-packets", microphone: packets(stage: fortyFourK, frames: 32, maximum: 16), seconds: 32.0 / 44100),
            Fixture(name: "microphone-timestamp-gap", microphone: quarters(Array(repeating: baseline, count: 4))
                .filter { !(0.4..<0.5).contains(CMTimeGetSeconds($0.time)) }, gap: 0.4..<0.5)
        ]
        for item in cases {
            let name = item.name
            let expectedFrames = Int((item.seconds * 48000).rounded())
            let fixture = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let source = fixture.appendingPathComponent("recording.mov")
            let failures = CaptureAudioFailures()
            let sink = try CaptureSink(url: source, systemAudio: true)
            sink.failed = { failures.receive($0) }
            let systemPackets = packets(stage: baseline, frames: expectedFrames, maximum: 480)
                .map { packet in var value = packet; value.system = true; return value }
            let events = (systemPackets + item.microphone).sorted {
                let order = CMTimeCompare($0.time, $1.time)
                return order == 0 ? $0.system && !$1.system : order < 0
            }
            do {
                for packet in events {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        sink.queue.async {
                            do {
                                sink.consume(try sample(packet, frequencies: packet.system ? [440, 660] : [880, 880]),
                                    type: packet.system ? .audio : .microphone)
                                continuation.resume()
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    // Real AAC encoding drains independently of the generated
                    // source clock and irregular native packet boundaries.
                    try await Task.sleep(for: .milliseconds(3))
                }
                try await sink.finish()
            } catch { await sink.cancel(); throw error }
            try expect(failures.messages.isEmpty, "Generated audio writer failed in \(name): \(failures.messages)")
            let asset = AVURLAsset(url: source)
            let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
            try expect(tracks.count == 2, "System and microphone must remain independent encoded tracks: \(name)")
            var results: [[String: Any]] = []
            for (index, track) in tracks.enumerated() {
                let range = try await track.load(.timeRange)
                let descriptions = try await track.load(.formatDescriptions)
                guard let description = descriptions.first,
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                    throw AppError.message("Generated AAC track has no format: \(name)")
                }
                try expect(format.mFormatID == kAudioFormatMPEG4AAC && format.mSampleRate == 48000 && format.mChannelsPerFrame == 2,
                    "A native microphone format change altered the encoded track's stable 48 kHz stereo format: \(name)")
                try expect(abs(CMTimeGetSeconds(range.start)) < 0.003 && abs(CMTimeGetSeconds(range.end) - item.seconds) < 0.003,
                    "A native format change silently shortened or shifted the \(index == 0 ? "system" : "microphone") track: \(name), \(CMTimeGetSeconds(range.end)) s")
                let decoded = try decode(asset: asset, track: track, frames: expectedFrames)
                let gap = index == 1 ? item.gap : nil
                let expected = decoded.coverage.indices.filter { gap?.contains(Double($0) / 48000) != true }
                let covered = expected.filter { decoded.coverage[$0] }.count
                // AAC edit metadata may round by one 48 kHz frame (~21 µs).
                // Converter delay must not silently eat any longer prefix/tail.
                try expect(covered >= expected.count - 1,
                    "Decoded audio lost native packet tails: \(name), covered \(covered) of \(expected.count) expected frames")
                var stageLevels: [[Double]] = []
                for quarter in 0..<(item.seconds >= 1 ? 4 : 0) {
                    let start = Double(quarter) * 0.25 + 0.05
                    if index == 0 {
                        let left = tone(decoded.channels[0], frequency: 440, start: start)
                        let right = tone(decoded.channels[1], frequency: 660, start: start)
                        try expect(left > -38 && right > -38
                            && tone(decoded.channels[0], frequency: 660, start: start) < -48
                            && tone(decoded.channels[1], frequency: 440, start: start) < -48
                            && tone(decoded.channels[0], frequency: 880, start: start) < -48,
                            "Microphone normalization mixed or lost the independent system stereo channels in quarter \(quarter): \(name)")
                        stageLevels.append([left, right])
                    } else {
                        let levels = decoded.channels.map { tone($0, frequency: 880, start: start) }
                        try expect(levels.allSatisfy { $0 > -38 }
                            && tone(decoded.channels[0], frequency: 440, start: start) < -48
                            && tone(decoded.channels[1], frequency: 660, start: start) < -48,
                            "Microphone tone disappeared or borrowed system audio after a native format change in quarter \(quarter): \(name)")
                        stageLevels.append(levels)
                    }
                }
                if let gap {
                    try expect(tone(decoded.channels[0], frequency: 880, start: gap.lowerBound + 0.025, duration: 0.05) < -55,
                        "A microphone timestamp gap was closed or filled with adjacent speech: \(name)")
                }
                results.append(["track": index == 0 ? "system" : "microphone", "end": CMTimeGetSeconds(range.end),
                    "decodedFrames": decoded.covered, "quarterToneLevelsDB": stageLevels])
            }
            try JSONSerialization.data(withJSONObject: ["expectedSeconds": item.seconds, "expectedFrames": expectedFrames,
                "tracks": results], options: [.prettyPrinted, .sortedKeys])
                .write(to: fixture.appendingPathComponent("capture-audio-expected.json"))
            print("PASS: actual CaptureSink keeps independent stereo AAC tracks, complete PCM tails and source timing: \(name)")
        }
    }

    private static func normalizerClockAndOverlap() throws {
        let stage = Stage(rate: 48000, channels: 2)
        let first = Packet(time: .zero, frames: 480, stage: stage)
        let normalizer = CaptureAudioNormalizer()
        let original = try sample(first, value: { _, _ in 0.1 })
        var output = try normalizer.normalize(original)
        try expect(try normalizer.normalize(original).isEmpty, "A duplicate audio callback must not duplicate PCM")
        let late = Packet(time: CMTime(value: 120, timescale: 48000), frames: 120, stage: stage)
        try expect(try normalizer.normalize(sample(late, value: { _, _ in 0.3 })).isEmpty,
            "A fully late callback must not rewind the normalized audio clock")
        let overlap = Packet(time: CMTime(value: 240, timescale: 48000), frames: 480, stage: stage)
        output += try normalizer.normalize(sample(overlap, value: { frame, _ in frame < 240 ? 0.2 : 0.7 }))
        output += try normalizer.finish()
        try expect(try normalizer.finish().isEmpty, "Finishing a normalizer twice repeated its PCM tail")
        let values = try pcmValues(output)
        try expect(values.count == 720 && values.prefix(480).allSatisfy { abs($0 - 0.1) < 0.00001 }
            && values.suffix(240).allSatisfy { abs($0 - 0.7) < 0.00001 },
            "Partial overlap must discard the first 240 source samples, preserving the latter 240 values")

        let separated = CaptureAudioNormalizer()
        var bounded = try separated.normalize(original)
        let gapFrames: Int64 = 172_800_000
        let resumed = Packet(time: CMTime(value: gapFrames + 480, timescale: 48000), frames: 480, stage: stage)
        let packets = try separated.normalize(sample(resumed, value: { _, _ in 0.3 }))
        let silence = packets.compactMap { packet -> (CMTime, Int64)? in
            if case let .silence(start, frames) = packet { return (start, frames) }
            return nil
        }
        let expectedStart = CMTime(value: 48_000_480, timescale: 48000)
        try expect(silence.count == 1 && silence[0].1 == gapFrames
            && CMTimeCompare(silence[0].0, expectedStart) == 0
            && packets.reduce(0, { $0 + $1.bufferedFrames }) <= 960,
            "A one-hour source gap must remain one compact silence interval without allocating its PCM")
        bounded += packets
        bounded += try separated.finish()
        try expect(try separated.finish().isEmpty, "Repeated finish recreated a long-gap normalizer tail")
        let materialized = try pcmValues(bounded, allowSilence: true)
        try expect(materialized.count == 960
            && materialized.prefix(480).allSatisfy { abs($0 - 0.1) < 0.00001 }
            && materialized.suffix(480).allSatisfy { abs($0 - 0.3) < 0.00001 },
            "Compact silence must preserve both real PCM buffers and their independent values")
        print("PASS: normalizer ignores duplicate/late PCM, trims the correct overlap samples, keeps hour-long gaps compact and drains once")
    }

    private static func pcmValues(_ packets: [CaptureAudioPacket], allowSilence: Bool = false) throws -> [Float] {
        var values: [Float] = []
        for packet in packets {
            guard case let .sample(sample) = packet else {
                try expect(allowSilence, "Unexpected silence in contiguous normalized PCM")
                continue
            }
            guard let description = CMSampleBufferGetFormatDescription(sample) else { throw AppError.message("Normalized PCM has no format") }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let frames = CMSampleBufferGetNumSamples(sample)
            guard format.commonFormat == .pcmFormatFloat32, format.sampleRate == 48000, format.channelCount == 2,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = pcm.floatChannelData else { throw AppError.message("Unexpected normalized PCM format") }
            pcm.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                into: pcm.mutableAudioBufferList) == noErr else { throw AppError.message("Cannot inspect normalized PCM values") }
            values += (0..<frames).map { format.isInterleaved ? data[0][$0 * 2] : data[0][$0] }
        }
        return values
    }

    private static func quarters(_ stages: [Stage]) -> [Packet] {
        (0..<100).map { index in
            let stage = stages[index / 25]
            return Packet(time: CMTime(value: Int64(index), timescale: 100), frames: Int(stage.rate / 100), stage: stage)
        }
    }

    private static func packets(stage: Stage, frames: Int, maximum: Int) -> [Packet] {
        stride(from: 0, to: frames, by: maximum).map { offset in
            Packet(time: CMTime(value: Int64(offset), timescale: Int32(stage.rate)),
                frames: min(maximum, frames - offset), stage: stage)
        }
    }

    nonisolated private static func sample(_ packet: Packet, frequencies: [Double]) throws -> CMSampleBuffer {
        try sample(packet) { frame, channel in
            let time = CMTimeGetSeconds(packet.time) + Double(frame) / packet.stage.rate
            return 0.15 * sin(2 * Double.pi * frequencies[channel] * time)
        }
    }

    nonisolated private static func sample(_ packet: Packet, value: (Int, Int) -> Double) throws -> CMSampleBuffer {
        let stage = packet.stage
        guard let format = AVAudioFormat(commonFormat: stage.common, sampleRate: stage.rate,
            channels: stage.channels, interleaved: stage.interleaved),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.frames)) else {
            throw AppError.message("Cannot allocate generated capture PCM")
        }
        let frames = packet.frames
        pcm.frameLength = AVAudioFrameCount(frames)
        for (plane, buffer) in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList).enumerated() {
            guard let data = buffer.mData else { throw AppError.message("Generated PCM has no storage") }
            let channels = Int(buffer.mNumberChannels)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let logical = stage.interleaved ? channel : plane
                    let generated = value(frame, logical)
                    let offset = frame * channels + channel
                    if stage.common == .pcmFormatFloat32 { data.assumingMemoryBound(to: Float.self)[offset] = Float(generated) }
                    else { data.assumingMemoryBound(to: Int16.self)[offset] = Int16((generated * 32767).rounded()) }
                }
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(stage.rate)),
            presentationTimeStamp: CMTime(value: 1000, timescale: 1) + packet.time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(sample) == noErr else {
            throw AppError.message("Cannot create generated native-format audio sample")
        }
        return sample
    }

    private static func decode(asset: AVAsset, track: AVAssetTrack, frames: Int) throws -> Decoded {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw AppError.message("Cannot decode generated capture audio") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError.message("Cannot start generated audio decode") }
        var channels = Array(repeating: [Float](repeating: 0, count: frames), count: 2)
        var covered = [Bool](repeating: false, count: frames)
        while let sample = output.copyNextSampleBuffer() {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { throw AppError.message("Decoded PCM has no description") }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let frames = CMSampleBufferGetNumSamples(sample)
            guard format.sampleRate == 48000, format.channelCount == 2, format.commonFormat == .pcmFormatFloat32,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = pcm.floatChannelData else { throw AppError.message("Decoded capture changed its PCM rate/channels") }
            pcm.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                into: pcm.mutableAudioBufferList) == noErr else { throw AppError.message("Cannot inspect decoded capture PCM") }
            let first = Int((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 48000).rounded())
            for frame in 0..<frames where covered.indices.contains(first + frame) {
                covered[first + frame] = true
                for channel in 0..<2 {
                    let value = format.isInterleaved ? data[0][frame * 2 + channel] : data[channel][frame]
                    guard value.isFinite else { throw AppError.message("Decoded capture contains invalid PCM values") }
                    channels[channel][first + frame] = value
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? AppError.message("Generated audio decode failed") }
        return Decoded(channels: channels, coverage: covered)
    }

    private static func tone(_ values: [Float], frequency: Double, start: Double, duration: Double = 0.15) -> Double {
        let lower = Int((start * 48000).rounded()), count = Int((duration * 48000).rounded())
        var real = 0.0, imaginary = 0.0
        for index in 0..<count {
            let value = Double(values[lower + index])
            let phase = 2 * Double.pi * frequency * Double(index) / 48000
            real += value * cos(phase); imaginary += value * sin(phase)
        }
        return 20 * log10(max(2 * hypot(real, imaginary) / Double(count), 1e-12))
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
}

private final class CaptureAudioFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func receive(_ message: String) { lock.lock(); values.append(message); lock.unlock() }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
#endif
