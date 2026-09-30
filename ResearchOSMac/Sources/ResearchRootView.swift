import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum ResearchTabContent: Hashable {
    case document(UUID)
    case paper(UUID)
    case browser(URL)
}

private struct ResearchTab: Identifiable, Hashable {
    let id: UUID
    let content: ResearchTabContent
    var browserTitle: String?

    init(content: ResearchTabContent) {
        id = UUID()
        self.content = content
    }
}

struct GlobalSearchResult: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
    let target: GlobalSearchTarget
}

enum GlobalSearchTarget { case question(UUID), paper(UUID), document(UUID) }

struct ResearchRootView: View {
    @ObservedObject var store: ResearchStore
    @State private var workspace: WorkspaceSection? = .questions
    @State private var selectedQuestion: UUID?
    @State private var selectedPaper: UUID?
    @State private var selectedMarkdownDocument: UUID?
    @State private var selectedGraphNode: UUID?
    @State private var selectedCollection: Int64?
    @State private var isImporting = false
    @State private var isImportingPaperFolder = false
    @State private var isImportingWritingDocument = false
    @State private var isImportingWritingFolder = false
    @State private var isSelectingWritingFolderForSync = false
    @State private var writingFolderSyncTarget: UUID?
    @State private var isSelectingWritingDocumentForSync = false
    @State private var writingDocumentSyncTarget: UUID?
    @State private var writingImportKind: WritingDocumentKind = .note
    @State private var showAsk = false
    @State private var showNewQuestion = false
    @State private var newWritingKind: WritingDocumentKind?
    @State private var showEditQuestion = false
    @State private var showDeleteQuestion = false
    @State private var tabs: [ResearchTab] = []
    @State private var recentlyClosedTabs: [ResearchTab] = []
    @State private var activeTabID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previousColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFocused = false
    @State private var writingQuery = ""
    @State private var inboxQuery = ""
    @State private var libraryQuery = ""
    @State private var globalSearchQuery = ""
    @State private var showGlobalSearch = false
    @State private var showNewWritingFolder = false
    @AppStorage("ResearchOS.isWorkspaceListHidden") private var isWorkspaceListHidden = false
    @AppStorage("ResearchOS.listDensity") private var listDensity = "comfortable"
    @AppStorage("ResearchOS.showsListPreview") private var showsListPreview = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var markdownReadingPositions = MarkdownReadingPositionStore()
    @StateObject private var pdfReadingPositions = PDFReadingPositionStore()

    init(store: ResearchStore) {
        self.store = store
        _selectedQuestion = State(initialValue: store.questions.first?.id)
        _selectedPaper = State(initialValue: store.papers.first?.id)
        _selectedMarkdownDocument = State(initialValue: store.markdownDocuments.first?.id)
        _selectedGraphNode = State(initialValue: store.knowledgeGraph.nodes.first?.id)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(selection: $workspace, inboxCount: 0)
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            workspaceColumns
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: paperImportTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let importedIDs = store.importPaperDocuments(from: urls)
            workspace = .library
            selectedPaper = importedIDs.first ?? store.papers.first?.id
        }
        .fileImporter(isPresented: $isImportingPaperFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let folderURL = urls.first else { return }
            let importedIDs = store.importPaperFolder(from: folderURL)
            workspace = .library
            selectedPaper = importedIDs.first ?? store.papers.first?.id
        }
        .fileImporter(isPresented: $isImportingWritingDocument, allowedContentTypes: writingImportTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var firstImportedID: UUID?
            for url in urls {
                let id = store.importWritingDocument(from: url, as: writingImportKind)
                if firstImportedID == nil { firstImportedID = id }
            }
            if let firstImportedID {
                selectedMarkdownDocument = firstImportedID
                workspace = .writing
                openTab(.document(firstImportedID))
            }
        }
        .fileImporter(isPresented: $isImportingWritingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let folderURL = urls.first else { return }
            let importedIDs = store.importWritingFolder(from: folderURL)
            if let firstImportedID = importedIDs.first {
                selectedMarkdownDocument = firstImportedID
                workspace = .writing
                openTab(.document(firstImportedID))
            }
        }
        .fileImporter(isPresented: $isSelectingWritingFolderForSync, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            defer { writingFolderSyncTarget = nil }
            guard case .success(let urls) = result,
                  let folderURL = urls.first,
                  let folderID = writingFolderSyncTarget else { return }
            store.linkAndSyncWritingFolder(folderID, from: folderURL)
        }
        .fileImporter(isPresented: $isSelectingWritingDocumentForSync, allowedContentTypes: writingImportTypes, allowsMultipleSelection: false) { result in
            defer { writingDocumentSyncTarget = nil }
            guard case .success(let urls) = result,
                  let sourceURL = urls.first,
                  let documentID = writingDocumentSyncTarget else { return }
            store.linkAndSyncWritingDocument(documentID, from: sourceURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.syncWritingSourcesWhenActivated()
        }
        .sheet(isPresented: $showAsk) {
            if let question = selectedResearchQuestion {
                AskResearchSheet(question: question)
            }
        }
        .sheet(isPresented: $showGlobalSearch) {
            GlobalSearchSheet(store: store, query: $globalSearchQuery) { result in
                switch result.target {
                case .question(let id): workspace = .questions; selectedQuestion = id
                case .paper(let id): workspace = .library; selectedPaper = id; openTab(.paper(id))
                case .document(let id): workspace = .writing; selectedMarkdownDocument = id; openTab(.document(id))
                }
                showGlobalSearch = false
            }
        }
        .sheet(isPresented: $showNewQuestion) {
            NewQuestionSheet { title, question in
                selectedQuestion = store.addQuestion(title: title, question: question)
                workspace = .questions
            }
        }
        .sheet(item: $newWritingKind) { initialKind in
            NewWritingDocumentSheet(initialKind: initialKind) { title, kind, format in
                let id = store.createWritingDocument(title: title, kind: kind, format: format)
                selectedMarkdownDocument = id
                workspace = .writing
                openTab(.document(id))
            }
        }
        .sheet(isPresented: $showNewWritingFolder) {
            WritingNameSheet(title: "新建文件夹", initialValue: "", prompt: "文件夹名称") { name in
                _ = store.createWritingFolder(name: name)
            }
        }
        .sheet(isPresented: $showEditQuestion) {
            if let question = selectedResearchQuestion {
                EditQuestionSheet(question: question) { title, updatedQuestion in
                    store.updateQuestion(question.id, title: title, question: updatedQuestion)
                }
            }
        }
        .alert("删除研究项目？", isPresented: $showDeleteQuestion) {
            Button("删除", role: .destructive) {
                guard let id = selectedQuestion else { return }
                store.deleteQuestion(id)
                selectedQuestion = store.questions.first?.id
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除这个研究项目及其证据卡片；论文和 Markdown 文稿不会删除。")
        }
        .onChange(of: selectedMarkdownDocument) { _, newValue in
            guard workspace == .writing, let newValue else { return }
            openTab(.document(newValue))
        }
        .onChange(of: selectedPaper) { _, newValue in
            guard workspace == .library, let newValue else { return }
            openTab(.paper(newValue))
        }
        .onChange(of: workspace) { _, newValue in
            if isFocused { toggleFocus() }
            switch newValue {
            case .writing:
                if let selectedMarkdownDocument { openTab(.document(selectedMarkdownDocument)) }
            case .library:
                if let selectedPaper { openTab(.paper(selectedPaper)) }
            default:
                activeTabID = nil
            }
        }
        .onChange(of: activeTabID) { _, newValue in
            if newValue == nil, isFocused { toggleFocus() }
        }
        .onChange(of: columnVisibility) { _, visibility in
            if isFocused, visibility != .detailOnly { isFocused = false }
        }
        .onChange(of: writingQuery) { _, value in revealListForSearch(value) }
        .onChange(of: inboxQuery) { _, value in revealListForSearch(value) }
        .onChange(of: libraryQuery) { _, value in revealListForSearch(value) }
    }

    private var workspaceColumns: some View {
        HSplitView {
            if showsWorkspaceList {
                contentColumn
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
            }

            detailColumn
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ResearchPalette.window)
        }
        .modifier(WorkspaceSearchModifier(query: workspaceSearch, enabled: supportsWorkspaceListToggle, prompt: searchPrompt))
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) {
            if let message = store.operationMessage {
                HStack(spacing: 8) {
                    if store.isBusy { ProgressView().controlSize(.small) }
                    Text(message).font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
    }

    private var supportsWorkspaceListToggle: Bool {
        switch workspace {
        case .writing, .library: true
        default: false
        }
    }

    private var showsWorkspaceList: Bool {
        !isFocused && (!supportsWorkspaceListToggle || !isWorkspaceListHidden)
    }

    private var workspaceSearch: Binding<String> {
        switch workspace {
        case .writing: $writingQuery
        case .inbox: $inboxQuery
        case .library: $libraryQuery
        default: .constant("")
        }
    }

    private var searchPrompt: String {
        workspace == .writing ? "搜索文稿" : "搜索标题或作者"
    }

    private func revealListForSearch(_ query: String) {
        guard !query.isEmpty else { return }
        if isFocused { toggleFocus() }
        isWorkspaceListHidden = false
    }

    private func toggleFocus() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            if isFocused {
                isFocused = false
                columnVisibility = previousColumnVisibility
            } else {
                previousColumnVisibility = columnVisibility
                isFocused = true
                columnVisibility = .detailOnly
            }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch workspace ?? .questions {
        case .questions:
            QuestionList(questions: store.questions, selection: $selectedQuestion, showNewQuestion: $showNewQuestion)
        case .writing:
            MarkdownDocumentList(
                store: store,
                selection: $selectedMarkdownDocument,
                query: $writingQuery,
                onNewNote: { presentNewWritingDocument(.note) },
                onNewPaper: { presentNewWritingDocument(.paper) },
                onImport: { presentWritingImporter(.note) },
                onImportFolder: { isImportingWritingFolder = true },
                onSyncFolder: syncWritingFolder,
                onSyncDocument: syncWritingDocument,
                onDuplicate: duplicateWritingDocumentAndOpen,
                onDelete: deleteWritingDocumentAndClose
            )
        case .knowledgeGraph:
            KnowledgeGraphNodeList(graph: store.knowledgeGraph, selection: $selectedGraphNode)
        case .inbox:
            PaperList(store: store, title: "论文库", papers: store.papers, selection: $selectedPaper, query: $libraryQuery)
        case .library:
            PaperList(
                store: store,
                title: "论文库",
                papers: store.papers,
                selection: $selectedPaper,
                query: $libraryQuery
            )
        case .zotero:
            ZoteroCollectionList(collections: store.zoteroCollections, selection: $selectedCollection)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        VStack(spacing: 0) {
            if activeTab != nil && !isFocused {
                ResearchTabBar(
                    tabs: tabs,
                    activeTabID: activeTabID,
                    store: store,
                    onSelect: { activeTabID = $0 },
                    onClose: closeTab,
                    onCloseOthers: closeOtherTabs,
                    onMove: moveTab,
                    onReopen: reopenLastTab,
                    canReopen: !recentlyClosedTabs.isEmpty,
                    onNewNote: { presentNewWritingDocument(.note) },
                    onNewPaper: { presentNewWritingDocument(.paper) }
                )
            }

            Group {
                if let tab = activeTab {
                    tabContent(tab)
                } else {
                    workspaceDetailColumn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Button("重新打开关闭的标签页", action: reopenLastTab)
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .hidden()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: ResearchTab) -> some View {
        switch tab.content {
        case .document(let id):
            MarkdownEditorWorkspace(
                store: store,
                documentID: id,
                readingPositionStore: markdownReadingPositions,
                onOpenURL: { openTab(.browser($0)) }
            )
        case .paper(let id):
            if let paper = store.papers.first(where: { $0.id == id }) {
                PaperReadingWorkspace(
                    store: store,
                    paper: paper,
                    readingPositionStore: pdfReadingPositions,
                    onOpenURL: { openTab(.browser($0)) },
                    onNewNote: { createReadingNote(for: paper) }
                )
                .id(paper.id)
            } else {
                ContentUnavailableView("论文不存在", systemImage: "doc.badge.ellipsis")
            }
        case .browser(let url):
            InAppBrowserWorkspace(
                initialURL: url,
                onClose: { closeTab(tab.id) },
                onTitleChange: { updateBrowserTitle($0, for: tab.id) }
            )
        }
    }

    @ViewBuilder
    private var workspaceDetailColumn: some View {
        switch workspace ?? .questions {
        case .questions:
            if let question = selectedResearchQuestion {
                QuestionDetailView(store: store, question: question)
            } else {
                ContentUnavailableView("选择一个研究项目", systemImage: "questionmark.bubble")
            }
        case .writing:
            if let id = selectedMarkdownDocument,
               store.markdownDocuments.contains(where: { $0.id == id }) {
                MarkdownEditorWorkspace(
                    store: store,
                    documentID: id,
                    readingPositionStore: markdownReadingPositions,
                    onOpenURL: { openTab(.browser($0)) }
                )
            } else {
                MarkdownWelcomeView(
                    onNewNote: { presentNewWritingDocument(.note) },
                    onNewPaper: { presentNewWritingDocument(.paper) },
                    onImport: { presentWritingImporter(.note) }
                )
            }
        case .knowledgeGraph:
            KnowledgeGraphDetailView(
                graph: store.knowledgeGraph,
                selection: $selectedGraphNode,
                onRebuild: {
                    store.rebuildKnowledgeGraph()
                    if selectedGraphNode == nil {
                        selectedGraphNode = store.knowledgeGraph.nodes.first?.id
                    }
                }
            )
        case .library:
            if let paper = selectedResearchPaper {
                PaperReadingWorkspace(
                    store: store,
                    paper: paper,
                    readingPositionStore: pdfReadingPositions,
                    onOpenURL: { openTab(.browser($0)) },
                    onNewNote: { createReadingNote(for: paper) }
                )
                .id(paper.id)
            } else {
                ContentUnavailableView("选择一篇论文", systemImage: "doc.text")
            }
        case .inbox:
            if let paper = selectedResearchPaper {
                PaperReadingWorkspace(
                    store: store,
                    paper: paper,
                    readingPositionStore: pdfReadingPositions,
                    onOpenURL: { openTab(.browser($0)) },
                    onNewNote: { presentNewWritingDocument(.note) }
                )
            } else {
                ContentUnavailableView("选择一篇论文", systemImage: "doc.text")
            }
        case .zotero:
            if let collection = store.zoteroCollections.first(where: { $0.id == selectedCollection }) {
                ZoteroCollectionDetail(store: store, collection: collection)
            } else {
                ZoteroWelcomeView(store: store)
            }
        }
    }

    private var selectedResearchQuestion: ResearchQuestion? {
        store.questions.first { $0.id == selectedQuestion }
    }

    private var selectedResearchPaper: Paper? {
        return store.papers.first { $0.id == selectedPaper }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if supportsWorkspaceListToggle {
                Button(isWorkspaceListHidden || isFocused ? "显示列表" : "隐藏列表", systemImage: "rectangle.leadinghalf.inset.filled") {
                    if isFocused {
                        toggleFocus()
                        isWorkspaceListHidden = false
                    } else {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            isWorkspaceListHidden.toggle()
                        }
                    }
                }
                .help(isWorkspaceListHidden || isFocused ? "显示文稿或论文列表" : "隐藏文稿或论文列表")
                .accessibilityIdentifier("workspace-list-toggle")
                Button(isFocused ? "退出专注" : "专注模式", systemImage: isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    toggleFocus()
                }
                .disabled(activeTab == nil)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help(isFocused ? "退出专注，恢复原布局（⇧⌘F）" : "隐藏导航、列表和标签栏，专注正文（⇧⌘F）")
                .accessibilityIdentifier("workspace-focus-toggle")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("全局搜索", systemImage: "magnifyingglass") { showGlobalSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .help("搜索论文、原文、文稿和研究问题")
            if supportsWorkspaceListToggle {
                Menu {
                    Picker("列表密度", selection: $listDensity) {
                        Text("紧凑").tag("compact")
                        Text("舒适").tag("comfortable")
                    }
                    if workspace == .writing {
                        Divider()
                        Toggle("显示正文预览", isOn: $showsListPreview)
                    }
                } label: {
                    Label("列表外观", systemImage: "slider.horizontal.3")
                }
                .help("列表密度与正文预览")
                .accessibilityIdentifier("workspace-list-appearance")
            }
            if activeTabID == nil, workspace == .questions {
                Button("新建研究项目", systemImage: "plus") { showNewQuestion = true }
                Button("编辑研究项目", systemImage: "pencil") { showEditQuestion = true }
                    .disabled(selectedResearchQuestion == nil)
                Button("询问 ResearchOS", systemImage: "sparkles") { showAsk = true }
                    .disabled(selectedResearchQuestion == nil)
            }
            if activeTabID == nil, workspace == .knowledgeGraph {
                Button("更新知识图谱", systemImage: "arrow.triangle.2.circlepath") {
                    store.rebuildKnowledgeGraph()
                    selectedGraphNode = store.knowledgeGraph.nodes.first?.id
                }
            }
            if workspace == .writing {
                Menu {
                    Section("新建") {
                        Button("新建笔记", systemImage: "note.text.badge.plus") { presentNewWritingDocument(.note) }
                        Button("新建论文", systemImage: "doc.badge.plus") { presentNewWritingDocument(.paper) }
                        Button("新建文件夹", systemImage: "folder.badge.plus") { showNewWritingFolder = true }
                    }
                    Section("导入") {
                        Button("导入为笔记", systemImage: "note.text") { presentWritingImporter(.note) }
                        Button("导入为论文", systemImage: "doc.text") { presentWritingImporter(.paper) }
                        Button("导入文件夹", systemImage: "folder.badge.plus") { isImportingWritingFolder = true }
                    }
                } label: {
                    Label("新建或导入", systemImage: "plus")
                }
                .help("新建笔记、论文或文件夹，导入已有文稿")
                .accessibilityIdentifier("workspace-add")
            } else if workspace == .library {
                Menu {
                    Button("导入文献文件", systemImage: "doc.badge.plus") { isImporting = true }
                    Button("导入文献文件夹", systemImage: "folder.badge.plus") { isImportingPaperFolder = true }
                    Divider()
                    Button("提取可用原文", systemImage: "doc.text.magnifyingglass") {
                        store.extractAvailableFullTexts()
                    }
                    .disabled(store.isBusy)
                } label: {
                    Label("导入文献", systemImage: "plus")
                }
                .help("导入 PDF、Word 或文献文件夹")
                .accessibilityIdentifier("workspace-add")
            }
            if activeTabID == nil && !supportsWorkspaceListToggle {
                Menu {
                    Button("导入 PDF 或 Word", systemImage: "doc.badge.plus") { isImporting = true }
                    Button("导入文献文件夹", systemImage: "folder.badge.plus") { isImportingPaperFolder = true }
                } label: {
                    Label("导入文献", systemImage: "square.and.arrow.down")
                }
                .help("导入 PDF、Word 或整个文献文件夹")
                if workspace == .questions, selectedResearchQuestion != nil {
                    Menu {
                        Button("编辑研究项目", systemImage: "pencil") { showEditQuestion = true }
                        Button("删除研究项目", systemImage: "trash", role: .destructive) { showDeleteQuestion = true }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var writingImportTypes: [UTType] {
        ["md", "markdown", "txt", "tex", "rtf", "rtfd", "docx"].compactMap { extensionName in
            UTType(filenameExtension: extensionName)
        }
    }

    private var paperImportTypes: [UTType] {
        ["pdf", "doc", "docx", "rtf", "rtfd"].compactMap { extensionName in
            UTType(filenameExtension: extensionName)
        }
    }

    private func presentNewWritingDocument(_ kind: WritingDocumentKind) {
        newWritingKind = kind
    }

    private func presentWritingImporter(_ kind: WritingDocumentKind) {
        writingImportKind = kind
        isImportingWritingDocument = true
    }

    private func syncWritingFolder(_ id: UUID) {
        if store.syncWritingFolder(id) { return }
        writingFolderSyncTarget = id
        isSelectingWritingFolderForSync = true
    }

    private func syncWritingDocument(_ id: UUID) {
        if store.syncWritingDocument(id) { return }
        writingDocumentSyncTarget = id
        isSelectingWritingDocumentForSync = true
    }

    private func duplicateWritingDocumentAndOpen(_ id: UUID) {
        guard let duplicateID = store.duplicateWritingDocument(id) else { return }
        selectedMarkdownDocument = duplicateID
        openTab(.document(duplicateID))
    }

    private func deleteWritingDocumentAndClose(_ id: UUID) {
        recentlyClosedTabs.removeAll { $0.content == .document(id) }
        let removedTabIDs = Set(tabs.compactMap { tab -> UUID? in
            guard case .document(let documentID) = tab.content, documentID == id else { return nil }
            return tab.id
        })
        let removedActiveTab = activeTabID.map(removedTabIDs.contains) ?? false
        tabs.removeAll { removedTabIDs.contains($0.id) }
        markdownReadingPositions.remove(id)
        store.deleteWritingDocument(id)
        if removedActiveTab { activeTabID = tabs.last?.id }
        if selectedMarkdownDocument == id {
            selectedMarkdownDocument = store.markdownDocuments.first?.id
        }
    }

    private var activeTab: ResearchTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    private func openTab(_ content: ResearchTabContent) {
        if let existing = tabs.first(where: { $0.content == content }) {
            activeTabID = existing.id
            return
        }
        let tab = ResearchTab(content: content)
        tabs.append(tab)
        activeTabID = tab.id
    }

    private func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        rememberClosedTab(closing)
        let wasActive = activeTabID == id
        tabs.remove(at: index)
        guard wasActive else { return }

        if !tabs.isEmpty {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        } else {
            activeTabID = nil
            switch closing.content {
            case .document:
                selectedMarkdownDocument = nil
            case .paper:
                selectedPaper = nil
            case .browser:
                break
            }
        }
    }

    private func closeOtherTabs(keeping id: UUID) {
        for tab in tabs where tab.id != id { rememberClosedTab(tab) }
        tabs.removeAll { $0.id != id }
        activeTabID = id
    }

    private func rememberClosedTab(_ tab: ResearchTab) {
        recentlyClosedTabs.removeAll { $0.content == tab.content }
        recentlyClosedTabs.append(tab)
        if recentlyClosedTabs.count > 20 { recentlyClosedTabs.removeFirst() }
    }

    private func reopenLastTab() {
        while let tab = recentlyClosedTabs.popLast() {
            switch tab.content {
            case .document(let id):
                guard store.markdownDocuments.contains(where: { $0.id == id }) else { continue }
            case .paper(let id):
                guard store.papers.contains(where: { $0.id == id }) else { continue }
            case .browser: break
            }
            if let existing = tabs.first(where: { $0.content == tab.content }) {
                activeTabID = existing.id
            } else {
                tabs.append(tab)
                activeTabID = tab.id
            }
            return
        }
    }

    private func moveTab(_ source: UUID, before target: UUID) {
        guard source != target,
              let from = tabs.firstIndex(where: { $0.id == source }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: from)
        let destination = from < to ? max(0, to - 1) : to
        tabs.insert(tab, at: min(destination, tabs.count))
    }

    private func createReadingNote(for paper: Paper) {
        let id = store.createWritingDocument(title: "\(paper.title) · 阅读笔记", kind: .note, format: .markdown)
        let source = paper.doi.map { "\n> DOI: https://doi.org/\($0)" } ?? ""
        store.updateMarkdown(id, content: "# \(paper.title)\n\n> \(paper.authors) · \(paper.year)\(source)\n\n## 阅读笔记\n\n## 原文摘录与页码\n\n## 我的思考\n\n")
        selectedMarkdownDocument = id
        workspace = .writing
        openTab(.document(id))
    }

    private func updateBrowserTitle(_ title: String, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        tabs[index].browserTitle = title
    }
}

private struct WorkspaceSearchModifier: ViewModifier {
    @Binding var query: String
    let enabled: Bool
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .toolbar, prompt: Text(prompt))
        } else {
            content
        }
    }
}

private struct ResearchTabBar: View {
    let tabs: [ResearchTab]
    let activeTabID: UUID?
    @ObservedObject var store: ResearchStore
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onCloseOthers: (UUID) -> Void
    let onMove: (UUID, UUID) -> Void
    let onReopen: () -> Void
    let canReopen: Bool
    let onNewNote: () -> Void
    let onNewPaper: () -> Void
    @State private var hoveredTabID: UUID?
    @State private var dragScopeID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct TabDragPayload: Codable, Transferable {
        let scopeID: UUID
        let tabID: UUID

        static var transferRepresentation: some TransferRepresentation {
            CodableRepresentation(contentType: UTType(exportedAs: "app.researchos.workspace-tab"))
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(tabs) { tab in
                                tabView(tab, width: tabWidth(in: geometry.size.width))
                                    .id(tab.id)
                            }
                        }
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    .onAppear { revealActiveTab(using: proxy, animated: false) }
                    .onChange(of: activeTabID) { _, _ in revealActiveTab(using: proxy) }
                    .onChange(of: tabs.map(\.id)) { _, _ in revealActiveTab(using: proxy) }
                    .onChange(of: geometry.size.width) { _, _ in
                        revealActiveTab(using: proxy, animated: false)
                    }
                }
            }

            Divider().frame(height: 20)

            Menu {
                ForEach(tabs) { tab in
                    Button {
                        onSelect(tab.id)
                    } label: {
                        HStack {
                            Image(systemName: activeTabID == tab.id ? "checkmark" : icon(for: tab))
                            Text(title(for: tab))
                        }
                    }
                }
                if !tabs.isEmpty { Divider() }
                Button("重新打开关闭的标签页", systemImage: "arrow.uturn.backward", action: onReopen)
                    .disabled(!canReopen)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("全部标签页")
            .accessibilityLabel("全部标签页")

            Menu {
                Button("新建笔记", systemImage: "note.text.badge.plus", action: onNewNote)
                Button("新建论文", systemImage: "doc.badge.plus", action: onNewPaper)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新建标签页")
            .accessibilityLabel("新建标签页")
        }
        .padding(4)
        .frame(height: 40)
        .researchGlassSurface(cornerRadius: 14)
        .padding(6)
    }

    private func tabView(_ tab: ResearchTab, width: CGFloat) -> some View {
        let isActive = activeTabID == tab.id
        let isHovered = hoveredTabID == tab.id
        return HStack(spacing: 6) {
            Button {
                onSelect(tab.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon(for: tab))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    Text(title(for: tab))
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title(for: tab))
            .accessibilityValue(isActive ? "当前标签页" : "")

            Button {
                onClose(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(isHovered ? Color.primary.opacity(0.07) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭标签页")
            .accessibilityLabel("关闭\(title(for: tab))")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(width: width, height: 32)
        .background(
            isActive ? Color.accentColor.opacity(0.13) : Color.primary.opacity(isHovered ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.2) : .clear, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            hoveredTabID = hovering ? tab.id : nil
        }
        .help(title(for: tab))
        .draggable(TabDragPayload(scopeID: dragScopeID, tabID: tab.id))
        .dropDestination(for: TabDragPayload.self) { items, _ in
            guard items.count == 1, let item = items.first,
                  item.scopeID == dragScopeID,
                  item.tabID != tab.id,
                  tabs.contains(where: { $0.id == item.tabID }),
                  tabs.contains(where: { $0.id == tab.id }) else { return false }
            onMove(item.tabID, tab.id)
            return true
        }
        .contextMenu {
            Button("关闭标签页") { onClose(tab.id) }
            Button("关闭其他标签页") { onCloseOthers(tab.id) }
                .disabled(tabs.count < 2)
            Divider()
            Button("重新打开关闭的标签页", action: onReopen)
                .disabled(!canReopen)
        }
    }

    private func tabWidth(in availableWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(tabs.count, 1))
        return min(240, max(140, (availableWidth - (count - 1) * 4) / count))
    }

    private func revealActiveTab(using proxy: ScrollViewProxy, animated: Bool = true) {
        guard let activeTabID, tabs.contains(where: { $0.id == activeTabID }) else { return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(activeTabID, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeTabID, anchor: .center)
        }
    }

    private func title(for tab: ResearchTab) -> String {
        switch tab.content {
        case .document(let id):
            return store.markdownDocuments.first(where: { $0.id == id })?.title ?? "文稿"
        case .paper(let id):
            return store.papers.first(where: { $0.id == id })?.title ?? "论文"
        case .browser(let url):
            return tab.browserTitle ?? url.host ?? "网页"
        }
    }

    private func icon(for tab: ResearchTab) -> String {
        switch tab.content {
        case .document(let id):
            return store.markdownDocuments.first(where: { $0.id == id })?.resolvedKind.symbol ?? "doc.text"
        case .paper:
            return "doc.richtext"
        case .browser:
            return "globe"
        }
    }
}

private struct WorkspaceSidebar: View {
    @Binding var selection: WorkspaceSection?
    let inboxCount: Int

    var body: some View {
        List(selection: $selection) {
            Section("工作区") {
                Label(WorkspaceSection.questions.title, systemImage: WorkspaceSection.questions.symbol)
                    .tag(WorkspaceSection.questions)
                Label(WorkspaceSection.writing.title, systemImage: WorkspaceSection.writing.symbol)
                    .tag(WorkspaceSection.writing)
                Label(WorkspaceSection.knowledgeGraph.title, systemImage: WorkspaceSection.knowledgeGraph.symbol)
                    .tag(WorkspaceSection.knowledgeGraph)
                Label(WorkspaceSection.library.title, systemImage: WorkspaceSection.library.symbol)
                    .tag(WorkspaceSection.library)
            }

            Section("资料来源") {
                Label(WorkspaceSection.zotero.title, systemImage: WorkspaceSection.zotero.symbol)
                    .tag(WorkspaceSection.zotero)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationTitle("ResearchOS")
    }
}

private struct QuestionList: View {
    let questions: [ResearchQuestion]
    @Binding var selection: UUID?
    @Binding var showNewQuestion: Bool

    var body: some View {
        Group {
            if questions.isEmpty {
                EmptyStateCard(title: "还没有研究项目", message: "先写下论文真正想回答的问题，再把证据组织到问题之下。", symbol: "questionmark.bubble") {
                    Button("新建研究项目") { showNewQuestion = true }
                }
            } else {
                List(selection: $selection) {
                    Section("我的研究") {
                        ForEach(questions) { question in
                            QuestionRow(question: question)
                                .tag(question.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("研究项目")
    }
}

private struct QuestionRow: View {
    let question: ResearchQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                StatusPill(text: question.status.title, color: question.status.color)
                Spacer()
                Text("\(question.paperCount) 篇")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(question.shortTitle)
                .font(.headline)
            Text(question.question)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if question.openGapCount > 0 {
                Label("\(question.openGapCount) 个证据空白", systemImage: "circle.dotted")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 6)
    }
}

private enum InboxQueueFilter: String, CaseIterable, Identifiable {
    case all
    case readable
    case preparation

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .readable: "可阅读"
        case .preparation: "待准备"
        }
    }
}

private enum InboxQueueStage: Int, CaseIterable, Identifiable {
    case reading
    case ready
    case needsText
    case missingPDF

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .reading: "正在精读"
        case .ready: "可以开始"
        case .needsText: "准备全文"
        case .missingPDF: "缺少原文"
        }
    }
    var detail: String {
        switch self {
        case .reading: "继续阅读并摘录证据"
        case .ready: "全文已经准备好"
        case .needsText: "已有 PDF，尚未提取文本"
        case .missingPDF: "需要先在 Zotero 中补充附件"
        }
    }
    var symbol: String {
        switch self {
        case .reading: "book.pages"
        case .ready: "checkmark.circle"
        case .needsText: "doc.text.magnifyingglass"
        case .missingPDF: "doc.badge.questionmark"
        }
    }
    var color: Color {
        switch self {
        case .reading: .blue
        case .ready: .green
        case .needsText: .orange
        case .missingPDF: .red
        }
    }
    var actionTitle: String {
        switch self {
        case .reading: "继续"
        case .ready: "开始"
        case .needsText: "提取"
        case .missingPDF: "查看"
        }
    }

    static func resolve(for paper: Paper) -> InboxQueueStage {
        if paper.status == .reading { return .reading }
        guard paper.hasAvailablePDF else { return .missingPDF }
        return paper.extractedCharacterCount > 0 ? .ready : .needsText
    }
}

extension Paper {
    var hasAvailablePDF: Bool {
        guard let attachmentPath else { return false }
        return FileManager.default.fileExists(atPath: attachmentPath)
    }

    var attachmentExtension: String {
        attachmentPath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
    }

    var isPDFAttachment: Bool { attachmentExtension == "pdf" }

    var attachmentKindTitle: String {
        switch attachmentExtension {
        case "doc", "docx": "Word"
        case "rtf", "rtfd": "RTF"
        default: "PDF"
        }
    }
}

private struct InboxQueueView: View {
    @ObservedObject var store: ResearchStore
    @Binding var selection: UUID?
    @Binding var query: String
    @State private var filter: InboxQueueFilter = .all

    private var matchingPapers: [Paper] {
        let parsed = TagFiltering.parse(query)
        return store.inboxPapers.filter { paper in
            let matchesQuery = parsed.text.isEmpty
                || paper.title.localizedCaseInsensitiveContains(parsed.text)
                || paper.authors.localizedCaseInsensitiveContains(parsed.text)
            guard TagFiltering.matches(tags: paper.tags, tag: parsed.tag) else { return false }
            guard matchesQuery else { return false }
            let stage = InboxQueueStage.resolve(for: paper)
            switch filter {
            case .all: return true
            case .readable: return stage == .reading || stage == .ready
            case .preparation: return stage == .needsText || stage == .missingPDF
            }
        }
    }

    private var extractableCount: Int {
        store.inboxPapers.filter { InboxQueueStage.resolve(for: $0) == .needsText }.count
    }

    private var readableCount: Int {
        store.inboxPapers.filter {
            let stage = InboxQueueStage.resolve(for: $0)
            return stage == .reading || stage == .ready
        }.count
    }

    private var missingCount: Int {
        store.inboxPapers.filter { InboxQueueStage.resolve(for: $0) == .missingPDF }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            InboxQueueHeader(
                total: store.inboxPapers.count,
                readable: readableCount,
                extractable: extractableCount,
                missing: missingCount,
                isBusy: store.isBusy,
                onPrepareAll: store.extractAvailableFullTexts
            )
            Divider()

            Picker("显示", selection: $filter) {
                ForEach(InboxQueueFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if store.inboxPapers.isEmpty {
                ContentUnavailableView {
                    Label("处理队列已清空", systemImage: "checkmark.circle")
                } description: {
                    Text("整理完成的论文仍然保留在论文库中。")
                }
            } else if matchingPapers.isEmpty {
                ContentUnavailableView("没有匹配的论文", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                List(selection: $selection) {
                    ForEach(InboxQueueStage.allCases) { stage in
                        let stagePapers = matchingPapers.filter { InboxQueueStage.resolve(for: $0) == stage }
                        if !stagePapers.isEmpty {
                            Section {
                                ForEach(stagePapers) { paper in
                                    InboxQueueRow(
                                        paper: paper,
                                        stage: stage,
                                        isBusy: store.isBusy,
                                        onPrimaryAction: { performPrimaryAction(for: paper, stage: stage) },
                                        onMarkReading: { store.markReading(paper.id) },
                                        onMarkProcessed: { store.markProcessed(paper.id) },
                                    )
                                    .tag(paper.id)
                                }
                            } header: {
                                HStack {
                                    Label(stage.title, systemImage: stage.symbol)
                                        .foregroundStyle(stage.color)
                                    Spacer()
                                    Text(stagePapers.count.formatted())
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(ResearchPalette.window)
            }
        }
        .navigationTitle("处理队列")
    }

    private func performPrimaryAction(for paper: Paper, stage: InboxQueueStage) {
        switch stage {
        case .reading:
            selection = paper.id
        case .ready:
            store.markReading(paper.id)
            selection = paper.id
        case .needsText:
            store.extractFullText(paper.id)
            selection = paper.id
        case .missingPDF:
            selection = paper.id
        }
    }
}

private struct InboxQueueHeader: View {
    let total: Int
    let readable: Int
    let extractable: Int
    let missing: Int
    let isBusy: Bool
    let onPrepareAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("待处理", systemImage: "tray")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(total) 篇")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                QueueCountLabel(value: readable, title: "可读", color: .green)
                QueueCountLabel(value: extractable, title: "待提取", color: .orange)
                QueueCountLabel(value: missing, title: "缺原文", color: .red)
            }

            if extractable > 0 {
                Button("提取 \(extractable) 份原文", systemImage: "doc.text.magnifyingglass", action: onPrepareAll)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isBusy)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

private struct QueueCountLabel: View {
    let value: Int
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value) \(title)")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct InboxQueueRow: View {
    let paper: Paper
    let stage: InboxQueueStage
    let isBusy: Bool
    let onPrimaryAction: () -> Void
    let onMarkReading: () -> Void
    let onMarkProcessed: () -> Void
    @AppStorage("ResearchOS.listDensity") private var listDensity = "comfortable"

    var body: some View {
        VStack(alignment: .leading, spacing: listDensity == "compact" ? 4 : 6) {
            Text(paper.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .help(paper.title)
            PaperByline(paper: paper)
            HStack(spacing: 7) {
                Label(stage.detail, systemImage: stage.symbol)
                    .font(.caption2)
                    .foregroundStyle(stage.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(stage.actionTitle, action: onPrimaryAction)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isBusy && stage == .needsText)
            }
        }
        .padding(.vertical, listDensity == "compact" ? 3 : 8)
        .contextMenu {
            if paper.status != .reading {
                Button("标记为正在精读", systemImage: "book.pages") {
                    onMarkReading()
                }
            }
            Button("完成整理", systemImage: "checkmark.circle", action: onMarkProcessed)
        }
    }
}

private struct PaperList: View {
    @ObservedObject var store: ResearchStore
    let title: String
    let papers: [Paper]
    @Binding var selection: UUID?
    @Binding var query: String
    @State private var statusFilter: ReadingStatusFilter = .all
    @State private var selectedIDs: Set<UUID> = []

    private enum ReadingStatusFilter: String, CaseIterable, Identifiable {
        case all, unread, reading, processed
        var id: String { rawValue }
        var title: String {
            switch self { case .all: "全部"; case .unread: "未读"; case .reading: "阅读中"; case .processed: "已整理" }
        }
        var status: ReadingStatus? {
            switch self { case .all: nil; case .unread: .unread; case .reading: .reading; case .processed: .processed }
        }
    }

    private var filtered: [Paper] {
        let parsed = TagFiltering.parse(query)
        return papers.filter {
            TagFiltering.matches(tags: $0.tags, tag: parsed.tag) && (statusFilter.status == nil || $0.status == statusFilter.status) && (parsed.text.isEmpty ||
            $0.title.localizedCaseInsensitiveContains(parsed.text) || $0.authors.localizedCaseInsensitiveContains(parsed.text))
        }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                EmptyStateCard(title: query.isEmpty ? "还没有文献" : "没有匹配的论文", message: query.isEmpty ? "从顶部导入 PDF、Word 或文献文件夹，建立你的研究资料库。" : "试试其他标题或作者关键词。", symbol: query.isEmpty ? "books.vertical" : "magnifyingglass") { EmptyView() }
            } else {
                List(filtered, selection: $selectedIDs) { paper in
                    PaperRow(paper: paper).tag(paper.id)
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Picker("状态", selection: $statusFilter) {
                    ForEach(ReadingStatusFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Label("全部文献", systemImage: "books.vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filtered.count) 篇")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
        .onChange(of: selectedIDs) { _, ids in selection = ids.first }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !selectedIDs.isEmpty {
                    Menu("批量操作", systemImage: "checkmark.circle") {
                        Button("标记为未读") { store.setReadingStatus(.unread, for: selectedIDs) }
                        Button("标记为阅读中") { store.setReadingStatus(.reading, for: selectedIDs) }
                        Button("标记为已整理") { store.setReadingStatus(.processed, for: selectedIDs) }
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}

private struct ZoteroCollectionList: View {
    let collections: [ZoteroCollection]
    @Binding var selection: Int64?

    var body: some View {
        Group {
            if collections.isEmpty {
                ContentUnavailableView("没有可用分类", systemImage: "externaldrive.badge.questionmark")
            } else {
                List(collections, selection: $selection) { collection in
                    HStack {
                        Label(collection.name, systemImage: "folder")
                            .lineLimit(2)
                        Spacer()
                        Text("\(collection.itemCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(collection.id)
                }
            }
        }
        .navigationTitle("Zotero 分类")
    }
}

private struct ZoteroWelcomeView: View {
    @ObservedObject var store: ResearchStore

    var body: some View {
        ContentUnavailableView {
            Label(store.zoteroAvailable ? "选择一个 Zotero 分类" : "未找到 Zotero", systemImage: "externaldrive.connected.to.line.below")
        } description: {
            Text(store.zoteroAvailable
                 ? "ResearchOS 通过临时只读快照读取题录和附件，不会修改 Zotero 数据。"
                 : "请先确认 Zotero 的数据目录位于默认位置。")
        } actions: {
            if store.zoteroAvailable {
                Button("重新读取分类") { store.connectZotero() }
            }
        }
    }
}

private struct ZoteroCollectionDetail: View {
    @ObservedObject var store: ResearchStore
    let collection: ZoteroCollection

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text(collection.name).font(.title.weight(.semibold))
            Text("这个分类包含 \(collection.itemCount) 条记录。导入时会保留作者、年份、期刊、DOI、摘要、Zotero Key 与原始 PDF 路径。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Label("只读连接：不会写回或修改 Zotero", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.green)
            Button("导入这个分类", systemImage: "square.and.arrow.down") {
                store.importZoteroCollection(collection)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || collection.itemCount == 0)
        }
        .padding(30)
        .navigationTitle(collection.name)
    }
}

private struct PaperRow: View {
    let paper: Paper
    @AppStorage("ResearchOS.listDensity") private var listDensity = "comfortable"

    var body: some View {
        VStack(alignment: .leading, spacing: listDensity == "compact" ? 4 : 6) {
            Text(paper.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .help(paper.title)
            PaperByline(paper: paper)
            Label(paper.status.title, systemImage: paper.status.symbol)
                .font(.caption2)
                .foregroundStyle(paper.status == .processed ? .green : .secondary)
        }
        .padding(.vertical, listDensity == "compact" ? 3 : 8)
    }
}

private struct PaperByline: View {
    let paper: Paper

    var body: some View {
        HStack(spacing: 6) {
            Text(paper.authors)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(paper.authors)
            Spacer(minLength: 0)
            if paper.year > 0 {
                Text(String(paper.year))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct QuestionDetailView: View {
    @ObservedObject var store: ResearchStore
    let question: ResearchQuestion
    @State private var showsPaperPicker = false
    @State private var showsRejected = false

    private var linkedPapers: [Paper] {
        let ids = Set(question.resolvedLinkedPaperIDs)
        return store.papers.filter { ids.contains($0.id) }
    }

    private var suggestedEvidence: [EvidenceItem] {
        question.evidence.filter { $0.resolvedReviewStatus == .aiSuggested }
    }

    private var confirmedEvidence: [EvidenceItem] {
        question.evidence.filter { $0.resolvedReviewStatus == .userConfirmed }
    }

    private var rejectedEvidence: [EvidenceItem] {
        question.evidence.filter { $0.resolvedReviewStatus == .userRejected }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("研究项目")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                            .textCase(.uppercase)
                        StatusPill(text: question.status.title, color: question.status.color)
                        Spacer()
                        Button("关联论文", systemImage: "link.badge.plus") {
                            showsPaperPicker = true
                        }
                        Button("生成候选证据", systemImage: "sparkles") {
                            store.generateEvidenceSuggestions(for: question.id)
                        }
                        .disabled(linkedPapers.isEmpty)
                    }
                    Text(question.question)
                        .font(.system(size: 28, weight: .bold))
                        .textSelection(.enabled)
                }

                ResearchArgumentFlow(
                    paperCount: linkedPapers.count,
                    suggestedCount: suggestedEvidence.count,
                    confirmedCount: confirmedEvidence.count
                )

                LinkedPapersCard(
                    papers: linkedPapers,
                    onAdd: { showsPaperPicker = true },
                    onGenerateSuggestions: { store.generateEvidenceSuggestions(for: question.id, paperID: $0) },
                    onUnlink: { store.unlinkPaper($0, from: question.id) }
                )

                if !suggestedEvidence.isEmpty {
                    EvidenceReviewQueue(
                        items: suggestedEvidence,
                        onConfirm: { store.confirmEvidence($0, in: question.id) },
                        onReject: { store.rejectEvidence($0, in: question.id) }
                    )
                }

                WorkingAnswerCard(answer: question.workingAnswer)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("已确认的证据").font(.title2.weight(.semibold))
                        Text("\(confirmedEvidence.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("只有你确认过的证据会进入正式论证与知识图谱。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if confirmedEvidence.isEmpty {
                        ResearchCard {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.seal")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("还没有已确认的证据").font(.headline)
                                    Text("从 PDF 选择原文保存，或先审核上方候选证据。")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        EvidenceBoard(
                            items: confirmedEvidence,
                            onDelete: { store.deleteEvidence($0, from: question.id) }
                        )
                    }
                }

                if !rejectedEvidence.isEmpty {
                    DisclosureGroup(isExpanded: $showsRejected) {
                        VStack(spacing: 8) {
                            ForEach(rejectedEvidence) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.claim).font(.callout).lineLimit(2)
                                        Text(item.source).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("重新审核") {
                                        store.restoreEvidenceSuggestion(item.id, in: question.id)
                                    }
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("已拒绝的建议（\(rejectedEvidence.count)）")
                            .font(.headline)
                    }
                }

                NextMoveCard(text: question.nextMove)
            }
            .padding(26)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(question.shortTitle)
        .sheet(isPresented: $showsPaperPicker) {
            PaperLinkSheet(store: store, questionID: question.id)
        }
    }
}

private struct ResearchArgumentFlow: View {
    let paperCount: Int
    let suggestedCount: Int
    let confirmedCount: Int

    var body: some View {
        HStack(spacing: 8) {
            FlowStage(symbol: "doc.text", value: paperCount, title: "论文来源", color: .blue)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            FlowStage(symbol: "sparkles", value: suggestedCount, title: "待审核", color: .orange)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            FlowStage(symbol: "checkmark.seal", value: confirmedCount, title: "已确认", color: .green)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            FlowStage(symbol: "questionmark.bubble", value: 1, title: "研究问题", color: .indigo)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ResearchPalette.separator.opacity(0.55), lineWidth: 0.5)
        }
    }
}

private struct FlowStage: View {
    let symbol: String
    let value: Int
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 27, height: 27)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(value.formatted()).font(.headline.monospacedDigit())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkedPapersCard: View {
    let papers: [Paper]
    let onAdd: () -> Void
    let onGenerateSuggestions: (UUID) -> Void
    let onUnlink: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("关联论文").font(.title2.weight(.semibold))
                    Text("关联只建立研究范围，不会移动或复制论文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加论文", systemImage: "plus", action: onAdd)
            }

            if papers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "link.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("先选择与这个问题直接相关的论文，之后才能生成候选证据。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(papers) { paper in
                    HStack(spacing: 11) {
                        Image(systemName: paper.pageCount > 0 ? "doc.text.fill" : "doc.text")
                            .foregroundStyle(paper.pageCount > 0 ? .blue : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(paper.title).font(.callout.weight(.medium)).lineLimit(2)
                            Text(paper.pageCount > 0 ? "\(paper.pageCount) 页 · 可生成带页码建议" : "尚未提取全文")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if paper.pageCount > 0 {
                            Button("生成建议") { onGenerateSuggestions(paper.id) }
                                .controlSize(.small)
                        }
                        Menu {
                            Button("取消关联", systemImage: "link.badge.minus", role: .destructive) {
                                onUnlink(paper.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(.vertical, 4)
                    if paper.id != papers.last?.id { Divider() }
                }
            }
        }
        .padding(18)
        .background(ResearchPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ResearchPalette.separator.opacity(0.55), lineWidth: 0.5)
        }
    }
}

private struct EvidenceReviewQueue: View {
    let items: [EvidenceItem]
    let onConfirm: (UUID) -> Void
    let onReject: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 310), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("待审核证据").font(.title2.weight(.semibold))
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("建议只在匹配到 PDF 原文和页码时生成；确认前不会进入正式论证。")
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(item.resolvedRole.title, systemImage: item.resolvedRole.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Spacer()
                            StatusPill(text: item.resolvedReviewStatus.title, color: .orange)
                        }
                        Text(item.claim).font(.callout.weight(.semibold)).lineSpacing(2)
                        if let quote = item.quote {
                            Text("“\(quote)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(5)
                                .textSelection(.enabled)
                        }
                        Label(item.source, systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            Button("拒绝", role: .destructive) { onReject(item.id) }
                            Spacer()
                            Button("确认并加入", systemImage: "checkmark") { onConfirm(item.id) }
                                .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.orange.opacity(0.22), lineWidth: 0.7)
                    }
                }
            }
        }
    }
}

private struct PaperLinkSheet: View {
    @ObservedObject var store: ResearchStore
    let questionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var question: ResearchQuestion? {
        store.questions.first { $0.id == questionID }
    }

    private var filteredPapers: [Paper] {
        query.isEmpty ? store.papers : store.papers.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.authors.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("关联论文").font(.title2.weight(.semibold))
                    Text("选择这个研究项目要持续追踪的论文。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            List(filteredPapers) { paper in
                let isLinked = question?.resolvedLinkedPaperIDs.contains(paper.id) == true
                Button {
                    if isLinked {
                        store.unlinkPaper(paper.id, from: questionID)
                    } else {
                        store.linkPaper(paper.id, to: questionID)
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: isLinked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isLinked ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(paper.title).font(.headline).lineLimit(2)
                            Text("\(paper.authors) · \(paper.year)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if paper.pageCount > 0 {
                            Text("\(paper.pageCount) 页")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: "搜索标题或作者")
        }
        .frame(width: 720, height: 620)
    }
}

private struct WorkingAnswerCard: View {
    let answer: String

    var body: some View {
        ResearchCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "text.quote")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前工作结论").font(.headline)
                    Text(answer)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                    Text("基于当前已整理证据；随着新论文加入而更新")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct EvidenceBoard: View {
    let items: [EvidenceItem]
    let onDelete: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(EvidenceKind.allCases) { kind in
                EvidenceLane(kind: kind, items: items.filter { $0.kind == kind }, onDelete: onDelete)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

private struct EvidenceLane: View {
    let kind: EvidenceKind
    let items: [EvidenceItem]
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: kind.symbol).foregroundStyle(kind.color)
                Text(kind.title).font(.headline)
                Spacer()
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Label(item.resolvedRole.title, systemImage: item.resolvedRole.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(kind.color)
                        Spacer()
                        Menu {
                            Button("删除证据", systemImage: "trash", role: .destructive) {
                                onDelete(item.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 20, height: 20)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Text(item.claim)
                        .font(.callout.weight(.medium))
                        .lineSpacing(3)
                    if let quote = item.quote, !quote.isEmpty {
                        Text("“\(quote)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .lineLimit(5)
                    }
                    Divider()
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(item.source)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(item.confidence)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(kind.color)
                }
                .padding(13)
                .background(kind.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(15)
        .background(ResearchPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ResearchPalette.separator.opacity(0.55), lineWidth: 0.5)
        }
    }
}

private struct NextMoveCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 7) {
                Text("建议的下一步").font(.headline)
                Text(text).font(.body).lineSpacing(4).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(18)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PaperDetailView: View {
    @ObservedObject var store: ResearchStore
    let paper: Paper
    let onOpenPDF: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        StatusPill(text: paper.status.title, color: paper.status == .processed ? .green : .orange)
                        StatusPill(text: paper.source.title, color: .blue)
                        StatusPill(text: paper.analysisState.title, color: paper.analysisState == .analyzed ? .purple : .secondary)
                    }
                    Text(paper.title).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                    Text("\(paper.authors) · \(String(paper.year)) · \(paper.venue)")
                        .font(.callout).foregroundStyle(.secondary)
                    TagEditor(tags: paper.tags) { store.setTags(forPaper: paper.id, tags: $0) }
                    if let doi = paper.doi {
                        Text("DOI  \(doi)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if paper.extractedCharacterCount > 0 {
                        Text(paper.pageCount > 0
                             ? "\(paper.pageCount) 页 · 已提取 \(paper.extractedCharacterCount.formatted()) 个字符"
                             : "已提取 \(paper.extractedCharacterCount.formatted()) 个字符")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if paper.attachmentPath != nil {
                            Button(paper.isPDFAttachment ? "打开 PDF" : "打开原文", systemImage: "doc.richtext") {
                                if paper.status == .unread {
                                    store.markReading(paper.id)
                                }
                                onOpenPDF()
                            }
                            if paper.pageCount == 0 {
                                Button("提取全文", systemImage: "doc.text.magnifyingglass") {
                                    store.extractFullText(paper.id)
                                }
                            }
                        } else {
                            Label("Zotero 中未找到 PDF 附件", systemImage: "doc.badge.questionmark")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !paper.abstractText.isEmpty {
                    PaperSection(title: "摘要", symbol: "doc.plaintext", text: paper.abstractText)
                }
                PaperSection(title: "研究问题", symbol: "questionmark.bubble", text: paper.researchQuestion)
                PaperSection(title: "方法", symbol: "hammer", text: paper.method)
                PaperSection(title: "关键发现", symbol: "lightbulb", text: paper.finding)
                PaperSection(title: "限制", symbol: "exclamationmark.triangle", text: paper.limitation)

                HStack {
                    switch paper.status {
                    case .unread:
                        Button("开始精读", systemImage: "book.pages") {
                            store.markReading(paper.id)
                        }
                    case .reading:
                        Button("完成整理", systemImage: "checkmark.circle") {
                            store.markProcessed(paper.id)
                        }
                    case .processed:
                        Button("标记为未读", systemImage: "circle") {
                            store.moveBackToInbox(paper.id)
                        }
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("论文卡片")
    }
}

private struct PaperReadingWorkspace: View {
    @ObservedObject var store: ResearchStore
    let paper: Paper
    let readingPositionStore: PDFReadingPositionStore
    let onOpenURL: (URL) -> Void
    let onNewNote: () -> Void
    @State private var showsSource: Bool
    @State private var showsInspector = true

    init(
        store: ResearchStore,
        paper: Paper,
        readingPositionStore: PDFReadingPositionStore,
        onOpenURL: @escaping (URL) -> Void,
        onNewNote: @escaping () -> Void
    ) {
        self.store = store
        self.paper = paper
        self.readingPositionStore = readingPositionStore
        self.onOpenURL = onOpenURL
        self.onNewNote = onNewNote
        _showsSource = State(initialValue: paper.attachmentPath != nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if showsSource, paper.attachmentPath != nil {
                    if paper.isPDFAttachment {
                        PDFReaderWorkspace(
                            store: store,
                            paper: paper,
                            readingPositionStore: readingPositionStore,
                            onClose: { showsSource = false },
                            onOpenURL: onOpenURL,
                            isInspectorPresented: showsInspector,
                            onToggleInspector: { withAnimation(.easeInOut(duration: 0.18)) { showsInspector.toggle() } }
                        )
                    } else {
                        ImportedPaperDocumentWorkspace(paper: paper) { showsSource = false }
                    }
                } else {
                    PaperDetailView(store: store, paper: paper) { showsSource = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsSource && showsInspector {
                Divider()
                PaperReadingInspector(
                    store: store,
                    paper: paper,
                    onClose: { withAnimation(.easeInOut(duration: 0.18)) { showsInspector = false } },
                    onNewNote: onNewNote
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(ResearchPalette.window)
        .overlay(alignment: .topTrailing) {
            if showsSource && !showsInspector && !paper.isPDFAttachment {
                Button("显示论文信息", systemImage: "sidebar.trailing") {
                    withAnimation(.easeInOut(duration: 0.18)) { showsInspector = true }
                }
                .labelStyle(.iconOnly)
                .help("显示论文信息")
                .padding(7)
                .researchGlassSurface(cornerRadius: 11)
                .padding(10)
            }
        }
        .navigationTitle(paper.title)
    }
}

private struct PaperReadingInspector: View {
    @ObservedObject var store: ResearchStore
    let paper: Paper
    let onClose: () -> Void
    let onNewNote: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("论文信息", systemImage: "sidebar.trailing")
                    .font(.headline)
                Spacer()
                Button("新建阅读笔记", systemImage: "note.text.badge.plus", action: onNewNote)
                    .labelStyle(.iconOnly)
                    .help("为这篇论文新建阅读笔记")
                Button("隐藏论文信息", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .help("隐藏论文信息")
            }
            .padding(10)
            .researchGlassSurface(cornerRadius: 14)
            .padding(10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(paper.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text("\(paper.authors) · \(paper.year)\(paper.venue.isEmpty ? "" : " · \(paper.venue)")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            StatusPill(text: paper.status.title, color: paper.status == .processed ? .green : .orange)
                            StatusPill(text: paper.source.title, color: .blue)
                        }
                    }

                    if let doi = paper.doi, !doi.isEmpty {
                        LabeledContent("DOI") {
                            Text(doi).textSelection(.enabled).lineLimit(2)
                        }
                        .font(.caption)
                    }

                    inspectorSection("摘要", text: paper.abstractText)
                    inspectorSection("研究问题", text: paper.researchQuestion)
                    inspectorSection("方法", text: paper.method)
                    inspectorSection("关键发现", text: paper.finding)
                    inspectorSection("限制", text: paper.limitation)

                    Divider()
                    switch paper.status {
                    case .unread:
                        Button("开始精读", systemImage: "book.pages") { store.markReading(paper.id) }
                    case .reading:
                        Button("完成整理", systemImage: "checkmark.circle") { store.markProcessed(paper.id) }
                    case .processed:
                        Button("标记为未读", systemImage: "circle") { store.moveBackToInbox(paper.id) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func inspectorSection(_ title: String, text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.callout).textSelection(.enabled)
            }
        }
    }
}

private struct NewQuestionSheet: View {
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("新建研究项目").font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), question.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("项目名称").font(.headline)
                TextField("例如：有限负荷转移的碳排放响应", text: $title)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("核心研究问题").font(.headline)
                TextEditor(text: $question)
                    .font(.body)
                    .frame(height: 140)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text("一个好的研究问题应明确对象、条件和希望解释或比较的结果。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .frame(width: 620, height: 380)
    }
}

private struct EditQuestionSheet: View {
    let question: ResearchQuestion
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var questionText: String

    init(question: ResearchQuestion, onSave: @escaping (String, String) -> Void) {
        self.question = question
        self.onSave = onSave
        _title = State(initialValue: question.shortTitle)
        _questionText = State(initialValue: question.question)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("编辑研究项目").font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        questionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("简短名称").font(.headline)
                TextField("研究项目名称", text: $title)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("核心研究问题").font(.headline)
                TextEditor(text: $questionText)
                    .font(.body)
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(ResearchPalette.card, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(width: 620, height: 430)
    }
}

private struct PaperSection: View {
    let title: String
    let symbol: String
    let text: String

    var body: some View {
        ResearchCard {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: symbol).font(.headline)
                Text(text).font(.body).lineSpacing(4).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AskResearchSheet: View {
    let question: ResearchQuestion
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = "目前最大的研究分歧是什么？"
    @State private var hasAsked = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("询问 ResearchOS", systemImage: "sparkles").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Text(question.shortTitle).font(.caption).foregroundStyle(.secondary)

            TextField("询问当前研究问题…", text: $prompt)
                .textFieldStyle(.roundedBorder)
                .onSubmit { hasAsked = true }

            if hasAsked {
                ResearchCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("基于当前证据").font(.headline)
                        Text("最大的分歧是记忆应当如何随时间变化：一类方法引入自然衰减，避免旧信息长期占据检索结果；另一类方法通过反思和整合强化被认为重要的经历。当前文献还缺少在同一长期任务上的直接比较，因此不能简单判断哪一种机制更优。")
                            .lineSpacing(4)
                            .textSelection(.enabled)
                        Divider()
                        Text("依据：MemoryBank、Generative Agents；置信度：中等")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
            HStack {
                Text("回答仅使用当前研究库中的已整理证据")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("提问") { hasAsked = true }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 650, height: 480)
    }
}
