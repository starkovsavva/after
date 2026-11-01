import Foundation
import AfterCore

package enum AppError: LocalizedError {
    case message(String)
    package var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

package struct InstalledLocalModel: Decodable, Identifiable, Hashable {
    package var id: String
    package var name: String
    package var provider: String
    package var endpoint: String

    package init(id: String, name: String, provider: String, endpoint: String) {
        self.id = id
        self.name = name
        self.provider = provider
        self.endpoint = endpoint
    }
}

package struct InstalledASRModel: Decodable, Identifiable, Hashable {
    package var id: String
    package var name: String
    package var path: String
    package var format: String
    package var source: String
    package var compatible: Bool
    package var reason: String

    package init(id: String, name: String, path: String, format: String, source: String, compatible: Bool, reason: String) {
        self.id = id
        self.name = name
        self.path = path
        self.format = format
        self.source = source
        self.compatible = compatible
        self.reason = reason
    }
}

package struct InstalledGGUFModel: Decodable, Identifiable, Hashable {
    package var id: String
    package var name: String
    package var path: String
    package var source: String
    package var sizeBytes: Int64
    package var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    package init(id: String, name: String, path: String, source: String, sizeBytes: Int64) {
        self.id = id
        self.name = name
        self.path = path
        self.source = source
        self.sizeBytes = sizeBytes
    }
}

package struct WorkerFailure: LocalizedError {
    package let message: String
    package let chatGPTDiagnostics: ChatGPTDiagnostics?
    package var errorDescription: String? { message }

    package init(message: String, chatGPTDiagnostics: ChatGPTDiagnostics? = nil) {
        self.message = message
        self.chatGPTDiagnostics = chatGPTDiagnostics
    }
}

package struct WorkerEvent: Decodable {
    package var event: String
    package var message: String?
    package var fraction: Double?
    package var models: [String]?
    package var model: String?
    package var ggufModels: [InstalledGGUFModel]?
    package var installedModels: [InstalledLocalModel]?
    package var asrModels: [InstalledASRModel]?
    package var notes: [String]?
    package var knowledgeRebuild: KnowledgeRebuildPreview?
    package var voicePlan: VoicePlan?
    package var dictation: DictationResult?
    package var chatGPTDiagnostics: ChatGPTDiagnostics?

    package init(event: String, message: String? = nil) {
        self.event = event; self.message = message
    }

    private enum CodingKeys: String, CodingKey { case event, message, fraction, models, model, ggufModels, asrModels, notes, voicePlan, dictation, chatGPTDiagnostics, knowledgeRebuild }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(String.self, forKey: .event)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        fraction = try values.decodeIfPresent(Double.self, forKey: .fraction)
        models = try? values.decode([String].self, forKey: .models)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        ggufModels = try values.decodeIfPresent([InstalledGGUFModel].self, forKey: .ggufModels)
        installedModels = try? values.decode([InstalledLocalModel].self, forKey: .models)
        asrModels = try values.decodeIfPresent([InstalledASRModel].self, forKey: .asrModels)
        notes = try values.decodeIfPresent([String].self, forKey: .notes)
        knowledgeRebuild = try values.decodeIfPresent(KnowledgeRebuildPreview.self, forKey: .knowledgeRebuild)
        voicePlan = try values.decodeIfPresent(VoicePlan.self, forKey: .voicePlan)
        dictation = try values.decodeIfPresent(DictationResult.self, forKey: .dictation)
        chatGPTDiagnostics = try? values.decodeIfPresent(ChatGPTDiagnostics.self, forKey: .chatGPTDiagnostics)
    }
}
