import Foundation

package struct RecordingDisplay: Identifiable, Equatable, Sendable {
    package let id: UInt32
    package let title: String
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let isMain: Bool
    package let persistentID: String

    package init(id: UInt32, title: String, pixelWidth: Int, pixelHeight: Int, isMain: Bool,
         persistentID: String? = nil) {
        self.id = id; self.title = title; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.isMain = isMain
        self.persistentID = persistentID ?? "synthetic:\(id)"
    }
}
