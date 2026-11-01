import Foundation

public struct RecordingVideoDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// Resolution limits apply to the complete display and never crop it to 16:9.
public enum RecordingVideoQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, clear, native
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .compact: return "Компактное · до 720p"
        case .clear: return "Чёткое · до 1080p"
        case .native: return "Разрешение экрана"
        }
    }
    public var detail: String {
        switch self {
        case .compact: return "Небольшой файл для просмотра встречи."
        case .clear: return "Лучше виден текст и содержимое экрана."
        case .native: return "Максимальная детализация, большой файл."
        }
    }
    public var frameRate: Int { 30 }

    /// Width/height are screen points; the filter's pointPixelScale supplies Retina density.
    /// H.264 requires even dimensions. The encoder fits the full source into these bounds.
    public func dimensions(width: Double, height: Double, scale: Double = 1) -> RecordingVideoDimensions? {
        guard width.isFinite, height.isFinite, scale.isFinite,
              width > 0, height > 0, scale > 0 else { return nil }
        let pixelWidth = width * scale, pixelHeight = height * scale
        // Also bounds integer conversion and bitrate arithmetic for corrupt display metadata.
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth >= 2, pixelHeight >= 2,
              pixelWidth <= 65536, pixelHeight <= 65536 else { return nil }
        let factor: Double
        switch self {
        case .native: factor = 1
        case .compact, .clear:
            let shortEdge = self == .compact ? 720.0 : 1080.0
            let longEdge = self == .compact ? 1280.0 : 1920.0
            factor = min(shortEdge / min(pixelWidth, pixelHeight), longEdge / max(pixelWidth, pixelHeight), 1)
        }
        let outputWidth = max(2, Int((pixelWidth * factor).rounded(.down)) / 2 * 2)
        let outputHeight = max(2, Int((pixelHeight * factor).rounded(.down)) / 2 * 2)
        return RecordingVideoDimensions(width: outputWidth, height: outputHeight)
    }

    public func bitRate(for dimensions: RecordingVideoDimensions) -> Int {
        let area = Double(dimensions.width) * Double(dimensions.height)
        guard area.isFinite, area > 0 else { return 1_000_000 }
        let bitsPerPixel: Double
        switch self {
        case .compact: bitsPerPixel = 0.075
        case .clear: bitsPerPixel = 0.09
        case .native: bitsPerPixel = 0.1
        }
        return Int(min(40_000_000, max(1_000_000, area * Double(frameRate) * bitsPerPixel)))
    }
}

public enum RecordingAudioQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, standard, high
    public var id: String { rawValue }
    public var bitRate: Int {
        switch self {
        case .compact: return 64_000
        case .standard: return 128_000
        case .high: return 192_000
        }
    }
    public var title: String {
        switch self {
        case .compact: return "Компактное · 64 кбит/с"
        case .standard: return "Обычное · 128 кбит/с"
        case .high: return "Высокое · 192 кбит/с"
        }
    }
}

/// Never silently capture another monitor after the user-selected display disconnects.
public enum RecordingDisplaySelection {
    public static func resolve(requested: UInt32?, available: [UInt32], main: UInt32) -> UInt32? {
        let selected = requested ?? main
        return available.contains(selected) ? selected : nil
    }
}
