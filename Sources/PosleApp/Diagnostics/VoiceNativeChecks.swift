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
        let lifecycleVoice = store.voice
        for transition in ["starting", "stopping", "terminating"] {
            store.startingRecording = transition == "starting"
            store.stoppingRecording = transition == "stopping"
            store.isTerminating = transition == "terminating"
            lifecycleVoice.startDictation()
            let expected = transition == "terminating" ? "Приложение завершает работу." : "Во время записи встречи введите поручение текстом. Микрофон занят записью."
            try expect(lifecycleVoice.phase == .editing && !store.busy && lifecycleVoice.message == expected,
                       "Dictation was admitted while capture or termination was transitioning")
        }
        store.startingRecording = false; store.stoppingRecording = false; store.isTerminating = false
        for failure: Error in [AppError.message("Synthetic capture stop failed"), CancellationError()] {
            lifecycleVoice.beginSyntheticDictationForChecks(stopFailure: failure)
            try expect(store.busy && lifecycleVoice.phase == .capturing, "Synthetic dictation did not reserve the actual global job")
            lifecycleVoice.finishDictation()
            try expect(!store.busy && store.assertions == 0 && !store.canCancelJob && lifecycleVoice.phase == .editing && lifecycleVoice.message != nil,
                       "A failed/cancelled capture stop leaked its job or power reservation")
        }
        lifecycleVoice.beginSyntheticDictationForChecks(stopFailure: CancellationError())
        lifecycleVoice.cancelWork()
        try await waitUntil { !store.busy }
        try expect(store.assertions == 0 && lifecycleVoice.phase == .editing, "Capture cancellation leaked its job or power reservation")
        print("PASS: dictation excludes capture/termination transitions and stop failure/cancellation release reservations")

        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/voice_fixture_server.py")
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
        func fixture(_ action: String, text: String = "", title: String = "", query: String = "", due: String = "", setDue: Bool = false, cards: [[String: String]] = [], delay: Double = 0) throws {
            let proposal: [String: Any] = ["action": action, "text": text, "title": title, "query": query,
                "due": due, "owner": "", "setDue": setDue, "setOwner": false, "setCompleted": false,
                "completed": false, "cards": cards]
            try JSONSerialization.data(withJSONObject: ["proposal": proposal, "delay": delay]).write(to: root.appendingPathComponent("fixture-response.json"))
        }
        func confirmTaskReview() async throws {
            try expect(voice.phase == .reviewing && voice.plan?.reviewRequired == true, "Task mutation requires a visible review")
            try expect(voice.canConfirmReview, "Valid task preview must be confirmable")
            voice.confirmReview(); voice.confirmReview()
            try await waitUntil { !voice.isWorking && !store.busy }
            try expect(voice.phase == .result, "Confirmed task mutation failed: \(voice.message ?? "")")
        }
        func taskFixture(_ action: String, targets: [(String, String)], text: String = "", query: String = "пилот") throws {
            try fixture(action, text: text, query: query)
            let file = root.appendingPathComponent("fixture-response.json")
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            value["reranking"] = ["matches": targets.map { ["id": $0.0, "reason": $0.1] }, "clarification": ""]
            try JSONSerialization.data(withJSONObject: value).write(to: file)
        }
        func prepare(_ text: String, taskID: String? = nil) {
            voice.dismiss(); voice.reset(); voice.present(taskID: taskID, title: "Выбранная задача"); voice.text = text
        }
        try fixture("createNote", text: "Для пилота нужен доступ к тестовому стенду.", title: "Доступ к стенду", delay: 0.4)
        prepare("Создай заметку про доступ к стенду")
        voice.perform(); voice.perform()
        try expect(voice.isWorking && voice.phase == .planning && !store.busy,
                   "Planning must reserve its own phase synchronously without globally blocking the app")
        try await waitUntil { store.jobs.jobs.contains { $0.kind == "voice-plan" && $0.active } }
        try expect(store.jobs.jobs.filter { $0.kind == "voice-plan" && $0.active }.count == 1,
                   "Double click must enqueue one real planning operation")
        store.showingRecord = true
        try expect(store.showingRecord && voice.isWorking && !store.busy && !store.startingRecording,
                   "Opening recording options must remain available during independent voice planning")
        store.showingRecord = false
        try await waitUntil { !voice.isWorking && !store.busy }
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
        // This temporary reopen only probes crash recovery. Stop its executor
        // before the original app continues; a real restart has one live store.
        await recovered.jobs.shutdown()
        voice.openResult()
        try expect(store.notes.selectedNoteID == noteID && store.librarySection == "inbox", "Result opens exact note")
        print("PASS: native voice stdin pipeline creates one note and opens its exact destination")

        try fixture("appendNote", text: "Проверить права на выгрузку.")
        prepare("Дополни эту заметку: проверить права на выгрузку")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.result?.target.id == noteID && store.notes.notes.first?.text.contains("Проверить права") == true, "Append must use selected note")
        voice.undo(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(store.notes.notes.first?.text == "Для пилота нужен доступ к тестовому стенду.", "Undo must preserve original note")
        print("PASS: append and undo restore original content through Rust revision checks")

        try fixture("createTask", text: "Проверить договор", title: "Договор для пилота")
        prepare("Создай задачу проверить договор")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        let taskID = try required(voice.result?.target.id, "Created task ID")
        try expect(store.notes.tasks.count == 1, "Task must appear in tracker")
        try fixture("appendTask", text: "Уточнить условия оплаты.")
        prepare("Дополни эту задачу: уточнить условия оплаты", taskID: taskID)
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(store.notes.tasks.first?.text.contains("Уточнить условия") == false, "Planning must not mutate a task before confirmation")
        try await confirmTaskReview()
        try expect(store.notes.tasks.count == 1 && store.notes.tasks.first?.text.contains("Уточнить условия") == true, "Task must be extended without duplication")
        try expect(store.notes.tasks.first?.history?.count == 1, "Append must retain task history")
        try fixture("updateTask", due: "завтра", setDue: true)
        prepare("Перенеси эту задачу на завтра", taskID: taskID)
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try await confirmTaskReview()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        try expect(store.notes.tasks.first?.due == formatter.string(from: tomorrow), "Relative due date must use client timezone")
        print("PASS: create, append, history and relative deadline keep one stable task")

        _ = store.notes.capture(text: "Проверить договор поставщика", kind: "task")
        try fixture("appendTask", text: "Запросить согласование.", query: "договор")
        prepare("К задаче про договор добавь запросить согласование")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.phase == .choosing && (voice.plan?.candidates?.count ?? 0) == 2, "Ambiguous task requires explicit choice: \(voice.message ?? "")")
        let candidate = try required(voice.plan?.candidates?.first, "Target candidate")
        voice.choose(candidate); try await waitUntil { !voice.isWorking && !store.busy }
        try await confirmTaskReview()
        try expect(voice.phase == .result && store.notes.tasks.filter { $0.text.contains("Запросить согласование") }.count == 1, "Choice modifies only one candidate")
        // A concurrent edit must prevent undo from overwriting newer work.
        let updated = try required(store.notes.notes.first { $0.id == voice.result?.target.id }, "Chosen task")
        var edited = updated; edited.text += "\nПравка после команды"; _ = store.notes.save(edited)
        voice.undo(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.result != nil && voice.message != nil && store.notes.notes.contains { $0.text.contains("Правка после команды") }, "Unsafe undo must fail with original data preserved")
        print("PASS: ambiguity is resolved explicitly; undo protects a later edit")

        let stableTask = try required(store.notes.tasks.first, "Task for semantic navigation")
        let originalNotes = store.notes.notes.count
        try taskFixture("openTask", targets: [(stableTask.id, "В задаче обсуждается договор для пилота")])
        prepare("Открой задачу, где нужно согласовать договор для пилота")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(store.librarySection == "tasks" && store.notes.selectedTaskID == stableTask.id && !voice.isPresented,
                   "Semantic navigation must open the exact existing task")
        try expect(store.notes.notes.count == originalNotes, "Navigation must not materialize or create a task")
        print("PASS: two-pass task intent opens an existing canonical task without mutation")

        let tasks = Array(store.notes.tasks.prefix(2))
        try expect(tasks.count == 2, "Batch fixture needs two tasks")
        try taskFixture("appendTaskContexts", targets: tasks.map { ($0.id, "Относится к согласованию договора") }, text: "Проверить оплату")
        prepare("Добавь мысль к задачам о договоре: проверить оплату")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.phase == .reviewing && voice.selectedTargetIDs.count == 2, "Batch plan must show both suggested targets")
        let excluded = try required(voice.plan?.candidates?.last, "Batch excluded target")
        voice.toggleReviewTarget(excluded, selected: false)
        voice.reviewText = "Уточнить оплату в два этапа"
        try await confirmTaskReview()
        func taskContext(_ id: String) throws -> String {
            let data = try RustBridge.shared.get().request(root: root, command: "task-context", arguments: ["taskID": id])
            return String(decoding: data, as: UTF8.self)
        }
        let included = try required(tasks.first { $0.id != excluded.id }, "Included batch task")
        try expect(try taskContext(included.id).contains("Уточнить оплату в два этапа"), "Edited context must reach the selected task")
        try expect(try !taskContext(excluded.id).contains("Уточнить оплату в два этапа"), "Excluded task must stay unchanged")
        voice.undo(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(try !taskContext(included.id).contains("Уточнить оплату в два этапа"), "Batch undo must remove only its additions")
        print("PASS: native batch preview edits text, selects a subset and undoes its atomic change")

        try taskFixture("completeTask", targets: [(included.id, "Пользователь завершает согласование договора")])
        prepare("Заверши задачу про согласование договора")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.phase == .reviewing, "Completion must stop at review")
        let noteForConflict = try required(store.notes.notes.first { included.id == "manual:\($0.id)" }, "Mutable task for conflict")
        var concurrentEdit = noteForConflict; concurrentEdit.owner = "Анна"; _ = store.notes.save(concurrentEdit)
        voice.confirmReview(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.phase == .reviewing && voice.message != nil && store.notes.tasks.first { $0.id == included.id }?.completed == false,
                   "Stale completion must preserve the newer task and stay reviewable")
        print("PASS: stale semantic completion fails before mutation and preserves a concurrent edit")

        try fixture("createCards", title: "Рабочая переписка", cards: [["kind": "phrase", "front": "follow up", "back": "Уточнить результат", "context": "Пример: I will follow up tomorrow."]])
        prepare("Сделай карточку с фразой follow up")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.result?.target.kind == "cards" && store.meetings.contains { $0.libraryKind == "cards" }, "Cards must be a real study deck")
        voice.openResult(); try expect(store.summary?.cards.count == 1, "Created cards must open for in-app study")
        voice.undo(); try await waitUntil { !voice.isWorking && !store.busy }; try expect(!store.meetings.contains { $0.libraryKind == "cards" }, "Undo removes only untouched created deck")
        print("PASS: voice-created cards are usable in the existing study system and undoable")
        try fixture("createCards", title: "Следующий шаг", cards: [["kind": "phrase", "front": "Следующий шаг", "back": "Next step", "context": "Пример: Let's agree on the next step."]])
        prepare("Сделай ещё одну карточку")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        let newDeck = try required(voice.result?.target.meetingID ?? voice.result?.target.id, "Created deck target")
        voice.continueCommand()
        try expect(voice.phase == .editing && voice.selectedContextForChecks == ["meetingID":newDeck], "Command continuation must select the NEW deck, without stale task/note scope")
        print("PASS: continuing a card creation targets the created deck and drops stale selected objects")


        // A library question ignores the selected task/project and produces an
        // ephemeral answer rather than a plan or an undoable write operation.
        let workspaceURL = root.appendingPathComponent("notes/workspace.json")
        let beforeQuestion = try Data(contentsOf: workspaceURL)
        try fixture("askKnowledge", query: "стенд")
        voice.dismiss(); voice.reset()
        voice.present(taskID: stableTask.id, title: "Выбранная задача", projectID: "Другой проект")
        voice.text = "Что нужно для доступа к стенду?"
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        let answer = try required(voice.knowledgeAnswer, "Read-only library answer: \(voice.message ?? "")")
        try expect(voice.phase == .result && voice.result == nil && voice.plan == nil,
                   "A knowledge answer must not create a mutation result, plan identity, or Undo")
        var noteSource = try required(answer.sources.first { $0.noteID == noteID }, "Global note citation outside selected project")
        try expect(!answer.paragraphs.isEmpty && answer.paragraphs.allSatisfy { !$0.sourceIDs.isEmpty }, "Library facts require real citations")
        try expect(try Data(contentsOf: workspaceURL) == beforeQuestion, "Read-only Q&A changed the notes/tasks/voice workspace")
        let originalQuestion = voice.text
        voice.continueQuestion()
        try expect(voice.phase == .editing && voice.text.isEmpty && voice.contextLabel == "Продолжение разговора", "Follow-up must preserve only the conversation topic")
        try fixture("askKnowledge", query: "стенд")
        voice.text = "А какие детали стоит проверить?"
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        let followUp = try required(voice.knowledgeAnswer, "Follow-up answer: \(voice.message ?? "")")
        let followPrompt = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture-classification-started.json"))) as! [String: Any]
        try expect((followPrompt["previous_questions"] as? [String]) == [originalQuestion], "Follow-up lost the original USER topic or retained an answer as evidence")
        try expect((followPrompt["selected_objects"] as? [Any])?.isEmpty == true && followPrompt["meeting"] is NSNull,
                   "Follow-up inherited a stale selected task, project or meeting")
        noteSource = try required(followUp.sources.first { $0.noteID == noteID }, "Fresh follow-up source")
        try expect(try Data(contentsOf: workspaceURL) == beforeQuestion, "Follow-up changed canonical notes/tasks/voice plans")
        print("PASS: native follow-up retains only bounded user topics and retrieves fresh global evidence")
        voice.openKnowledgeSource(noteSource)
        try await waitUntil { voice.knowledgeOpeningID == nil }
        try expect(!voice.isPresented && store.notes.selectedNoteID == noteID && store.librarySection == "inbox",
                   "A validated citation must open the exact saved note")
        try expect(voice.knowledgeAnswer == nil, "Source navigation must clear the ephemeral answer")

        try fixture("askKnowledge", query: "стенд")
        prepare("Что нужно для стенда?")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        let staleSource = try required(voice.knowledgeAnswer?.sources.first { $0.noteID == noteID }, "Citation for stale test")
        var changedNote = try required(store.notes.notes.first { $0.id == noteID }, "Cited note")
        changedNote.text += "\nДоступ согласован позже."; _ = store.notes.save(changedNote)
        store.librarySection = "tasks"
        voice.openKnowledgeSource(staleSource)
        try await waitUntil { voice.knowledgeOpeningID == nil }
        try expect(voice.isPresented && store.librarySection == "tasks" && voice.message != nil,
                   "A changed source must remain visible as a stale citation, without navigating")
        voice.reset()
        try expect(voice.knowledgeAnswer == nil && voice.result == nil && voice.phase == .editing, "Reset must clear all answer state")
        print("PASS: global Q&A is read-only, ignores selected project, and validates exact/stale note navigation")

        // Synthetic calendar evidence follows the same validation route without
        // constructing EventKit or touching accounts, permissions or sync links.
        store.calendar.seedPreview()
        let snapshot = store.calendar.knowledgeSnapshot(question: "Промежуточные результаты")
        let event = try required(snapshot.events.first { $0.id == "project-checkpoint" }, "Synthetic calendar event")
        try expect(snapshot.connected && snapshot.events.count <= 128 && (try JSONEncoder().encode(snapshot).count) < 128 * 1024, "Already-connected calendar snapshot must be bounded")
        let beforeCalendarQuestion = try Data(contentsOf: workspaceURL)
        try fixture("askKnowledge", query: "Промежуточные результаты")
        prepare("Когда промежуточные результаты?")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        let calendarSource = try required(voice.knowledgeAnswer?.sources.first { $0.kind == "calendar" && $0.eventID == event.id }, "Real calendar citation from synthetic snapshot")
        voice.openKnowledgeSource(calendarSource)
        try await waitUntil { voice.knowledgeOpeningID == nil }
        try expect(store.librarySection == "calendar" && store.calendar.displayMode == .day && !voice.isPresented,
                   "Calendar citation must reveal the correct day without scheduling a new event")
        try expect(Calendar.current.isDate(store.calendar.selectedDate, inSameDayAs: Date(timeIntervalSince1970: event.start)), "Calendar citation opened a different date")
        try expect(try Data(contentsOf: workspaceURL) == beforeCalendarQuestion, "Calendar question/navigation changed task or note data")
        print("PASS: synthetic calendar Q&A opens its occurrence using fresh read-only validation")

        try CalendarStore.verifyKnowledgeSnapshotBounds()
        store.calendar.seedPreview()
        try fixture("askKnowledge", query: "Промежуточные результаты")
        let knowledgeResponse = root.appendingPathComponent("fixture-response.json")
        var changing = try JSONSerialization.jsonObject(with: Data(contentsOf: knowledgeResponse)) as! [String: Any]
        changing["knowledgeDelay"] = 1; changing["knowledgeMixed"] = true
        try JSONSerialization.data(withJSONObject: changing).write(to: knowledgeResponse)
        let knowledgeStarted = root.appendingPathComponent("fixture-knowledge-started.json")
        try? FileManager.default.removeItem(at: knowledgeStarted)
        prepare("Когда промежуточные результаты и что нужно сделать?")
        voice.perform()
        try await waitUntil { FileManager.default.fileExists(atPath: knowledgeStarted.path) }
        store.calendar.changeKnowledgeEventForChecks(id: "project-checkpoint", title: "Встреча перенесена: дату уточним")
        try await waitUntil { !voice.isWorking && !store.busy }
        let changedAnswer = try required(voice.knowledgeAnswer, "Answer after an in-flight calendar change")
        try expect(changedAnswer.sources.isEmpty && changedAnswer.paragraphs.allSatisfy { $0.sourceIDs.isEmpty },
                   "A whole mixed task/calendar paragraph must be removed when its event changes during the model call")
        try expect(changedAnswer.warnings.contains { $0.contains("изменились во время ответа") }, "Changed calendar evidence must produce a visible warning")
        try expect(try Data(contentsOf: workspaceURL) == beforeCalendarQuestion, "In-flight event validation changed note/task data")
        voice.reset()
        print("PASS: calendar snapshot stays within count/UTF-8 budgets; changed in-flight evidence removes a whole mixed paragraph")

        let farDate = store.calendar.seedKnowledgeLongTailForChecks()
        let literalDate = formatter.string(from: farDate)
        for (question, query) in [("Когда проверка астролябии?", "астролябии"), ("Что запланировано на \(literalDate)?", "")] {
            try fixture("askKnowledge", query: query)
            var calendarFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: knowledgeResponse)) as! [String: Any]
            calendarFixture["knowledgeKinds"] = ["calendar"]
            try JSONSerialization.data(withJSONObject: calendarFixture).write(to: knowledgeResponse)
            prepare(question)
            voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
            let longTailAnswer = try required(voice.knowledgeAnswer, "Long-tail calendar answer: \(voice.message ?? "")")
            try expect(longTailAnswer.sources.contains { $0.eventID == "far-astrolabe" },
                       "The real question pipeline dropped a far calendar match behind 200 nearby events")
            try expect(longTailAnswer.paragraphs.contains { !$0.sourceIDs.isEmpty }, "Long-tail calendar fact lost its source")
            voice.reset()
        }
        try expect(try Data(contentsOf: workspaceURL) == beforeCalendarQuestion, "Long-tail calendar Q&A modified the task/note workspace")
        print("PASS: 200 nearby calendar events do not hide a later title or explicit-date match through the native Q&A pipeline")

        // The second user question omits the date. The classifier resolves it
        // from the preceding USER question; native capture and post-answer
        // validation must use that same resolved period rather than a nearby
        // default calendar window.
        for followUp in [false, true] {
            try fixture("askKnowledge", query: literalDate)
            var datedFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: knowledgeResponse)) as! [String: Any]
            datedFixture["knowledgeKinds"] = ["calendar"]
            try JSONSerialization.data(withJSONObject: datedFixture).write(to: knowledgeResponse)
            if followUp { voice.continueQuestion(); voice.text = "Во сколько начинается эта встреча?" }
            else { prepare("Что запланировано на \(literalDate)?") }
            voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
            let datedAnswer = try required(voice.knowledgeAnswer, "Resolved-date follow-up: \(voice.message ?? "")")
            try expect(datedAnswer.sources.contains { $0.eventID == "far-astrolabe" } && datedAnswer.paragraphs.contains { !$0.sourceIDs.isEmpty },
                       "A follow-up lost the far event when only the resolved query retained its calendar date")
        }
        voice.reset()
        try expect(try Data(contentsOf: workspaceURL) == beforeCalendarQuestion, "Resolved-date follow-up changed the workspace")
        print("PASS: calendar follow-up captures and revalidates the resolved far date without repeating it in the user question")

        // Calendar access changes while the classifier is in flight. The
        // second native phase must capture the new permission state before
        // sending any calendar evidence to the synthesis provider.
        store.calendar.seedPreview()
        let privateCanary = "CALENDAR_PRIVATE_CANARY_MUST_NOT_REACH_SYNTHESIS"
        store.calendar.changeKnowledgeEventForChecks(id: "project-checkpoint", title: privateCanary)
        try fixture("askKnowledge", query: "стенд")
        var revoking = try JSONSerialization.jsonObject(with: Data(contentsOf: knowledgeResponse)) as! [String: Any]
        revoking["classificationDelay"] = 1
        try JSONSerialization.data(withJSONObject: revoking).write(to: knowledgeResponse)
        let classificationStarted = root.appendingPathComponent("fixture-classification-started.json")
        try? FileManager.default.removeItem(at: classificationStarted)
        try? FileManager.default.removeItem(at: knowledgeStarted)
        prepare("Что нужно для доступа к стенду и когда встреча?")
        voice.perform()
        try await waitUntil { FileManager.default.fileExists(atPath: classificationStarted.path) }
        let classificationPrompt = try String(contentsOf: classificationStarted, encoding: .utf8)
        try expect(!classificationPrompt.contains(privateCanary), "The classifier must not receive any raw calendar snapshot")
        store.calendar.disconnect()
        try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.knowledgeAnswer != nil && !store.calendar.connected, "The non-calendar library answer should survive calendar disconnection")
        let synthesisPrompt = try String(contentsOf: knowledgeStarted, encoding: .utf8)
        try expect(!synthesisPrompt.contains(privateCanary), "Revoked calendar evidence was sent to synthesis after classification")
        try expect(voice.knowledgeAnswer?.sources.contains { $0.kind == "calendar" } == false,
                   "A disconnected calendar must not remain a citation in the accepted answer")
        try expect(try Data(contentsOf: workspaceURL) == beforeCalendarQuestion, "Two-phase permission recheck changed task/note data")
        voice.reset()
        print("PASS: two-phase Q&A rechecks native calendar permission after classification and sends no revoked evidence to synthesis")

        // History Retry bypasses VoiceController. Neither the durable queue nor
        // a later execution attempt may reuse its original EventKit snapshot.
        store.calendar.seedPreview()
        store.calendar.changeKnowledgeEventForChecks(id: "project-checkpoint", title: privateCanary)
        let queuedSnapshot = store.calendar.knowledgeSnapshot(question: "Что нужно для стенда и когда встреча?")
        let retryQuestion: [String: Any] = ["text": "Что нужно для стенда и когда встреча?", "query": "стенд",
            "questionOnly": true, "now": Date().timeIntervalSince1970, "timeZoneOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            "calendar": try JSONSerialization.jsonObject(with: JSONEncoder().encode(queuedSnapshot))]
        let retryInput = try JSONSerialization.data(withJSONObject: retryQuestion, options: [.sortedKeys])
        var changedSnapshot = retryQuestion; changedSnapshot["calendar"] = ["connected": false, "events": []]
        let changedSnapshotInput = try JSONSerialization.data(withJSONObject: changedSnapshot, options: [.sortedKeys])
        let persisted = try AppStore.persistableJobInput(command: "voice-plan", input: retryInput)
        try expect(persisted == AppStore.persistableJobInput(command: "voice-plan", input: changedSnapshotInput),
                   "Volatile calendar evidence changed the canonical queued request or its revision")
        try fixture("askKnowledge", query: "стенд")
        var failingQuestion = try JSONSerialization.jsonObject(with: Data(contentsOf: knowledgeResponse)) as! [String: Any]
        failingQuestion["knowledge"] = ["title": "Invalid fixture", "paragraphs": "invalid"]
        try JSONSerialization.data(withJSONObject: failingQuestion).write(to: knowledgeResponse)
        do {
            _ = try await store.worker("voice-plan", input: retryInput)
            throw AppError.message("Invalid question fixture unexpectedly succeeded")
        } catch {
            try expect(error.localizedDescription != "Invalid question fixture unexpectedly succeeded", "Question retry fixture did not fail")
        }
        try await waitUntil { store.jobs.jobs.contains { $0.kind == "voice-plan" && $0.state == "failed" && $0.config.input == persisted } }
        guard let failedQuestion = store.jobs.jobs.first(where: { $0.kind == "voice-plan" && $0.state == "failed" && $0.config.input == persisted }),
              let savedQuestionInput = failedQuestion.config.input,
              let savedQuestion = try JSONSerialization.jsonObject(with: savedQuestionInput) as? [String: Any] else {
            throw AppError.message("Durable failed question job missing")
        }
        try expect(savedQuestion["calendar"] == nil && !String(decoding: savedQuestionInput, as: UTF8.self).contains(privateCanary),
                   "The durable queue retained a private calendar snapshot")
        store.calendar.disconnect()
        try fixture("askKnowledge", query: "стенд")
        try? FileManager.default.removeItem(at: knowledgeStarted)
        store.jobs.retry(failedQuestion)
        try await waitUntil { store.jobs.jobs.contains { $0.id == failedQuestion.id && $0.attempt == failedQuestion.attempt + 1 && $0.state == "succeeded" } }
        let retryPrompt = try String(contentsOf: knowledgeStarted, encoding: .utf8)
        try expect(!retryPrompt.contains(privateCanary), "History Retry sent revoked persisted calendar evidence to synthesis")
        try expect(store.jobs.jobs.first { $0.id == failedQuestion.id }?.inputRevision == failedQuestion.inputRevision,
                   "Refreshing volatile calendar evidence invalidated the original question revision")
        try expect(try Data(contentsOf: workspaceURL) == beforeCalendarQuestion, "Question history retry modified notes or tasks")
        print("PASS: question queue persists only the request; History Retry refreshes revoked calendar access without changing its revision")

        // The search controller must reject a source changed after its result
        // was shown, then navigate only from a fresh result. Debounce cancellation
        // cannot repopulate a dismissed search sheet.
        let search = KnowledgeSearchController()
        store.showingSearch = true; store.librarySection = "tasks"
        search.update(store: store, query: "стенд", scope: "notes", immediate: true)
        try await waitUntil { !search.searching }
        let staleSearchSource = try required(search.sources.first { $0.noteID == noteID }, "Search note source: \(search.error ?? "")")
        var searchEdited = try required(store.notes.notes.first { $0.id == noteID }, "Search fixture note")
        searchEdited.text += "\nУточнение после показа результатов поиска."
        _ = store.notes.save(searchEdited)
        search.open(staleSearchSource, store: store)
        try await waitUntil { search.openingID == nil }
        try expect(search.error != nil && store.showingSearch && store.librarySection == "tasks", "Stale search source navigated despite its changed fingerprint")
        search.update(store: store, query: "стенд", scope: "notes", immediate: true)
        try await waitUntil { !search.searching }
        let freshSearchSource = try required(search.sources.first { $0.noteID == noteID }, "Refreshed search source")
        search.open(freshSearchSource, store: store)
        try await waitUntil { search.openingID == nil }
        try expect(search.error == nil && !store.showingSearch && store.librarySection == "inbox" && store.notes.selectedNoteID == noteID, "Fresh search did not open the exact saved note")
        search.update(store: store, query: "стенд", scope: "notes", immediate: false)
        search.cancel()
        try await Task.sleep(for: .milliseconds(450))
        try expect(!search.searching && search.sources.isEmpty && search.openingID == nil, "Cancelled debounced search published a late result")
        print("PASS: native knowledge search rejects stale sources, opens fresh notes and cancels debounced work")

        func libraryFixture(delay: Double = 0) throws {
            let data = try RustBridge.shared.get().request(root: root, command: "knowledge-search", arguments: ["text": "стенд", "query": "стенд", "kinds": ["note"]])
            let found = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let sources = found["sources"] as? [[String: Any]] ?? []
            let selected = try required(sources.first { $0["noteID"] as? String == noteID }, "Library navigation source")
            try fixture("openNote", query: "стенд")
            let file = root.appendingPathComponent("fixture-response.json")
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            value["reranking"] = ["matches": [["id": selected["id"]!, "reason": "Заметка о доступе к стенду"]], "clarification": ""]
            value["rerankingDelay"] = delay
            try JSONSerialization.data(withJSONObject: value).write(to: file)
        }
        try libraryFixture()
        let beforeOpen = try required(store.notes.notes.first { $0.id == noteID }, "Read-only navigation note")
        store.librarySection = "tasks"
        prepare("Найди и открой заметку про доступ к стенду")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy && voice.knowledgeOpeningID == nil }
        try expect(voice.result?.target.kind == "librarySource" && voice.result?.target.source?.noteID == noteID,
                   "Two-pass native navigation did not return a typed, validated note source: \(voice.message ?? "")")
        try expect(!voice.isPresented && store.librarySection == "inbox" && store.notes.selectedNoteID == noteID, "Found note did not open in its native destination")
        try expect(store.notes.notes.first { $0.id == noteID }?.revision == beforeOpen.revision, "Opening a note changed its content or revision")
        print("PASS: native assistant retrieves, revalidates and opens the exact note without editing it")

        try libraryFixture(delay: 1)
        let rankStarted = root.appendingPathComponent("fixture-reranking-started.json")
        try? FileManager.default.removeItem(at: rankStarted)
        store.librarySection = "tasks"
        prepare("Найди заметку про доступ к стенду")
        voice.perform()
        try await waitUntil { FileManager.default.fileExists(atPath: rankStarted.path) }
        var changedDuringRanking = try required(store.notes.notes.first { $0.id == noteID }, "Ranking fixture note")
        changedDuringRanking.text += "\nИсточник изменился во время выбора."
        _ = store.notes.save(changedDuringRanking)
        try await waitUntil { !voice.isWorking && !store.busy && voice.knowledgeOpeningID == nil }
        try expect(voice.phase == .editing && voice.result == nil && voice.message != nil && store.librarySection == "tasks",
                   "A note changed during reranking was opened using a stale source")
        voice.reset()
        print("PASS: in-flight reranking rejects changed evidence before native source navigation")

        // Restored conversations may contain long multibyte questions from an
        // older build. The real planner must receive the newest whole topics
        // within the same byte limits used by Rust, without replaying answers.
        let multibyteTopics = (0..<6).map { "Вопрос \($0): " + String(repeating: "🧠", count: 400) }
        _ = try RustBridge.shared.get().request(root: root, command: "write", arguments: ["path": "voice-draft.json", "value": [
            "text": "Что известно про стенд? " + String(repeating: "🧠", count: 400),
            "contextLabel": "Продолжение разговора", "previousQuestions": multibyteTopics
        ]])
        let restoredConversation = VoiceCommandController(); restoredConversation.connect(store); restoredConversation.present()
        try fixture("askKnowledge", query: "стенд")
        restoredConversation.perform(); try await waitUntil { !restoredConversation.isWorking && !store.busy }
        try expect(restoredConversation.knowledgeAnswer != nil, "Restored multibyte history failed the actual planner: \(restoredConversation.message ?? "")")
        let multibytePrompt = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture-classification-started.json"))) as! [String: Any]
        let retained = multibytePrompt["previous_questions"] as? [String] ?? []
        try expect(!retained.isEmpty && retained.count <= 6 && retained.allSatisfy { $0.utf8.count <= 1500 } && retained.reduce(0, { $0 + $1.utf8.count }) <= 5000,
                   "Restored history exceeded per-topic or total UTF-8 limits")
        try expect(retained.last?.hasPrefix("Вопрос 5:") == true, "Conversation budget dropped the newest user topic")
        restoredConversation.continueQuestion(); restoredConversation.text = "А что проверить дальше?"; _ = restoredConversation.flushDraft()
        let continuedDraft = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("voice-draft.json"))) as! [String: Any]
        let continuedTopics = continuedDraft["previousQuestions"] as? [String] ?? []
        try expect(continuedTopics.allSatisfy { $0.utf8.count <= 1500 } && continuedTopics.reduce(0, { $0 + $1.utf8.count }) <= 5000,
                   "Appending a multibyte user question exceeded durable history limits")
        restoredConversation.reset(); restoredConversation.dismiss()
        print("PASS: restored and continued emoji conversations stay within core UTF-8 budgets")

        let count = store.notes.notes.count
        try fixture("unsupported", text: "Уточните, какую заметку нужно изменить.")
        prepare("Поменяй там всё")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.phase == .editing && store.notes.notes.count == count, "Unsupported command cannot mutate data")
        try JSONSerialization.data(withJSONObject: ["content": "invalid JSON"]).write(to: root.appendingPathComponent("fixture-response.json"))
        prepare("Создай заметку")
        voice.perform(); try await waitUntil { !voice.isWorking && !store.busy }
        try expect(voice.message != nil && !voice.isWorking && store.notes.notes.count == count, "Invalid model response releases controls and preserves data")
        print("PASS: unsupported and malformed responses do not mutate the library")
        try fixture("createNote", text: "Эта заметка не должна появиться", title: "Отменённая команда")
        let responseURL = root.appendingPathComponent("fixture-response.json")
        var delayed = try JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as! [String: Any]
        delayed["delay"] = 2
        try JSONSerialization.data(withJSONObject: delayed).write(to: responseURL)
        prepare("Создай заметку, которую сейчас отменим")
        voice.perform()
        try await waitUntil { store.jobs.jobs.contains { $0.kind == "voice-plan" && $0.active } }
        guard let planning = store.jobs.jobs.first(where: { $0.kind == "voice-plan" && $0.active }) else {
            throw AppError.message("Delayed real planning job missing")
        }
        try expect(voice.phase == .planning && !store.busy, "Delayed planning must stay independent of exclusive UI work")
        voice.cancelWork()
        try expect(!voice.isWorking && !voice.text.isEmpty, "Cancel must immediately release voice controls and retain the command")
        try await waitUntil { store.jobs.jobs.contains { $0.id == planning.id && $0.state == "cancelled" } && store.jobs.activeCount == 0 }
        try await Task.sleep(for: .milliseconds(2200))
        try expect(!voice.isWorking && !store.busy && store.notes.notes.count == count && !voice.text.isEmpty && voice.result == nil,
                   "A cancelled planner's late HTTP response must not apply a mutation or drop the command")
        try notesDraftCheck(store: store)
        print("PASS: cancelling real delayed HTTP planning drains safely and preserves draft")
        prepare(String(repeating: "Длинный черновик. ", count: 700))
        let longDraft = voice.text
        try expect(voice.flushDraft(), "Draft should persist")
        let reopened = AppStore(preview: true)
        try expect(reopened.voice.text == longDraft && !reopened.voice.isWorking, "Reopen must preserve full draft without truncation or microphone access")
        voice.reset(); _ = voice.flushDraft()
        print("PASS: crash recovery keeps committed operation identity; long drafts survive reopening intact")
        print("23 native voice E2E groups passed")
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
