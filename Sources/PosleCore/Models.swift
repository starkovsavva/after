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
    public var libraryKind: String? = nil

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

public struct OverviewClaim: Codable, Hashable {
    public var text: String
    public var itemIndices: [Int]
    public init(text: String, itemIndices: [Int]) { self.text = text; self.itemIndices = itemIndices }
}

public struct Summary: Codable {
    public var overview: String
    public var items: [Insight]
    public var cards: [Flashcard]
    public var provider: String
    public var model: String
    public var generatedAt: Double
    public var warnings: [String]
    public var overviewClaims: [OverviewClaim] = []

    public init(overview: String, items: [Insight], cards: [Flashcard], provider: String, model: String,
                generatedAt: Double, warnings: [String], overviewClaims: [OverviewClaim] = []) {
        self.overview = overview; self.items = items; self.cards = cards; self.provider = provider
        self.model = model; self.generatedAt = generatedAt; self.warnings = warnings; self.overviewClaims = overviewClaims
    }
    private enum CodingKeys: String, CodingKey {
        case overview, items, cards, provider, model, generatedAt, warnings, overviewClaims
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        overview = try values.decode(String.self, forKey: .overview)
        items = try values.decode([Insight].self, forKey: .items)
        cards = try values.decode([Flashcard].self, forKey: .cards)
        provider = try values.decode(String.self, forKey: .provider)
        model = try values.decode(String.self, forKey: .model)
        generatedAt = try values.decode(Double.self, forKey: .generatedAt)
        warnings = try values.decode([String].self, forKey: .warnings)
        overviewClaims = try values.decodeIfPresent([OverviewClaim].self, forKey: .overviewClaims) ?? []
    }

    /// Never attach citations to edited or inconsistent prose, or to missing facts/segments.
    public func hasVerifiedOverviewClaims(transcript: Transcript?) -> Bool {
        guard !overviewClaims.isEmpty, let transcript else { return false }
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard normalized(overviewClaims.map(\.text).joined(separator: " ")) == normalized(overview) else { return false }
        let ids = Set(transcript.segments.map(\.id))
        return overviewClaims.allSatisfy { claim in
            !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !claim.itemIndices.isEmpty &&
            claim.itemIndices.allSatisfy { index in
                items.indices.contains(index) && !items[index].segmentIDs.isEmpty && items[index].segmentIDs.allSatisfy(ids.contains)
            }
        }
    }
}

public struct SearchHit: Decodable, Identifiable, Hashable {
    public var id: String
    public var meetingID: String
    public var meetingTitle: String
    public var createdAt: Double
    public var kind: String
    public var text: String
    public var snippet: String
    public var segmentIDs: [Int]
    public var itemIndex: Int?
    public var cardID: String?
    public var start: Double?
    public var sourceFingerprint: String
    public var noteID: String? = nil
    public var noteRevision: Int? = nil
}

public struct SearchResponse: Decodable {
    public var hits: [SearchHit]
    public var total: Int
    public var truncated: Bool
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

public struct CloudProfile: Codable, Equatable {
    public var endpoint: String
    public var model: String
    public var api: String
    public var output: String
    public init(endpoint: String = "", model: String, api: String = "chat", output: String = "schema") {
        self.endpoint = endpoint; self.model = model; self.api = api; self.output = output
    }
}

public struct AppSettings: Codable {
    public static let qualityLocalModel = "qwen3.5:9b-q4_K_M"
    public static let fastLocalModel = "qwen3.5:4b-q4_K_M"
    public var startSection = "meetings"
    public var recordSystemAudio = true
    public var recordVideo = false
    public var quickCaptureEnabled = true
    public var bookmarkShortcutEnabled = true
    public var quickCaptureShortcut = "controlOptionN"
    public var notesAutoTimestamp = true
    public var notesSaveToActiveMeeting = true
    public var defaultTemplateID = ""
    public var mode = "local"
    public var localModel = AppSettings.qualityLocalModel
    public var localProvider = "managed"
    public var localEndpoint = ""
    public var asrModelPath = ""
    public var asrModelFormat = "auto"
    public var speechMode = "local"
    public var speechLocalModel = "parakeet-v3"
    public var speechCloudProvider = "openai"
    public var speechCloudEndpoint = ""
    public var speechCloudModel = "gpt-transcribe"
    public var speechResponseFormat = "json"
    public var speechLanguage = "auto"
    public var cloudModel = "gpt-4.1-mini"
    public var cloudProvider = "openai"
    public var cloudEndpoint = ""
    public var cloudAPI = "responses"
    public var cloudOutput = "schema"
    public var cloudProfiles: [String: CloudProfile] = [:]
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

    public var cloudProviderTitle: String {
        switch cloudProvider {
        case "openrouter": return "OpenRouter"
        case "polza": return "Polza"
        case "custom": return "Свой провайдер"
        default: return "OpenAI"
        }
    }

    public var resolvedCloudEndpoint: String {
        switch cloudProvider {
        case "openai": return "https://api.openai.com/v1"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "polza": return "https://polza.ai/api/v1"
        case "custom": return cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return ""
        }
    }

    /// Same address rules as the Rust client. Keys are scoped to this exact base
    /// URL; a half-edited or invalid address must not reuse a different host's key.
    public func validatedCloudEndpoint() -> URL? {
        let raw = resolvedCloudEndpoint
        guard var components = URLComponents(string: raw),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              let scheme = components.scheme?.lowercased() else { return nil }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (cloudProvider == "custom" && scheme == "http" && local) else { return nil }
        components.scheme = scheme
        components.host = host == "localhost" ? "127.0.0.1" : host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url, url.host != nil else { return nil }
        return url
    }

    public mutating func switchCloudProvider(_ provider: String) {
        guard ["openai", "openrouter", "polza", "custom"].contains(provider), provider != cloudProvider else { return }
        cloudProfiles[cloudProvider] = CloudProfile(endpoint: cloudEndpoint, model: cloudModel, api: cloudAPI, output: cloudOutput)
        cloudProvider = provider
        let defaults: CloudProfile
        switch provider {
        case "openai": defaults = CloudProfile(model: "gpt-4.1-mini", api: "responses")
        case "openrouter", "polza": defaults = CloudProfile(model: "openai/gpt-4.1-mini")
        default: defaults = CloudProfile(model: "")
        }
        let profile = cloudProfiles[provider] ?? defaults
        cloudEndpoint = profile.endpoint; cloudModel = profile.model
        cloudAPI = profile.api; cloudOutput = profile.output
    }

    private enum CodingKeys: String, CodingKey {
        case startSection, recordSystemAudio, recordVideo, quickCaptureEnabled, bookmarkShortcutEnabled, quickCaptureShortcut, notesAutoTimestamp, notesSaveToActiveMeeting, defaultTemplateID
        case mode, localModel, localProvider, localEndpoint, asrModelPath, asrModelFormat
        case speechMode, speechLocalModel, speechCloudProvider, speechCloudEndpoint, speechCloudModel, speechResponseFormat, speechLanguage
        case cloudModel, cloudProvider, cloudEndpoint, cloudAPI, cloudOutput, cloudProfiles, language, diarization, speakerCount, autoSummary, focus
    }

    // Defaults are applied per field, so adding settings never resets an existing setup.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startSection = try values.decodeIfPresent(String.self, forKey: .startSection) ?? startSection
        recordSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .recordSystemAudio) ?? recordSystemAudio
        recordVideo = try values.decodeIfPresent(Bool.self, forKey: .recordVideo) ?? recordVideo
        quickCaptureEnabled = try values.decodeIfPresent(Bool.self, forKey: .quickCaptureEnabled) ?? quickCaptureEnabled
        bookmarkShortcutEnabled = try values.decodeIfPresent(Bool.self, forKey: .bookmarkShortcutEnabled) ?? bookmarkShortcutEnabled
        quickCaptureShortcut = try values.decodeIfPresent(String.self, forKey: .quickCaptureShortcut) ?? quickCaptureShortcut
        notesAutoTimestamp = try values.decodeIfPresent(Bool.self, forKey: .notesAutoTimestamp) ?? notesAutoTimestamp
        notesSaveToActiveMeeting = try values.decodeIfPresent(Bool.self, forKey: .notesSaveToActiveMeeting) ?? notesSaveToActiveMeeting
        defaultTemplateID = try values.decodeIfPresent(String.self, forKey: .defaultTemplateID) ?? defaultTemplateID
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? mode
        localModel = try values.decodeIfPresent(String.self, forKey: .localModel) ?? localModel
        localProvider = try values.decodeIfPresent(String.self, forKey: .localProvider) ?? localProvider
        localEndpoint = try values.decodeIfPresent(String.self, forKey: .localEndpoint) ?? localEndpoint
        asrModelPath = try values.decodeIfPresent(String.self, forKey: .asrModelPath) ?? asrModelPath
        asrModelFormat = try values.decodeIfPresent(String.self, forKey: .asrModelFormat) ?? asrModelFormat
        speechMode = try values.decodeIfPresent(String.self, forKey: .speechMode) ?? speechMode
        speechLocalModel = try values.decodeIfPresent(String.self, forKey: .speechLocalModel) ?? speechLocalModel
        speechCloudProvider = try values.decodeIfPresent(String.self, forKey: .speechCloudProvider) ?? speechCloudProvider
        speechCloudEndpoint = try values.decodeIfPresent(String.self, forKey: .speechCloudEndpoint) ?? speechCloudEndpoint
        speechCloudModel = try values.decodeIfPresent(String.self, forKey: .speechCloudModel) ?? speechCloudModel
        speechResponseFormat = try values.decodeIfPresent(String.self, forKey: .speechResponseFormat) ?? speechResponseFormat
        speechLanguage = try values.decodeIfPresent(String.self, forKey: .speechLanguage) ?? speechLanguage
        cloudModel = try values.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        cloudProvider = try values.decodeIfPresent(String.self, forKey: .cloudProvider) ?? cloudProvider
        cloudEndpoint = try values.decodeIfPresent(String.self, forKey: .cloudEndpoint) ?? cloudEndpoint
        cloudAPI = try values.decodeIfPresent(String.self, forKey: .cloudAPI) ?? cloudAPI
        cloudOutput = try values.decodeIfPresent(String.self, forKey: .cloudOutput) ?? cloudOutput
        cloudProfiles = try values.decodeIfPresent([String: CloudProfile].self, forKey: .cloudProfiles) ?? cloudProfiles
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
