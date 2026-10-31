import AfterLocalization
import SwiftUI

/// The release catalogue supplies both navigation and counts. No generated
/// copy, enabled state or settings route is invented by the presentation.
struct ReleaseNotesView: View {
    @ObservedObject var controller: GuidanceController
    @FocusState private var focusedFeature: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(Ink.paper).tint(Ink.accent).appControlDefaults()
        .onAppear { controller.markSelectedRead() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: BrandArtwork.menuBarImage()).renderingMode(.template).resizable()
                .scaledToFit().frame(width: 30, height: 30).padding(12)
                .foregroundStyle(Color.primary).background(Ink.soft, in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(LF("Что нового в After {0}", arguments: [controller.releaseVersion]))
                    .font(AppTypography.modalTitle).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("releases.title")
                Text(versionDescription).font(AppTypography.control).foregroundStyle(Ink.secondaryText)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("releases.version")
                HStack(spacing: 18) {
                    count(controller.changeCounts.added, title: L("Добавлено"), icon: "plus.circle")
                    count(controller.changeCounts.changed, title: L("Изменено"), icon: "arrow.triangle.2.circlepath")
                    count(controller.changeCounts.fixed, title: L("Исправлено"), icon: "checkmark.circle")
                }.padding(.top, 3).accessibilityIdentifier("releases.counts")
            }
            Spacer(minLength: 0)
            Button { controller.complete() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .accessibilityLabel(L("Закрыть")).accessibilityIdentifier("releases.close")
        }.padding(22)
    }

    private var versionDescription: String {
        if let previous = controller.previousVersion, controller.previousVersionIsExact {
            return LF("Обновлено с версии {0}", arguments: [previous])
        }
        if let previous = controller.previousVersion {
            return LF("Изменения после версии {0}", arguments: [previous])
        }
        return L("Изменения в этой версии")
    }

    private func count(_ value: Int, title: String, icon: String) -> some View {
        Label("\(title) · \(value)", systemImage: icon)
            .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(controller.featureGroups) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L(section.group.titleKey)).font(AppTypography.captionStrong)
                            .foregroundStyle(Ink.secondaryText).padding(.horizontal, 11).padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.updates) { update in featureButton(update) }
                    }
                }
            }.padding(12)
        }.background(Ink.soft).accessibilityIdentifier("releases.features")
    }

    private func featureButton(_ update: ReleaseFeatureUpdate) -> some View {
        let selected = controller.selectedFeatureID == update.id
        return Button { select(update.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: update.icon).frame(width: 18).foregroundStyle(selected ? Color.primary : Ink.secondaryText)
                Text(L(update.titleKey)).font(selected ? AppTypography.controlStrong : AppTypography.control)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                if controller.isUnread(update.id) {
                    Circle().fill(Ink.accent).frame(width: 5, height: 5).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.primary)
        .focusable().focused($focusedFeature, equals: update.id)
        .accessibilityLabel(L(update.titleKey)).accessibilityValue(selected ? L("Выбрана") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("releases.feature." + update.id)
        .onKeyPress(keys: [.upArrow, .downArrow, .home, .end]) { key in navigate(key, from: update.id) }
    }

    @ViewBuilder private var detail: some View {
        if let update = controller.selectedFeature {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: update.icon).font(.system(size: 24)).foregroundStyle(Ink.accent).frame(width: 30)
                                Text(L(update.titleKey)).font(AppTypography.sectionTitle)
                                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                                    .accessibilityIdentifier("releases.detail.title")
                            }
                            if isDisabled(update.id) {
                                Text(L("Эта возможность выключена. Включите её в настройках, когда она понадобится."))
                                    .font(AppTypography.body).foregroundStyle(Ink.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if update.isNewFeature {
                                Label(L("Новая возможность"), systemImage: "sparkles")
                                    .font(AppTypography.captionStrong).foregroundStyle(Ink.secondaryText)
                            }
                            Button { controller.openFeatureSettings(update.id) } label: {
                                Label(isDisabled(update.id) ? L("Включить в настройках") : L("Открыть настройки"), systemImage: "slider.horizontal.3")
                            }.buttonStyle(.bordered).accessibilityIdentifier("releases.settings")
                        }.id("detail-top")
                        ForEach([ReleaseChangeKind.added, .changed, .fixed], id: \.self) { kind in
                            let changes = update.changes.filter { $0.kind == kind }
                            if !changes.isEmpty { changeSection(kind, changes: changes) }
                        }
                    }.padding(AppLayout.contentInset).frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("releases.detail")
                .onChange(of: controller.selectedFeatureID) { _, _ in proxy.scrollTo("detail-top", anchor: .top) }
            }
        } else {
            Text(L("Выберите возможность слева, чтобы прочитать изменения."))
                .font(AppTypography.body).foregroundStyle(Ink.secondaryText).padding(28)
        }
    }

    private func changeSection(_ kind: ReleaseChangeKind, changes: [ReleaseChange]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(kindTitle(kind), systemImage: kindIcon(kind)).font(AppTypography.heading)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                HStack(alignment: .top, spacing: 11) {
                    Circle().fill(Ink.secondaryText.opacity(0.55)).frame(width: 4, height: 4).padding(.top, 8).accessibilityHidden(true)
                    Text(L(change.textKey)).font(AppTypography.body).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("releases.change.\(kind).\(index)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("Подсказки по ходу работы"), isOn: Binding(get: { controller.hintsEnabled }, set: { controller.setHintsEnabled($0) }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("releases.hints")
                if let error = controller.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
            }
            Spacer(minLength: 0)
            Button(L("Поддержать After…")) { controller.complete(with: .support) }
                .buttonStyle(.borderless).font(AppTypography.control).accessibilityIdentifier("releases.support")
            Button(L("Понятно")) { controller.complete() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("releases.done")
        }.padding(.horizontal, 22).padding(.vertical, 14)
    }

    private func isDisabled(_ id: String) -> Bool {
        controller.featureGroups.contains { $0.group == .disabled && $0.updates.contains { $0.id == id } }
    }
    private func select(_ id: String) { controller.selectFeature(id); focusedFeature = id }
    private func navigate(_ key: KeyPress, from id: String) -> KeyPress.Result {
        guard key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        let ids = controller.featureGroups.flatMap(\.updates).map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = ids.firstIndex(of: id) ?? 0
        let index = key.key == .home ? 0 : key.key == .end ? ids.count - 1
            : min(ids.count - 1, max(0, current + (key.key == .downArrow ? 1 : -1)))
        select(ids[index]); return .handled
    }
    private func kindTitle(_ kind: ReleaseChangeKind) -> String {
        switch kind { case .added: return L("Добавлено"); case .changed: return L("Изменено"); case .fixed: return L("Исправлено") }
    }
    private func kindIcon(_ kind: ReleaseChangeKind) -> String {
        switch kind { case .added: return "plus.circle"; case .changed: return "arrow.triangle.2.circlepath"; case .fixed: return "checkmark.circle" }
    }
}
