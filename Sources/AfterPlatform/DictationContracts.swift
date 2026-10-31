import Foundation

package struct DictationResult: Decodable, Sendable {
    package var text: String
    package var duration: Double
    package var model: String
    package var pid: Int
    package var warnings: [String]
    package var segments: [DictationSegment]

    package init(text: String, duration: Double, model: String, pid: Int, warnings: [String], segments: [DictationSegment]) {
        self.text = text
        self.duration = duration
        self.model = model
        self.pid = pid
        self.warnings = warnings
        self.segments = segments
    }
}

package struct DictationSegment: Decodable, Sendable {
    package var id: Int
    package var start: Double
    package var end: Double
    package var text: String

    package init(id: Int, start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}
