import SwiftUI
import PDFKit

struct PDFReaderWorkspace: View {
    @ObservedObject var store: ResearchStore
    let paper: Paper
    let readingPositionStore: PDFReadingPositionStore
    let onClose: () -> Void
    let onOpenURL: (URL) -> Void
    let isInspectorPresented: Bool
    let onToggleInspector: (() -> Void)?
    @StateObject private var reader = PDFReaderController()
    @State private var evidenceDraft: PDFTextExcerpt?
    @State private var showsFind = false
    @State private var findQuery = ""
    @State private var pageInput = "1"
    @State private var invalidPageInput = false
    @State private var password = ""
    @FocusState private var findFocused: Bool
    @FocusState private var pageFocused: Bool

    init(
        store: ResearchStore,
        paper: Paper,
        readingPositionStore: PDFReadingPositionStore,
        onClose: @escaping () -> Void,
        onOpenURL: @escaping (URL) -> Void,
        isInspectorPresented: Bool = false,
        onToggleInspector: (() -> Void)? = nil
    ) {
        self.store = store
        self.paper = paper
        self.readingPositionStore = readingPositionStore
        self.onClose = onClose
        self.onOpenURL = onOpenURL
        self.isInspectorPresented = isInspectorPresented
        self.onToggleInspector = onToggleInspector
    }

    private var attachmentIdentity: String {
        "\(paper.id.uuidString):\(paper.attachmentPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        leadingActions
                        toolbarDivider
                        pageControls
                        Spacer(minLength: 8)
                        zoomControls
                        toolbarDivider
                        trailingActions
                    }
                    VStack(spacing: 8) {
                        HStack {
                            leadingActions
                            Spacer(minLength: 8)
                            trailingActions
                        }
                        HStack(spacing: 8) {
                            pageControls
                            Spacer(minLength: 4)
                            zoomControls
                        }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                if showsFind { findBar }
            }
            .padding(10)
            .researchGlassSurface(cornerRadius: 12)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            HStack(spacing: 0) {
                if reader.showsNavigator && reader.canNavigate {
                    navigator
                        .frame(width: 180)
                    Divider()
                }
                EmbeddedPDFReader(controller: reader)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { documentState }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("阅读 PDF")
        .task(id: attachmentIdentity) {
            findQuery = ""
            showsFind = false
            password = ""
            invalidPageInput = false
            reader.onOpenURL = onOpenURL
            await reader.open(
                url: paper.attachmentPath.map(URL.init(fileURLWithPath:)),
                paperID: paper.id,
                positionStore: readingPositionStore
            )
            pageInput = String(reader.currentPage)
        }
        .onChange(of: reader.currentPage) { _, value in
            if !pageFocused { pageInput = String(value) }
        }
        .onChange(of: pageFocused) { _, focused in
            if !focused {
                pageInput = String(reader.currentPage)
                invalidPageInput = false
            }
        }
        .onChange(of: findQuery) { _, query in reader.search(query) }
        .onExitCommand {
            if showsFind { closeFind() } else { onClose() }
        }
        .sheet(item: $evidenceDraft) { excerpt in
            EvidenceCaptureSheet(store: store, paper: paper, excerpt: excerpt)
        }
    }

    private var toolbarDivider: some View { Divider().frame(height: 18) }

    private var leadingActions: some View {
        HStack(spacing: 12) {
            Button("返回", systemImage: "chevron.left", action: onClose)
                .help("返回文献概览")
            Button {
                reader.toggleNavigator()
            } label: {
                Image(systemName: "sidebar.leading")
                    .foregroundStyle(reader.showsNavigator ? Color.accentColor : .secondary)
            }
            .accessibilityLabel(reader.showsNavigator ? "隐藏 PDF 导航" : "显示 PDF 导航")
            .help("显示或隐藏目录与缩略图")
        }
        .fixedSize()
    }

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button("上一页", systemImage: "chevron.up") { reader.movePage(by: -1) }
                .labelStyle(.iconOnly)
                .disabled(!reader.canNavigate || reader.currentPage <= 1)
            TextField("页码", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 43)
                .focused($pageFocused)
                .disabled(!reader.canNavigate)
                .onSubmit {
                    invalidPageInput = !reader.goToPage(pageInput)
                    if !invalidPageInput { pageFocused = false }
                }
                .overlay {
                    if invalidPageInput {
                        RoundedRectangle(cornerRadius: 5).stroke(.red.opacity(0.8), lineWidth: 1)
                    }
                }
                .help(invalidPageInput ? "请输入 1 到 \(reader.pageCount) 之间的页码" : "输入页码，按回车跳转")
                .accessibilityLabel("当前 PDF 页码")
            Text("/ \(reader.pageCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("下一页", systemImage: "chevron.down") { reader.movePage(by: 1) }
                .labelStyle(.iconOnly)
                .disabled(!reader.canNavigate || reader.currentPage >= reader.pageCount)
        }
        .fixedSize()
    }

    private var zoomControls: some View {
        Menu {
            Button("放大") { reader.setZoom(reader.scaleFactor * 1.25) }
            Button("缩小") { reader.setZoom(reader.scaleFactor / 1.25) }
            Divider()
            ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { percent in
                Button("\(percent)%") { reader.setZoom(CGFloat(percent) / 100) }
            }
            Divider()
            Button("适合宽度") { reader.fit(.fitWidth) }
            Button("整页显示") { reader.fit(.fitPage) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass")
                Text("\(Int((reader.scaleFactor * 100).rounded()))%").monospacedDigit()
            }
            .frame(minWidth: 70)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!reader.canNavigate)
        .help("缩放比例、适合宽度或整页显示")
        .accessibilityLabel("PDF 缩放 \(Int((reader.scaleFactor * 100).rounded()))%")
    }

    private var trailingActions: some View {
        HStack(spacing: 12) {
            Button {
                showsFind = true
                findFocused = true
            } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!reader.canSearch)
                .accessibilityLabel("在 PDF 中查找")
                .help(reader.isLocked ? "解锁 PDF 后查找" : "在 PDF 中查找（⌘F）")
            Button {
                evidenceDraft = reader.selectedExcerpt
            } label: {
                Image(systemName: reader.selectedExcerpt == nil ? "quote.bubble" : "quote.bubble.fill")
                    .foregroundStyle(reader.selectedExcerpt == nil ? Color.secondary : Color.accentColor)
            }
            .disabled(reader.selectedExcerpt == nil)
            .accessibilityLabel("保存选中文字为证据")
            .help(reader.selectedExcerpt.map { "保存为证据 · \($0.locator) · \($0.text.count) 字" } ?? "先在 PDF 正文中选择一段文字")
            if let onToggleInspector {
                Button(action: onToggleInspector) {
                    Image(systemName: "sidebar.trailing")
                        .foregroundStyle(isInspectorPresented ? Color.accentColor : .secondary)
                }
                .accessibilityLabel(isInspectorPresented ? "隐藏文献信息" : "显示文献信息")
                .help("显示或隐藏文献信息")
            }
        }
        .fixedSize()
    }

    private var findBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在 PDF 中查找", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { reader.moveMatch(by: 1) }
                .frame(minWidth: 60)
                .accessibilityLabel("PDF 查找文字")
            if reader.isSearching {
                ProgressView().controlSize(.mini)
                    .help("正在查找")
            }
            Text(findStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("查找结果：\(findStatus)")
            Button("上一个匹配", systemImage: "chevron.up") { reader.moveMatch(by: -1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .labelStyle(.iconOnly)
                .disabled(reader.matchCount == 0)
            Button("下一个匹配", systemImage: "chevron.down") { reader.moveMatch(by: 1) }
                .keyboardShortcut("g", modifiers: .command)
                .labelStyle(.iconOnly)
                .disabled(reader.matchCount == 0)
            Button("关闭查找", systemImage: "xmark", action: closeFind)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private var findStatus: String {
        guard !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        if let index = reader.selectedMatchIndex { return "\(index + 1) / \(reader.matchCount)" }
        return reader.isSearching ? "\(reader.matchCount) 项…" : "\(reader.matchCount) 项"
    }

    private func closeFind() {
        reader.cancelSearch()
        findQuery = ""
        showsFind = false
        findFocused = false
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            Picker("PDF 导航", selection: Binding(
                get: { reader.navigatorMode },
                set: { reader.setNavigatorMode($0) }
            )) {
                ForEach(PDFNavigatorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            if reader.navigatorMode == .thumbnails {
                PDFThumbnails(controller: reader)
            } else if reader.hasOutline, let document = reader.document {
                PDFOutlineNavigator(document: document, onSelect: reader.go)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.indent").font(.title2)
                    Text("此 PDF 没有目录").font(.callout)
                    Button("查看缩略图") { reader.setNavigatorMode(.thumbnails) }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .researchGlassSurface(cornerRadius: 0)
    }

    @ViewBuilder
    private var documentState: some View {
        if reader.isLoading {
            ProgressView("正在打开 PDF…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        } else if let error = reader.loadError {
            ContentUnavailableView("无法读取 PDF", systemImage: "doc.badge.questionmark", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        } else if reader.isLocked {
            VStack(spacing: 14) {
                Image(systemName: "lock.doc").font(.largeTitle).foregroundStyle(.secondary)
                Text("这份 PDF 需要密码").font(.headline)
                SecureField("PDF 密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(unlock)
                if let error = reader.passwordError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("解锁", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func unlock() {
        if reader.unlock(password: password) { password = "" }
    }
}

private final class ResearchPDFView: PDFView {
    var onViewportResize: (() -> Void)?
    private var lastSize: NSSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        DispatchQueue.main.async { [weak self] in self?.onViewportResize?() }
    }
}

private struct EmbeddedPDFReader: NSViewRepresentable {
    let controller: PDFReaderController

    func makeNSView(context: Context) -> ResearchPDFView {
        let view = ResearchPDFView()
        controller.attach(view)
        view.onViewportResize = { [weak controller] in controller?.viewportDidResize() }
        return view
    }

    func updateNSView(_ view: ResearchPDFView, context: Context) {}

    static func dismantleNSView(_ view: ResearchPDFView, coordinator: PDFReaderController) {
        view.onViewportResize = nil
        coordinator.detach(view)
    }

    func makeCoordinator() -> PDFReaderController { controller }
}

private struct PDFThumbnails: NSViewRepresentable {
    let controller: PDFReaderController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = NSSize(width: 108, height: 144)
        view.backgroundColor = .clear
        view.pdfView = controller.pdfView
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== controller.pdfView { view.pdfView = controller.pdfView }
    }
}

/// PDFOutline is queried only for visible/expanded branches; large outlines are never flattened.
private struct PDFOutlineNavigator: NSViewRepresentable {
    let document: PDFDocument
    let onSelect: (PDFOutline) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(document: document, onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        column.title = "目录"
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 29
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.style = .sourceList
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        outline.reloadData()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.document !== document {
            context.coordinator.document = document
            (scroll.documentView as? NSOutlineView)?.reloadData()
        }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var document: PDFDocument
        var onSelect: (PDFOutline) -> Void
        init(document: PDFDocument, onSelect: @escaping (PDFOutline) -> Void) {
            self.document = document
            self.onSelect = onSelect
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            ((item as? PDFOutline) ?? document.outlineRoot)?.numberOfChildren ?? 0
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? PDFOutline) ?? document.outlineRoot)?.child(at: index) ?? PDFOutline()
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let entry = item as? PDFOutline else { return nil }
            let label = NSTextField(labelWithString: entry.label ?? "未命名章节")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = entry.label
            return label
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView, outline.selectedRow >= 0,
                  let entry = outline.item(atRow: outline.selectedRow) as? PDFOutline else { return }
            onSelect(entry)
        }
    }
}

private struct EvidenceCaptureSheet: View {
    @ObservedObject var store: ResearchStore
    let paper: Paper
    let excerpt: PDFTextExcerpt
    @Environment(\.dismiss) private var dismiss
    @State private var questionID: UUID?
    @State private var role: EvidenceRole = .claim
    @State private var kind: EvidenceKind = .convergence
    @State private var claim: String
    @State private var note = ""
    @State private var newQuestionTitle = ""
    @State private var newQuestionText = ""

    init(store: ResearchStore, paper: Paper, excerpt: PDFTextExcerpt) {
        self.store = store
        self.paper = paper
        self.excerpt = excerpt
        _questionID = State(initialValue: store.questions.first?.id)
        let compact = excerpt.text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        _claim = State(initialValue: String(compact.prefix(180)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("保存为证据")
                        .font(.title2.weight(.semibold))
                    Text("《\(paper.title)》· \(excerpt.locator)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(questionID == nil || claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }

            GroupBox("原文摘录") {
                ScrollView {
                    Text(excerpt.text)
                        .font(.system(size: 13.5, design: .serif))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 112)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("关联研究问题").font(.headline)
                    if store.questions.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("先创建一个研究问题", systemImage: "questionmark.bubble")
                                .foregroundStyle(.orange)
                            TextField("简短名称", text: $newQuestionTitle)
                            TextField("完整研究问题", text: $newQuestionText)
                            Button("创建并关联", systemImage: "plus") {
                                questionID = store.addQuestion(
                                    title: newQuestionTitle,
                                    question: newQuestionText
                                )
                            }
                            .disabled(
                                newQuestionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || newQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    } else {
                        Picker("研究问题", selection: $questionID) {
                            ForEach(store.questions) { question in
                                Text(question.shortTitle).tag(Optional(question.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    Text("内容类型").font(.headline)
                    Picker("内容类型", selection: $role) {
                        ForEach(EvidenceRole.allCases) { role in
                            Label(role.title, systemImage: role.symbol).tag(role)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("它说明了什么？").font(.headline)
                TextEditor(text: $claim)
                    .font(.body)
                    .frame(height: 78)
                    .padding(7)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                Text("用自己的话概括这段证据；原文会单独保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("与研究问题的关系").font(.headline)
                Picker("关系", selection: $kind) {
                    ForEach(EvidenceKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            TextField("补充判断或可信度说明（可选）", text: $note)
        }
        .padding(24)
        .frame(width: 680, height: store.questions.isEmpty ? 680 : 610)
    }

    private func save() {
        guard let questionID else { return }
        store.addEvidence(
            to: questionID,
            paperID: paper.id,
            quote: excerpt.text,
            locator: excerpt.locator,
            claim: claim,
            role: role,
            kind: kind,
            note: note
        )
        dismiss()
    }
}
