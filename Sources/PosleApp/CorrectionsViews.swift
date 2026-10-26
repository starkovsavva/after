import SwiftUI
import PosleCore

private struct MeetingContentSnapshot: Decodable {
    var transcript: Transcript?
    var transcriptFingerprint: String
    var summary: Summary?
    var summaryFingerprint: String
}

struct TranscriptSegmentEditor: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let meetingID: String
    let segmentID: Int
    @State private var snapshot: MeetingContentSnapshot?
    @State private var text = ""
    @State private var speaker = ""
    @State private var saving = false
    @State private var editorID = UUID()
    @State private var confirmingDiscard = false
    @State private var error: String?
    private var dirty: Bool {
        guard let original = snapshot?.transcript?.segments.first(where: { $0.id == segmentID }) else { return false }
        return text != original.text || speaker != original.speaker
    }
    private var speakers: [String] { Array(Set(snapshot?.transcript?.segments.map(\.speaker) ?? [])).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeader(title: "Изменить реплику", modal: true)
            if snapshot != nil {
                Picker("Собеседник", selection: $speaker) {
                    ForEach(speakers, id: \.self) { value in Text(app.meetings.first(where: { $0.id == meetingID })?.speakerName(value) ?? value).tag(value) }
                }
                TextEditor(text: $text).font(AppTypography.body).frame(minHeight: 180).padding(8)
                    .background(Ink.field, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Текст реплики").accessibilityIdentifier("transcript.edit.text")
                Text("Таймкод и исходная запись сохранятся. Конспект можно обновить после исправлений.")
                    .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            } else if error == nil { ProgressView() }
            if let error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled).accessibilityIdentifier("transcript.edit.error") }
            HStack {
                Button("Отмена", role: .cancel) { if dirty { confirmingDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction).accessibilityIdentifier("transcript.edit.cancel")
                Spacer()
                Button("Сохранить") { save() }.buttonStyle(.borderedProminent)
                    .disabled(snapshot == nil || saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("transcript.edit.save")
            }
        }.padding(24).frame(width: 580).appControlDefaults().tint(Ink.accent).disabled(saving).task { await load() }
            .interactiveDismissDisabled(dirty || saving)
            .onChange(of: dirty) { _, value in UnsavedEditorRegistry.set(id: editorID, title: "Правка реплики", dirty: value) }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .confirmationDialog("Отменить правки реплики?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Продолжить редактирование", role: .cancel) {}
                Button("Отменить правки", role: .destructive) { UnsavedEditorRegistry.remove(id: editorID); dismiss() }.accessibilityIdentifier("transcript.edit.discard")
            }
    }
    private func load() async {
        do {
            let root = app.root
            let value = try await Task.detached {
                let data = try RustBridge.shared.get().request(root: root, command: "meeting-content-snapshot", arguments: ["meetingID": meetingID])
                return try JSONDecoder().decode(MeetingContentSnapshot.self, from: data)
            }.value
            guard let segment = value.transcript?.segments.first(where: { $0.id == segmentID }) else { throw AppError.message("Реплика изменилась или удалена. Откройте транскрипт заново.") }
            snapshot = value; text = segment.text; speaker = segment.speaker
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard let snapshot else { return }
        saving = true; error = nil
        let root = app.root, text = text, speaker = speaker
        Task {
            defer { saving = false }
            do {
                _ = try await Task.detached {
                    try RustBridge.shared.get().request(root: root, command: "transcript-segment-save", arguments: [
                        "meetingID": meetingID, "segmentID": segmentID, "text": text, "speaker": speaker,
                        "expectedFingerprint": snapshot.transcriptFingerprint
                    ])
                }.value
                app.refreshResults(meetingID); app.notes.reload(); app.notes.loadTasks()
                app.notice = "Реплика сохранена. Проверьте связанные выводы конспекта."
                UnsavedEditorRegistry.remove(id: editorID); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct SummaryInsightEditor: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let meetingID: String
    let itemIndex: Int
    @State private var snapshot: MeetingContentSnapshot?
    @State private var text = ""
    @State private var owner = ""
    @State private var due = ""
    @State private var saving = false
    @State private var editorID = UUID()
    @State private var confirmingDiscard = false
    @State private var error: String?
    private var originalItem: Insight? {
        guard let items = snapshot?.summary?.items, items.indices.contains(itemIndex) else { return nil }
        return items[itemIndex]
    }
    private var dirty: Bool { originalItem.map { text != $0.text || owner != $0.owner || due != $0.due } ?? false }
    private var selectedDate: Binding<Date> {
        Binding(get: {
            let reference = app.meetings.first(where: { $0.id == meetingID }).map { Date(timeIntervalSince1970: $0.createdAt) }
            return TaskDueDate.resolve(due, reference: reference) ?? Date()
        }, set: { due = TaskDueDate.storage($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeader(title: "Изменить пункт конспекта", modal: true)
            if snapshot != nil {
                TextEditor(text: $text).font(AppTypography.body).frame(minHeight: 130).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Текст пункта").accessibilityIdentifier("summary.edit.text")
                if originalItem?.kind == "action" {
                    TextField("Ответственный", text: $owner).textFieldStyle(.roundedBorder)
                    HStack {
                        if !due.isEmpty { DatePicker("Срок", selection: selectedDate, displayedComponents: .date).environment(\.locale, Locale(identifier: "ru_RU")) }
                        else { Text("Без срока").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Сегодня") { due = TaskDueDate.storage(Date()) }
                        Button("Завтра") { due = TaskDueDate.storage(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) }
                        Button("Без срока") { due = "" }
                    }.font(AppTypography.control)
                }
                Text("Связь с исходными репликами сохранится.").font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            } else if error == nil { ProgressView() }
            if let error { Text(error).foregroundStyle(Ink.warning).textSelection(.enabled).accessibilityIdentifier("summary.edit.error") }
            HStack {
                Button("Отмена", role: .cancel) { if dirty { confirmingDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction).accessibilityIdentifier("summary.edit.cancel")
                Spacer()
                Button("Сохранить") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(snapshot == nil || saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("summary.edit.save")
            }
        }.padding(24).frame(width: 560).appControlDefaults().tint(Ink.accent).disabled(saving).task { await load() }
            .interactiveDismissDisabled(dirty || saving)
            .onChange(of: dirty) { _, value in UnsavedEditorRegistry.set(id: editorID, title: "Правка пункта конспекта", dirty: value) }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .confirmationDialog("Отменить правки пункта?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Продолжить редактирование", role: .cancel) {}
                Button("Отменить правки", role: .destructive) { UnsavedEditorRegistry.remove(id: editorID); dismiss() }.accessibilityIdentifier("summary.edit.discard")
            }
    }
    private func load() async {
        do {
            let root = app.root
            let value = try await Task.detached {
                let data = try RustBridge.shared.get().request(root: root, command: "meeting-content-snapshot", arguments: ["meetingID": meetingID])
                return try JSONDecoder().decode(MeetingContentSnapshot.self, from: data)
            }.value
            guard let summary = value.summary, summary.items.indices.contains(itemIndex) else { throw AppError.message("Пункт изменился. Откройте конспект заново.") }
            let item = summary.items[itemIndex]; text = item.text; owner = item.owner; due = item.due; snapshot = value
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard let snapshot else { return }
        let root = app.root, text = text, owner = owner, due = due
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                _ = try await Task.detached {
                    try RustBridge.shared.get().request(root: root, command: "summary-item-save", arguments: [
                        "meetingID": meetingID, "itemIndex": itemIndex, "text": text, "owner": owner, "due": due,
                        "expectedFingerprint": snapshot.summaryFingerprint
                    ])
                }.value
                app.refreshResults(meetingID); app.notes.reload(); app.notes.loadTasks(); UnsavedEditorRegistry.remove(id: editorID); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
