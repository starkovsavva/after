import Foundation
import PosleCore
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var queryFocused: Bool
    @State private var selectedID: String?
    @State private var byMeaning = false
    @StateObject private var knowledge = KnowledgeSearchController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 21)).foregroundStyle(Ink.accent)
                TextField(L("Слово или фраза"), text: $store.searchQuery)
                    .font(.system(size: 20)).textFieldStyle(.plain).focused($queryFocused)
                    .accessibilityLabel(store.notes.folder(store.folderSelection).map { L("Поиск в папке «") + $0.name + "»" } ?? L("Поиск по всей библиотеке"))
                    .onSubmit { openSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if byMeaning ? knowledge.searching || knowledge.openingID != nil : store.searching || store.searchOpeningID != nil { ProgressView().controlSize(.small) }
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(L("Очистить поиск"))
                }
                Button(L("Закрыть")) { store.showingSearch = false }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }.padding(22)
            if let folder = store.notes.folder(store.folderSelection) {
                HStack(spacing: 12) {
                    Label(L("В папке «") + folder.name + "»", systemImage: "folder").lineLimit(1)
                    Spacer()
                    Button(L("Искать во всей библиотеке")) { store.folderSelection = nil }
                        .buttonStyle(.borderless).accessibilityIdentifier("search.allFolders")
                }.font(AppTypography.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 12)
            }
            if store.isFeatureEnabled(.semanticSearch) {
                Picker(L("Способ поиска"), selection: $byMeaning) {
                    Text(L("По словам")).tag(false); Text(L("По смыслу")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230).padding(.horizontal, 22).padding(.bottom, 12)
                    .accessibilityIdentifier("search.mode")
            }
            Picker(L("Область поиска"), selection: $store.searchScope) {
                Text(L("Всё")).tag("all")
                Text(L("Заметки")).tag("notes")
                Text(L("Транскрипт")).tag("transcript")
                if store.isFeatureEnabled(.cards) { Text(L("Карточки")).tag("cards") }
                Text(L("Названия")).tag("meetings")
                if byMeaning && store.isFeatureEnabled(.tasks) { Text(L("Задачи")).tag("tasks"); Text(L("Код")).tag("code") }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(L("Область поиска")).tint(Ink.actionFill).padding(.horizontal, 22).padding(.bottom, 16)
            Rectangle().fill(Ink.line).frame(height: 1)
            if let message = byMeaning ? knowledge.error : store.searchError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Ink.warning)
                    Text(message).font(AppTypography.control).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Повторить")) { updateSearch(immediate: true) }.buttonStyle(.borderless)
                }.padding(14).background(Ink.warning.opacity(0.07))
            }
            Group { if byMeaning { meaningContent } else { content } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Ink.line).frame(height: 1)
            HStack {
                Spacer()
                Text(L("↑ ↓ выбрать · Return открыть · Esc закрыть")).foregroundStyle(.secondary)
            }.font(AppTypography.caption).padding(.horizontal, 22).padding(.vertical, 13)
        }.frame(width: 760, height: 650).background(Ink.paper).tint(Ink.accent).appControlDefaults()
            .onAppear {
                queryFocused = true
                #if DEBUG
                if releaseSearchPreview && store.isFeatureEnabled(.semanticSearch) {
                    byMeaning = true; knowledge.seedPreview(ReleasePreviewFixtures.semanticSources)
                    selectedID = knowledge.sources.first?.id
                    return
                }
                #endif
                struct Envelope: Decodable { var config: SemanticSearchConfiguration }
                if store.isFeatureEnabled(.semanticSearch),
                   let data = try? RustBridge.shared.get().request(root: store.root, command: "semantic-config"),
                   let value = try? JSONDecoder().decode(Envelope.self, from: data) { byMeaning = value.config.enabled }
                else { byMeaning = false }
                updateSearch(immediate: true)
            }
            .onChange(of: store.searchQuery) { _, _ in updateSearch() }
            .onChange(of: store.searchScope) { _, _ in updateSearch() }
            .onChange(of: byMeaning) { _, _ in updateSearch(immediate: true) }
            .onChange(of: store.visibleFeatures) { _, _ in updateSearch(immediate: true) }
            .onChange(of: store.folderSelection) { _, _ in updateSearch(immediate: true) }
            .onChange(of: knowledge.sources) { _, hits in selectedID = hits.first?.id }
            .onChange(of: store.searchHits) { _, _ in selectedID = visibleSearchHits.first?.id }
            .onDisappear { store.cancelSearch(); knowledge.cancel() }
    }

    #if DEBUG
    private var releaseSearchPreview: Bool {
        store.isPreview && ProcessInfo.processInfo.arguments.contains("--preview-semantic-search")
    }
    #endif
    private func updateSearch(immediate: Bool = false) {
        #if DEBUG
        if releaseSearchPreview && store.isFeatureEnabled(.semanticSearch) { return }
        #endif
        // Saved scopes and in-flight results must not reopen disabled tools.
        if !store.isFeatureEnabled(.semanticSearch) { byMeaning = false }
        let scope = store.visibleFeatures.normalizedSearchScope(store.searchScope, byMeaning: byMeaning)
        if store.searchScope != scope { store.searchScope = scope }
        if byMeaning { store.cancelSearch(); knowledge.update(store: store, query: store.searchQuery, scope: store.searchScope, immediate: immediate) }
        else { knowledge.cancel(); store.updateSearch(immediate: immediate) }
    }
    @ViewBuilder private var meaningContent: some View {
        if store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder(L("Найдите по смыслу"), L("Опишите, что помните: например, выражение о возвращении к вопросу."), icon: "sparkle.magnifyingglass")
        } else if knowledge.searching && knowledge.sources.isEmpty {
            ProgressView(L("Ищу в библиотеке…")).font(AppTypography.control)
        } else if knowledge.sources.isEmpty && knowledge.error == nil {
            placeholder(L("Ничего не найдено"), L("Уточните тему или проверьте, обновлён ли смысловой индекс."), icon: "magnifyingglass")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(knowledge.sources) { source in
                            Button { selectedID = source.id; knowledge.open(source, store: store) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: meaningIcon(source.kind)).foregroundStyle(Ink.accent).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(source.title).font(AppTypography.controlStrong).lineLimit(2)
                                        Text(source.excerpt).font(AppTypography.control).lineLimit(3).foregroundStyle(.secondary)
                                        Text(meaningLabel(source.kind)).font(AppTypography.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if knowledge.openingID == source.id { ProgressView().controlSize(.mini) }
                                    else if selectedID == source.id { Image(systemName: "return").font(AppTypography.caption).foregroundStyle(Ink.accent) }
                                }.padding(13).background(selectedID == source.id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(source.id).disabled(knowledge.openingID != nil).accessibilityAddTraits(selectedID == source.id ? .isSelected : [])
                        }
                        ForEach(knowledge.warnings, id: \.self) { Text($0).font(AppTypography.caption).foregroundStyle(Ink.warning).padding(10) }
                    }.padding(12)
                }.onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
    private func meaningIcon(_ kind: String) -> String { ["task":"checklist","note":"note.text","code":"curlybraces","card":"rectangle.on.rectangle","meeting":"rectangle.stack","transcript":"quote.bubble"][kind] ?? "doc.text" }
    private func meaningLabel(_ kind: String) -> String { ["task":L("Задача"),"note":L("Заметка"),"code":L("Код"),"card":L("Карточка"),"meeting":L("Встреча"),"transcript":L("Реплика"),"summary":L("Конспект")][kind] ?? L("Источник") }

    @ViewBuilder private var content: some View {
        if store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder(store.folderSelection == nil ? L("Поиск по библиотеке") : L("Поиск в папке"), L("Например: бюджет, доступы или follow up."), icon: "text.magnifyingglass")
        } else if store.searching && visibleSearchHits.isEmpty {
            VStack(spacing: 12) { ProgressView(); Text(store.folderSelection == nil ? L("Ищу в библиотеке…") : L("Ищу в папке…")).font(AppTypography.control).foregroundStyle(.secondary) }
        } else if visibleSearchHits.isEmpty && store.searchError == nil {
            placeholder(L("Ничего не найдено"), L("Попробуйте другое слово или сократите запрос."), icon: "magnifyingglass")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(store.searchTruncated ? LF("Показаны первые {0} результатов", arguments: [String(describing: (visibleSearchHits.count))]) : LF("Результатов: {0}", arguments: [String(describing: (visibleSearchHits.count))]))
                            Spacer()
                        }.font(AppTypography.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 8)
                        ForEach(visibleSearchHits) { hit in
                            Button { selectedID = hit.id; store.openSearchHit(hit) } label: { row(hit) }
                                .buttonStyle(.plain).id(hit.id).disabled(store.searchOpeningID != nil)
                                .accessibilityAddTraits(selectedID == hit.id ? .isSelected : [])
                                .accessibilityHint(L("Открыть фрагмент встречи"))
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
                    Text(Date(timeIntervalSince1970: hit.createdAt).formatted(.dateTime.day().month(.abbreviated).year().locale(UILocale())))
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
        if byMeaning {
            let sources = knowledge.sources; guard !sources.isEmpty else { return }
            let current = sources.firstIndex { $0.id == selectedID } ?? (direction > 0 ? -1 : sources.count)
            selectedID = sources[min(max(current + direction, 0), sources.count - 1)].id; return
        }
        guard !visibleSearchHits.isEmpty else { return }
        let hits = visibleSearchHits
        let current = hits.firstIndex(where: { $0.id == selectedID }) ?? (direction > 0 ? -1 : hits.count)
        selectedID = hits[min(max(current + direction, 0), hits.count - 1)].id
    }
    private func openSelected() {
        if byMeaning { if let source = knowledge.sources.first(where: { $0.id == selectedID }) { knowledge.open(source, store: store) }; return }
        if let hit = visibleSearchHits.first(where: { $0.id == selectedID }) { store.openSearchHit(hit) }
    }
    private var visibleSearchHits: [SearchHit] {
        store.searchHits.filter {
            store.visibleFeatures.allowsKnowledgeKind($0.kind)
                && ($0.cardID == nil || store.isFeatureEnabled(.cards))
        }
    }
    private func label(_ kind: String) -> String {
        ["title": L("Название встречи"), "overview": L("Краткий конспект"), "item": L("Факт из конспекта"), "transcript": L("Исходная реплика"), "card": L("Карточка"), "manual": L("Моя заметка")][kind] ?? L("Встреча")
    }
    private func icon(_ kind: String) -> String {
        ["title": "rectangle.stack", "overview": "text.bubble", "item": "pin", "transcript": "quote.bubble", "card": "rectangle.on.rectangle.angled", "manual": "square.and.pencil"][kind] ?? "doc.text"
    }
}
