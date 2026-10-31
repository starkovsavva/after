import Foundation
#if SWIFT_PACKAGE
import XCTest
@testable import PosleCore
#endif
#if !SWIFT_PACKAGE
@main
#endif
struct AssistantReadChecks {
    static func main() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-11-01T03:30:00Z")!
        let scope = AssistantReadPlan.Scope(folderID: "work", projectID: "alpha")
        let today = AssistantReadPlan.parse("Покажи задачи на сегодня", scope: scope,
                                            now: beforeMidnight, timeZone: ny)!
        precondition(today.selector.type == .dueRange)
        precondition(today.selector.startDate == "2026-10-31" && today.selector.endDateExclusive == "2026-11-01")
        precondition(today.scope.folderID == "work" && today.scope.projectID == "alpha")
        let latest = AssistantReadPlan.parse("Открой последнюю задачу", scope: scope)!
        precondition(latest.intent == .open && latest.selector.type == .latestCreated)
        let search = AssistantReadPlan.parse("Find task PILOT", scope: .init(projectID: ""))!
        precondition(search.selector.query == "pilot" && search.scope.projectID == "")
        let inspect = AssistantReadPlan.parse("Что в последней таске?", scope: scope)!
        precondition(inspect.intent == .inspect && inspect.selector.type == .latestCreated)
        precondition(AssistantReadPlan.parse("Что агент сделал в последней задаче?", scope: scope)?.intent == .inspect)
        precondition(AssistantReadPlan.parse("Что решить в последней задаче?", scope: scope) == nil)
        precondition(AssistantReadPlan.parse("Открой задачу на завтра", scope: scope) == nil)
        precondition(AssistantReadPlan.parseFollowUp("Открой её!") == .only)
        precondition(AssistantReadPlan.parseFollowUp("Покажи вторую") == .index(1))
        precondition(AssistantReadPlan.parseFollowUp("Вторую") == .index(1))
        precondition(AssistantReadPlan.parseFollowUp("Open third") == .index(2))
        precondition(AssistantReadPlan.parseFollowUp("Удали её") == nil)
        precondition(AssistantNoteQuery.parse("Найди заметку про пилот?")?.query == "пилот")
        precondition(AssistantNoteQuery.parse("Open a note about launch")?.open == true)
        precondition(AssistantNoteQuery.parse("Удали заметку про пилот") == nil)
        let decoded = try JSONDecoder().decode(AssistantReadPlan.self, from: JSONEncoder().encode(today))
        precondition(decoded == today)
        let ref = SourceRef(libraryID: UUID().uuidString, kind: .note, objectID: "Note_42")
        precondition(ref.isValid)
        precondition(!SourceRef(libraryID: ref.libraryID, kind: .note, objectID: "../secret").isValid)
        let refRoundtrip = try JSONDecoder().decode(SourceRef.self, from: JSONEncoder().encode(ref))
        precondition(refRoundtrip == ref)
        let unknown = #"{"libraryID":"00000000-0000-0000-0000-000000000001","kind":"newKind","objectID":"x"}"#
        precondition((try? JSONDecoder().decode(SourceRef.self, from: Data(unknown.utf8))) == nil)
        print("PASS: local commands, scoped dates, safe fallback and typed source identities")
    }
}
#if SWIFT_PACKAGE
final class AssistantReadTests: XCTestCase {
    func testReadPlans() throws { try AssistantReadChecks.main() }
}
#endif
