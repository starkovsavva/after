import AfterLocalization
import AfterPlatform
import AVFoundation

/// Detaches frames from ScreenCaptureKit's small IOSurface pool before the
/// asynchronous encoder or the static-screen tail can retain them. All access
/// belongs to CaptureSink.queue; a slow encoder may drop frames, never grow
/// this pool without a bound or hold up the screen capture pool.
final class CaptureVideoFrameCopier {
    private struct Layout: Equatable {
        let width: Int
        let height: Int
        let format: OSType
    }
    private var layout: Layout?
    private var pool: CVPixelBufferPool?
    private let allocationLimit: CFDictionary = [
        kCVPixelBufferPoolAllocationThresholdKey as String: 8
    ] as CFDictionary

    func copy(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { throw copyingError }
        let current = Layout(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source),
                             format: CVPixelBufferGetPixelFormatType(source))
        if let layout {
            guard layout == current else { throw copyingError }
        } else {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: current.width,
                kCVPixelBufferHeightKey as String: current.height,
                kCVPixelBufferPixelFormatTypeKey as String: current.format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var next: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &next)
                    == kCVReturnSuccess, let next else { throw copyingError }
            pool = next; layout = current
        }
        guard let pool else { throw copyingError }
        var image: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                                                                        allocationLimit, &image)
        // Preserve the previous owned frame for a static tail if the encoder
        // currently holds every slot. Never retain the original as a fallback.
        if result == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard result == kCVReturnSuccess, let image else { throw copyingError }
        try copyPixels(source, to: image)
        // This also preserves color primaries, transfer function and matrix.
        CVBufferRemoveAllAttachments(image)
        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            if let attachments = CVBufferCopyAttachments(source, mode) {
                CVBufferSetAttachments(image, attachments, mode)
            }
        }
        // The owned surface can have a different row stride. Reusing the source
        // description would make an otherwise valid image fail CoreMedia checks.
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format) == noErr, let format else { throw copyingError }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else {
            throw copyingError
        }
        var owned: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &owned) == noErr,
              let owned else { throw copyingError }
        return owned
    }

    private func copyPixels(_ source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw copyingError }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { throw copyingError }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planes = CVPixelBufferGetPlaneCount(source)
        guard planes == CVPixelBufferGetPlaneCount(destination) else { throw copyingError }
        if planes == 0 {
            try copyRows(from: CVPixelBufferGetBaseAddress(source), stride: CVPixelBufferGetBytesPerRow(source),
                to: CVPixelBufferGetBaseAddress(destination), stride: CVPixelBufferGetBytesPerRow(destination),
                height: CVPixelBufferGetHeight(source))
        } else {
            for plane in 0..<planes {
                try copyRows(from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                    stride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    to: CVPixelBufferGetBaseAddressOfPlane(destination, plane),
                    stride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                    height: CVPixelBufferGetHeightOfPlane(source, plane))
            }
        }
    }

    private func copyRows(from source: UnsafeMutableRawPointer?, stride sourceStride: Int,
                          to destination: UnsafeMutableRawPointer?, stride destinationStride: Int,
                          height: Int) throws {
        guard let source, let destination, sourceStride > 0, destinationStride > 0, height > 0 else {
            throw copyingError
        }
        for row in 0..<height {
            memcpy(destination.advanced(by: row * destinationStride), source.advanced(by: row * sourceStride),
                   min(sourceStride, destinationStride))
        }
    }

    private var copyingError: AppError {
        .message(L("Не удалось подготовить видеокадр. Исходная запись со звуком сохранена."))
    }
}
