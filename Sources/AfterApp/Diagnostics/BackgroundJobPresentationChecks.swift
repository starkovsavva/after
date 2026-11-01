#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import Foundation
import AfterCore

/// Pure display contracts: no coordinator, UI, models or production library.
enum BackgroundJobPresentationChecks {
    static func run() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "BackgroundJobPresentation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func job(_ id: String, kind: String = "summarize", object: String = "meeting", state: String,
                 time: Double, created: Double? = nil, attempt: Int = 1, extra: [String] = [], input: Data? = nil,
                 model: String = "gpt-6-luna") -> BackgroundJob {
            var settings = AppSettings(); settings.mode = "cloud"; settings.cloudModel = model
            let config = JobConfiguration(command: kind, meetingID: object, extra: extra, input: input, settings: settings)
            return BackgroundJob(id: id, kind: kind, objectID: object, inputRevision: id, dependencies: [], config: config,
                resource: "cloud", state: state, progress: 0, message: state, title: "Конспект · Урок английского", attempt: attempt,
                paid: true, cancelRequested: false, createdAt: created ?? time, updatedAt: time)
        }
        let old = job("old", state: "failed", time: 1, model: "gpt-4.1-mini")
        let success = job("success", state: "succeeded", time: 2)
        try expect(!BackgroundJobPresentation.needsAttention(in: [old, success]), "A successful new summary must resolve an older version/model's failure badge")
        try expect(BackgroundJobPresentation.latestIDs(in: [old, success]) == [success.id], "Historical duplicate rows must not both offer Retry")
        try expect(BackgroundJobPresentation.metadata(old, historical: true).contains("Ранее") && BackgroundJobPresentation.metadata(old, historical: true).contains("gpt-4.1-mini"), "History must retain its actual saved model and a past-attempt label")
        let newFailure = job("new-failure", state: "failed", time: 3)
        try expect(BackgroundJobPresentation.needsAttention(in: [success, newFailure]), "A new failure cannot be hidden by an earlier success")
        let explicitRetry = job("old", state: "interrupted", time: 4, created: 1, attempt: 2)
        try expect(BackgroundJobPresentation.latestIDs(in: [success, explicitRetry]) == [success.id], "A late old-generation failure/retry cannot revive its badge after a newer generation succeeded")
        let currentRetry = job("success", state: "interrupted", time: 5, created: 2, attempt: 2)
        try expect(BackgroundJobPresentation.latestIDs(in: [old, currentRetry]) == [currentRetry.id], "Retrying the latest generation must preserve its current identity")
        let crowded = (0..<40).map { job("success-\($0)", object: "other-\($0)", state: "succeeded", time: Double(100 + $0)) }
        try expect(BackgroundJobPresentation.ordered(crowded + [newFailure]).prefix(30).contains { $0.id == newFailure.id }, "An unresolved failure must remain reachable when the popover limits history to 30 rows")
        let cardA = job("card-a", kind: "example", state: "failed", time: 1, extra: ["--card", "a"])
        let cardB = job("card-b", kind: "example", state: "succeeded", time: 2, extra: ["--card", "b"])
        try expect(BackgroundJobPresentation.needsAttention(in: [cardA, cardB]) && BackgroundJobPresentation.latestIDs(in: [cardA, cardB]).count == 2, "One card's successful example must not suppress another card's failure")
        let fixedCardA = job("fixed-a", kind: "example", state: "succeeded", time: 3, extra: ["--card", "a"])
        try expect(!BackgroundJobPresentation.needsAttention(in: [cardA, cardB, fixedCardA]), "The matching card's later success should resolve its own failure")
        let noteA = job("note-a", kind: "expand-notes", object: "app:expand-notes", state: "failed", time: 1, extra: ["--note", "a"])
        let noteB = job("note-b", kind: "expand-notes", object: "app:expand-notes", state: "succeeded", time: 2, extra: ["--note", "b"])
        try expect(BackgroundJobPresentation.needsAttention(in: [noteA, noteB]), "Different note expansions must remain independent")
        let voiceA = job("voice-a", kind: "voice-plan", object: "app:voice-plan", state: "failed", time: 1, input: Data("first request".utf8))
        let voiceB = job("voice-b", kind: "voice-plan", object: "app:voice-plan", state: "succeeded", time: 2, input: Data("other request".utf8))
        try expect(BackgroundJobPresentation.needsAttention(in: [voiceA, voiceB]), "Different dictated requests cannot acknowledge each other")
        var reopened = job("voice-reopened", kind: "voice-plan", object: "app:voice-plan", state: "succeeded", time: 3, input: Data("first request with fresh clock".utf8))
        reopened.config.restartOfJobID = voiceA.id
        try expect(!BackgroundJobPresentation.needsAttention(in: [voiceA, voiceB, reopened]), "Explicit fresh success must acknowledge only the reopened failure despite its new input timestamp")
        reopened.state = "failed"
        try expect(BackgroundJobPresentation.latestIDs(in: [voiceA, voiceB, reopened]) == [voiceB.id, reopened.id], "A failed fresh operation must show its current error without reviving the old error")
        let unrelated = job("voice-unrelated", kind: "voice-plan", object: "app:voice-plan", state: "failed", time: 4, input: Data("third request".utf8))
        try expect(BackgroundJobPresentation.latestIDs(in: [voiceA, reopened, unrelated]).contains(unrelated.id), "An explicit restart must not hide another command's unresolved failure")
        var malformedLink = reopened; malformedLink.objectID = "another-object"
        try expect(BackgroundJobPresentation.latestIDs(in: [voiceA, malformedLink]).contains(voiceA.id), "A restart link cannot suppress a different object scope")
        print("PASS: explicit fresh voice operations preserve history, replace only their linked error and leave unrelated failures visible")
        let malformed = job("unknown-card", kind: "example", state: "failed", time: 1)
        try expect(BackgroundJobPresentation.needsAttention(in: [malformed, cardB]), "A missing target must not silently merge with another operation")
        try expect(BackgroundJobPresentation.latestIDs(in: [cardA, noteA, old]).count == 3, "Operation kinds and target scopes cannot collapse")
        print("PASS: history preserves records while latest retry/error state follows the same meeting/card/note/request target")
    }
}
#endif
