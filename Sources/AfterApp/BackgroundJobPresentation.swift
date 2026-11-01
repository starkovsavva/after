import AfterLocalization
import CryptoKit
import Foundation
import AfterCore

/// History stays durable. Only the latest attempt for the same operation can
/// raise an unresolved-error badge or offer a retry in the history popover.
/// Configuration/model changes intentionally do not create a new target, while
/// distinct cards, notes and dictated requests must remain independent.
enum BackgroundJobPresentation {
    private struct Operation: Hashable {
        let kind: String
        let objectID: String
        let target: Target
    }
    private enum Target: Hashable {
        case meeting
        case card(String)
        case note(String)
        case input(Data)
        case isolated(String)
    }
    static func latestIDs(in jobs: [BackgroundJob]) -> Set<String> {
        var latest: [Operation: BackgroundJob] = [:]
        for job in jobs {
            let key = operation(job)
            if let previous = latest[key], !moreRecent(job, than: previous) { continue }
            latest[key] = job
        }
        var current = Set(latest.values.map(\.id))
        let indexed = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for job in jobs {
            guard let id = job.config.restartOfJobID, let previous = indexed[id],
                  job.kind == "voice-plan", previous.kind == job.kind,
                  previous.objectID == job.objectID, previous.createdAt < job.createdAt else { continue }
            current.remove(id)
        }
        return current
    }
    static func needsAttention(in jobs: [BackgroundJob]) -> Bool {
        let latest = latestIDs(in: jobs)
        return jobs.contains { latest.contains($0.id) && ["failed", "interrupted"].contains($0.state) }
    }
    static func ordered(_ jobs: [BackgroundJob]) -> [BackgroundJob] {
        let latest = latestIDs(in: jobs)
        func priority(_ job: BackgroundJob) -> Int {
            if job.active { return 0 }
            if latest.contains(job.id) { return ["failed", "interrupted"].contains(job.state) ? 1 : 2 }
            return 3
        }
        return jobs.sorted { left, right in
            if priority(left) != priority(right) { return priority(left) < priority(right) }
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            return left.id > right.id
        }
    }
    /// Only generated operation labels are translated. Meeting titles remain verbatim.
    static func title(_ job: BackgroundJob) -> String {
        let labels = ["Распознавание", "Собеседники", "Подготовка MP3", "Конспект", "Пример к карточке", "Голосовое поручение", "Диктовка поручения", "Дополнение заметки"]
        for label in labels where job.title == label || job.title.hasPrefix(label + " · ") {
            return L(label) + job.title.dropFirst(label.count)
        }
        return job.title
    }
    static func metadata(_ job: BackgroundJob, historical: Bool) -> String {
        let time = Date(timeIntervalSince1970: job.createdAt)
            .formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UILocale()))
        var parts = historical ? [L("Ранее"), time] : [time]
        if job.attempt > 0 { parts.append(LF("Попытка {0}", arguments: [String(describing: job.attempt)])) }
        let settings = job.config.settings
        let model: String
        switch job.kind {
        case "transcribe", "dictate":
            model = settings.speechMode == "cloud" ? settings.speechCloudModel : settings.speechLocalModel
        case "summarize", "example", "expand-notes", "voice-plan":
            model = settings.mode == "cloud" ? settings.cloudModel : settings.localModel
        default: model = ""
        }
        if !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " · ")
    }
    private static func operation(_ job: BackgroundJob) -> Operation {
        let target: Target
        switch job.kind {
        case "transcribe", "diarize", "finalize", "summarize": target = .meeting
        case "example": target = argument("--card", in: job.config.extra).map(Target.card) ?? .isolated(job.id)
        case "expand-notes": target = argument("--note", in: job.config.extra).map(Target.note) ?? .isolated(job.id)
        case "voice-plan":
            target = job.config.input.map { .input(Data(SHA256.hash(data: $0))) } ?? .isolated(job.id)
        default: target = .isolated(job.id)
        }
        return Operation(kind: job.kind, objectID: job.objectID, target: target)
    }
    private static func argument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              !arguments[index + 1].isEmpty else { return nil }
        return arguments[index + 1]
    }
    private static func moreRecent(_ left: BackgroundJob, than right: BackgroundJob) -> Bool {
        // A late failure/progress event from an older generation cannot make
        // that generation current again after a newer input has been submitted.
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        if left.attempt != right.attempt { return left.attempt > right.attempt }
        return left.id > right.id
    }
}
