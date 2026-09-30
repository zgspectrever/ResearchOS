import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum MarkdownDisplayMode: String, CaseIterable, Identifiable {
    case edit
    case split
    case preview

    var id: String { rawValue }
    var title: String {
        switch self {
        case .edit: "编辑"
        case .split: "并排"
        case .preview: "阅读"
        }
    }
}

struct MarkdownDocumentList: View {
    @ObservedObject var store: ResearchStore
    @Binding var selection: UUID?
    @Binding var query: String
    let onNewNote: () -> Void
    let onNewPaper: () -> Void
    let onImport: () -> Void
    let onImportFolder: () -> Void
    let onSyncFolder: (UUID) -> Void
    let onSyncDocument: (UUID) -> Void
    let onDuplicate: (UUID) -> Void
    let onDelete: (UUID) -> Void
    @AppStorage("ResearchOS.listDensity") private var listDensity = "comfortable"
    @AppStorage("ResearchOS.showsListPreview") private var showsListPreview = true
    @State private var renameDocument: MarkdownDocument?
    @State private var renameFolder: WritingFolder?
    @State private var folderCreationRequest: FolderCreationRequest?
    @State private var pendingDeletion: MarkdownDocument?
    @State private var pendingFolderDeletion: WritingFolder?

    private var documents: [MarkdownDocument] { store.markdownDocuments }

    private var filteredDocuments: [MarkdownDocument] {
        let sorted = documents.sorted { $0.modifiedAt > $1.modifiedAt }
        let parsed = TagFiltering.parse(query)
        guard !parsed.text.isEmpty || parsed.tag != nil else { return sorted }
        return sorted.filter {
            TagFiltering.matches(tags: $0.tags, tag: parsed.tag) && (parsed.text.isEmpty ||
            $0.title.localizedCaseInsensitiveContains(parsed.text) ||
            $0.content.localizedCaseInsensitiveContains(parsed.text))
        }
    }

    private var unfiledDocuments: [MarkdownDocument] {
        let folderIDs = Set(store.writingFolders.map(\.id))
        return filteredDocuments.filter { document in
            guard let folderID = document.folderID else { return true }
            return !folderIDs.contains(folderID)
        }
    }

    var body: some View {
        Group {
            if documents.isEmpty {
                EmptyStateCard(title: "还没有写作内容", message: "新建笔记或论文，也可以导入已有文档继续编辑。", symbol: "doc.richtext") {
                    Button("新建笔记", action: onNewNote)
                    Button("新建论文", action: onNewPaper)
                    Button("导入文档", action: onImport)
                }
            } else if !query.isEmpty && filteredDocuments.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: $selection) {
                    if !query.isEmpty {
                        Section("搜索结果") {
                            ForEach(filteredDocuments) { documentRow($0) }
                        }
                    } else {
                        if !unfiledDocuments.isEmpty {
                            Section("未分类") {
                                ForEach(unfiledDocuments) { documentRow($0) }
                            }
                        }
                        ForEach(store.writingFolders) { folder in
                            Section {
                                ForEach(filteredDocuments.filter { $0.folderID == folder.id }) { documentRow($0) }
                            } header: {
                                folderHeader(folder)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { writingLibraryBar }
                .scrollContentBackground(.hidden)
                .background(ResearchPalette.window)
            }
        }
        .navigationTitle("写作")
        .sheet(item: $renameDocument) { document in
            WritingNameSheet(title: "重命名文稿", initialValue: document.title, prompt: "文稿名称") { name in
                store.renameWritingDocument(document.id, to: name)
            }
        }
        .sheet(item: $renameFolder) { folder in
            WritingNameSheet(title: "重命名文件夹", initialValue: folder.name, prompt: "文件夹名称") { name in
                store.renameWritingFolder(folder.id, to: name)
            }
        }
        .sheet(item: $folderCreationRequest) { request in
            WritingNameSheet(title: "新建文件夹", initialValue: "", prompt: "文件夹名称") { name in
                guard let folderID = store.createWritingFolder(name: name) else { return }
                if let documentID = request.documentID {
                    store.moveWritingDocument(documentID, to: folderID)
                }
            }
        }
        .alert("删除文稿？", isPresented: deletionPresented, presenting: pendingDeletion) { document in
            Button("删除", role: .destructive) { onDelete(document.id) }
            Button("取消", role: .cancel) {}
        } message: { document in
            Text("“\(document.title.isEmpty ? "未命名文稿" : document.title)”将从 ResearchOS 中删除，此操作无法撤销。")
        }
        .alert("移除文件夹？", isPresented: folderDeletionPresented, presenting: pendingFolderDeletion) { folder in
            Button("移除", role: .destructive) { store.deleteWritingFolder(folder.id) }
            Button("取消", role: .cancel) {}
        } message: { folder in
            Text("文件夹“\(folder.name)”会被移除，其中的文稿将保留并移到“未分类”。")
        }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var folderDeletionPresented: Binding<Bool> {
        Binding(get: { pendingFolderDeletion != nil }, set: { if !$0 { pendingFolderDeletion = nil } })
    }

    private var writingLibraryBar: some View {
        HStack(spacing: 8) {
            Label("文稿", systemImage: "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(filteredDocuments.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(ResearchPalette.window)
    }

    private func folderHeader(_ folder: WritingFolder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(folder.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(documents.filter { $0.folderID == folder.id }.count)")
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                onSyncFolder(folder.id)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同步更新 \(folder.name)")
            .help(folder.sourceBookmark == nil ? "重新选择来源文件夹并开始同步" : "同步更新此文件夹")
            Menu {
                Button("重命名文件夹", systemImage: "pencil") { renameFolder = folder }
                Button("移除文件夹", systemImage: "trash", role: .destructive) {
                    pendingFolderDeletion = folder
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("文件夹操作")
        }
    }

    private func documentRow(_ document: MarkdownDocument) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: document.resolvedKind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(document.resolvedKind == .paper ? .blue : .orange)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: listDensity == "compact" ? 3 : 5) {
                Text(document.title.isEmpty ? "未命名文稿" : document.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text("\(document.resolvedFormat.title) · \(shortDate(document.modifiedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("\(document.resolvedKind.title) · \(document.modifiedAt.formatted(date: .complete, time: .shortened))")
                if showsListPreview {
                    Text(document.content.prefix(300).replacingOccurrences(of: "\n", with: " "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(listDensity == "compact" ? 1 : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            documentMenu(document)
        }
        .padding(.vertical, listDensity == "compact" ? 3 : 7)
        .tag(document.id)
    }

    private func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let day = "\(components.month ?? 1)月\(components.day ?? 1)日"
        return calendar.component(.year, from: Date()) == components.year
            ? day : "\(components.year ?? 0)年\(day)"
    }

    private func documentMenu(_ document: MarkdownDocument) -> some View {
        Menu {
            if document.importedName != nil {
                Button("从原文件同步更新", systemImage: "arrow.triangle.2.circlepath") {
                    onSyncDocument(document.id)
                }
                Divider()
            }
            Button("重命名", systemImage: "pencil") { renameDocument = document }
            Button("制作副本", systemImage: "plus.square.on.square") { onDuplicate(document.id) }
            Menu("移动到文件夹", systemImage: "folder") {
                Button {
                    store.moveWritingDocument(document.id, to: nil)
                } label: {
                    if document.folderID == nil { Label("未分类", systemImage: "checkmark") }
                    else { Text("未分类") }
                }
                Divider()
                ForEach(store.writingFolders) { folder in
                    Button {
                        store.moveWritingDocument(document.id, to: folder.id)
                    } label: {
                        if document.folderID == folder.id { Label(folder.name, systemImage: "checkmark") }
                        else { Text(folder.name) }
                    }
                }
                Divider()
                Button("新建文件夹…", systemImage: "folder.badge.plus") {
                    folderCreationRequest = FolderCreationRequest(documentID: document.id)
                }
            }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = document }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("文稿操作")
    }
}

private struct FolderCreationRequest: Identifiable {
    let id = UUID()
    let documentID: UUID?
}

struct WritingNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialValue: String
    let prompt: String
    let onSave: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.semibold))
            TextField(prompt, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { value = initialValue }
    }

    private func save() {
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanValue.isEmpty else { return }
        onSave(cleanValue)
        dismiss()
    }
}

struct MarkdownWelcomeView: View {
    let onNewNote: () -> Void
    let onNewPaper: () -> Void
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("写作资料库", systemImage: "doc.richtext")
        } description: {
            Text("笔记支持 Markdown；论文支持 LaTeX 或 Word，并可在这里直接阅读和编辑。")
        } actions: {
            Button("新建笔记", action: onNewNote)
            Button("新建论文", action: onNewPaper)
            Button("导入文档", action: onImport)
        }
    }
}

final class MarkdownReadingPositionStore: ObservableObject {
    private var offsets: [UUID: CGFloat] = [:]

    func offset(for documentID: UUID) -> CGFloat {
        offsets[documentID] ?? 0
    }

    func setOffset(_ offset: CGFloat, for documentID: UUID) {
        offsets[documentID] = max(0, offset)
    }

    func remove(_ documentID: UUID) {
        offsets.removeValue(forKey: documentID)
    }
}

struct MarkdownEditorWorkspace: View {
    @ObservedObject var store: ResearchStore
    let documentID: UUID
    let readingPositionStore: MarkdownReadingPositionStore
    let onOpenURL: (URL) -> Void
    @State private var displayMode: MarkdownDisplayMode = .preview
    @StateObject private var editorController = MarkdownEditorController()
    @StateObject private var splitScrollController = MarkdownSplitScrollController()
    @StateObject private var previewController = MarkdownPreviewController()
    @State private var showsOutline = false
    @State private var showsReadingSettings = false
    @State private var showsRename = false
    @AppStorage("ResearchOS.readingFontSize") private var readingFontSize = 17.0
    @AppStorage("ResearchOS.readingLineHeight") private var readingLineHeight = 1.72
    @AppStorage("ResearchOS.readingPageWidth") private var readingPageWidth = 790.0

    private var document: MarkdownDocument? {
        store.markdownDocuments.first { $0.id == documentID }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { document?.title ?? "" },
            set: { store.updateMarkdown(documentID, title: $0) }
        )
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: { document?.content ?? "" },
            set: { store.updateMarkdown(documentID, content: $0) }
        )
    }

    var body: some View {
        if let document {
            if document.resolvedFormat == .word {
                WordDocumentWorkspace(store: store, documentID: documentID, onOpenURL: onOpenURL)
            } else {
                VStack(spacing: 0) {
                    documentBar(document)
                    TagEditor(tags: document.tags) { store.setTags(forDocument: document.id, tags: $0) }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    if displayMode != .preview {
                        MarkdownFormattingBar(controller: editorController)
                    }
                    editorBody(document)
                }
                .background(ResearchPalette.window)
                .navigationTitle(document.title)
                .sheet(isPresented: $showsRename) {
                    WritingNameSheet(title: "重命名文稿", initialValue: document.title, prompt: "文稿名称") { name in
                        store.renameWritingDocument(documentID, to: name)
                    }
                }
                .onChange(of: documentID) { _, _ in
                    displayMode = .preview
                    showsOutline = false
                }
                .onChange(of: displayMode) { _, mode in
                    if mode == .edit {
                        showsOutline = false
                        showsReadingSettings = false
                    }
                }
            }
        } else {
            ContentUnavailableView("文稿不存在", systemImage: "doc.badge.ellipsis")
        }
    }

    private func documentBar(_ document: MarkdownDocument) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                documentIdentity(document)
                    .frame(minWidth: 160)
                documentControls(document, compact: false)
            }
            VStack(spacing: 8) {
                documentIdentity(document)
                HStack {
                    Spacer(minLength: 0)
                    documentControls(document, compact: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            // Register once, outside the alternative layouts in ViewThatFits.
            Button("保存文稿") { store.saveWritingDocument(documentID) }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private func documentIdentity(_ document: MarkdownDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: document.resolvedKind.symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if displayMode == .preview {
                    Text(document.title.isEmpty ? "未命名文稿" : document.title)
                        .help(document.title)
                } else {
                    TextField("文稿标题", text: titleBinding)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("文稿标题")
                }
                Text(document.resolvedFormat.title)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 34)
    }

    private func documentControls(_ document: MarkdownDocument, compact: Bool) -> some View {
        HStack(spacing: 6) {
            if displayMode != .edit {
                Button { showsOutline.toggle() } label: {
                    Image(systemName: "list.bullet.indent")
                        .frame(width: 28, height: 28)
                }
                .help("章节目录")
                .accessibilityLabel("章节目录")
                .popover(isPresented: $showsOutline, arrowEdge: .bottom) {
                    MarkdownOutlinePopover(controller: previewController) { heading in
                        showsOutline = false
                        previewController.scroll(to: heading)
                    }
                }
                Button { showsReadingSettings.toggle() } label: {
                    Image(systemName: "textformat.size")
                        .frame(width: 28, height: 28)
                }
                .help("阅读设置")
                .accessibilityLabel("阅读设置")
                .popover(isPresented: $showsReadingSettings, arrowEdge: .bottom) {
                    MarkdownReadingSettings()
                }
            }
            Button {
                store.saveWritingDocument(documentID)
            } label: {
                if compact {
                    Image(systemName: "tray.and.arrow.down")
                        .frame(width: 28, height: 28)
                } else {
                    Label("保存", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 4)
                        .frame(height: 28)
                }
            }
            .accessibilityLabel("保存文稿")
            .help("保存到 ResearchOS（⌘S）；编辑内容也会自动保存到本应用")
            if compact {
                Menu {
                    Picker("显示方式", selection: $displayMode) {
                        ForEach(MarkdownDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Text(displayMode.title)
                        .frame(minWidth: 34, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .help("显示方式：\(displayMode.title)")
                .accessibilityLabel("显示方式")
            } else {
                Picker("显示方式", selection: $displayMode) {
                    ForEach(MarkdownDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 174)
            }
            Menu {
                Button("重命名文稿…", systemImage: "pencil") { showsRename = true }
                Button("导出文稿…", systemImage: "square.and.arrow.up") { export(document) }
                if displayMode != .preview {
                    Divider()
                    Button("在文末插入公式", systemImage: "function", action: appendFormulaBlock)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("文稿更多操作")
            .accessibilityLabel("文稿更多操作")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(5)
        .researchGlassSurface()
        .fixedSize()
    }

    @ViewBuilder
    private func editorBody(_ document: MarkdownDocument) -> some View {
        switch displayMode {
        case .edit:
            sourceEditor(document, scrollSync: nil)
        case .preview:
            documentPreview(document, scrollSync: nil)
        case .split:
            HSplitView {
                sourceEditor(document, scrollSync: splitScrollController)
                    .frame(minWidth: 200)
                documentPreview(document, scrollSync: splitScrollController)
                    .frame(minWidth: 220)
            }
        }
    }

    private func sourceEditor(
        _ document: MarkdownDocument,
        scrollSync: MarkdownSplitScrollController?
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.resolvedFormat == .latex ? "LATEX" : "MARKDOWN")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("公式：$…$  或  $$…$$")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.7))

            MarkdownTextEditor(
                text: contentBinding,
                controller: editorController,
                scrollSyncController: scrollSync
            )
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private func documentPreview(
        _ document: MarkdownDocument,
        scrollSync: MarkdownSplitScrollController?
    ) -> some View {
        if document.resolvedFormat == .latex {
            MarkdownPreview(
                documentID: documentID,
                markdown: Self.markdownFromLaTeX(document.content),
                readingPositionStore: readingPositionStore,
                scrollSyncController: scrollSync,
                previewController: previewController,
                readingOptions: readingOptions,
                onOpenURL: onOpenURL
            )
        } else {
            MarkdownPreview(
                documentID: documentID,
                markdown: document.content,
                readingPositionStore: readingPositionStore,
                scrollSyncController: scrollSync,
                previewController: previewController,
                readingOptions: readingOptions,
                onOpenURL: onOpenURL
            )
        }
    }

    private var readingOptions: MarkdownReadingOptions {
        MarkdownReadingOptions(fontSize: readingFontSize, lineHeight: readingLineHeight, pageWidth: readingPageWidth)
    }

    private func appendFormulaBlock() {
        let current = document?.content ?? ""
        let separator = current.hasSuffix("\n") ? "\n" : "\n\n"
        store.updateMarkdown(documentID, content: current + separator + "$$\n\\hat{\\beta} = (X^\\top X)^{-1}X^\\top y\n$$\n")
    }

    private func export(_ document: MarkdownDocument) {
        let panel = NSSavePanel()
        panel.title = "导出 \(document.resolvedFormat.title)"
        let ext = document.resolvedFormat.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = document.title.isEmpty ? "未命名文稿.\(ext)" : "\(document.title).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.content.write(to: url, atomically: true, encoding: .utf8)
            store.operationMessage = "已导出 \(url.lastPathComponent)"
        } catch {
            store.operationMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private static func markdownFromLaTeX(_ source: String) -> String {
        var output = source
        output = output.replacingOccurrences(of: #"\\documentclass(?:\[[^\]]*\])?\{[^}]*\}"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\usepackage(?:\[[^\]]*\])?\{[^}]*\}"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\begin\{document\}|\\end\{document\}|\\maketitle|\\date\{[^}]*\}|\\author\{[^}]*\}"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\title\{([^}]*)\}"#, with: "# $1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\section\{([^}]*)\}"#, with: "## $1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\subsection\{([^}]*)\}"#, with: "### $1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\subsubsection\{([^}]*)\}"#, with: "#### $1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\textbf\{([^}]*)\}"#, with: "**$1**", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\(?:emph|textit)\{([^}]*)\}"#, with: "*$1*", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\begin\{(?:itemize|enumerate)\}|\\end\{(?:itemize|enumerate)\}"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\\item\s*"#, with: "- ", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class MarkdownSplitScrollController: ObservableObject {
    private weak var editorScrollView: NSScrollView?
    private weak var previewWebView: WKWebView?
    private var editorBoundsObserver: NSObjectProtocol?
    private var isApplyingEditorScroll = false
    private var isApplyingPreviewScroll = false
    private var latestProgress: CGFloat?

    func attachEditor(_ scrollView: NSScrollView) {
        guard editorScrollView !== scrollView else {
            if let latestProgress { applyToEditor(latestProgress) }
            return
        }
        detachEditor(editorScrollView)
        editorScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        editorBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            guard let self, let scrollView else { return }
            Task { @MainActor in self.editorDidScroll(scrollView) }
        }
        if let latestProgress { applyToEditor(latestProgress) }
    }

    func detachEditor(_ scrollView: NSScrollView?) {
        guard scrollView == nil || editorScrollView === scrollView else { return }
        if let editorBoundsObserver {
            NotificationCenter.default.removeObserver(editorBoundsObserver)
            self.editorBoundsObserver = nil
        }
        editorScrollView = nil
    }

    func attachPreview(_ webView: WKWebView) {
        guard previewWebView !== webView else { return }
        previewWebView = webView
        if let latestProgress { applyToPreview(latestProgress) }
    }

    func detachPreview(_ webView: WKWebView?) {
        guard webView == nil || previewWebView === webView else { return }
        previewWebView = nil
    }

    func previewDidScroll(progress: CGFloat) {
        guard !isApplyingPreviewScroll else { return }
        let progress = clamped(progress)
        latestProgress = progress
        applyToEditor(progress)
    }

    private func editorDidScroll(_ scrollView: NSScrollView) {
        guard !isApplyingEditorScroll else { return }
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let viewportHeight = scrollView.contentView.bounds.height
        let maximumOffset = max(0, documentHeight - viewportHeight)
        let progress = maximumOffset > 0 ? scrollView.contentView.bounds.minY / maximumOffset : 0
        let clampedProgress = clamped(progress)
        latestProgress = clampedProgress
        applyToPreview(clampedProgress)
    }

    private func applyToEditor(_ progress: CGFloat) {
        guard let scrollView = editorScrollView,
              let documentView = scrollView.documentView else { return }
        let maximumOffset = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        isApplyingEditorScroll = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset * clamped(progress)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.async { [weak self] in self?.isApplyingEditorScroll = false }
    }

    private func applyToPreview(_ progress: CGFloat) {
        guard let previewWebView else { return }
        isApplyingPreviewScroll = true
        let progress = clamped(progress)
        previewWebView.evaluateJavaScript(
            "window.scrollTo(0, Math.max(0, document.documentElement.scrollHeight - window.innerHeight) * \(progress));"
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.isApplyingPreviewScroll = false }
        }
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value.isFinite ? value : 0))
    }

    deinit {
        if let editorBoundsObserver { NotificationCenter.default.removeObserver(editorBoundsObserver) }
    }
}

@MainActor
final class MarkdownEditorController: ObservableObject {
    weak var textView: NSTextView?

    func attach(_ textView: NSTextView) {
        self.textView = textView
    }

    func undo() {
        focusEditor()
        textView?.undoManager?.undo()
    }

    func redo() {
        focusEditor()
        textView?.undoManager?.redo()
    }

    func wrap(prefix: String, suffix: String, placeholder: String) {
        guard let textView else { return }
        focusEditor()
        let range = textView.selectedRange()
        let source = textView.string as NSString
        let selected = range.length > 0 ? source.substring(with: range) : placeholder
        replace(range: range, with: prefix + selected + suffix)
        textView.setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: selected.utf16.count))
    }

    func heading(level: Int) {
        transformSelectedLines { line in
            let stripped = line.replacingOccurrences(
                of: #"^#{1,6}\s+"#,
                with: "",
                options: .regularExpression
            )
            return String(repeating: "#", count: level) + " " + stripped
        }
    }

    func prefixLines(_ prefix: String) {
        transformSelectedLines { line in
            line.hasPrefix(prefix) ? line : prefix + line
        }
    }

    func numberedList() {
        var index = 0
        transformSelectedLines { line in
            index += 1
            return "\(index). " + line
        }
    }

    func insert(_ text: String, selecting placeholder: String? = nil) {
        guard let textView else { return }
        focusEditor()
        let range = textView.selectedRange()
        replace(range: range, with: text)
        if let placeholder,
           let placeholderRange = text.range(of: placeholder) {
            let prefix = text[..<placeholderRange.lowerBound]
            textView.setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: placeholder.utf16.count))
        } else {
            textView.setSelectedRange(NSRange(location: range.location + text.utf16.count, length: 0))
        }
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.title = "插入附件链接"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let filename = url.lastPathComponent
        let isImage = ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(url.pathExtension.lowercased())
        let markdown = isImage
            ? "![\(filename)](\(url.absoluteString))"
            : "[\(filename)](\(url.absoluteString))"
        insert(markdown)
    }

    private func focusEditor() {
        if let textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        guard let textView else { return }
        focusEditor()
        let source = textView.string as NSString
        let selected = textView.selectedRange()
        let lineRange = source.lineRange(for: selected)
        let original = source.substring(with: lineRange)
        let keepsTrailingNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if keepsTrailingNewline, lines.last == "" { lines.removeLast() }
        let replacement = lines.map(transform).joined(separator: "\n") + (keepsTrailingNewline ? "\n" : "")
        replace(range: lineRange, with: replacement)
        textView.setSelectedRange(NSRange(location: lineRange.location, length: replacement.utf16.count))
    }

    private func replace(range: NSRange, with replacement: String) {
        guard let textView,
              textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
    }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    let scrollSyncController: MarkdownSplitScrollController?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        controller.attach(textView)
        scrollSyncController?.attachEditor(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.attach(textView)
        scrollSyncController?.attachEditor(scrollView)
        guard textView.string != text else { return }
        let selection = textView.selectedRange()
        textView.string = text
        let safeLocation = min(selection.location, (text as NSString).length)
        let safeLength = min(selection.length, (text as NSString).length - safeLocation)
        textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.parent.scrollSyncController?.detachEditor(scrollView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor

        init(parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

struct MarkdownFormattingBar: View {
    @ObservedObject var controller: MarkdownEditorController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                toolButton("撤销", icon: "arrow.uturn.backward", action: controller.undo)
                toolButton("重做", icon: "arrow.uturn.forward", action: controller.redo)
                separator

                Menu {
                    Button("一级标题") { controller.heading(level: 1) }
                    Button("二级标题") { controller.heading(level: 2) }
                    Button("三级标题") { controller.heading(level: 3) }
                } label: {
                    Label("标题", systemImage: "textformat.size")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("设置标题级别")

                toolButton("粗体", icon: "bold") {
                    controller.wrap(prefix: "**", suffix: "**", placeholder: "粗体文字")
                }
                toolButton("斜体", icon: "italic") {
                    controller.wrap(prefix: "*", suffix: "*", placeholder: "斜体文字")
                }
                toolButton("删除线", icon: "strikethrough") {
                    controller.wrap(prefix: "~~", suffix: "~~", placeholder: "删除文字")
                }
                toolButton("行内代码", icon: "chevron.left.forwardslash.chevron.right") {
                    controller.wrap(prefix: "`", suffix: "`", placeholder: "代码")
                }
                separator

                toolButton("链接", icon: "link") {
                    controller.wrap(prefix: "[", suffix: "](https://)", placeholder: "链接文字")
                }
                toolButton("附件", icon: "paperclip", action: controller.chooseAttachment)
                toolButton("引用", icon: "text.quote") { controller.prefixLines("> ") }
                toolButton("无序列表", icon: "list.bullet") { controller.prefixLines("- ") }
                toolButton("有序列表", icon: "list.number") { controller.numberedList() }
                toolButton("任务项", icon: "checkmark.circle") { controller.prefixLines("- [ ] ") }
                separator

                toolButton("表格", icon: "tablecells") {
                    controller.insert("| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |\n", selecting: "列 1")
                }
                toolButton("代码块", icon: "curlybraces") {
                    controller.insert("```\n代码\n```\n", selecting: "代码")
                }
                toolButton("公式", icon: "function") {
                    controller.insert("$$\n\\hat{\\beta} = (X^\\top X)^{-1}X^\\top y\n$$\n", selecting: "\\hat{\\beta} = (X^\\top X)^{-1}X^\\top y")
                }
                toolButton("分隔线", icon: "minus") { controller.insert("\n---\n") }
                separator
                toolButton("全屏", icon: "arrow.up.left.and.arrow.down.right", action: controller.toggleFullScreen)
            }
            .fixedSize()
            HStack(spacing: 6) {
                toolButton("撤销", icon: "arrow.uturn.backward", action: controller.undo)
                toolButton("重做", icon: "arrow.uturn.forward", action: controller.redo)
                separator
                Menu {
                    ForEach(1...6, id: \.self) { level in
                        Button("\(level) 级标题") { controller.heading(level: level) }
                    }
                } label: { Label("标题", systemImage: "textformat.size") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                toolButton("粗体", icon: "bold") {
                    controller.wrap(prefix: "**", suffix: "**", placeholder: "粗体文字")
                }
                toolButton("斜体", icon: "italic") {
                    controller.wrap(prefix: "*", suffix: "*", placeholder: "斜体文字")
                }
                toolButton("链接", icon: "link") {
                    controller.wrap(prefix: "[", suffix: "](https://)", placeholder: "链接文字")
                }
                Menu {
                    Button("删除线", systemImage: "strikethrough") {
                        controller.wrap(prefix: "~~", suffix: "~~", placeholder: "删除文字")
                    }
                    Button("行内代码", systemImage: "chevron.left.forwardslash.chevron.right") {
                        controller.wrap(prefix: "`", suffix: "`", placeholder: "代码")
                    }
                    Button("附件", systemImage: "paperclip", action: controller.chooseAttachment)
                    Divider()
                    Button("引用", systemImage: "text.quote") { controller.prefixLines("> ") }
                    Button("无序列表", systemImage: "list.bullet") { controller.prefixLines("- ") }
                    Button("有序列表", systemImage: "list.number", action: controller.numberedList)
                    Button("任务项", systemImage: "checkmark.circle") { controller.prefixLines("- [ ] ") }
                    Divider()
                    Button("表格", systemImage: "tablecells") {
                        controller.insert("| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |\n", selecting: "列 1")
                    }
                    Button("代码块", systemImage: "curlybraces") {
                        controller.insert("```\n代码\n```\n", selecting: "代码")
                    }
                    Button("公式", systemImage: "function") {
                        controller.insert("$$\n\\hat{\\beta} = (X^\\top X)^{-1}X^\\top y\n$$\n", selecting: "\\hat{\\beta} = (X^\\top X)^{-1}X^\\top y")
                    }
                    Button("分隔线", systemImage: "minus") { controller.insert("\n---\n") }
                    Divider()
                    Button("全屏", systemImage: "arrow.up.left.and.arrow.down.right", action: controller.toggleFullScreen)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("更多格式")
                .accessibilityLabel("更多格式")
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .researchGlassSurface(cornerRadius: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 3)
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct NewWritingDocumentSheet: View {
    let initialKind: WritingDocumentKind
    let onCreate: (String, WritingDocumentKind, WritingDocumentFormat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: WritingDocumentKind
    @State private var format: WritingDocumentFormat

    init(
        initialKind: WritingDocumentKind,
        onCreate: @escaping (String, WritingDocumentKind, WritingDocumentFormat) -> Void
    ) {
        self.initialKind = initialKind
        self.onCreate = onCreate
        _kind = State(initialValue: initialKind)
        _format = State(initialValue: initialKind == .note ? .markdown : .latex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(kind == .note ? "新建笔记" : "新建论文")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    onCreate(title, kind, resolvedFormat)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Picker("内容类型", selection: $kind) {
                ForEach(WritingDocumentKind.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, newKind in
                format = newKind == .note ? .markdown : .latex
            }

            TextField(kind == .note ? "例如：研究思路随记" : "例如：有限负荷转移的碳排放决策", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onCreate(title, kind, resolvedFormat)
                    dismiss()
                }

            if kind == .paper {
                VStack(alignment: .leading, spacing: 8) {
                    Text("论文格式")
                        .font(.subheadline.weight(.medium))
                    Picker("论文格式", selection: $format) {
                        Label("LaTeX", systemImage: "function").tag(WritingDocumentFormat.latex)
                        Label("Word", systemImage: "doc.richtext").tag(WritingDocumentFormat.word)
                    }
                    .pickerStyle(.segmented)
                }
            }

            Text(kind == .note
                 ? "笔记使用 Markdown，支持公式、表格和阅读预览。"
                 : "LaTeX 提供源码与实时预览；Word 提供 App 内富文本编辑并可导出 .docx。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(width: 540, height: kind == .paper ? 330 : 270)
    }

    private var resolvedFormat: WritingDocumentFormat {
        kind == .note ? .markdown : format
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let documentID: UUID
    let markdown: String
    let readingPositionStore: MarkdownReadingPositionStore
    let scrollSyncController: MarkdownSplitScrollController?
    let previewController: MarkdownPreviewController
    let readingOptions: MarkdownReadingOptions
    var onOpenURL: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "readingPosition")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                window.addEventListener('scroll', () => {
                  const offset = window.scrollY || 0;
                  const maximum = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
                  window.webkit.messageHandlers.readingPosition.postMessage({
                    offset: offset,
                    progress: maximum > 0 ? offset / maximum : 0
                  });
                }, { passive: true });
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.pendingMarkdown = markdown
        previewController.attach(webView, documentID: documentID)
        scrollSyncController?.attachPreview(webView)
        webView.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.parent.documentID != documentID {
            context.coordinator.captureScrollPosition()
        }
        context.coordinator.parent = self
        previewController.attach(webView, documentID: documentID)
        scrollSyncController?.attachPreview(webView)
        context.coordinator.render(markdown)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.captureScrollPosition()
        coordinator.parent.scrollSyncController?.detachPreview(webView)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingPosition")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownPreview
        weak var webView: WKWebView?
        var isReady = false
        var pendingMarkdown = ""
        private var lastRendered: String?
        private var lastRenderedDocumentID: UUID?
        private var lastAppliedOptions: MarkdownReadingOptions?
        private var renderGeneration = 0
        private var isRestoringPosition = true

        init(parent: MarkdownPreview) {
            self.parent = parent
        }

        func captureScrollPosition() {
            guard isReady, !isRestoringPosition, let webView else { return }
            let documentID = parent.documentID
            let positionStore = parent.readingPositionStore
            webView.evaluateJavaScript("window.scrollY || 0") { [weak self] result, _ in
                guard self != nil, let offset = result as? NSNumber else { return }
                positionStore.setOffset(CGFloat(truncating: offset), for: documentID)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isRestoringPosition, message.name == "readingPosition" else { return }
            if let payload = message.body as? [String: Any],
               let offset = payload["offset"] as? NSNumber,
               let progress = payload["progress"] as? NSNumber {
                parent.readingPositionStore.setOffset(CGFloat(truncating: offset), for: parent.documentID)
                parent.scrollSyncController?.previewDidScroll(progress: CGFloat(truncating: progress))
            } else if let offset = message.body as? NSNumber {
                parent.readingPositionStore.setOffset(CGFloat(truncating: offset), for: parent.documentID)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            render(pendingMarkdown)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
                let url = navigationAction.request.url {
                if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    captureScrollPosition()
                    parent.onOpenURL?(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func render(_ markdown: String) {
            pendingMarkdown = markdown
            guard isReady, let webView else { return }
            guard markdown != lastRendered || parent.documentID != lastRenderedDocumentID else {
                applyReadingOptions()
                return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: [markdown]),
                  let jsonArray = String(data: data, encoding: .utf8) else { return }
            lastRendered = markdown
            lastRenderedDocumentID = parent.documentID
            lastAppliedOptions = parent.readingOptions
            isRestoringPosition = true
            renderGeneration += 1
            let generation = renderGeneration
            let documentID = parent.documentID
            let script = "applyReadingOptions(\(parent.readingOptions.javascriptValue), false); renderMarkdown((\(jsonArray))[0]);"
            webView.evaluateJavaScript(script) { [weak self] headings, _ in
                DispatchQueue.main.async {
                    guard let self, self.renderGeneration == generation,
                          self.parent.documentID == documentID else { return }
                    self.parent.previewController.updateHeadings(headings, documentID: documentID)
                    self.restoreScrollPosition()
                }
            }
        }

        private func applyReadingOptions() {
            guard lastAppliedOptions != parent.readingOptions, let webView else { return }
            lastAppliedOptions = parent.readingOptions
            webView.evaluateJavaScript("applyReadingOptions(\(parent.readingOptions.javascriptValue), true);") { [weak self] _, _ in
                self?.captureScrollPosition()
            }
        }

        private func restoreScrollPosition() {
            guard let webView else {
                isRestoringPosition = false
                return
            }
            let savedOffset = parent.readingPositionStore.offset(for: parent.documentID)
            let generation = renderGeneration
            webView.evaluateJavaScript(
                "window.scrollTo(0, Math.min(\(savedOffset), Math.max(0, document.documentElement.scrollHeight - window.innerHeight)));"
            ) { [weak self] _, _ in
                guard let self, self.renderGeneration == generation else { return }
                self.isRestoringPosition = false
                webView.evaluateJavaScript(
                    "(() => { const maximum = Math.max(0, document.documentElement.scrollHeight - window.innerHeight); return maximum > 0 ? (window.scrollY || 0) / maximum : 0; })()"
                ) { [weak self] result, _ in
                    guard let progress = result as? NSNumber else { return }
                    self?.parent.scrollSyncController?.previewDidScroll(progress: CGFloat(truncating: progress))
                }
            }
        }
    }

    private static let html = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="stylesheet" href="MarkdownAssets/katex.min.css">
      <script src="MarkdownAssets/marked.min.js"></script>
      <script src="MarkdownAssets/katex.min.js"></script>
      <script src="MarkdownAssets/auto-render.min.js"></script>
      <style>
        :root { color-scheme: light dark; --paper:#ffffff; --ink:#202124; --muted:#6b6f76; --rule:#e5e7eb; --accent:#1769e0; --code:#f3f5f8; --quote:#edf4ff; --reading-font-size:17px; --reading-line-height:1.72; --reading-page-width:790px; }
        @media (prefers-color-scheme: dark) { :root { --paper:#1c1c1e; --ink:#f2f2f3; --muted:#a7a7ad; --rule:#38383c; --accent:#5e9cff; --code:#292a2e; --quote:#17263d; } }
        * { box-sizing:border-box; }
        html, body { margin:0; min-height:100%; background:transparent; color:var(--ink); }
        body { font-family:"New York", "Songti SC", ui-serif, Georgia, serif; font-size:var(--reading-font-size); line-height:var(--reading-line-height); -webkit-font-smoothing:antialiased; overflow-wrap:anywhere; }
        #content { max-width:var(--reading-page-width); min-height:100vh; margin:0 auto; padding:44px 48px 96px; background:var(--paper); }
        h1, h2, h3, h4, h5, h6 { font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; letter-spacing:-0.02em; line-height:1.35; scroll-margin-top:24px; }
        h1 { font-size:1.8em; margin:1.8em 0 .9em; padding-bottom:.42em; border-bottom:1px solid var(--rule); }
        #content > :first-child { margin-top:0; }
        h2 { font-size:1.35em; margin:1.9em 0 .75em; }
        h3 { font-size:1.15em; margin:1.6em 0 .55em; }
        h4, h5, h6 { font-size:1em; margin:1.5em 0 .5em; }
        p { margin:.85em 0; }
        a { color:var(--accent); text-decoration-thickness:1px; text-underline-offset:3px; }
        blockquote { margin:1.4em 0; padding:10px 18px; border-left:3px solid var(--accent); background:var(--quote); color:var(--muted); }
        blockquote p { margin:.35em 0; }
        code { font-family:"SFMono-Regular", ui-monospace, monospace; font-size:.84em; padding:.15em .36em; border-radius:5px; background:var(--code); }
        pre { overflow:auto; padding:17px 19px; border:1px solid var(--rule); border-radius:10px; background:var(--code); line-height:1.55; }
        pre code { padding:0; background:transparent; }
        table { width:100%; margin:1.4em 0; border-collapse:collapse; font-family:-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; font-size:.9em; }
        th, td { padding:10px 12px; border-bottom:1px solid var(--rule); text-align:left; }
        th { font-weight:650; background:var(--code); }
        img { max-width:100%; border-radius:8px; }
        hr { border:0; border-top:1px solid var(--rule); margin:2.3em 0; }
        li { margin:.28em 0; }
        input[type="checkbox"] { margin-right:8px; accent-color:var(--accent); }
        .katex-display { overflow-x:auto; overflow-y:hidden; padding:12px 0; }
        .katex { font-size:1.08em; }
        @media (max-width:700px) { #content { padding:30px 28px 70px; } }
        @media (max-width:450px) { #content { padding:24px 18px 64px; } }
      </style>
    </head>
    <body>
      <main id="content"></main>
      <script>
        const safeRenderer = {
          html(token) {
            return token.text
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;');
          }
        };
        marked.use({ gfm: true, breaks: false, renderer: safeRenderer });

        function applyReadingOptions(options, preservePosition) {
          const content = document.getElementById('content');
          const previousOffset = window.scrollY || 0;
          let anchor = null;
          if (preservePosition && previousOffset > 0) {
            const element = Array.from(content.children).find(node => node.getBoundingClientRect().bottom > 0);
            if (element) {
              const bounds = element.getBoundingClientRect();
              anchor = { element, fraction: -bounds.top / Math.max(1, bounds.height) };
            }
          }
          const safeNumber = (value, fallback, minimum, maximum) =>
            Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, value)) : fallback;
          const root = document.documentElement.style;
          root.setProperty('--reading-font-size', `${safeNumber(options.fontSize, 17, 14, 24)}px`);
          root.setProperty('--reading-line-height', safeNumber(options.lineHeight, 1.72, 1.4, 2.1));
          root.setProperty('--reading-page-width', `${safeNumber(options.pageWidth, 790, 600, 1200)}px`);
          if (preservePosition) {
            if (anchor) {
              const bounds = anchor.element.getBoundingClientRect();
              window.scrollTo(0, bounds.top + window.scrollY + anchor.fraction * bounds.height);
            } else {
              window.scrollTo(0, previousOffset);
            }
          }
          return window.scrollY || 0;
        }

        function protectMath(source) {
          const formulas = [];
          const stash = (raw, display) => {
            const index = formulas.length;
            formulas.push(raw);
            const token = `ROSMATH${display ? 'BLOCK' : 'INLINE'}TOKEN${index}END`;
            return display ? `\n\n${token}\n\n` : token;
          };

          let protectedSource = source || '';
          protectedSource = protectedSource.replace(
            /\\begin\{(equation\*?|align\*?|gather\*?|multline\*?)\}[\s\S]*?\\end\{\1\}/g,
            raw => stash(raw, true)
          );
          protectedSource = protectedSource.replace(/\$\$[\s\S]*?\$\$/g, raw => stash(raw, true));
          protectedSource = protectedSource.replace(/\\\[[\s\S]*?\\\]/g, raw => stash(raw, true));
          protectedSource = protectedSource.replace(/\\\([\s\S]*?\\\)/g, raw => stash(raw, false));
          protectedSource = protectedSource.replace(
            /(^|[^\\$])\$([^$\n]+?)\$/gm,
            (_, prefix, expression) => prefix + stash(`$${expression}$`, false)
          );
          return { source: protectedSource, formulas };
        }

        function restoreMath(target, formulas) {
          if (!formulas.length) return;
          const tokenPattern = /ROSMATH(?:BLOCK|INLINE)TOKEN(\d+)END/g;
          const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT);
          const nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);

          for (const node of nodes) {
            const text = node.nodeValue || '';
            if (!tokenPattern.test(text)) {
              tokenPattern.lastIndex = 0;
              continue;
            }
            tokenPattern.lastIndex = 0;
            const fragment = document.createDocumentFragment();
            let cursor = 0;
            let match;
            while ((match = tokenPattern.exec(text)) !== null) {
              fragment.appendChild(document.createTextNode(text.slice(cursor, match.index)));
              fragment.appendChild(document.createTextNode(formulas[Number(match[1])] || ''));
              cursor = match.index + match[0].length;
            }
            fragment.appendChild(document.createTextNode(text.slice(cursor)));
            node.parentNode.replaceChild(fragment, node);
          }
        }

        function renderMarkdown(source) {
          const target = document.getElementById('content');
          const protectedMath = protectMath(source);
          target.innerHTML = marked.parse(protectedMath.source);
          restoreMath(target, protectedMath.formulas);
          renderMathInElement(target, {
            delimiters: [
              {left: '$$', right: '$$', display: true},
              {left: '\\[', right: '\\]', display: true},
              {left: '\\(', right: '\\)', display: false},
              {left: '\\begin{equation}', right: '\\end{equation}', display: true},
              {left: '\\begin{equation*}', right: '\\end{equation*}', display: true},
              {left: '\\begin{align}', right: '\\end{align}', display: true},
              {left: '\\begin{align*}', right: '\\end{align*}', display: true},
              {left: '\\begin{gather}', right: '\\end{gather}', display: true},
              {left: '\\begin{gather*}', right: '\\end{gather*}', display: true},
              {left: '\\begin{multline}', right: '\\end{multline}', display: true},
              {left: '\\begin{multline*}', right: '\\end{multline*}', display: true},
              {left: '$', right: '$', display: false}
            ],
            throwOnError: false,
            strict: 'ignore',
            ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
          });
          // Read the rendered structure, so fenced code, escaped HTML and formulas
          // cannot accidentally become outline entries. Index IDs also handle repeats.
          return Array.from(target.querySelectorAll('h1, h2, h3, h4, h5, h6')).map((heading, index) => {
            heading.id = `researchos-heading-${index}`;
            const label = heading.cloneNode(true);
            label.querySelectorAll('.katex-mathml').forEach(node => node.remove());
            return {
              id: heading.id,
              level: Number(heading.tagName.slice(1)),
              title: (label.textContent || '').replace(/\s+/g, ' ').trim() || '未命名标题'
            };
          });
        }
      </script>
    </body>
    </html>
    """#
}
