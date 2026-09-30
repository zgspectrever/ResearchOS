import SwiftUI

struct GlobalSearchSheet: View {
    @ObservedObject var store: ResearchStore
    @Binding var query: String
    let onSelect: (GlobalSearchResult) -> Void

    private var results: [GlobalSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var output: [GlobalSearchResult] = []
        for question in store.questions where question.shortTitle.localizedCaseInsensitiveContains(q) || question.question.localizedCaseInsensitiveContains(q) {
            output.append(GlobalSearchResult(title: question.shortTitle, detail: "研究问题", symbol: "questionmark.bubble", target: .question(question.id)))
        }
        for paper in store.papers where paper.title.localizedCaseInsensitiveContains(q) || paper.authors.localizedCaseInsensitiveContains(q) || paper.abstractText.localizedCaseInsensitiveContains(q) || paper.analysisInput.localizedCaseInsensitiveContains(q) {
            output.append(GlobalSearchResult(title: paper.title, detail: "论文 · \(paper.authors)", symbol: "doc.text", target: .paper(paper.id)))
        }
        for document in store.markdownDocuments where document.title.localizedCaseInsensitiveContains(q) || document.content.localizedCaseInsensitiveContains(q) {
            output.append(GlobalSearchResult(title: document.title.isEmpty ? "未命名文稿" : document.title, detail: "写作 · \(document.resolvedFormat.title)", symbol: "doc.richtext", target: .document(document.id)))
        }
        return Array(output.prefix(80))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索论文、原文、文稿和研究问题", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
            }
            .padding(18)
            Divider()
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("开始搜索", systemImage: "magnifyingglass", description: Text("支持标题、作者、摘要、PDF 原文和写作文档内容。"))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(results) { result in
                    Button { onSelect(result) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).lineLimit(1)
                                Text(result.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: result.symbol).foregroundStyle(.blue) }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(width: 620, height: 480)
        .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}
