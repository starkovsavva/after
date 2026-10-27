import Foundation
#if SWIFT_PACKAGE
import XCTest
@testable import PosleCore
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct CoreChecks {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        #if SWIFT_PACKAGE
        XCTAssertTrue(value(), message, line: line)
        #else
        precondition(value(), "Line \(line): \(message)")
        #endif
    }
    static func main() throws {
        expect(Exporter.timestamp(-2) == "00:00", "negative timestamp")
        expect(Exporter.timestamp(65.8) == "01:05", "minute timestamp")
        expect(Exporter.timestamp(3725) == "1:02:05", "hour timestamp")
        for invalid in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude, Double(Int.max)] {
            expect(Exporter.timestamp(invalid) == "00:00", "invalid timestamp cannot trap")
        }
        expect(Exporter.timestamp(3_600_000_000_000) == "1000000000:00:00", "large valid hour value keeps full precision")
        let malformedTiming = try JSONDecoder().decode(Transcript.self, from: Data(#"{"duration":1e100,"segments":[{"id":0,"start":1e100,"end":1e100,"speaker":"speaker_1","text":"Повреждённое время","overlap":false}],"warnings":[],"model":"fixture"}"#.utf8))
        expect(Exporter.timestamp(malformedTiming.segments[0].start) == "00:00", "oversized JSON timestamp cannot crash rendering")
        print("PASS: timestamps, oversized JSON values and non-finite input")

        var meeting = Meeting(title: "Встреча / Meeting", source: "source.mov")
        meeting.speakerNames["speaker_1"] = "Аня"
        meeting.generateCards = true
        meeting.meetingPurpose = "Синк с руководителем о прогрессе"
        meeting.completedTasks = ["commitment-1"]; meeting.recordingTracks = true; meeting.hasVideo = true
        meeting.recordingAudioQuality = "high"; meeting.recordingVideoQuality = "native"; meeting.recordingDisplayUUID = "display-fixture"
        let copy = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        expect(copy == meeting, "metadata round trip")
        var legacyMeetingObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as! [String: Any]
        for key in ["recordingAudioQuality", "recordingVideoQuality", "recordingDisplayUUID", "meetingPurpose"] { legacyMeetingObject.removeValue(forKey: key) }
        let legacyMeeting = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: legacyMeetingObject))
        expect(legacyMeeting.recordingAudioQuality == nil && legacyMeeting.recordingVideoQuality == nil && legacyMeeting.recordingDisplayUUID == nil, "old recordings do not fabricate quality or monitor metadata")
        expect(legacyMeeting.meetingPurpose == nil && copy.meetingPurpose == meeting.meetingPurpose, "meeting purpose remains optional on legacy metadata and persists when specified")
        expect(copy.speakerName("speaker_1") == "Аня", "speaker rename")
        expect(copy.speakerName("speaker_2") == "Участник 2", "speaker fallback")
        expect(copy.speakerName("unknown") == "Голос не определён", "unknown speaker")
        print("PASS: metadata, recording options and speaker names")

        let transcript = Transcript(duration: 100, segments: [Segment(id: 7, start: 65, end: 71, speaker: "speaker_1", text: "Send 25 units by Friday.")], warnings: [], model: "test")
        let summary = Summary(overview: "Обсудили поставку.", items: [Insight(kind: "action", text: "Отправить 25 штук", owner: "Аня", due: "в пятницу", segmentIDs: [7])], cards: [], provider: "local", model: "test", generatedAt: 0, warnings: [])
        let text = Exporter.markdown(meeting: meeting, transcript: transcript, summary: summary)
        expect(text.contains("Отправить 25 штук · Аня · в пятницу [01:05]"), "sourced deadline")
        expect(text.contains("01:05 · Аня"), "renamed speaker export")
        print("PASS: sourced Markdown export")

        let card = Flashcard(id: "1", kind: "phrase", front: "<script>\tphrase", back: "Line1\nLine2 & more", context: "A\tB", segmentIDs: [0])
        let tsv = Exporter.anki(cards: [card], title: "Sync")
        expect(tsv.contains("#html:true"), "Anki HTML directive")
        expect(tsv.contains("&lt;script&gt;"), "escaped card HTML")
        expect(tsv.contains("Line1<br>Line2 &amp; more"), "multiline card")
        let rows = tsv.split(separator: "\n").filter { !$0.hasPrefix("#") }
        expect(rows.count == 1, "one card row")
        expect(rows[0].split(separator: "\t").count == 3, "three Anki columns")
        print("PASS: Anki TSV export and escaping")

        let old = ReviewState(due: "2020-01-01T00:00:00.123+00:00", count: 2, lastRating: 3)
        let future = ReviewState(due: "2090-01-01T00:00:00.123+00:00", count: 2, lastRating: 3)
        expect(old.isDue, "past review date")
        expect(!future.isDue, "future FSRS date")
        print("PASS: FSRS date compatibility")
        let legacySettings = Data(#"{"mode":"cloud","localModel":"qwen:old","cloudModel":"custom-cloud","language":"en","diarization":false,"speakerCount":3,"autoSummary":false,"focus":"Keep precise details"}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: legacySettings)
        expect(settings.mode == "cloud" && settings.localModel == "qwen:old", "old provider and model retained")
        expect(settings.cloudModel == "custom-cloud" && settings.language == "en", "old cloud and language retained")
        expect(!settings.diarization && settings.speakerCount == 3 && !settings.autoSummary, "old processing options retained")
        expect(settings.focus == "Keep precise details", "old focus retained")
        expect(settings.localProvider == "managed" && settings.asrModelPath.isEmpty, "new settings default without reset")
        expect(settings.summaryUserContext.isEmpty, "legacy settings do not invent a personal profile")
        settings.summaryUserContext = "Я стажёр в команде разработки"
        settings.localProvider = "lmstudio"; settings.localModel = "local/qwen"
        settings.asrModelPath = "/tmp/parakeet"; settings.asrModelFormat = "onnx"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        expect(restored.summaryUserContext == settings.summaryUserContext, "explicit summary context persists independently of provider")
        expect(restored.localProvider == "lmstudio" && restored.localModel == "local/qwen", "external model selection round trip")
        expect(restored.resolvedLocalEndpoint == "http://127.0.0.1:1234", "LM Studio default endpoint")
        expect(restored.asrModelPath == "/tmp/parakeet" && restored.asrModelFormat == "onnx", "ASR selection round trip")
        expect(!restored.autoSummary && restored.focus == "Keep precise details", "unrelated settings preserved")
        let minimal = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        expect(minimal.localModel == AppSettings.qualityLocalModel && minimal.diarization, "minimal settings defaults")
        expect(minimal.recordAudioQuality == .standard && minimal.recordVideoQuality == .compact && minimal.recordDisplayUUID.isEmpty, "new recording defaults migrate independently")
        settings.recordAudioQuality = .high; settings.recordVideoQuality = .native; settings.recordDisplayUUID = "stable-display-uuid"
        let recordingSettings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        expect(recordingSettings.recordAudioQuality == .high && recordingSettings.recordVideoQuality == .native && recordingSettings.recordDisplayUUID == "stable-display-uuid", "recording profiles and stable monitor selection survive reopen")
        let futureSettings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"recordAudioQuality":"future-profile","recordVideoQuality":"8k","localModel":"keep-model","focus":"Keep details"}"#.utf8))
        expect(futureSettings.recordAudioQuality == .standard && futureSettings.recordVideoQuality == .compact && futureSettings.localModel == "keep-model" && futureSettings.focus == "Keep details", "unknown future profiles fall back without resetting unrelated settings")
        expect(minimal.features == AppFeatures() && settings.features == AppFeatures(), "base-only defaults also apply to legacy settings")
        let partialFeatures = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"features":{"cards":true},"localModel":"keep-model"}"#.utf8))
        expect(partialFeatures.features.cards && !partialFeatures.features.assistant && !partialFeatures.features.tasks, "partial opt-in never enables unrelated features")
        var chosenFeatures = partialFeatures
        chosenFeatures.features.tasks = true
        let featureCopy = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(chosenFeatures))
        expect(featureCopy.features == chosenFeatures.features && featureCopy.localModel == "keep-model", "feature choices round trip without changing models")
        expect(!minimal.allowsSection("cards") && !minimal.allowsSection("contexts") && minimal.allowsSection("inbox"), "section policy keeps notes and hides optional projects")
        expect(copy.generateCards == true && legacyMeeting.generateCards == true, "explicit per-meeting cards opt-in survives metadata changes")
        legacyMeetingObject.removeValue(forKey: "generateCards")
        let minimalMeeting = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: legacyMeetingObject))
        expect(minimalMeeting.generateCards == nil, "old meeting has no implicit card opt-in")
        print("PASS: settings migration and external model selection")
        var linked = summary
        linked.overviewClaims = [OverviewClaim(text: "Обсудили поставку.", itemIndices: [0])]
        expect(linked.hasVerifiedOverviewClaims(transcript: transcript), "linked overview resolves a real fact and source")
        let currentSummary = try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(linked))
        expect(currentSummary.overviewClaims == linked.overviewClaims, "claim links persist")
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(linked)) as! [String: Any]
        legacyObject.removeValue(forKey: "overviewClaims")
        let legacySummary = try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        expect(legacySummary.overviewClaims.isEmpty && legacySummary.items == linked.items, "old summaries preserve facts with no fabricated claim links")
        linked.overview = "Ручная правка."
        expect(!linked.hasVerifiedOverviewClaims(transcript: transcript), "edited prose cannot borrow old claim links")
        linked.overview = summary.overview; linked.overviewClaims[0].itemIndices = [17]
        expect(!linked.hasVerifiedOverviewClaims(transcript: transcript), "out of range fact links rejected")
        linked.overviewClaims[0].itemIndices = [0]; linked.items[0].segmentIDs = [99]
        expect(!linked.hasVerifiedOverviewClaims(transcript: transcript), "missing source link rejected")
        linked.items[0].segmentIDs = []
        expect(!linked.hasVerifiedOverviewClaims(transcript: transcript), "uncited fact cannot support claim")
        expect(!summary.hasVerifiedOverviewClaims(transcript: nil), "no transcript does not fabricate evidence")
        print("PASS: legacy summaries, linked claims and stale source safety")
        var cloud = try JSONDecoder().decode(AppSettings.self, from: legacySettings)
        expect(cloud.cloudProvider == "openai" && cloud.cloudAPI == "responses" && cloud.cloudModel == "custom-cloud", "Legacy cloud settings keep OpenAI and model")
        cloud.switchCloudProvider("openrouter"); cloud.cloudModel = "vendor/model"
        cloud.switchCloudProvider("custom"); cloud.cloudEndpoint = "https://example.com/gateway/v1"; cloud.cloudModel = "my-model"; cloud.cloudOutput = "json"
        cloud.switchCloudProvider("openrouter"); expect(cloud.cloudModel == "vendor/model", "Provider models stay independent")
        cloud.switchCloudProvider("custom"); expect(cloud.cloudModel == "my-model" && cloud.cloudOutput == "json" && cloud.resolvedCloudEndpoint.contains("gateway"), "Custom connection restores endpoint and output mode")
        let providerCopy = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(cloud))
        expect(providerCopy.cloudProvider == "custom" && providerCopy.cloudAPI == "chat", "Cloud protocol settings roundtrip with exact acronym")
        expect(providerCopy.speechMode == "local" && providerCopy.speechLocalModel == "parakeet-v3", "Speech model defaults migrate without an implicit cloud upload")
        cloud.cloudEndpoint = "https://user:password@example.com/v1"; expect(cloud.validatedCloudEndpoint() == nil, "URL credentials are refused")
        cloud.cloudEndpoint = "http://example.com/v1"; expect(cloud.validatedCloudEndpoint() == nil, "Remote plaintext HTTP is refused")
        print("PASS: cloud provider migration, independent profiles, exact API format and endpoint validation")
        expect(cloud.cloudReasoning == "none" && cloud.chatGPTAccountID.isEmpty, "Legacy settings never connect a subscription or enable reasoning implicitly")
        let apiProfile = cloud.cloudModel
        cloud.switchCloudProvider("chatgpt")
        expect(cloud.cloudModel.isEmpty && cloud.cloudAPI == "responses", "Subscription model must come from the signed-in account catalog")
        cloud.cloudEndpoint = "https://other-provider.invalid/v1"
        expect(cloud.resolvedCloudEndpoint == "https://api.openai.com/v1", "Subscription credentials cannot be redirected to a custom endpoint")
        cloud.chatGPTAccountID = "synthetic-account"; cloud.cloudModel = "catalog-model"; cloud.cloudReasoning = "low"
        let subscription = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(cloud))
        expect(subscription.chatGPTAccountID == "synthetic-account" && subscription.cloudReasoning == "low", "Queued subscription settings keep non-secret account identity and chosen reasoning")
        cloud.switchCloudProvider("custom")
        expect(cloud.cloudModel == apiProfile, "Switching to subscription preserves the independent API profile")
        cloud.switchCloudProvider("chatgpt")
        expect(cloud.cloudModel == "catalog-model" && cloud.cloudProviderTitle == "ChatGPT", "Returning to subscription restores the selected catalog model")
        expect(cloud.validatedCloudEndpoint()?.host == "api.openai.com", "Subscription uses the fixed public OpenAI endpoint")
        print("PASS: subscription migration, account-pinned snapshots, fixed endpoint and independent provider profiles")
        let compact = RecordingVideoQuality.compact.dimensions(width: 1440, height: 900, scale: 2)
        expect(compact == RecordingVideoDimensions(width: 1152, height: 720), "Retina 16:10 stays full-display 16:10 at 720p")
        let clear = RecordingVideoQuality.clear.dimensions(width: 1440, height: 900, scale: 2)
        expect(clear == RecordingVideoDimensions(width: 1728, height: 1080), "1080p preserves the whole 16:10 display")
        expect(RecordingVideoQuality.native.dimensions(width: 1728, height: 1117, scale: 2)
            == RecordingVideoDimensions(width: 3456, height: 2234), "native uses backing pixels instead of Retina points")
        expect(RecordingVideoQuality.compact.dimensions(width: 900, height: 1440, scale: 2)
            == RecordingVideoDimensions(width: 720, height: 1152), "portrait displays keep orientation and aspect")
        expect(RecordingVideoQuality.compact.dimensions(width: 3440, height: 1440)
            == RecordingVideoDimensions(width: 1280, height: 534), "ultrawide display fits without center crop")
        expect(RecordingVideoQuality.clear.dimensions(width: 640, height: 480)
            == RecordingVideoDimensions(width: 640, height: 480), "small displays are not upscaled")
        expect(RecordingVideoQuality.native.dimensions(width: 1513, height: 983)
            == RecordingVideoDimensions(width: 1512, height: 982), "odd source sizes round down to H.264 even output bounds")
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1, Double.greatestFiniteMagnitude] {
            expect(RecordingVideoQuality.native.dimensions(width: invalid, height: 900) == nil, "invalid display width is rejected")
            expect(RecordingVideoQuality.native.dimensions(width: 1440, height: 900, scale: invalid) == nil, "invalid pixel scale is rejected")
        }
        expect(RecordingDisplaySelection.resolve(requested: 2, available: [1, 2], main: 1) == 2, "explicit selected monitor wins over main")
        expect(RecordingDisplaySelection.resolve(requested: 9, available: [1, 2], main: 1) == nil, "disconnected monitor never silently switches")
        expect(RecordingDisplaySelection.resolve(requested: nil, available: [1, 2], main: 2) == 2, "default captures current main display")
        expect(RecordingDisplaySelection.resolve(requested: nil, available: [2], main: 1) == nil, "missing main never selects an unrelated monitor")
        expect(RecordingAudioQuality.allCases.map(\.bitRate) == [64_000, 128_000, 192_000], "audio quality controls source encoding bitrate")
        expect(RecordingVideoQuality.compact.bitRate(for: compact!) < RecordingVideoQuality.clear.bitRate(for: clear!), "higher resolution has enough encoding bitrate")
        expect(RecordingVideoQuality.native.bitRate(for: .init(width: Int.max, height: Int.max)) == 40_000_000, "bitrate arithmetic cannot overflow")
        let qualityCopy = try JSONDecoder().decode(RecordingVideoQuality.self, from: JSONEncoder().encode(RecordingVideoQuality.native))
        expect(qualityCopy == .native && RecordingVideoQuality.allCases.allSatisfy { $0.frameRate == 30 }, "quality persists and every preset keeps 30 fps")
        print("PASS: full-display recording profiles, Retina geometry, aspect ratio, audio bitrates and disconnected-display safety")
        print("10 Swift checks passed")
    }
}

#if SWIFT_PACKAGE
final class CoreChecksTests: XCTestCase {
    func testContracts() throws { try CoreChecks.main() }
}
#endif
