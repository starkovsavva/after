import AfterCore
import AfterLocalization
import SwiftUI

/// One extensible entry point for library conditions. Editing a popover draft
/// never changes the library until its owner accepts the complete selection.
struct MaterialFiltersControl: View {
    @Binding var selection: MaterialFilterSet
    let target: MaterialFilterTarget
    let topics: [MaterialFilterTopic]
    let topicsLoading: Bool
    let onLoadTopics: () -> Void
    let identifier: String
    var canLoadMoreTopics = false
    var onLoadMoreTopics: () -> Void = {}
    @State private var showing = false
    @State private var draft = MaterialFilterSet()
    @State private var fields = Set<Field>()
    @State private var topicQuery = ""
    @State private var rejected = false

    private enum Field: String, CaseIterable, Identifiable {
        case origin, topic, kind
        var id: String { rawValue }
    }
    private var availableFields: [Field] { Field.allCases }
    private var kinds: [(value: String, title: String)] {
        target == .cards ? [("phrase", L("Фраза")), ("concept", L("Понятие"))]
            : [("note", L("Заметка")), ("important", L("Важно")), ("question", L("Вопрос")), ("task", L("Задача"))]
    }
    private var filteredTopics: [MaterialFilterTopic] {
        availableTopics.filter { topicQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(topicQuery) }
    }
    private var availableTopics: [MaterialFilterTopic] { target == .cards ? topics.filter { !$0.meetingIDs.isEmpty } : topics }

    var body: some View {
        AfterControlFlow {
            Button { open() } label: {
                Label(selection.activeCount == 0 ? L("Фильтры") : LF("Фильтры · {0}", arguments: [String(selection.activeCount)]), systemImage: "line.3.horizontal.decrease")
            }.buttonStyle(AfterSoftButtonStyle()).accessibilityIdentifier(identifier + ".button")
                .accessibilityValue(String(selection.activeCount))
                .popover(isPresented: $showing, arrowEdge: .bottom) { editor }
            ForEach(activeFields(selection)) { field in
                HStack(spacing: 5) {
                    Button { open() } label: { Text(chipTitle(field)).lineLimit(2).multilineTextAlignment(.leading) }
                        .buttonStyle(.plain).accessibilityIdentifier(identifier + ".chip." + field.rawValue)
                    Button { var value = selection; remove(field, from: &value); selection = value } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 22)
                    }.buttonStyle(.plain).accessibilityLabel(L("Удалить условие") + ": " + title(field))
                        .accessibilityIdentifier(identifier + ".remove." + field.rawValue)
                }.font(AppTypography.caption).padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 4)
                    .frame(maxWidth: 280).fixedSize(horizontal: true, vertical: false)
                    .background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: AppLayout.controlRadius).strokeBorder(Ink.line))
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Фильтры")).font(AppTypography.heading).accessibilityIdentifier(identifier + ".popover")
                Spacer()
                Button(L("Очистить")) { draft = MaterialFilterSet(); fields = []; rejected = false }
                    .buttonStyle(.plain).disabled(fields.isEmpty).accessibilityIdentifier(identifier + ".clear")
            }
            Text(L("Между условиями — «И», внутри одного условия — «ИЛИ»."))
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(availableFields.filter { fields.contains($0) }) { field in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(title(field)).font(AppTypography.controlStrong)
                                Spacer()
                                Button { fields.remove(field); remove(field, from: &draft); rejected = false } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).accessibilityLabel(L("Удалить условие") + ": " + title(field))
                                    .accessibilityIdentifier(identifier + ".row.remove." + field.rawValue)
                            }
                            fieldEditor(field)
                        }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
                    }
                    if fields.isEmpty {
                        Text(L("Добавьте условие, чтобы сузить список."))
                            .font(AppTypography.control).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
            }.frame(minHeight: 48, maxHeight: 420).fixedSize(horizontal: false, vertical: true)
            Menu {
                ForEach(availableFields.filter { !fields.contains($0) }) { field in
                    Button(title(field)) {
                        fields.insert(field); rejected = false
                        if field == .topic { onLoadTopics() }
                    }.accessibilityIdentifier(identifier + ".add." + field.rawValue)
                }
            } label: { Label(L("Добавить условие"), systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier(identifier + ".add")
                .disabled(availableFields.allSatisfy { fields.contains($0) })
            if rejected {
                Text(L("Не удалось применить фильтры. Проверьте открытые правки."))
                    .font(AppTypography.caption).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Отмена")) { showing = false }.keyboardShortcut(.cancelAction)
                    .buttonStyle(AfterSoftButtonStyle()).accessibilityIdentifier(identifier + ".cancel")
                Spacer()
                Button(L("Применить")) {
                    let candidate = draft
                    selection = candidate
                    if selection == candidate { showing = false } else { rejected = true }
                }.buttonStyle(AfterSoftButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(identifier + ".apply")
            }
        }.padding(20).frame(width: 440).background(Ink.paper).appControlDefaults()
    }

    @ViewBuilder private func fieldEditor(_ field: Field) -> some View {
        switch field {
        case .origin:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(MaterialCreationOrigin.allCases, id: \.self) { origin in
                    Toggle(L(origin.titleKey), isOn: Binding(get: { draft.origins.contains(origin) }, set: { enabled in
                        if enabled { draft.origins.insert(origin) } else { draft.origins.remove(origin) }
                    })).toggleStyle(.checkbox).accessibilityIdentifier(identifier + ".origin." + origin.rawValue)
                }
            }
        case .kind:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(kinds, id: \.value) { kind in
                    Toggle(kind.title, isOn: Binding(get: { draft.kinds.contains(kind.value) }, set: { enabled in
                        if enabled { draft.kinds.insert(kind.value) } else { draft.kinds.remove(kind.value) }
                    })).toggleStyle(.checkbox).accessibilityIdentifier(identifier + ".kind." + kind.value)
                }
                ForEach(draft.kinds.filter { value in !kinds.contains { $0.value == value } }.sorted(), id: \.self) { value in
                    Toggle(kindTitle(value), isOn: Binding(get: { draft.kinds.contains(value) }, set: { enabled in
                        if !enabled { draft.kinds.remove(value) }
                    })).toggleStyle(.checkbox).accessibilityIdentifier(identifier + ".kind." + value)
                }
            }
        case .topic:
            VStack(alignment: .leading, spacing: 9) {
                if target == .cards {
                    Text(L("Карточки из встреч, которые входят в выбранные темы. Тема относится к источнику карточки."))
                        .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                TextField(L("Найти тему"), text: $topicQuery).afterSearchField()
                    .accessibilityIdentifier(identifier + ".topic.search")
                if topicsLoading { ProgressView(L("Загружаю темы…")).controlSize(.small) }
                if filteredTopics.isEmpty {
                    if !topicsLoading { Text(L("Темы не найдены")).font(AppTypography.caption).foregroundStyle(.secondary) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(filteredTopics) { topic in
                                Toggle(topic.title, isOn: Binding(get: { draft.topicIDs.contains(topic.id) }, set: { enabled in
                                    if enabled { draft.topicIDs.insert(topic.id) } else { draft.topicIDs.remove(topic.id) }
                                })).toggleStyle(.checkbox).accessibilityIdentifier(identifier + ".topic." + topic.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }
                if canLoadMoreTopics {
                    Button(L("Показать ещё"), action: onLoadMoreTopics).buttonStyle(AfterSoftButtonStyle())
                        .disabled(topicsLoading).accessibilityIdentifier(identifier + ".topic.more")
                }
                ForEach(draft.topicIDs.filter { id in !availableTopics.contains { $0.id == id } }.sorted(), id: \.self) { id in
                    Toggle(L("Тема сейчас недоступна"), isOn: Binding(get: { draft.topicIDs.contains(id) }, set: { enabled in
                        if !enabled { draft.topicIDs.remove(id) }
                    })).toggleStyle(.checkbox).accessibilityIdentifier(identifier + ".topic." + id)
                }
            }
        }
    }
    private func open() {
        draft = selection; fields = Set(activeFields(selection)); topicQuery = ""; rejected = false; showing = true
        if !selection.topicIDs.isEmpty { onLoadTopics() }
    }
    private func title(_ field: Field) -> String {
        switch field {
        case .origin: L("Происхождение")
        case .topic: L(target == .cards ? "Тема источника" : "Тема")
        case .kind: L(target == .cards ? "Тип карточки" : "Тип заметки")
        }
    }
    private func activeFields(_ value: MaterialFilterSet) -> [Field] {
        Field.allCases.filter { field in
            switch field {
            case .origin: !value.origins.isEmpty
            case .topic: !value.topicIDs.isEmpty
            case .kind: !value.kinds.isEmpty
            }
        }
    }
    private func chipTitle(_ field: Field) -> String {
        let value: String
        switch field {
        case .origin: value = MaterialCreationOrigin.allCases.filter { selection.origins.contains($0) }.map { L($0.titleKey) }.joined(separator: ", ")
        case .topic: value = selection.topicIDs.sorted().map { id in availableTopics.first { $0.id == id }?.title ?? L("Тема сейчас недоступна") }.joined(separator: ", ")
        case .kind: value = selection.kinds.sorted().map(kindTitle).joined(separator: ", ")
        }
        return title(field) + ": " + value
    }
    private func kindTitle(_ value: String) -> String {
        kinds.first { $0.value == value }?.title ?? LF("Недоступный тип: {0}", arguments: [value.isEmpty ? "—" : value])
    }
    private func remove(_ field: Field, from value: inout MaterialFilterSet) {
        switch field {
        case .origin: value.origins = []
        case .topic: value.topicIDs = []
        case .kind: value.kinds = []
        }
    }
}
