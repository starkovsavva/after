import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

/// Evidence stays next to the claim it supports. Navigation revalidates the
/// original before opening; model text can never create an application route.
struct KnowledgeAnswerView: View {
    @ObservedObject private var theme = ThemeController.shared
    let answer: KnowledgeAnswer
    let openingID: String?
    let open: (KnowledgeSource) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.title).font(AppTypography.heading)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(answer.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(paragraph.text).font(AppTypography.body).lineSpacing(4)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(sources(for: paragraph)) { source in
                                Button { open(source) } label: {
                                    HStack(alignment: .top, spacing: 7) {
                                        if openingID == source.id { ProgressView().controlSize(.mini).frame(width: 14) }
                                        else { Image(systemName: symbol(source.kind)).frame(width: 14) }
                                        Text(source.title).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right").font(AppTypography.caption)
                                    }.font(AppTypography.captionStrong).foregroundStyle(Ink.accent)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(openingID != nil)
                                    .help(source.excerpt).accessibilityIdentifier("knowledge.source." + source.id)
                            }
                        }
                    }
                    ForEach(Array(answer.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(AppTypography.caption).foregroundStyle(Ink.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if answer.truncated && answer.warnings.isEmpty {
                        Text(L("Ответ подготовлен по части найденных материалов. Уточните тему или период, чтобы сузить поиск."))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 3)
            }.frame(maxHeight: 360)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("knowledge.answer")
    }
    private func sources(for paragraph: KnowledgeParagraph) -> [KnowledgeSource] {
        var seen = Set<String>()
        return paragraph.sourceIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return answer.sources.first { $0.id == id }
        }
    }
    private func symbol(_ kind: String) -> String {
        switch kind {
        case "task": return "checklist"
        case "note": return "note.text"
        case "calendar": return "calendar"
        case "code": return "curlybraces"
        case "card": return "rectangle.on.rectangle"
        case "transcript": return "quote.bubble"
        default: return "doc.text"
        }
    }
    static func copy(_ answer: KnowledgeAnswer) {
        let lines = answer.paragraphs.map { paragraph in
            let references = paragraph.sourceIDs.compactMap { id in answer.sources.first { $0.id == id }?.title }
            return paragraph.text + (references.isEmpty ? "" : L("\n\nИсточник: ") + references.joined(separator: "; "))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((["# " + answer.title] + lines + answer.warnings).joined(separator: "\n\n"), forType: .string)
    }
}
