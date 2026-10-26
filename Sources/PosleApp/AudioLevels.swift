import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AudioLevels: ObservableObject {
    @Published var microphone = 0.0
    @Published var system = 0.0
    @Published var microphoneSeen = false
    @Published var systemSeen = false
    func receive(microphone: Double?, system: Double?) {
        if let microphone { self.microphone = microphone; microphoneSeen = true }
        if let system { self.system = system; systemSeen = true }
    }
    func clear() { microphone = 0; system = 0; microphoneSeen = false; systemSeen = false }
}

struct AudioLevelView: View {
    @ObservedObject var levels: AudioLevels
    var systemAudio = true
    var compact = false
    var active = true
    private func meter(_ label: String, value: Double, seen: Bool) -> some View {
        let status = !active ? "Не проверен" : seen ? value > 0.005 ? "Звук поступает" : "Тишина" : "Ожидаю звук"
        return HStack(spacing: 8) {
            Text(label).frame(width: compact ? 44 : 92, alignment: .leading)
            GeometryReader { proxy in
                Capsule().fill(Ink.soft)
                    .overlay(alignment: .leading) {
                        Capsule().fill(value > 0.9 ? Ink.warning : Ink.green)
                            .frame(width: max(0, proxy.size.width * min(1, max(0, sqrt(value)))))
                    }
            }.frame(width: compact ? 50 : 120, height: 5)
            if !compact { Text(status).frame(width: 120, alignment: .leading) }
        }.font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityValue(status)
    }
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    meter("Микр.", value: levels.microphone, seen: levels.microphoneSeen)
                    if systemAudio { meter("Mac", value: levels.system, seen: levels.systemSeen) }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    meter("Микрофон", value: levels.microphone, seen: levels.microphoneSeen)
                    if systemAudio { meter("Звук Mac", value: levels.system, seen: levels.systemSeen) }
                }
            }
        }
    }
}

/// Explicit preflight only. Temporary samples are removed; no library entry is made.
@MainActor
final class AudioCheckController: ObservableObject {
    let levels = AudioLevels()
    @Published var running = false
    @Published var starting = false
    @Published var stopping = false
    @Published var error: String?
    private let recorder = MeetingRecorder()
    private var directory: URL?
    private var generation = UUID()
    private var startTask: Task<Void, Never>?
    func start(systemAudio: Bool) {
        guard !running, !starting, !stopping else { return }
        let token = UUID(); generation = token; starting = true; error = nil; levels.clear()
        recorder.levels = { [weak self] microphone, system in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.levels.receive(microphone: microphone, system: system)
            }
        }
        recorder.failed = { [weak self] failure in
            Task { @MainActor in
                guard let self, self.directory?.lastPathComponent == failure.sessionID,
                      self.running || self.starting else { return }
                await self.stop()
                self.error = "Проверка прервалась: \(failure.message)"
            }
        }
        startTask = Task {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("posle-audio-check-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                self.directory = directory
                try await recorder.start(url: directory.appendingPathComponent(systemAudio ? "check.mov" : "check.m4a"), systemAudio: systemAudio)
                guard generation == token else { try? await recorder.stop(); cleanup(); starting = false; return }
                running = true; starting = false
            } catch { self.error = error.localizedDescription; starting = false; running = false; cleanup() }
        }
    }
    func stop() async {
        if stopping {
            while stopping { try? await Task.sleep(for: .milliseconds(20)) }
            return
        }
        stopping = true
        defer { stopping = false }
        generation = UUID(); running = false
        if let startTask { await startTask.value; self.startTask = nil }
        try? await recorder.stop(); cleanup(); starting = false; levels.clear()
    }
    private func cleanup() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

struct RecordingAudioCheck: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var check: AudioCheckController
    var systemAudio: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Проверка звука").font(AppTypography.controlStrong)
                Spacer()
                Button(check.running || check.stopping ? "Остановить проверку" : "Проверить звук") {
                    if check.running { Task { await check.stop() } }
                    else if !app.isPreview { check.start(systemAudio: systemAudio) }
                }.buttonStyle(.borderless).disabled(check.starting || check.stopping || app.isPreview)
            }
            AudioLevelView(levels: check.levels, systemAudio: systemAudio, active: check.running || check.starting)
            if let error = check.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.padding(14).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: systemAudio) { _, _ in Task { await check.stop() } }
            .onDisappear { Task { await check.stop() } }
    }
}
