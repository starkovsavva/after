import Foundation
import PosleCore
import SwiftUI

struct LibraryCardEntry: Decodable, Identifiable {
    let meeting: Meeting
    let card: Flashcard
    let review: ReviewState?
    let example: CardExample?
    let fingerprint: String
    let reviewFingerprint: String
    let suspended: Bool
    let exampleIsStale: Bool
    let sourceStale: Bool
    var id: String { meeting.id + ":" + card.id }
    var isDue: Bool { !suspended && (review?.isDue ?? true) }
}
private struct CardLibraryResponse: Decodable { let entries: [LibraryCardEntry]; let errors: [String] }
struct CardReviewOption: Decodable { let rating: Int; let due: String; let intervalSeconds: Int
    var title: String {
        if intervalSeconds < 60 { return "\(max(1, intervalSeconds)) с" }
        if intervalSeconds < 3600 {
            let remainder = intervalSeconds % 60
            return "\(intervalSeconds / 60) мин" + (remainder == 0 ? "" : " \(remainder) с")
        }
        if intervalSeconds < 86400 { return "\(intervalSeconds / 3600) ч" }
        return "\(intervalSeconds / 86400) дн."
    }
}
private struct CardReviewOptions: Decodable { let options: [CardReviewOption] }
private struct CardReviewReceipt: Decodable { let undoID: String; let meetingID: String; let cardID: String }
struct CardSaveResult: Decodable { let meeting: Meeting; let card: Flashcard }

@MainActor
final class CardsWorkspace: ObservableObject {
    @Published private(set) var entries: [LibraryCardEntry] = []
    @Published private(set) var errors: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var options: [Int: String] = [:]
    @Published var message: String?
    @Published var error: String?
    @Published private var lastReview: CardReviewReceipt?
    var canUndo: Bool { lastReview != nil }
    private var generation = UUID()
    private var optionGeneration = UUID()
    func reload(root: URL, meetingID: String?) async {
        let token = UUID(); generation = token; loading = true
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                var arguments: [String: Any] = [:]
                if let meetingID { arguments["meetingID"] = meetingID }
                let data = try RustBridge.shared.get().request(root: root, command: "cards-library", arguments: arguments)
                return try JSONDecoder().decode(CardLibraryResponse.self, from: data)
            }.value
            guard generation == token else { return }
            entries = loaded.entries; errors = loaded.errors; error = nil; loading = false
        } catch {
            guard generation == token else { return }
            // Previously loaded entries remain usable when a refresh fails.
            self.error = error.localizedDescription; loading = false
        }
    }
    func preview(root: URL, entry: LibraryCardEntry?) async {
        let token = UUID(); optionGeneration = token; options = [:]
        guard let entry, !entry.suspended else { return }
        do {
            let loaded = try await Task.detached(priority: .utility) {
                let data = try RustBridge.shared.get().request(root: root, command: "cards-review-preview", arguments: Self.arguments(entry))
                return try JSONDecoder().decode(CardReviewOptions.self, from: data)
            }.value
            guard optionGeneration == token else { return }
            options = Dictionary(uniqueKeysWithValues: loaded.options.map { ($0.rating, $0.title) })
        } catch {
            guard optionGeneration == token else { return }
            self.error = error.localizedDescription
        }
    }
    func rate(root: URL, entry: LibraryCardEntry, rating: Int, meetingID: String?) async {
        guard !saving, !entry.suspended else { return }; saving = true
        defer { saving = false }
        do {
            let receipt = try await Task.detached(priority: .userInitiated) {
                var args = Self.arguments(entry); args["rating"] = rating
                let data = try RustBridge.shared.get().request(root: root, command: "cards-review", arguments: args)
                return try JSONDecoder().decode(CardReviewReceipt.self, from: data)
            }.value
            lastReview = receipt; message = "Ответ сохранён"; error = nil
            await reload(root: root, meetingID: meetingID)
        } catch { self.error = error.localizedDescription }
    }
    func undo(root: URL, meetingID: String?) async {
        guard let receipt = lastReview, !saving else { return }; saving = true
        defer { saving = false }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try RustBridge.shared.get().request(root: root, command: "cards-review-undo", arguments: ["meetingID": receipt.meetingID, "undoID": receipt.undoID])
            }.value
            lastReview = nil; message = "Последняя оценка отменена"; error = nil
            await reload(root: root, meetingID: meetingID)
        } catch { self.error = error.localizedDescription }
    }
    func mutate(root: URL, entry: LibraryCardEntry, delete: Bool, meetingID: String?) async {
        guard !saving else { return }; saving = true
        defer { saving = false }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                var args = Self.arguments(entry); args["suspended"] = !entry.suspended
                return try RustBridge.shared.get().request(root: root, command: delete ? "card-delete" : "card-suspend", arguments: args)
            }.value
            message = delete ? "Карточка удалена" : entry.suspended ? "Карточка вернулась в повторение" : "Карточка исключена из повторения"
            error = nil
            await reload(root: root, meetingID: meetingID)
        } catch { self.error = error.localizedDescription }
    }
    nonisolated static func arguments(_ entry: LibraryCardEntry) -> [String: Any] {
        ["meetingID": entry.meeting.id, "cardID": entry.card.id, "expectedFingerprint": entry.fingerprint, "expectedReviewFingerprint": entry.reviewFingerprint]
    }
}
