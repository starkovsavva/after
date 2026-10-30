import SwiftUI

struct GuidanceSheet: View {
    @ObservedObject var controller: GuidanceController
    @State private var showsGettingStarted: Bool
    init(controller: GuidanceController) {
        self.controller = controller
        _showsGettingStarted = State(initialValue: controller.presentation == .gettingStarted)
    }
    var body: some View {
        if showsGettingStarted {
            gettingStarted
        } else {
            ReleaseNotesView(controller: controller).frame(width: 940, height: 680)
        }
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                AppPageHeader(title: L("Начните со встречи"), modal: true)
                Button { controller.complete() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(L("Закрыть"))
            }
            Text(L("Запишите звонок или добавьте готовое аудио. After соберёт транскрипт и конспект со ссылками на реплики. Дополнительные возможности можно включить в настройках."))
                .font(AppTypography.body).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button { controller.complete(with: .record) } label: { Label(L("Записать встречу"), systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                Button { controller.complete(with: .importFile) } label: { Label(L("Добавить файл…"), systemImage: "arrow.down.doc") }.buttonStyle(.bordered)
            }
            Button(L("Выбрать локальную или облачную модель")) { controller.complete(with: .speechSettings) }.buttonStyle(.borderless)
            Divider()
            HStack(spacing: 14) {
                Toggle(L("Подсказки по ходу работы"), isOn: Binding(get: { controller.hintsEnabled }, set: { controller.setHintsEnabled($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button(L("Позже")) { controller.complete() }
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            }
            if let error = controller.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.padding(28).frame(width: 580).appControlDefaults().tint(Ink.accent).background(Ink.paper)
    }
}

