import AfterLocalization
import AfterPlatform
import AfterPlatformMacOS
import Foundation
import AfterCore

extension AppStore {
    var knowledgeRebuildProviderDescription: String {
        let configuration = effectiveSettings(folderID: folderSelection)
        if configuration.mode == "cloud" {
            return LF("Выбранные тексты будут отправлены в {0} · {1}.", arguments: [configuration.cloudProviderTitle, configuration.cloudModel])
        }
        return LF("Выбранные тексты обработает локальная модель {0}.", arguments: [configuration.localModel])
    }

    /// Cancellation owns only this preview request. It never cancels another
    /// queue job or stops a runtime while somebody else owns the local lease.
    func cancelKnowledgeRebuildGeneration() {
        guard let runner = knowledgeRebuildRunner else { return }
        knowledgeRebuildCancelled = true
        runner.cancel()
        if knowledgeRebuildOwnsLocalRuntime { localService.stop() }
    }

    func generateKnowledgeRebuild(noteIDs: [String], folderID: String?, instruction: String,
        event: @escaping @MainActor @Sendable (String) -> Void) async throws -> Data {
        guard !busy, !isRecording, !startingRecording, !stoppingRecording, !isTerminating,
              knowledgeRebuildRunner == nil else {
            throw AppError.message(L("Дождитесь завершения записи или текущей обработки, чтобы пересобрать базу."))
        }
        try Task.checkCancellation()
        // Persist the exact UI selection before the core resolves a profile;
        // credentials are not part of AppSettings or this disk snapshot.
        try write(settings, root.appendingPathComponent("settings.json"))
        let (profile, profileBytes) = try folderProfile(folderID: folderID)
        let configuration = profile.overrides.apply(to: settings)
        let frozenSettings = WorkerEnvironment.json(try JSONEncoder().encode(configuration))
        let frozenProfile = WorkerEnvironment.json(profileBytes)
        let requestRunner = ProcessRunner(), runID = UUID()
        beginJob(id: nil)
        knowledgeRebuildRunner = requestRunner; knowledgeRebuildRunID = runID
        knowledgeRebuildCancelled = false
        knowledgeRebuildCloudAccountID = configuration.mode == "cloud" && configuration.cloudProvider == "chatgpt" ? configuration.chatGPTAccountID : nil
        defer {
            if knowledgeRebuildRunID == runID {
                if knowledgeRebuildOwnsLocalRuntime && (knowledgeRebuildCancelled || Task.isCancelled) { localService.stop() }
                knowledgeRebuildRunner = nil; knowledgeRebuildRunID = nil
                knowledgeRebuildCloudAccountID = nil; knowledgeRebuildOwnsLocalRuntime = false
                knowledgeRebuildCancelled = false; endJob()
            }
        }
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard knowledgeRebuildRunID == runID, !knowledgeRebuildCancelled, !cancellationRequested,
                  !isRecording, !startingRecording, !stoppingRecording, !isTerminating else { throw CancellationError() }
        }
        progressText = L("Подготавливаю выбранные заметки…"); event(progressText)
        let libraryRoot = root
        var args: [String: Any] = ["noteIDs": noteIDs, "instruction": instruction]
        if let folderID { args["folderID"] = folderID }
        let prepareArguments = args
        let preparedBytes = try await Task.detached(priority: .userInitiated) {
            try RustBridge.shared.get().request(root: libraryRoot, command: "kb-rebuild-prepare", arguments: prepareArguments)
        }.value
        try checkCurrent()
        let prepared = try JSONDecoder().decode(KnowledgeRebuildPrepared.self, from: preparedBytes)
        let lease: UUID?
        if configuration.mode == "local" {
            lease = try await localRuntimeLease.acquire { [weak self] in
                guard let self else { return true }
                return await self.knowledgeRebuildAdmissionCancelled
            }
        } else { lease = nil }
        defer { if let lease { Task { await localRuntimeLease.release(lease) } } }
        try checkCurrent()
        if configuration.mode == "local" {
            knowledgeRebuildOwnsLocalRuntime = true
            try await localService.ensure(root: root, settings: configuration,
                cancelled: { self.knowledgeRebuildAdmissionCancelled })
        }
        try checkCurrent()
        var environment = ["POSLE_JOB_SETTINGS": frozenSettings, "POSLE_JOB_FOLDER_PROFILE": frozenProfile,
                           "POSLE_OLLAMA_URL": localService.baseURL]
        if configuration.mode == "cloud" { environment["POSLE_API_KEY"] = try await cloudCredential(for: configuration) }
        try checkCurrent()
        progressText = L("Предлагаю новую структуру и тексты…"); event(progressText)
        let input = try JSONSerialization.data(withJSONObject: ["draftID": prepared.draftID])
        let result: WorkerEvent?
        do {
            result = try await withTaskCancellationHandler {
                try await requestRunner.run(rustEngine, arguments: ["knowledge-rebuild", "--root", root.path],
                    environment: environment, input: input) { message in
                    guard let text = message.message else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.knowledgeRebuildRunID == runID, !self.knowledgeRebuildCancelled else { return }
                        self.progressText = text; event(text)
                    }
                }
            } onCancel: {
                requestRunner.cancel()
                Task { @MainActor [weak self] in
                    guard self?.knowledgeRebuildRunID == runID else { return }
                    self?.cancelKnowledgeRebuildGeneration()
                }
            }
        } catch {
            if Task.isCancelled || knowledgeRebuildCancelled { throw CancellationError() }
            throw error
        }
        try checkCurrent()
        guard let preview = result?.knowledgeRebuild else {
            throw AppError.message(L("Модель не вернула проверяемый план. Изменения не применены."))
        }
        return try JSONEncoder().encode(preview)
    }

    private var knowledgeRebuildAdmissionCancelled: Bool {
        knowledgeRebuildCancelled || cancellationRequested || isRecording || startingRecording || stoppingRecording || isTerminating
    }
}
