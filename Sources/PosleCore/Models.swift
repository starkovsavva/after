import Foundation

public struct Meeting: Codable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var createdAt: Double
    public var source: String
    public var status: String
    public var duration: Double
    public var speakerNames: [String: String]
    public var completedTasks: [String]
    public var focus: String
    public var recordingTracks: Bool = false
    public var hasVideo: Bool = false
    public var error: String?

    public init(title: String, source: String, status: String = "imported", focus: String = "") {
        id = UUID().uuidString.lowercased()
        self.title = title; self.source = source; self.status = status
        self.focus = focus; createdAt = Date().timeIntervalSince1970
        duration = 0; speakerNames = [:]; completedTasks = []
    }

    public func speakerName(_ key: String) -> String {
        if let name = speakerNames[key], !name.isEmpty { return name }
        if key == "unknown" { return "Голос не определён" }
        return "Участник \(key.replacingOccurrences(of: "speaker_", with: ""))"
    }
}

public struct Segment: Codable, Identifiable, Hashable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public var overlap: Bool
    public init(id: Int, start: Double, end: Double, speaker: String, text: String, overlap: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.speaker = speaker
        self.text = text; self.overlap = overlap
    }
}

public struct Transcript: Codable {
    public var duration: Double
    public var segments: [Segment]
    public var warnings: [String]
    public var model: String
}

public struct Insight: Codable, Identifiable, Hashable {
    public var kind: String
    public var text: String
    public var owner: String
    public var due: String
    public var segmentIDs: [Int]
    public var id: String { "\(kind)-\(segmentIDs.map(String.init).joined(separator: "-"))-\(text)" }
}

public struct Flashcard: Codable, Identifiable, Hashable {
    public var id: String
    public var kind: String
    public var front: String
    public var back: String
    public var context: String
    public var segmentIDs: [Int]
}

public struct Summary: Codable {
    public var overview: String
    public var items: [Insight]
    public var cards: [Flashcard]
    public var provider: String
    public var model: String
    public var generatedAt: Double
    public var warnings: [String]
}

public struct CardExample: Codable {
    public var example: String
    public var translation: String
    public var explanation: String
}

public struct ReviewState: Codable {
    public var due: String
    public var count: Int
    public var lastRating: Int
    public var isDue: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: due) ?? ISO8601DateFormatter().date(from: due)
        return (date ?? .distantPast) <= Date()
    }
}

public struct AppSettings: Codable {
    public static let qualityLocalModel = "qwen3.5:9b-q4_K_M"
    public static let fastLocalModel = "qwen3.5:4b-q4_K_M"
    public var mode = "local"
    public var localModel = AppSettings.qualityLocalModel
    public var localProvider = "managed"
    public var localEndpoint = ""
    public var asrModelPath = ""
    public var asrModelFormat = "auto"
    public var cloudModel = "gpt-4.1-mini"
    public var language = "ru"
    public var diarization = true
    public var speakerCount = 0
    public var autoSummary = true
    public var focus = "Решения, задачи, ответственные, сроки, точные цифры, требования и риски. Полезные английские фразы и важные понятия для запоминания."
    public init() {}

    public var resolvedLocalEndpoint: String {
        let endpoint = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty { return endpoint }
        return localProvider == "lmstudio" ? "http://127.0.0.1:1234" : "http://127.0.0.1:11434"
    }

    private enum CodingKeys: String, CodingKey {
        case mode, localModel, localProvider, localEndpoint, asrModelPath, asrModelFormat
        case cloudModel, language, diarization, speakerCount, autoSummary, focus
    }

    // Defaults are applied per field, so adding settings never resets an existing setup.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? mode
        localModel = try values.decodeIfPresent(String.self, forKey: .localModel) ?? localModel
        localProvider = try values.decodeIfPresent(String.self, forKey: .localProvider) ?? localProvider
        localEndpoint = try values.decodeIfPresent(String.self, forKey: .localEndpoint) ?? localEndpoint
        asrModelPath = try values.decodeIfPresent(String.self, forKey: .asrModelPath) ?? asrModelPath
        asrModelFormat = try values.decodeIfPresent(String.self, forKey: .asrModelFormat) ?? asrModelFormat
        cloudModel = try values.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        diarization = try values.decodeIfPresent(Bool.self, forKey: .diarization) ?? diarization
        speakerCount = try values.decodeIfPresent(Int.self, forKey: .speakerCount) ?? speakerCount
        autoSummary = try values.decodeIfPresent(Bool.self, forKey: .autoSummary) ?? autoSummary
        focus = try values.decodeIfPresent(String.self, forKey: .focus) ?? focus
    }
}

public enum Exporter {
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    public static func markdown(meeting: Meeting, transcript: Transcript?, summary: Summary?) -> String {
        var text = "# \(meeting.title)\n\n"
        if let summary {
            text += "## Конспект\n\n\(summary.overview)\n\n"
            let groups = [("decision", "Решения"), ("action", "Задачи"), ("detail", "Важные детали"), ("question", "Открытые вопросы")]
            for (kind, title) in groups {
                let items = summary.items.filter { $0.kind == kind }
                guard !items.isEmpty else { continue }
                text += "## \(title)\n\n"
                for item in items {
                    let refs = item.segmentIDs.compactMap { id in transcript?.segments.first { $0.id == id } }
                        .map { timestamp($0.start) }.joined(separator: ", ")
                    text += "- \(item.text)"
                    if !item.owner.isEmpty { text += " · \(item.owner)" }
                    if !item.due.isEmpty { text += " · \(item.due)" }
                    if !refs.isEmpty { text += " [\(refs)]" }
                    text += "\n"
                }
                text += "\n"
            }
        }
        if let transcript {
            text += "## Транскрипция\n\n"
            for s in transcript.segments {
                text += "**\(timestamp(s.start)) · \(meeting.speakerName(s.speaker))**\n\(s.text)\n\n"
            }
        }
        return text
    }

    /// Anki's text importer interprets <br> when html:true. Escape content before exporting.
    public static func anki(cards: [Flashcard], title: String) -> String {
        func html(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        let header = "#separator:Tab\n#html:true\n#columns:Front\tBack\tTags\n"
        return header + cards.map { card in
            "\(html(card.front))\t\(html(card.back))<br><br>\(html(card.context))<br><small>\(html(title))</small>\tposle \(card.kind)"
        }.joined(separator: "\n") + "\n"
    }
}
