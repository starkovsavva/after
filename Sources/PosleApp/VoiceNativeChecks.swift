#if DEBUG
import AppKit
import Foundation
import PosleCore

/// Real Swift controller → stdin CLI → localhost model fixture → Rust durable
/// mutations. No microphone, Keychain, real models or external requests.
@MainActor
enum VoiceNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = env["POSLE_DATA_DIR"],
              let binary = env["POSLE_RUST_ENGINE"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw AppError.message("Voice checks require --preview and disposable runtime overrides")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable root required")
        let store = AppStore(preview: true)
        try expect(store.meetings.isEmpty && store.notes.notes.isEmpty, "Voice checks require an empty fixture")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/voice_fixture_server.py")
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, "--root", root.path]; server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        server.environment = ProcessEnvironment.withoutSecrets(env)
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let portFile = root.appendingPathComponent("fixture-port")
        try await waitUntil { FileManager.default.fileExists(atPath: portFile.path) || !server.isRunning }
        let port = try String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.mode = "local"; store.settings.localProvider = "lmstudio"
        store.settings.localModel = "voice-fixture"; store.settings.localEndpoint = "http://127.0.0.1:\(port)"
        let voice = store.voice
        func fixture(_ action: String, text: String = "", title: String = "", query: String = "", due: String = "", setDue: Bool = false, cards: [[String: String]] = []) throws {
            let proposal: [String: Any] = ["action": action, "text": text, "title": title, "query": query,
                "due": due, "owner": "", "setDue": setDue, "setOwner": false, "setCompleted": false,
                "completed": false, "cards": cards]
            try JSONSerialization.data(withJSONObject: ["proposal": proposal]).write(to: root.appendingPathComponent("fixture-response.json"))
        }
        func prepare(_ text: String, taskID: String? = nil) {
            voice.dismiss(); voice.reset(); voice.present(taskID: taskID, title: "Выбранная задача"); voice.text = text
        }
        try fixture("createNote", text: "Для пилота нужен доступ к тестовому стенду.", title: "Доступ к стенду")
        prepare("Создай заметку про доступ к стенду")
        voice.perform(); voice.perform()
        try expect(store.busy && voice.isWorking, "Voice must reserve a job synchronously")
        try await waitUntil { !store.busy }
        try expect(voice.phase == .result && store.notes.notes.count == 1, "Double click must create exactly one note: \(voice.message ?? "")")
        let noteID = try required(voice.result?.target.id, "Created note ID")
        try expect(voice.result?.canUndo == true, "New note must be undoable")
        // Simulate exit after Rust committed but before Swift cleared the draft.
        guard let committedPlan = voice.plan else { throw AppError.message("Committed plan missing") }
        _ = try RustBridge.shared.get().request(root: root, command: "write", arguments: ["path": "voice-draft.json", "value": [
            "text": voice.text, "contextLabel": "Библиотека", "planID": committedPlan.planID!, "operationID": committedPlan.operationID!
        ]])
        let recovered = AppStore(preview: true)
        try expect(recovered.voice.result?.target.id == noteID && recovered.notes.notes.count == 1,
                   "Crash recovery must find committed result without planning or creating a duplicate")
        voice.openResult()
        try expect(store.notes.selectedNoteID == noteID && store.librarySection == "inbox", "Result opens exact note")
        print("PASS: native voice stdin pipeline creates one note and opens its exact destination")

        try fixture("appendNote", text: "Проверить права на выгрузку.")
        prepare("Дополни эту заметку: проверить права на выгрузку")
        voice.perform(); try await waitUntil { !store.busy }
        try expect(voice.result?.target.id == noteID && store.notes.notes.first?.text.contains("Проверить права") == true, "Append must use selected note")
        voice.undo(); try await waitUntil { !store.busy }
        try expect(store.notes.notes.first?.text == "Для пилота нужен доступ к тестовому стенду.", "Undo must preserve original note")
        print("PASS: append and undo restore original content through Rust revision checks")

        try fixture("createTask", text: "Проверить договор", title: "Договор для пилота")
        prepare("Создай задачу проверить договор")
        voice.perform(); try await waitUntil { !store.busy }
        let taskID = try required(voice.result?.target.id, "Created task ID")
        try expect(store.notes.tasks.count == 1, "Task must appear in tracker")
        try fixture("appendTask", text: "Уточнить условия оплаты.")
        prepare("Дополни эту задачу: уточнить условия оплаты", taskID: taskID)
        voice.perform(); try await waitUntil { !store.busy }
        try expect(store.notes.tasks.count == 1 && store.notes.tasks.first?.text.contains("Уточнить условия") == true, "Task must be extended without duplication")
        try expect(store.notes.tasks.first?.history?.count == 1, "Append must retain task history")
        try fixture("updateTask", due: "завтра", setDue: true)
        prepare("Перенеси эту задачу на завтра", taskID: taskID)
        voice.perform(); try await waitUntil { !store.busy }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        try expect(store.notes.tasks.first?.due == formatter.string(from: tomorrow), "Relative due date must use client timezone")
        print("PASS: create, append, history and relative deadline keep one stable task")

        _ = store.notes.capture(text: "Проверить договор поставщика", kind: "task")
        try fixture("appendTask", text: "Запросить согласование.", query: "договор")
        prepare("К задаче про договор добавь запросить согласование")
        voice.perform(); try await waitUntil { !store.busy }
        try expect(voice.phase == .choosing && (voice.plan?.candidates?.count ?? 0) == 2, "Ambiguous task requires explicit choice: \(voice.message ?? "")")
        let candidate = try required(voice.plan?.candidates?.first, "Target candidate")
        voice.choose(candidate); try await waitUntil { !store.busy }
        try expect(voice.phase == .result && store.notes.tasks.filter { $0.text.contains("Запросить согласование") }.count == 1, "Choice modifies only one candidate")
        // A concurrent edit must prevent undo from overwriting newer work.
        let updated = try required(store.notes.notes.first { $0.id == voice.result?.target.id }, "Chosen task")
        var edited = updated; edited.text += "\nПравка после команды"; _ = store.notes.save(edited)
        voice.undo(); try await waitUntil { !store.busy }
        try expect(voice.result != nil && voice.message != nil && store.notes.notes.contains { $0.text.contains("Правка после команды") }, "Unsafe undo must fail with original data preserved")
        print("PASS: ambiguity is resolved explicitly; undo protects a later edit")

        try fixture("createCards", title: "Рабочая переписка", cards: [["kind": "phrase", "front": "follow up", "back": "Уточнить результат", "context": "Пример: I will follow up tomorrow."]])
        prepare("Сделай карточку с фразой follow up")
        voice.perform(); try await waitUntil { !store.busy }
        try expect(voice.result?.target.kind == "cards" && store.meetings.contains { $0.libraryKind == "cards" }, "Cards must be a real study deck")
        voice.openResult(); try expect(store.summary?.cards.count == 1, "Created cards must open for in-app study")
        voice.undo(); try await waitUntil { !store.busy }; try expect(!store.meetings.contains { $0.libraryKind == "cards" }, "Undo removes only untouched created deck")
        print("PASS: voice-created cards are usable in the existing study system and undoable")

        let count = store.notes.notes.count
        try fixture("unsupported", text: "Уточните, какую заметку нужно изменить.")
        prepare("Поменяй там всё")
        voice.perform(); try await waitUntil { !store.busy }
        try expect(voice.phase == .editing && store.notes.notes.count == count, "Unsupported command cannot mutate data")
        try JSONSerialization.data(withJSONObject: ["content": "invalid JSON"]).write(to: root.appendingPathComponent("fixture-response.json"))
        prepare("Создай заметку")
        voice.perform(); try await waitUntil { !store.busy }
        try expect(voice.message != nil && !voice.isWorking && store.notes.notes.count == count, "Invalid model response releases controls and preserves data")
        print("PASS: unsupported and malformed responses do not mutate the library")
        try fixture("createNote", text: "Эта заметка не должна появиться", title: "Отменённая команда")
        let responseURL = root.appendingPathComponent("fixture-response.json")
        var delayed = try JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as! [String: Any]
        delayed["delay"] = 2
        try JSONSerialization.data(withJSONObject: delayed).write(to: responseURL)
        prepare("Создай заметку, которую сейчас отменим")
        voice.perform(); try await Task.sleep(for: .milliseconds(200)); store.cancelJob()
        try expect(store.busy, "Cancel must keep the processing reservation while the child drains")
        try await waitUntil { !store.busy }
        try expect(!voice.isWorking && store.notes.notes.count == count && !voice.text.isEmpty,
                   "Cancelled planner must not mutate the library or drop the command")
        try notesDraftCheck(store: store)
        print("PASS: cancelling real delayed HTTP planning drains safely and preserves draft")
        prepare(String(repeating: "Длинный черновик. ", count: 700))
        let longDraft = voice.text
        try expect(voice.flushDraft(), "Draft should persist")
        let reopened = AppStore(preview: true)
        try expect(reopened.voice.text == longDraft && !reopened.voice.isWorking, "Reopen must preserve full draft without truncation or microphone access")
        voice.reset(); _ = voice.flushDraft()
        print("PASS: crash recovery keeps committed operation identity; long drafts survive reopening intact")
        print("8 native voice E2E groups passed")
    }
    private static func notesDraftCheck(store: AppStore) throws {
        store.notes.captureDrafts["taskappend:pending"] = "Не потерять уточнение задачи"
        _ = store.notes.flushCaptureDrafts()
        let reopened = NotesStore(root: store.root)
        try expect(reopened.captureDrafts["taskappend:pending"] == "Не потерять уточнение задачи", "Task draft must survive reopen")
        store.notes.captureDrafts.removeAll(); _ = store.notes.flushCaptureDrafts()
    }
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Voice E2E timed out")
    }
    private static func required<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw AppError.message("Missing \(label)") }; return value
    }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
}
#endif
