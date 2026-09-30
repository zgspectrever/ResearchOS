import SwiftUI
import WebKit

struct MarkdownHeading: Identifiable {
    let id: String
    let title: String
    let level: Int
}

struct MarkdownReadingOptions: Equatable {
    var fontSize: Double = 17
    var lineHeight: Double = 1.72
    var pageWidth: Double = 790

    var javascriptValue: String {
        let values = [
            "fontSize": min(24, max(14, fontSize)),
            "lineHeight": min(2.1, max(1.4, lineHeight)),
            "pageWidth": min(1200, max(600, pageWidth))
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

@MainActor
final class MarkdownPreviewController: ObservableObject {
    @Published private(set) var headings: [MarkdownHeading] = []
    @Published private(set) var isLoading = true
    private weak var webView: WKWebView?
    private var documentID: UUID?

    func attach(_ webView: WKWebView, documentID: UUID) {
        self.webView = webView
        if self.documentID != documentID {
            self.documentID = documentID
            // A representable update can happen during SwiftUI's render pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.documentID == documentID else { return }
                self.headings = []
                self.isLoading = true
            }
        }
    }

    func updateHeadings(_ payload: Any?, documentID: UUID) {
        guard self.documentID == documentID else { return }
        headings = (payload as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String,
                  let level = item["level"] as? Int else { return nil }
            return MarkdownHeading(id: id, title: title, level: level)
        }
        isLoading = false
    }

    func scroll(to heading: MarkdownHeading) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: [heading.id]),
              let value = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.getElementById((\(value))[0])?.scrollIntoView({block: 'start', behavior: 'auto'});")
    }
}

struct MarkdownOutlinePopover: View {
    @ObservedObject var controller: MarkdownPreviewController
    let onSelect: (MarkdownHeading) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("章节目录").font(.headline)
                Spacer()
                if !controller.headings.isEmpty {
                    Text("\(controller.headings.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            if controller.isLoading {
                ProgressView("正在读取目录…")
                    .frame(maxWidth: .infinity)
                    .padding(28)
            } else if controller.headings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有章节标题").font(.subheadline.weight(.medium))
                    Text("在文稿中添加标题后，目录会自动显示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.headings) { heading in
                            Button { onSelect(heading) } label: {
                                Text(heading.title)
                                    .font(.system(size: 12, weight: heading.level <= 2 ? .medium : .regular))
                                    .foregroundStyle(heading.level <= 2 ? .primary : .secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .padding(.leading, CGFloat(max(0, heading.level - minimumLevel)) * 12)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(heading.title)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 310)
    }

    private var minimumLevel: Int { controller.headings.map(\.level).min() ?? 1 }
}

struct MarkdownReadingSettings: View {
    @AppStorage("ResearchOS.readingFontSize") private var fontSize = 17.0
    @AppStorage("ResearchOS.readingLineHeight") private var lineHeight = 1.72
    @AppStorage("ResearchOS.readingPageWidth") private var pageWidth = 790.0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("阅读设置").font(.headline)
            HStack {
                Text("字号")
                Spacer()
                Stepper(value: $fontSize, in: 14...24, step: 1) {
                    Text("\(Int(fontSize))")
                        .monospacedDigit()
                        .frame(width: 28)
                }
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("行距").font(.subheadline)
                Picker("行距", selection: $lineHeight) {
                    Text("紧凑").tag(1.5)
                    Text("适中").tag(1.72)
                    Text("宽松").tag(2.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("正文宽度").font(.subheadline)
                Picker("正文宽度", selection: $pageWidth) {
                    Text("窄").tag(660.0)
                    Text("适中").tag(790.0)
                    Text("宽").tag(980.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Divider()
            HStack {
                Text("适用于所有 Markdown 与 LaTeX 预览")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("恢复默认") {
                    fontSize = 17
                    lineHeight = 1.72
                    pageWidth = 790
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}
