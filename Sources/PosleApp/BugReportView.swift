import SwiftUI

struct BugReportView: View {
    @ObservedObject var session: BugReportSession
    let copy: () -> Void
    let save: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "ladybug").font(.system(size: 25)).foregroundStyle(Ink.secondaryText).accessibilityHidden(true)
                        AppPageHeader(title: "Сообщить об ошибке", subtitle: "Скопируйте отчёт и отправьте его сообщением разработчику.", modal: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Что произошло? Обязательно").font(AppTypography.controlStrong)
                        TextField("Например, поручение не выполняется", text: $session.draft.actual, axis: .vertical)
                            .lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityLabel("Что произошло").accessibilityIdentifier("bugReport.actual")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Что ожидалось? Необязательно").font(AppTypography.controlStrong)
                        TextField("Какой результат вы хотели получить", text: $session.draft.expected, axis: .vertical)
                            .lineLimit(2...3).textFieldStyle(.roundedBorder).accessibilityLabel("Что ожидалось").accessibilityIdentifier("bugReport.expected")
                    }
                    Text("Добавляются версия приложения, macOS, тип обработки и код последней ошибки. Записи, заметки, аккаунты и ключи не собираются. Проверьте свой текст и не вставляйте секреты.")
                        .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Состав отчёта", isExpanded: $session.previewExpanded) {
                        Text(session.document.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
                            .accessibilityIdentifier("bugReport.preview")
                    }.accessibilityIdentifier("bugReport.previewDisclosure")
                    if session.draft.tooLong {
                        Text("Сократите каждое поле до 8 000 символов, чтобы скопировать или сохранить отчёт.")
                            .font(AppTypography.caption).foregroundStyle(Ink.warning).accessibilityIdentifier("bugReport.validation")
                    }
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let failure = session.failure {
                    Text(failure).font(AppTypography.caption).foregroundStyle(Ink.warning)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("bugReport.failure")
                }
                if let status = session.status {
                    Label(status, systemImage: "checkmark.circle").font(AppTypography.caption).foregroundStyle(Ink.green)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("bugReport.status")
                }
                HStack(spacing: 10) {
                    Button("Закрыть", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("bugReport.close")
                    Spacer(minLength: 12)
                    Button("Сохранить…", action: save).disabled(!session.draft.isValid).accessibilityIdentifier("bugReport.save")
                    Button("Скопировать отчёт", action: copy).buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        .disabled(!session.draft.isValid).keyboardShortcut(.defaultAction).accessibilityIdentifier("bugReport.copy")
                }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(minWidth: 570, minHeight: 480).appControlDefaults().tint(Ink.accent).background(Ink.paper)
    }
}
