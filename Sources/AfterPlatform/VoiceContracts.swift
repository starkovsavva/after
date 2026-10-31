import Foundation
import AfterCore

package struct VoiceTarget: Codable, Hashable {
    package var kind: String
    package var id: String
    package var meetingID: String?
    package var source: KnowledgeSource? = nil

    package init(kind: String, id: String, meetingID: String? = nil, source: KnowledgeSource? = nil) {
        self.kind = kind
        self.id = id
        self.meetingID = meetingID
        self.source = source
    }
}
package struct VoiceCandidate: Codable, Identifiable {
    package var id: String
    package var title: String
    package var detail: String
    package var reason: String? = nil
    package var completed: Bool? = nil
    package var selected: Bool? = nil

    package init(id: String, title: String, detail: String, reason: String? = nil, completed: Bool? = nil, selected: Bool? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.reason = reason
        self.completed = completed
        self.selected = selected
    }
}
package struct VoicePlan: Codable {
    package var status: String
    package var planID: String?
    package var operationID: String?
    package var title: String
    package var detail: String
    package var target: VoiceTarget?
    package var candidates: [VoiceCandidate]?
    package var action: String? = nil
    package var reviewRequired: Bool? = nil
    package var selectionMode: String? = nil
    package var text: String? = nil
    package var knowledgeAnswer: KnowledgeAnswer? = nil
    package var query: String? = nil

    package init(status: String, planID: String? = nil, operationID: String? = nil, title: String, detail: String, target: VoiceTarget? = nil, candidates: [VoiceCandidate]? = nil, action: String? = nil, reviewRequired: Bool? = nil, selectionMode: String? = nil, text: String? = nil, knowledgeAnswer: KnowledgeAnswer? = nil, query: String? = nil) {
        self.status = status
        self.planID = planID
        self.operationID = operationID
        self.title = title
        self.detail = detail
        self.target = target
        self.candidates = candidates
        self.action = action
        self.reviewRequired = reviewRequired
        self.selectionMode = selectionMode
        self.text = text
        self.knowledgeAnswer = knowledgeAnswer
        self.query = query
    }
}
package struct VoiceResult: Codable {
    package var operationID: String
    package var title: String
    package var detail: String
    package var target: VoiceTarget
    package var canUndo: Bool
    package var undone: Bool? = nil

    package init(operationID: String, title: String, detail: String, target: VoiceTarget, canUndo: Bool, undone: Bool? = nil) {
        self.operationID = operationID
        self.title = title
        self.detail = detail
        self.target = target
        self.canUndo = canUndo
        self.undone = undone
    }
}
