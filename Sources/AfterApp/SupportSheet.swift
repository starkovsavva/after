import AfterLocalization
import SwiftUI

struct SupportSheet: View {
    let close: () -> Void
    let feedback: () -> Void
    private let github = URL(string: "https://github.com/starkovsavva/after")!

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "heart.fill").font(.system(size: 25)).foregroundStyle(Ink.accent)
                    .frame(width: 60, height: 60).background(Ink.accent.opacity(0.08), in: Circle())
                    .accessibilityHidden(true)
                Text(L("Помогите After развиваться")).font(AppTypography.modalTitle)
                Spacer()
            }
            Text(L("After — бесплатный проект с открытым кодом. Если приложение помогает вам в работе, звезда на GitHub и обратная связь помогут сделать его лучше."))
                .font(AppTypography.body).foregroundStyle(Ink.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link(destination: github) { Label(L("Поставить звезду на GitHub"), systemImage: "star") }
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .accessibilityIdentifier("support.github")
                Button(L("Обратная связь…"), action: feedback).buttonStyle(.bordered)
                    .accessibilityIdentifier("support.feedback")
            }
            Text(L("Спасибо, что помогаете After становиться лучше."))
                .font(AppTypography.control).foregroundStyle(Ink.secondaryText)
            HStack {
                Spacer()
                Button(L("Готово"), action: close).buttonStyle(.bordered).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("support.close")
            }
        }.padding(28).frame(width: 680).background(Ink.paper).tint(Ink.accent).appControlDefaults()
            .onExitCommand(perform: close)
    }
}
