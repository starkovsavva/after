import CoreMedia
import Foundation

/// Capture sources can use different clocks even when their timestamps look
/// like uptime. Rewrite real sample timing before the shared writer sees it.
enum CaptureSampleClock {
    static func hostTimed(_ buffer: CMSampleBuffer, clock: CMClock) throws -> CMSampleBuffer {
        try convert(buffer, from: clock, to: CMClockGetHostTimeClock())
    }

    /// Timebases make the same production conversion testable with independent
    /// origins/rates, without opening capture devices or changing the host clock.
    static func convert(_ buffer: CMSampleBuffer, from source: CMClockOrTimebase,
                        to destination: CMClockOrTimebase) throws -> CMSampleBuffer {
        guard CMSampleBufferIsValid(buffer), CMSampleBufferGetNumSamples(buffer) > 0 else { throw timingError }
        let rate = CMSyncGetRelativeRate(source, relativeTo: destination)
        guard rate.isFinite, rate > 0 else { throw timingError }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil,
            entriesNeededOut: &count) == noErr,
              count > 0, count <= 16_384,
              count == 1 || count == CMSampleBufferGetNumSamples(buffer) else { throw timingError }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let readStatus = timing.withUnsafeMutableBufferPointer {
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: $0.baseAddress,
                                                  entriesNeededOut: nil)
        }
        guard readStatus == noErr else { throw timingError }
        for index in timing.indices {
            let original = timing[index]
            let pts = try converted(original.presentationTimeStamp, from: source, to: destination)
            timing[index].presentationTimeStamp = pts
            // Raw PCM and uncompressed frames normally have no decode timestamp.
            if original.decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = try converted(original.decodeTimeStamp, from: source, to: destination)
            }
            if original.duration.isValid {
                guard numeric(original.duration), CMTimeCompare(original.duration, .zero) >= 0 else { throw timingError }
                let end = try converted(CMTimeAdd(original.presentationTimeStamp, original.duration), from: source, to: destination)
                let duration = CMTimeSubtract(end, pts)
                guard numeric(duration), CMTimeCompare(duration, .zero) >= 0 else { throw timingError }
                timing[index].duration = duration
            }
        }
        var result: CMSampleBuffer?
        let copyStatus = timing.withUnsafeBufferPointer {
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                sampleTimingEntryCount: count, sampleTimingArray: $0.baseAddress, sampleBufferOut: &result)
        }
        guard copyStatus == noErr, let result else { throw timingError }
        // CoreMedia's shallow copy propagates only propagatable attachments.
        // Clock conversion must also retain source metadata in the other mode.
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                target: buffer, attachmentMode: mode) {
                CMSetAttachments(result, attachments: attachments, attachmentMode: mode)
            }
        }
        return result
    }

    private static func converted(_ time: CMTime, from source: CMClockOrTimebase,
                                  to destination: CMClockOrTimebase) throws -> CMTime {
        guard numeric(time) else { throw timingError }
        let result = CMSyncConvertTime(time, from: source, to: destination)
        guard numeric(result) else { throw timingError }
        return result
    }

    private static func numeric(_ time: CMTime) -> Bool {
        time.isValid && time.isNumeric && time.timescale > 0 && time.seconds.isFinite
    }

    private static var timingError: AppError { .message(L("Не удалось синхронизировать дорожки записи.")) }
}
