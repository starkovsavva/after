import AppKit
import ScreenCaptureKit

/// Consent comes from macOS for this exact selection. Do not enumerate
/// SCShareableContent here: that asks for separate, persistent TCC permission.
@MainActor
final class SystemCapturePicker: NSObject, SCContentSharingPickerObserver {
    private static let lease = CaptureSelectionLease()
    private let request = CaptureSelectionRequest<SCContentFilter>(lease: lease)
    private let picker = SCContentSharingPicker.shared
    private var observing = false
    private weak var stream: SCStream?
    var selectionChanged: (() -> Void)?

    override init() {
        super.init()
        request.didRelease = { [weak self] in self?.removeObserver() }
    }

    private var configuration: SCContentSharingPickerConfiguration {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleDisplay
        // The writer's geometry is fixed. A different target needs a new recording.
        configuration.allowsChangingSelectedContent = false
        return configuration
    }

    func selectDisplay() async throws -> SCContentFilter {
        do {
            let filter = try await request.select {
                picker.defaultConfiguration = configuration
                picker.maximumStreamCount = 1
                picker.add(self)
                observing = true
                picker.isActive = true
                picker.present(using: .display)
            }
            guard filter.style == .display else {
                close()
                throw AppError.message(L("Выберите экран целиком в окне macOS и повторите запись."))
            }
            return filter
        } catch CaptureSelectionFailure.busy {
            throw AppError.message(L("Другая запись или проверка звука уже выбирает или использует экран. Сначала остановите её."))
        }
    }

    func bind(_ stream: SCStream) {
        self.stream = stream
        picker.setConfiguration(configuration, for: stream)
    }

    func cancelPendingSelection() {
        request.cancelPending()
    }

    func close() { request.release() }

    private func removeObserver() {
        guard observing else { return }
        picker.remove(self)
        picker.isActive = false
        picker.maximumStreamCount = 0
        observing = false
        stream = nil
        selectionChanged = nil
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            // Canceling a proposed change does not stop an already selected stream.
            guard stream == nil else { return }
            self?.request.resolve(.failure(CancellationError()))
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, request.ownsLease else { return }
            if let stream {
                guard self.stream === stream else { return }
                // Defensive: do not write a new source into the old meeting.
                selectionChanged?()
            } else { request.resolve(.success(filter)) }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            let code = (error as NSError).code
            self?.request.resolve(.failure(AppError.message(LF("Не удалось открыть выбор экрана macOS (код {0}). Повторите попытку.", arguments: [String(code)]))))
        }
    }
}
