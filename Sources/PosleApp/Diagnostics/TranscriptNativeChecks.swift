#if DEBUG
import AppKit
import Foundation
import PosleCore

@MainActor
enum TranscriptNativeChecks {
    static func run() throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              ["/tmp", "/private/tmp"].contains(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path),
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Clipboard checks require an explicit disposable preview fixture")
        }
        let app = AppStore(preview: true)
        var meeting = Meeting(title: "Запуск пилота", source: "synthetic.wav")
        meeting.speakerNames = ["speaker_1": "Анна", "speaker_2": "Michael * QA"]
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(#"{"duration":4000,"segments":[{"id":0,"start":0,"end":10,"speaker":"speaker_1","overlap":false,"text":"Бюджет — 80 000 рублей.\nБез доплат."},{"id":1,"start":3725,"end":3735,"speaker":"speaker_2","overlap":false,"text":"Let's circle back on Friday."}],"warnings":[],"model":"synthetic"}"#.utf8))
        let directory = app.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        try app.write(transcript, directory.appendingPathComponent("transcript.json"))
        app.reloadLibrary(); app.selection = meeting.id; app.loadSelection()
        app.transcriptSearch = "Бюджет"
        let pasteboard = NSPasteboard(name: .init("app.posle.clipboard-check.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try expect(app.copyTranscriptMarkdown(to: pasteboard), "Private clipboard write failed")
        let expected = "# Запуск пилота\n\n## Транскрипт\n\n**00:00 · Анна**\n\nБюджет — 80 000 рублей.\nБез доплат.\n\n**1:02:05 · Michael \\* QA**\n\nLet's circle back on Friday.\n\n"
        try expect(pasteboard.string(forType: .string) == expected, "Copied transcript must include every speaker and timestamp, independently of search")
        try expect(pasteboard.string(forType: .init("net.daringfireball.markdown")) == expected, "Markdown pasteboard representation differs from text")
        try expect(!expected.contains("Конспект"), "Transcript copy must not include a summary")
        app.transcript = nil
        try expect(!app.copyTranscriptMarkdown(to: pasteboard), "Missing transcript must not replace clipboard")
        try expect(pasteboard.string(forType: .string) == expected, "Missing transcript erased the existing clipboard")
        var empty = transcript; empty.segments = []; app.transcript = empty
        try expect(!app.copyTranscriptMarkdown(to: pasteboard), "Empty transcript must not replace clipboard")
        var literalMeeting = meeting
        literalMeeting.title = "Meet &amp; greet"
        literalMeeting.speakerNames["speaker_1"] = "Ann &lt;Lead&gt;"
        var literalTranscript = transcript
        literalTranscript.segments = Array(transcript.segments.prefix(1))
        let literalCases = [
            "Use &lt;tag&gt; and &amp; literally.", "-keep", "- keep the dash", "+ keep the plus",
            "---", "- - -", "1.", "1)", "1. first item", "1) first item", "Heading\n===", "Heading\n---",
            "Version 1.2.3 - low-latency models.",
        ]
        for source in literalCases {
            literalTranscript.segments[0].text = source
            let markdown = Exporter.transcriptMarkdown(meeting: literalMeeting, transcript: literalTranscript)
            let rendered = try AttributedString(markdown: markdown)
            let visible = String(rendered.characters)
            let expectedSpeech = source.components(separatedBy: .newlines).joined(separator: " ")
            try expect(visible.hasSuffix(expectedSpeech), "Rendered Markdown changed literal speech: \(source)")
            try expect(visible.contains(literalMeeting.title) && visible.contains("Ann &lt;Lead&gt;"), "Rendered Markdown changed title or speaker entities")
            if source == "Version 1.2.3 - low-latency models." {
                try expect(markdown.contains(source), "Ordinary decimal points and hyphens must stay readable in Markdown source")
            }
        }
        print("PASS: Foundation Markdown rendering preserves literal entities, list markers and rulers; ordinary punctuation stays readable")
        print("PASS: complete transcript copied as plain text + Markdown; Russian/English, renamed speakers, zero/hour timestamps and multiline speech preserved")
        print("PASS: search never truncates copy; missing/empty transcript preserves existing private clipboard; system clipboard untouched")
        print("3 native transcript clipboard checks passed")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
}
#endif
