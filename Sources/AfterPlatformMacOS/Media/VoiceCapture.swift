import AfterLocalization
import AfterPlatform
import AVFoundation
import Foundation

/// Short, explicit microphone sessions. Meeting recording owns its microphone
/// independently; this recorder never silently starts or captures system audio.
@MainActor
package final class VoiceCapture: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var directory: URL?
    private var timer: Timer?
    package override init() { super.init() }
    package var limitReached: (() -> Void)?
    package var failed: ((String) -> Void)?
    package func start(root: URL) async throws {
        guard recorder == nil else { throw AppError.message(L("Диктовка уже идёт.")) }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw AppError.message(L("Разрешите доступ к микрофону в настройках macOS.")) }
        try Task.checkCancellation()
        let base = root.appendingPathComponent("voice-inputs", isDirectory: true)
        try Self.validateDirectory(base, create: true)
        let directory = base.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        do {
            let audio = try AVAudioRecorder(url: directory.appendingPathComponent("input.m4a"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            audio.delegate = self
            guard audio.prepareToRecord(), audio.record() else { throw AppError.message(L("Не удалось включить микрофон.")) }
            recorder = audio
            timer = Timer.scheduledTimer(withTimeInterval: 175, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.recorder === audio else { return }; self.limitReached?()
                }
            }
        } catch { discard(); throw error }
    }
    package func stop() throws -> URL {
        guard let recorder else { throw AppError.message(L("Диктовка не начата.")) }
        timer?.invalidate(); timer = nil
        recorder.stop(); self.recorder = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recorder.url.path)
        return recorder.url
    }
    package func discard() {
        timer?.invalidate(); timer = nil; recorder?.stop(); recorder = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private static func validateDirectory(_ url: URL, create: Bool) throws {
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.message(L("Папка диктовки недоступна.")) }
    }
    package nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }; self.failed?(L("Не удалось сохранить диктовку. Повторите запись."))
        }
    }
}
