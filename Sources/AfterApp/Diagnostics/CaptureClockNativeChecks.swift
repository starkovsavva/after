import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import CoreMedia
import Foundation

/// Synthetic clocks, bytes and metadata only. Never creates a capture session,
/// enumerates devices, requests permission or changes the system host clock.
enum CaptureClockNativeChecks {
    static func run() throws {
        let source = try timebase(rate: 2, origin: 100)
        let destination = try timebase(rate: 0.5, origin: 20)
        let originalTiming = [
            info(pts: 104, dts: 103, duration: 4),
            info(pts: 108, dts: 107, duration: 2),
            info(pts: 110, dts: 109, duration: 6)
        ]
        let original = try sample(timing: originalTiming, count: 3)
        let propagated = "PosleClockPropagated" as CFString
        let local = "PosleClockLocal" as CFString
        CMSetAttachment(original, key: propagated, value: "shared metadata" as CFString, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(original, key: local, value: "local metadata" as CFString, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        if let entries = CMSampleBufferGetSampleAttachmentsArray(original, createIfNecessary: true) as? [NSMutableDictionary] {
            for entry in entries { entry[kCMSampleAttachmentKey_NotSync as String] = true }
        }
        try expect(CMSampleBufferSetOutputPresentationTimeStamp(original, newValue: CMTime(seconds: 999, preferredTimescale: 600)) == noErr,
                   "Cannot create synthetic output timestamp override")
        let converted = try CaptureSampleClock.convert(original, from: source, to: destination)
        try close(CMSampleBufferGetPresentationTimeStamp(converted), 21, "Actual PTS retained the source origin")
        try close(CMSampleBufferGetOutputPresentationTimeStamp(converted), 21, "A stale output timestamp survived real timing replacement")
        for (index, expected) in [(0, (21.0, 20.75, 1.0)), (1, (22.0, 21.75, 0.5)), (2, (22.5, 22.25, 1.5))] {
            var timing = CMSampleTimingInfo()
            try expect(CMSampleBufferGetSampleTimingInfo(converted, at: index, timingInfoOut: &timing) == noErr, "Converted timing entry missing")
            try close(timing.presentationTimeStamp, expected.0, "Per-sample PTS was not converted")
            try close(timing.decodeTimeStamp, expected.1, "Per-sample DTS was not converted")
            try close(timing.duration, expected.2, "Duration used an absolute origin instead of a relative interval")
        }
        let originalBytes = try bytes(original), convertedBytes = try bytes(converted)
        try expect(CMSampleBufferGetNumSamples(converted) == 3 && CMSampleBufferDataIsReady(converted) &&
                   CMSampleBufferGetTotalSampleSize(converted) == CMSampleBufferGetTotalSampleSize(original) &&
                   convertedBytes == originalBytes, "Retiming changed sample count, readiness or encoded content")
        if let originalFormat = CMSampleBufferGetFormatDescription(original), let convertedFormat = CMSampleBufferGetFormatDescription(converted) {
            try expect(CMFormatDescriptionEqual(originalFormat, otherFormatDescription: convertedFormat), "Retiming changed the media format description")
        } else { throw AppError.message("Synthetic media format missing") }
        for (key, expected, expectedMode) in [(propagated, "shared metadata", kCMAttachmentMode_ShouldPropagate),
                                               (local, "local metadata", kCMAttachmentMode_ShouldNotPropagate)] {
            var mode: CMAttachmentMode = 99
            let value = CMGetAttachment(converted, key: key, attachmentModeOut: &mode)
            try expect((value as? String) == expected && mode == expectedMode, "Retiming lost attachment metadata or its propagation mode")
        }
        guard let beforeAttachments = CMSampleBufferGetSampleAttachmentsArray(original, createIfNecessary: false),
              let afterAttachments = CMSampleBufferGetSampleAttachmentsArray(converted, createIfNecessary: false) else {
            throw AppError.message("Retiming lost per-sample attachments")
        }
        try expect(CFEqual(beforeAttachments, afterAttachments), "Retiming changed per-sample attachments")
        try close(CMSampleBufferGetPresentationTimeStamp(original), 104, "Retiming mutated the producer's original PTS")
        print("PASS: synthetic independent clocks convert real multi-sample PTS/DTS and relative durations while preserving source bytes/format and both attachment modes")

        let compact = try sample(timing: [info(pts: 104, dts: nil, duration: 2)], count: 4)
        let compactCopy = try CaptureSampleClock.convert(compact, from: source, to: destination)
        var last = CMSampleTimingInfo()
        try expect(CMSampleBufferGetSampleTimingInfo(compactCopy, at: 3, timingInfoOut: &last) == noErr && !last.decodeTimeStamp.isValid,
                   "Compact timing did not cover all samples or invalid DTS became numeric")
        try close(last.presentationTimeStamp, 22.5, "Compact timing's derived sample PTS drifted")
        try close(last.duration, 0.5, "Compact per-sample duration was not scaled")
        try close(CMSampleBufferGetDuration(compactCopy), 2, "Compact buffer duration lost its sample count")
        let unknown = try sample(timing: [CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: 104, timescale: 1), decodeTimeStamp: .invalid)], count: 1)
        let unknownCopy = try CaptureSampleClock.convert(unknown, from: source, to: destination)
        var unknownTiming = CMSampleTimingInfo()
        try expect(CMSampleBufferGetSampleTimingInfo(unknownCopy, at: 0, timingInfoOut: &unknownTiming) == noErr &&
                   !unknownTiming.duration.isValid && !unknownTiming.decodeTimeStamp.isValid,
                   "Unknown duration or absent DTS must retain its invalid marker")
        let host = CMClockGetHostTimeClock()
        let hostSample = try sample(timing: [CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 100), presentationTimeStamp: CMClockGetTime(host), decodeTimeStamp: .invalid)], count: 1)
        let hostCopy = try CaptureSampleClock.hostTimed(hostSample, clock: host)
        try expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(hostCopy), CMSampleBufferGetPresentationTimeStamp(hostSample)) == 0,
                   "Production hostTimed changed timestamps already on the host clock")
        print("PASS: compact timing scales every derived sample, unknown timing markers remain unknown, and production host-clock conversion preserves host PTS")

        for bad in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            let invalid = try sample(timing: [CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: bad, decodeTimeStamp: .invalid)], count: 1)
            try rejects { try CaptureSampleClock.convert(invalid, from: source, to: destination) }
        }
        let invalidated = try sample(timing: [info(pts: 104, dts: nil, duration: 1)], count: 1)
        CMSampleBufferInvalidate(invalidated)
        try rejects { try CaptureSampleClock.convert(invalidated, from: source, to: destination) }
        let reverse = try timebase(rate: -1, origin: 0)
        try rejects { try CaptureSampleClock.convert(compact, from: reverse, to: destination) }
        let oversized = try sample(timing: (0..<16_385).map { info(pts: 104 + Double($0), dts: nil, duration: 0.5) }, count: 16_385)
        try rejects { try CaptureSampleClock.convert(oversized, from: source, to: destination) }
        print("PASS: nonnumeric PTS, invalidated buffers, reversing clocks and oversized timing arrays fail before entering the writer")
    }

    private static func timebase(rate: Double, origin: Double) throws -> CMTimebase {
        var value: CMTimebase?
        try expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &value) == noErr,
                   "Cannot create synthetic clock timebase")
        guard let value else { throw AppError.message("Synthetic clock missing") }
        try expect(CMTimebaseSetRateAndAnchorTime(value, rate: rate, anchorTime: CMTime(seconds: origin, preferredTimescale: 600),
                                                immediateSourceTime: CMTime(value: 1000, timescale: 1)) == noErr,
                   "Cannot anchor synthetic clock")
        return value
    }
    private static func info(pts: Double, dts: Double?, duration: Double) -> CMSampleTimingInfo {
        CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600),
            decodeTimeStamp: dts.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid)
    }
    private static func sample(timing: [CMSampleTimingInfo], count: Int) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        try expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 16, height: 16, extensions: ["PosleSyntheticFormat": "unchanged"] as CFDictionary, formatDescriptionOut: &format) == noErr,
                   "Cannot create synthetic media format")
        var block: CMBlockBuffer?
        try expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count,
            flags: 0, blockBufferOut: &block) == noErr, "Cannot create synthetic sample content")
        guard let block else { throw AppError.message("Synthetic sample data missing") }
        let content = (0..<count).map { UInt8($0 % 251) }
        try content.withUnsafeBytes {
            try expect(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) == noErr,
                       "Cannot fill synthetic sample content")
        }
        var size = 1
        var result: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer {
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: count, sampleTimingEntryCount: timing.count, sampleTimingArray: $0.baseAddress,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result)
        }
        guard status == noErr, let result else { throw AppError.message("Cannot create synthetic timed buffer: \(status)") }
        return result
    }
    private static func bytes(_ sample: CMSampleBuffer) throws -> [UInt8] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw AppError.message("Retimed sample content missing") }
        var result = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        let status = result.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        try expect(status == noErr, "Cannot read synthetic sample bytes")
        return result
    }
    private static func close(_ time: CMTime, _ expected: Double, _ message: String) throws {
        try expect(time.isNumeric && time.seconds.isFinite && abs(time.seconds - expected) < 0.000001, message + ": \(time.seconds)")
    }
    private static func rejects(_ operation: () throws -> CMSampleBuffer) throws {
        do { _ = try operation() }
        catch { return }
        throw AppError.message("Invalid clock/sample timing was accepted")
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw AppError.message(message) }
    }
}
#endif
