import Foundation
import PosleCore
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var queryFocused: Bool
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 21)).foregroundStyle(Ink.accent)
                TextField("Слово или фраза", text: $store.searchQuery)
                    .font(.system(size: 20)).textFieldStyle(.plain).focused($queryFocused)
                    .accessibilityLabel("Поиск по всей библиотеке")
                    .onSubmit { openSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if store.searching || store.searchOpeningID != nil { ProgressView().controlSize(.small) }
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
                Button("Закрыть") { store.showingSearch = false }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }.padding(22)
            Picker("Область поиска", selection: $store.searchScope) {
                Text("Всё").tag("all")
                Text("Заметки").tag("notes")
                Text("Транскрипт").tag("transcript")
                Text("Карточки").tag("cards")
                Text("Названия").tag("meetings")
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Область поиска").tint(Ink.actionFill).padding(.horizontal, 22).padding(.bottom, 16)
            Rectangle().fill(Ink.line).frame(height: 1)
            if let message = store.searchError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Ink.warning)
                    Text(message).font(AppTypography.control).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Повторить") { store.updateSearch(immediate: true) }.buttonStyle(.borderless)
                }.padding(14).background(Ink.warning.opacity(0.07))
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Ink.line).frame(height: 1)
            HStack {
                Spacer()
                Text("↑ ↓ выбрать · Return открыть · Esc закрыть").foregroundStyle(.secondary)
            }.font(AppTypography.caption).padding(.horizontal, 22).padding(.vertical, 13)
        }.frame(width: 760, height: 650).background(Ink.paper).tint(Ink.accent).appControlDefaults()
            .onAppear { queryFocused = true; store.updateSearch(immediate: true) }
            .onChange(of: store.searchQuery) { _, _ in store.updateSearch() }
            .onChange(of: store.searchScope) { _, _ in store.updateSearch() }
            .onChange(of: store.searchHits) { _, hits in selectedID = hits.first?.id }
            .onDisappear { store.cancelSearch() }
    }

    @ViewBuilder private var content: some View {
        if store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder("Поиск по библиотеке", "Например: бюджет, доступы или follow up.", icon: "text.magnifyingglass")
        } else if store.searching && store.searchHits.isEmpty {
            VStack(spacing: 12) { ProgressView(); Text("Ищу во всех встречах…").font(AppTypography.control).foregroundStyle(.secondary) }
        } else if store.searchHits.isEmpty && store.searchError == nil {
            placeholder("Ничего не найдено", "Попробуйте другое слово или сократите запрос.", icon: "magnifyingglass")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(store.searchTruncated ? "Показаны первые \(store.searchHits.count) из \(store.searchTotal) результатов" : "Результатов: \(store.searchTotal)")
                            Spacer()
                        }.font(AppTypography.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 8)
                        ForEach(store.searchHits) { hit in
                            Button { selectedID = hit.id; store.openSearchHit(hit) } label: { row(hit) }
                                .buttonStyle(.plain).id(hit.id).disabled(store.searchOpeningID != nil)
                                .accessibilityAddTraits(selectedID == hit.id ? .isSelected : [])
                                .accessibilityHint("Открыть фрагмент встречи")
                        }
                        ForEach(store.searchWarnings, id: \.self) { Text($0).font(AppTypography.caption).foregroundStyle(Ink.warning).padding(10) }
                    }.padding(12)
                }.onChange(of: selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } } }
            }
        }
    }
    private func row(_ hit: SearchHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(hit.kind)).font(.system(size: 16)).foregroundStyle(Ink.accent).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hit.meetingTitle).font(AppTypography.controlStrong).lineLimit(1)
                    Spacer()
                    Text(Date(timeIntervalSince1970: hit.createdAt).formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "ru_RU"))))
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
                if hit.kind != "title" {
                    Text(highlighted(hit.snippet)).font(AppTypography.control).lineSpacing(3).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Text(label(hit.kind))
                    if let start = hit.start { Text("·"); Text(Exporter.timestamp(start)).monospacedDigit() }
                }.font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if store.searchOpeningID == hit.id { ProgressView().controlSize(.mini) }
            else if selectedID == hit.id { Image(systemName: "return").font(AppTypography.caption).foregroundStyle(Ink.accent).padding(.top, 3) }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == hit.id ? Ink.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selectedID == hit.id ? Ink.accent.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
    }
    private func highlighted(_ snippet: String) -> AttributedString {
        var value = AttributedString(snippet)
        let terms = Set(store.searchQuery.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for term in terms where !term.isEmpty {
            var remaining = snippet.startIndex..<snippet.endIndex
            while let match = snippet.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                if let lower = AttributedString.Index(match.lowerBound, within: value),
                   let upper = AttributedString.Index(match.upperBound, within: value) {
                    value[lower..<upper].font = AppTypography.controlStrong
                    value[lower..<upper].foregroundColor = Ink.accent
                }
                guard match.upperBound < snippet.endIndex else { break }
                remaining = match.upperBound..<snippet.endIndex
            }
        }
        return value
    }
    private func placeholder(_ title: String, _ subtitle: String, icon: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(Ink.accent)
            Text(title).font(AppTypography.emptyTitle)
            Text(subtitle).font(AppTypography.control).lineSpacing(5).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470)
        }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func move(_ direction: Int) {
        guard !store.searchHits.isEmpty else { return }
        let current = store.searchHits.firstIndex(where: { $0.id == selectedID }) ?? (direction > 0 ? -1 : store.searchHits.count)
        selectedID = store.searchHits[min(max(current + direction, 0), store.searchHits.count - 1)].id
    }
    private func openSelected() {
        if let hit = store.searchHits.first(where: { $0.id == selectedID }) { store.openSearchHit(hit) }
    }
    private func label(_ kind: String) -> String {
        ["title": "Название встречи", "overview": "Краткий конспект", "item": "Факт из конспекта", "transcript": "Исходная реплика", "card": "Карточка", "manual": "Моя заметка"][kind] ?? "Встреча"
    }
    private func icon(_ kind: String) -> String {
        ["title": "rectangle.stack", "overview": "text.bubble", "item": "pin", "transcript": "quote.bubble", "card": "rectangle.on.rectangle.angled", "manual": "square.and.pencil"][kind] ?? "doc.text"
    }
}
