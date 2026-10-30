#if DEBUG
import AVFoundation
import Foundation

/// Software PCM and invented host timestamps only. No audio device, capture
/// session, permission, output playback or on-disk recording is involved.
enum CaptureDriftNativeChecks {
    private struct Stage {
        let rate: Int
        let channels: Int
        let seconds: Int
    }
    private struct Result {
        var end = CMTime.invalid
        var pcmFrames: Int64 = 0
        var silenceFrames: Int64 = 0
        var maximumLag = 0.0
        var maximumLead = 0.0
        var largestGap: Int64 = 0
    }

    static func run() throws {
        for seconds in [30, 60] {
            for ppm in [0, 100, -100] {
                let result = try measure(stages: [Stage(rate: 48000, channels: 2, seconds: seconds)], ppm: ppm,
                                         checkPassthrough: true)
                let expected = Double(seconds) * (1 + Double(ppm) / 1_000_000)
                try expect(result.maximumLag <= 0.0021 && result.maximumLead <= 1.0 / 48000,
                           "Clock skew escaped the two-ms bound at \(ppm) ppm / \(seconds)s: lag \(result.maximumLag), lead \(result.maximumLead)")
                try expect(abs(result.end.seconds - 1000 - expected) <= 1.0 / 48000,
                           "EOS shortened or extended host-timed audio at \(ppm) ppm / \(seconds)s")
                try expect(result.largestGap <= 101, "A drift correction introduced a larger-than-bounded silent interval")
                if ppm >= 0 {
                    try expect(result.pcmFrames == Int64(seconds * 48000), "Positive drift altered or discarded native PCM")
                }
                if ppm == 0 { try expect(result.silenceFrames == 0, "A stable clock acquired unnecessary silence") }
                if ppm > 0 { try expect(result.silenceFrames > 0, "Positive clock skew was left to accumulate") }
            }
        }
        print("PASS: ±100 ppm over 30/60 s remains within 2.1 ms and one final PCM frame; zero drift adds no silence and native 48k samples stay unchanged")

        // Compare resampler latency against the same format's zero-skew path:
        // converter priming is unrelated to accumulated clock phase error.
        let formats = [Stage(rate: 48000, channels: 2, seconds: 15),
                       Stage(rate: 96000, channels: 1, seconds: 15),
                       Stage(rate: 44100, channels: 2, seconds: 15),
                       Stage(rate: 384000, channels: 2, seconds: 15)]
        let baseline = try measure(stages: formats, ppm: 0, checkPassthrough: false)
        for ppm in [100, -100] {
            let result = try measure(stages: formats, ppm: ppm, checkPassthrough: false)
            let expected = 60 * (1 + Double(ppm) / 1_000_000)
            try expect(result.maximumLag <= baseline.maximumLag + 0.0021 &&
                       abs(result.end.seconds - 1000 - expected) <= 1.0 / 48000,
                       "Mixed-rate converter tails lost the host clock or accumulated phase error")
        }
        let fast = [Stage(rate: 384000, channels: 2, seconds: 60)]
        let fastBaseline = try measure(stages: fast, ppm: 0, checkPassthrough: false)
        let fastDrift = try measure(stages: fast, ppm: 100, checkPassthrough: false)
        try expect(fastDrift.maximumLag <= fastBaseline.maximumLag + 0.0021 &&
                   abs(fastDrift.end.seconds - 1060.006) <= 1.0 / 48000,
                   "Continuous high-rate conversion accumulated independent-clock drift")
        print("PASS: stereo/mono 48→96→44.1→384k handoffs and continuous 384k keep converter tails and host duration without per-packet resets")
        try verifyOverlap()
    }

    private static func measure(stages: [Stage], ppm: Int, checkPassthrough: Bool) throws -> Result {
        let normalizer = CaptureAudioNormalizer()
        let ratio = 1 + Double(ppm) / 1_000_000
        var nominalTime = 0.0
        var result = Result()
        for stage in stages {
            let frames = stage.rate / 100
            for index in 0..<(stage.seconds * 100) {
                try autoreleasepool {
                    let pts = 1000 + (nominalTime + Double(index) / 100) * ratio
                    let input = try sample(time: CMTime(seconds: pts, preferredTimescale: 2_000_000_000),
                                           frames: frames, stage: stage, ratio: ratio)
                    let intendedEnd = 1000 + (nominalTime + Double(index + 1) / 100) * ratio
                    try append(normalizer.normalize(input), to: &result, intendedEnd: intendedEnd,
                               checkPassthrough: checkPassthrough)
                }
            }
            nominalTime += Double(stage.seconds)
        }
        try append(normalizer.finish(), to: &result, intendedEnd: 1000 + nominalTime * ratio,
                   checkPassthrough: checkPassthrough)
        return result
    }

    private static func append(_ packets: [CaptureAudioPacket], to result: inout Result,
                               intendedEnd: Double, checkPassthrough: Bool) throws {
        for packet in packets {
            let start: CMTime, frames: Int64
            switch packet {
            case let .sample(sample):
                start = CMSampleBufferGetPresentationTimeStamp(sample)
                frames = Int64(CMSampleBufferGetNumSamples(sample))
                result.pcmFrames += frames
                try verifyPCM(sample, unchanged: checkPassthrough)
            case let .silence(time, count):
                start = time; frames = count
                result.silenceFrames += count; result.largestGap = max(result.largestGap, count)
            }
            try expect(start.isNumeric && frames > 0, "Drift correction emitted invalid timing or an empty packet")
            if result.end.isValid {
                try expect(abs((start - result.end).seconds) < 0.0000001,
                           "Drift correction reordered, overlapped or left an implicit PCM gap")
            }
            result.end = start + CMTime(value: frames, timescale: 48000)
        }
        if result.end.isValid {
            result.maximumLag = max(result.maximumLag, intendedEnd - result.end.seconds)
            result.maximumLead = max(result.maximumLead, result.end.seconds - intendedEnd)
        }
    }

    private static func verifyPCM(_ sample: CMSampleBuffer, unchanged: Bool) throws {
        let pcm = try pcm(sample)
        guard let channels = pcm.floatChannelData else { throw AppError.message("Normalized drift PCM is not float") }
        for channel in 0..<Int(pcm.format.channelCount) {
            let expected: Float = channel == 0 ? 0.25 : -0.375
            for frame in 0..<Int(pcm.frameLength) {
                let value = channels[channel][frame]
                if !value.isFinite || abs(value) >= 1 { throw AppError.message("Drift correction corrupted PCM") }
                if unchanged && value != expected { throw AppError.message("Drift correction modified native PCM instead of an explicit silence descriptor") }
            }
        }
    }

    private static func verifyOverlap() throws {
        let normalizer = CaptureAudioNormalizer()
        let stage = Stage(rate: 48000, channels: 2, seconds: 1)
        let origin = CMTime(value: 1000, timescale: 1)
        _ = try normalizer.normalize(sample(time: origin, frames: 480, stage: stage, ratio: 1.0001, namedBase: 0))
        let nextTime = origin + CMTime(value: 10001, timescale: 2_000_000)
        let packets = try normalizer.normalize(sample(time: nextTime, frames: 480, stage: stage, ratio: 1.0001, namedBase: 500))
        var count = 0
        for packet in packets {
            guard case let .sample(sample) = packet else { throw AppError.message("Partial host-timed overlap introduced silence") }
            let decoded = try pcm(sample)
            guard let channels = decoded.floatChannelData else { throw AppError.message("Overlap PCM missing") }
            for frame in 0..<Int(decoded.frameLength) {
                let expected = Float(740 + count + frame) / 1000
                try expect(channels[0][frame] == expected && channels[1][frame] == expected,
                           "Host-duration overlap selected the wrong native PCM frame")
            }
            count += Int(decoded.frameLength)
        }
        try expect(count == 240, "100ppm half-overlap dropped an extra native PCM frame: \(count)")
        _ = try normalizer.finish()
        print("PASS: host-scaled partial overlap preserves the exact 240 remaining native frames and their named PCM values")
    }

    private static func pcm(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { throw AppError.message("Normalized drift PCM format missing") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
            throw AppError.message("Cannot allocate drift verification PCM")
        }
        pcm.frameLength = pcm.frameCapacity
        try expect(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(pcm.frameLength),
            into: pcm.mutableAudioBufferList) == noErr, "Cannot read normalized drift PCM")
        return pcm
    }

    private static func sample(time: CMTime, frames: Int, stage: Stage, ratio: Double, namedBase: Int? = nil) throws -> CMSampleBuffer {
        let stride = stage.channels * MemoryLayout<Float>.size
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(stage.rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(stride), mFramesPerPacket: 1, mBytesPerFrame: UInt32(stride),
            mChannelsPerFrame: UInt32(stage.channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw AppError.message("Cannot describe generated drift PCM")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * stride, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * stride, flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw AppError.message("Cannot allocate generated drift PCM")
        }
        let values = (0..<(frames * stage.channels)).map { index -> Float in
            if let namedBase { return Float(namedBase + index / stage.channels) / 1000 }
            return index % stage.channels == 0 ? 0.25 : -0.375
        }
        try values.withUnsafeBytes {
            try expect(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: $0.count) == noErr, "Cannot fill generated drift PCM")
        }
        let duration = stage.rate <= Int(Int32.max) / 10_000
            ? CMTime(value: Int64((ratio * 10_000).rounded()), timescale: Int32(stage.rate * 10_000))
            : CMTime(seconds: ratio / Double(stage.rate), preferredTimescale: 2_000_000_000)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = stride
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result) == noErr, let result else {
            throw AppError.message("Cannot create generated drift PCM")
        }
        return result
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppError.message(message) }
    }
}
#endif
