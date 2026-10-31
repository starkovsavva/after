import AfterLocalization
import SwiftUI

/// Personal vocabulary and role are opt-in framing, never facts about a meeting.
struct SummaryContextSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("О себе для конспектов")).font(AppTypography.heading)
            Text(L("Роль, проекты и рабочие термины помогут выделить главное. Необязательно."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { store.settings.summaryUserContext }, set: { value in
                store.settings.summaryUserContext = String(value.prefix(500))
            }))
                .font(AppTypography.control).frame(height: 90).padding(8)
                .scrollContentBackground(.hidden)
                .background(Ink.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
                .accessibilityLabel(L("О себе для конспектов"))
                .accessibilityHint(L("Необязательный контекст: роль, проекты и термины. До 500 символов."))
            Text(L("Учитывается при создании новых конспектов. В облачном режиме отправляется выбранному провайдеру вместе с текстом встречи."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
