import Foundation
import PosleCore

enum ReleaseChangeKind: String, CaseIterable, Sendable {
    case added, changed, fixed
}

struct ReleaseChange: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ReleaseChangeKind
    let textKey: String
}

struct ReleaseFeatureUpdate: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let icon: String
    let requiredFeature: AppFeature?
    let settingsSection: String
    let isNewFeature: Bool
    let changes: [ReleaseChange]
}

enum ReleaseFeatureGroup: String, CaseIterable, Identifiable, Sendable {
    case new, used, other, disabled
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .new: "Новые возможности"
        case .used: "Вы используете"
        case .other: "Другие изменения"
        case .disabled: "Пока не включены"
        }
    }
}

struct ReleaseFeatureSection: Identifiable, Equatable, Sendable {
    let group: ReleaseFeatureGroup
    let updates: [ReleaseFeatureUpdate]
    var id: ReleaseFeatureGroup { group }
}

/// Numeric public versions only. A legacy guide label never proves an exact
/// previous application version; the controller keeps that distinction.
struct ReleaseVersion: Comparable, Sendable {
    let components: [Int]
    init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(pieces.count), value.utf8.count <= 24,
              pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              pieces.allSatisfy({ $0.count <= 4 }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count else { return nil }
        components = numbers + Array(repeating: 0, count: 4 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

enum ReleaseNotesCatalog {
    private struct Entry {
        let version: String
        let updates: [ReleaseFeatureUpdate]
    }
    private static func update(_ id: String, _ title: String, _ icon: String, _ settings: String,
                               feature: AppFeature? = nil, new: Bool = false,
                               _ changes: [(String, ReleaseChangeKind, String)]) -> ReleaseFeatureUpdate {
        ReleaseFeatureUpdate(id: id, titleKey: title, icon: icon, requiredFeature: feature, settingsSection: settings,
                             isNewFeature: new, changes: changes.map { ReleaseChange(id: $0.0, kind: $0.1, textKey: $0.2) })
    }
    // Historical entries follow docs/releases exactly; current notes describe
    // the fixes included in this build, without inferring unavailable telemetry.
    private static let entries: [Entry] = [
        Entry(version: "0.17.6.2", updates: [
            update("summary", "Конспект", "text.alignleft", "ai", [
                ("summary.profile-unicode", .fixed, "Русский текст и другие Unicode-символы в контексте больше не вызывают ложную ошибку сохранённого профиля. Повторный запуск использует текущие настройки.")]),
            update("assistant", "Помощник", "mic", "features", feature: .assistant, [
                ("assistant.profile-unicode", .fixed, "Голосовые поручения с русским контекстом больше не отклоняются из-за изменения символов при передаче настроек.")]),
            update("recording", "Запись встречи", "record.circle", "record", [
                ("recording.cancel-start", .fixed, "Отмена начала записи и выход из приложения не ждут ответа на запрос доступа к микрофону. Поздний ответ не запускает отменённую запись."),
                ("recording.session-identity", .fixed, "Ошибка от предыдущей записи больше не прерывает новую сессию.")]),
            update("queue", "Фоновые задачи", "list.bullet.rectangle", "ai", [
                ("queue.chatgpt-pause", .fixed, "Пауза после лимита ChatGPT сохраняется при перезапуске. Продолжить эту очередь можно только после вашего подтверждения.")])
        ]),
        Entry(version: "0.17.6.3", updates: [
            update("appearance", "Оформление After", "paintpalette", "appearance", [
                ("appearance.icon", .changed, "Новый знак After используется в Dock, Finder, строке меню и на странице возврата после входа в ChatGPT.")])
        ]),
        Entry(version: "0.17.6.4", updates: [
            update("recording", "Запись встречи", "record.circle", "record", [
                ("recording.video-pool", .fixed, "Видео больше не останавливается на первом кадре, даже когда экран меняется редко. Сохраняются цвета и полная длительность записи."),
                ("recording.permissions", .changed, "Подсказки помогают восстановить доступ к записи экрана, если macOS его отклонила.")])
        ]),
        Entry(version: "0.17.6.5", updates: [
            update("whats-new", "Изменения для вас", "sparkles", "updates", new: true, [
                ("whats-new.personal", .added, "Изменения сгруппированы по используемым, новым и отключённым возможностям. У каждой есть переход в настройки и отдельная отметка прочтения.")]),
            update("recording", "Запись встречи", "record.circle", "record", [
                ("recording.microphone-route", .added, "При смене устройства запись пытается подключить системный микрофон заново. Пока микрофон недоступен, сохраняется тишина."),
                ("recording.audio-clock", .fixed, "Исправлены сдвиги и сокращение звука при переключении микрофона, смене частоты и числа каналов, а также паузах.")]),
            update("sources", "Источники конспекта", "quote.bubble", "ai", [
                ("sources.performance", .fixed, "Окно источников открывается быстрее на длинных встречах. Цитаты подгружаются по мере просмотра."),
                ("sources.freshness", .fixed, "Устаревшие ссылки закрываются при изменении исходных данных. Повторное открытие и переименование участников сохраняют корректную навигацию.")]),
            update("calendar", "Календарь", "calendar", "features", feature: .calendar, [
                ("calendar.unsaved-draft", .fixed, "Черновик события защищён от потери при обновлении приложения. Повторное подключение календаря не перезаписывает несохранённые изменения.")]),
            update("trash", "Корзина", "trash", "data", [
                ("trash.retry", .fixed, "Повтор завершённой операции с Корзиной учитывает сохранённый результат и не меняет уже восстановленные данные.")]),
            update("import", "Импорт аудио и видео", "arrow.down.doc", "data", [
                ("import.audio-quality", .fixed, "Прослушивание готовится из исходной аудиодорожки отдельно от копии для распознавания. Готовый файл появляется только после завершения подготовки.")]),
            update("appearance", "Оформление After", "paintpalette", "appearance", [
                ("appearance.brand", .changed, "Название After едино для русского и английского интерфейса, настроек macOS и новых установочных пакетов. Библиотека и подключения сохраняются.")])
        ])
    ]

    static func updates(from previous: String?, through current: String) -> [ReleaseFeatureUpdate] {
        guard let upper = ReleaseVersion(current) else { return [] }
        let lower = previous.flatMap(ReleaseVersion.init)
        let eligible = entries.filter {
            guard let version = ReleaseVersion($0.version) else { return false }
            return version <= upper && (lower.map { version > $0 } ?? (version == upper))
        }
        var result: [ReleaseFeatureUpdate] = []
        for entry in eligible {
            for update in entry.updates {
                if let index = result.firstIndex(where: { $0.id == update.id }) {
                    let earlier = result[index]
                    result[index] = ReleaseFeatureUpdate(id: update.id, titleKey: update.titleKey, icon: update.icon,
                                                        requiredFeature: update.requiredFeature, settingsSection: update.settingsSection,
                                                        isNewFeature: earlier.isNewFeature || update.isNewFeature,
                                                        changes: earlier.changes + update.changes.filter { change in !earlier.changes.contains { $0.id == change.id } })
                } else { result.append(update) }
            }
        }
        return result
    }
    static var featureIDs: Set<String> {
        Set(entries.flatMap(\.updates).map(\.id))
            .union(AppFeature.allCases.map(\.rawValue))
            .union(["meetings", "notes", "recording", "import", "summary", "sources", "queue", "trash", "appearance", "whats-new"])
    }
    static var latestVersion: String { entries.last?.version ?? "" }
}
