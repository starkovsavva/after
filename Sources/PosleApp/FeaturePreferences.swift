import Foundation
import PosleCore

extension AppStore {
    /// Persist consent before publishing it: publishing starts/stops integrations.
    /// A failed atomic write leaves both runtime state and existing preferences intact.
    @discardableResult
    func setFeature(_ feature: AppFeature, enabled: Bool) -> Bool {
        guard settings.isEnabled(feature) != enabled else { return true }
        guard !startingRecording && !isRecording && !stoppingRecording && !busy && jobs.activeCount == 0 else {
            error = L("Изменить возможности можно после завершения записи и обработки.")
            return false
        }
        guard !UnsavedEditorRegistry.hasUnsaved else {
            error = L("Сохраните или отмените открытые правки перед изменением возможностей.")
            return false
        }
        if feature == .assistant, !enabled, !voice.flushDraft() {
            error = L("Не удалось сохранить черновик помощника. Повторите попытку перед отключением.")
            return false
        }
        var candidate = settings
        candidate.features[feature] = enabled
        do {
            try write(candidate, root.appendingPathComponent("settings.json"))
            settings = candidate
            NotificationCenter.default.post(name: Notification.Name("PosleShortcutsChanged"), object: nil)
            return true
        } catch {
            self.error = L("Не удалось сохранить выбор возможностей. ") + error.localizedDescription
            return false
        }
    }
}
