import Foundation

public struct SpeechModelPreset: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let downloadBytes: Int64
    public let detail: String
    public let sourceURL: URL
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file) }
    public static let catalog: [SpeechModelPreset] = [
        .init(id: "parakeet-v3", name: "Parakeet v3", downloadBytes: 2_508_532_829,
              detail: "Русский и английский · 25 языков", sourceURL: URL(string: "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3")!),
        .init(id: "whisper-turbo", name: "Whisper Large v3 Turbo", downloadBytes: 1_613_977_880,
              detail: "Русский и английский · многоязычная", sourceURL: URL(string: "https://huggingface.co/mlx-community/whisper-large-v3-turbo")!),
        .init(id: "whisper-small", name: "Whisper Small", downloadBytes: 481_307_858,
              detail: "Меньше загрузка · русский и английский", sourceURL: URL(string: "https://huggingface.co/mlx-community/whisper-small-mlx")!)
    ]
}

public extension AppSettings {
    var resolvedSpeechEndpoint: String {
        speechCloudProvider == "openai" ? "https://api.openai.com/v1" : speechCloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Credentials are scoped to the exact destination, independently from text AI.
    var speechKeyAccount: String {
        "speech:" + speechCloudProvider + ":" + resolvedSpeechEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    var speechDestinationLabel: String {
        URL(string: resolvedSpeechEndpoint)?.host ?? "выбранный сервер"
    }
}
