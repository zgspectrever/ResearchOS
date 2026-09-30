import SwiftUI

struct ImportedPaperDocumentWorkspace: View {
    let paper: Paper
    let onClose: () -> Void
    @State private var fullText = ""
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("返回", systemImage: "chevron.left", action: onClose)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Divider().frame(height: 18)
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(paper.authors) · \(paper.year) · \(paper.attachmentKindTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if let loadError {
                ContentUnavailableView(
                    "无法读取原文",
                    systemImage: "doc.badge.questionmark",
                    description: Text(loadError)
                )
            } else if fullText.isEmpty {
                ProgressView("正在载入原文…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(fullText)
                        .font(.system(size: 16, design: .serif))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: 780, alignment: .leading)
                        .padding(.horizontal, 56)
                        .padding(.vertical, 46)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .background(ResearchPalette.window)
            }
        }
        .navigationTitle("阅读原文")
        .task(id: paper.attachmentPath) {
            guard let path = paper.attachmentPath else {
                loadError = "原文附件不存在。"
                return
            }
            do {
                fullText = try PDFPaperImporter.parse(url: URL(fileURLWithPath: path)).text
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
