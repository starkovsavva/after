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
        print("PASS: timestamps")

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
        print("5 Swift checks passed")
    }
}
