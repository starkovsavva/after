import AVFoundation

enum CaptureAudioPacket {
    case sample(CMSampleBuffer)
    // A compact interval, expanded only as the writer becomes ready. A long
    // microphone absence must not allocate its entire PCM silence at once.
    case silence(start: CMTime, frames: Int64)

    var bufferedFrames: Int {
        if case let .sample(sample) = self { return CMSampleBufferGetNumSamples(sample) }
        return 0
    }
}

/// One instance per audio track, confined to CaptureSink.queue. Microphone
/// buffers use the device's native format, which may change with the route.
/// AVAssetWriter must receive one stable PCM format throughout an AAC track.
final class CaptureAudioNormalizer {
    private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 48000, channels: 2, interleaved: false)!
    private var outputFormat: AVAudioFormat { Self.pcmFormat }
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var previousEnd = CMTime.invalid
    private var outputTime = CMTime.invalid
    private var expectedInputTime = CMTime.invalid

    func normalize(_ sample: CMSampleBuffer) throws -> [CaptureAudioPacket] {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mFormatID == kAudioFormatLinearPCM, basic.mSampleRate.isFinite,
              basic.mSampleRate >= 1, basic.mSampleRate <= 768000,
              basic.mChannelsPerFrame > 0, basic.mChannelsPerFrame <= 32 else { throw conversionError }
        let total = CMSampleBufferGetNumSamples(sample)
        guard total > 0, total <= 192000 else { throw conversionError }
        var count = total
        var offset = 0
        var time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time.isNumeric else { throw conversionError }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let nominalDuration = CMTime(seconds: Double(total) / format.sampleRate, preferredTimescale: 600_000_000)
        let sampleDuration = CMSampleBufferGetDuration(sample)
        // hostTimed also converts per-sample duration. A device clock's rate
        // can differ slightly from the nominal rate in its PCM description.
        let duration = sampleDuration.isValid && sampleDuration.isNumeric && sampleDuration > .zero
            ? sampleDuration : nominalDuration
        let end = time + duration
        if previousEnd.isValid, CMTimeGetSeconds(previousEnd - time) > 0.5 / format.sampleRate {
            // Old device callbacks may already be queued at a handoff. Never
            // feed duplicated PCM or rewind the writer's audio clock.
            if end <= previousEnd { return [] }
            offset = min(total, Int(ceil(CMTimeGetSeconds(previousEnd - time) / duration.seconds * Double(total))))
            count -= offset
            guard count > 0 else { return [] }
            time = time + CMTimeMultiplyByRatio(duration, multiplier: Int32(offset), divisor: Int32(total))
        }
        let tolerance = max(2 / format.sampleRate, 2 / outputFormat.sampleRate)
        let discontinuity = previousEnd.isValid && abs(CMTimeGetSeconds(time - previousEnd)) > tolerance
        var samples: [CaptureAudioPacket] = []
        if inputFormat != format || discontinuity {
            samples = try finish()
            guard let next = AVAudioConverter(from: format, to: outputFormat) else { throw conversionError }
            next.primeMethod = .normal
            converter = next; inputFormat = format
            if outputTime.isValid, time > outputTime {
                let gap = CMTimeConvertScale(time - outputTime, timescale: 48000,
                                              method: .roundHalfAwayFromZero).value
                if gap > 0 {
                    samples.append(.silence(start: outputTime, frames: gap))
                    outputTime = outputTime + CMTime(value: gap, timescale: 48000)
                }
            } else if !outputTime.isValid {
                outputTime = time
            }
            expectedInputTime = time
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw conversionError
        }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset), frameCount: Int32(count),
            into: input.mutableAudioBufferList) == noErr else { throw conversionError }
        // Small clock skew never reaches the packet-discontinuity threshold:
        // each packet can be only a microsecond late while minutes accumulate.
        // Keep the existing converter and bound that phase error to two ms.
        if expectedInputTime.isValid {
            let lag = time - expectedInputTime
            if lag.seconds > 0.002 {
                let frames = CMTimeConvertScale(lag, timescale: 48000, method: .roundHalfAwayFromZero).value
                if frames > 0 {
                    samples.append(.silence(start: outputTime, frames: frames))
                    let correction = CMTime(value: frames, timescale: 48000)
                    outputTime = outputTime + correction
                    expectedInputTime = expectedInputTime + correction
                }
            } else if lag.seconds < -0.002 {
                // makeSample already trims output which would lead host time.
                expectedInputTime = time
            }
        } else { expectedInputTime = time }
        expectedInputTime = expectedInputTime + CMTime(seconds: Double(count) / format.sampleRate,
                                                      preferredTimescale: 600_000_000)
        previousEnd = end
        var supplied = false
        samples += try convert(using: converter) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true; result.pointee = .haveData; return input
        }.map(CaptureAudioPacket.sample)
        return samples
    }

    /// Finish the old converter before a device-format change or stream stop.
    /// A valid short buffer may produce its first output only here.
    func finish() throws -> [CaptureAudioPacket] {
        guard let converter else { return [] }
        defer { self.converter = nil; inputFormat = nil; expectedInputTime = .invalid }
        var samples = try convert(using: converter) { _, result in
            result.pointee = .endOfStream; return nil
        }.map(CaptureAudioPacket.sample)
        // A final sub-threshold drift must not shorten this track when there
        // is no next packet to trigger phase correction or a format handoff.
        if outputTime.isValid, previousEnd.isValid {
            let frames = CMTimeConvertScale(previousEnd - outputTime, timescale: 48000,
                                           method: .roundHalfAwayFromZero).value
            if frames > 0 {
                samples.append(.silence(start: outputTime, frames: frames))
                outputTime = outputTime + CMTime(value: frames, timescale: 48000)
            }
        }
        return samples
    }

    /// Called only while the microphone route is absent. Flush converter tails
    /// before extending silence; late callbacks may not overwrite that interval.
    func fillSilence(until time: CMTime) throws -> [CaptureAudioPacket] {
        guard outputTime.isValid, time.isValid, time.isNumeric else { return [] }
        var samples = try finish()
        let frames = CMTimeConvertScale(time - outputTime, timescale: 48000,
                                       method: .roundHalfAwayFromZero).value
        if frames > 0 {
            samples.append(.silence(start: outputTime, frames: frames))
            outputTime = outputTime + CMTime(value: frames, timescale: 48000)
            previousEnd = outputTime
        }
        return samples
    }

    private func convert(using converter: AVAudioConverter,
                         input: @escaping AVAudioConverterInputBlock) throws -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        // Bound both allocation and iterations even for malformed or unusually
        // large native buffers. Normally only one 4096-frame block is produced.
        for _ in 0..<512 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { throw conversionError }
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            guard status != .error, error == nil else { throw conversionError }
            if output.frameLength > 0, let sample = try makeSample(output) { samples.append(sample) }
            if status == .inputRanDry || status == .endOfStream { return samples }
            guard output.frameLength > 0 else { throw conversionError }
        }
        throw conversionError
    }

    private func makeSample(_ output: AVAudioPCMBuffer) throws -> CMSampleBuffer? {
        guard outputTime.isValid, previousEnd.isValid else { throw conversionError }
        // Do not extend the capture with filter padding at EOS. Rounding to the
        // nearest target frame keeps format transitions within one PCM sample.
        let remaining = CMTimeConvertScale(previousEnd - outputTime, timescale: 48000,
                                           method: .roundHalfAwayFromZero).value
        guard remaining > 0 else { return nil }
        output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), remaining))
        let normalized = try Self.sample(output, at: outputTime)
        outputTime = outputTime + CMTime(value: Int64(output.frameLength), timescale: 48000)
        return normalized
    }

    static func silence(at time: CMTime, frames: Int) throws -> CMSampleBuffer {
        guard frames > 0, frames <= 4096,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AppError.message(L("Не удалось преобразовать звук микрофона или системы. Исходная запись сохранена."))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = plane.mData { memset(data, 0, Int(plane.mDataByteSize)) }
        }
        return try sample(buffer, at: time)
    }

    private static func sample(_ output: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var normalized: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: pcmFormat.formatDescription,
            sampleCount: Int(output.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &normalized) == noErr,
              let normalized,
              CMSampleBufferSetDataBufferFromAudioBufferList(normalized,
                blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: output.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(normalized) == noErr else {
            throw AppError.message(L("Не удалось преобразовать звук микрофона или системы. Исходная запись сохранена."))
        }
        return normalized
    }

    private var conversionError: AppError {
        .message(L("Не удалось преобразовать звук микрофона или системы. Исходная запись сохранена."))
    }
}
