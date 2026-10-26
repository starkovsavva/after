import Foundation

// A small executable test harness: runs on Apple's Command Line Tools without full Xcode.
@main
struct CoreChecks {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        precondition(value(), "Line \(line): \(message)")
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
        meeting.completedTasks = ["commitment-1"]; meeting.recordingTracks = true; meeting.hasVideo = true
        let copy = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        expect(copy == meeting, "metadata round trip")
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
        settings.localProvider = "lmstudio"; settings.localModel = "local/qwen"
        settings.asrModelPath = "/tmp/parakeet"; settings.asrModelFormat = "onnx"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        expect(restored.localProvider == "lmstudio" && restored.localModel == "local/qwen", "external model selection round trip")
        expect(restored.resolvedLocalEndpoint == "http://127.0.0.1:1234", "LM Studio default endpoint")
        expect(restored.asrModelPath == "/tmp/parakeet" && restored.asrModelFormat == "onnx", "ASR selection round trip")
        expect(!restored.autoSummary && restored.focus == "Keep precise details", "unrelated settings preserved")
        let minimal = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        expect(minimal.localModel == AppSettings.qualityLocalModel && minimal.diarization, "minimal settings defaults")
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
        print("8 Swift checks passed")
    }
}
