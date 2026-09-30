import AppKit
import Foundation
import PDFKit

@MainActor
final class ResearchStore: ObservableObject {
    @Published var questions: [ResearchQuestion] = []
    @Published var papers: [Paper] = []
    @Published var markdownDocuments: [MarkdownDocument] = []
    @Published var writingDocumentVersions: [WritingDocumentVersion] = []
    @Published private(set) var writingSyncConflicts: [WritingSyncConflict] = []

    var healthIssues: [String] {
        var issues: [String] = []
        for paper in papers where paper.attachmentPath == nil { issues.append("论文“\(paper.title)”缺少原文附件") }
        for paper in papers {
            if let path = paper.attachmentPath, !FileManager.default.fileExists(atPath: path) {
                issues.append("论文“\(paper.title)”的原文路径已失效")
            }
        }
        for document in markdownDocuments where document.sourceBookmark != nil {
            var stale = false
            if let bookmark = document.sourceBookmark,
               let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
               (!FileManager.default.fileExists(atPath: url.path) || stale) {
                issues.append("文稿“\(document.title)”的外部来源需要重新授权")
            }
        }
        let duplicateGroups = Dictionary(grouping: markdownDocuments, by: { $0.content }).values.filter { $0.count > 1 }
        issues.append(contentsOf: duplicateGroups.map { "发现重复文稿：\($0.first?.title ?? "未命名文稿") 等 \($0.count) 篇" })
        let duplicatePapers = Dictionary(grouping: papers, by: { normalizedPaperKey($0) }).values.filter { $0.count > 1 }
        issues.append(contentsOf: duplicatePapers.map { "发现疑似重复论文：\($0.first?.title ?? "未命名论文") 等 \($0.count) 篇" })
        return issues
    }

    private func normalizedPaperKey(_ paper: Paper) -> String {
        if let doi = paper.doi, !doi.isEmpty { return "doi:\(doi.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))" }
        return paper.title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var tagUsage: [(String, Int)] {
        var counts: [String: Int] = [:]
        papers.flatMap(\.tags).forEach { counts[$0, default: 0] += 1 }
        markdownDocuments.flatMap(\.tags).forEach { counts[$0, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }
    }

    func setTags(forPaper id: UUID, tags: [String]) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        save()
    }

    func setTags(forDocument id: UUID, tags: [String]) {
        guard let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return }
        markdownDocuments[index].tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        save()
    }

    func setReadingStatus(_ status: ReadingStatus, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in papers.indices where ids.contains(papers[index].id) { papers[index].status = status }
        save()
        operationMessage = "已批量更新 (ids.count) 篇论文"
    }
    @Published var writingFolders: [WritingFolder] = []
    @Published var knowledgeGraph: KnowledgeGraph = .empty
    @Published var zoteroCollections: [ZoteroCollection] = []
    @Published var isBusy = false
    @Published var operationMessage: String? {
        didSet {
            operationMessageDismissTask?.cancel()
            guard let message = operationMessage else { return }
            operationMessageDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, self?.operationMessage == message else { return }
                self?.operationMessage = nil
            }
        }
    }
    private var storageModificationDate: Date?
    private var externalChangeTimer: Timer?
    private var lastWritingSourceSyncAt: Date?
    private var operationMessageDismissTask: Task<Void, Never>?

    init() {
        load()
        syncWritingSources(automatic: true)
        connectZotero()
        startExternalChangeMonitor()
    }

    var inboxPapers: [Paper] { papers.filter { $0.status != .processed } }
    var zoteroAvailable: Bool { ZoteroLibrary.isAvailable }

    // MARK: - Settings & data safety
    var libraryItemCount: Int { questions.count + papers.count + markdownDocuments.count }

    func versions(for documentID: UUID) -> [WritingDocumentVersion] {
        writingDocumentVersions.filter { $0.documentID == documentID }.sorted { $0.createdAt > $1.createdAt }
    }

    func restoreVersion(_ versionID: UUID) {
        guard let version = writingDocumentVersions.first(where: { $0.id == versionID }),
              let index = markdownDocuments.firstIndex(where: { $0.id == version.documentID }) else { return }
        captureVersion(of: markdownDocuments[index])
        markdownDocuments[index].content = version.content
        markdownDocuments[index].richTextData = version.richTextData
        markdownDocuments[index].modifiedAt = Date()
        writingDocumentVersions.removeAll { $0.id == versionID }
        save()
        operationMessage = "已恢复“\(version.title)”的历史版本"
    }

    private func captureVersion(of document: MarkdownDocument) {
        guard !document.content.isEmpty else { return }
        let recent = writingDocumentVersions.filter { $0.documentID == document.id }.max { $0.createdAt < $1.createdAt }
        guard recent?.content != document.content else { return }
        writingDocumentVersions.append(WritingDocumentVersion(id: UUID(), documentID: document.id, title: document.title, content: document.content, richTextData: document.richTextData, createdAt: Date()))
        let ids = writingDocumentVersions.filter { $0.documentID == document.id }.sorted { $0.createdAt > $1.createdAt }.dropFirst(20).map(\.id)
        writingDocumentVersions.removeAll { ids.contains($0.id) }
    }

    private func addSyncConflict(for document: MarkdownDocument) {
        guard !writingSyncConflicts.contains(where: { $0.documentID == document.id }) else { return }
        writingSyncConflicts.append(WritingSyncConflict(id: UUID(), documentID: document.id, title: document.title, detectedAt: Date()))
    }

    func resolveSyncConflict(_ conflictID: UUID, keepExternal: Bool) {
        guard let conflict = writingSyncConflicts.first(where: { $0.id == conflictID }) else { return }
        if keepExternal { _ = syncWritingDocument(conflict.documentID, automatic: false, forceExternal: true) }
        writingSyncConflicts.removeAll { $0.id == conflictID }
        if !keepExternal { operationMessage = "已保留 ResearchOS 中的版本" }
    }

    func exportLibrary(to url: URL) throws {
        let data = try JSONEncoder().encode(PersistedLibrary(
            questions: questions,
            papers: papers,
            markdownDocuments: markdownDocuments,
            writingDocumentVersions: writingDocumentVersions,
            writingFolders: writingFolders,
            knowledgeGraph: knowledgeGraph
        ))
        try data.write(to: url, options: .atomic)
        operationMessage = "已导出 ResearchOS 数据备份"
    }

    func importLibrary(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode(PersistedLibrary.self, from: data)
        // Keep the current library recoverable before replacing it.
        if let backupURL = automaticBackupURL() {
            try? exportLibrary(to: backupURL)
        }
        questions = imported.questions
        papers = imported.papers
        markdownDocuments = imported.markdownDocuments ?? []
        writingDocumentVersions = imported.writingDocumentVersions ?? []
        writingFolders = imported.writingFolders ?? []
        knowledgeGraph = imported.knowledgeGraph ?? .empty
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已恢复数据；恢复前的版本已自动备份"
    }

    @discardableResult
    func createBackup() -> URL? {
        guard let url = automaticBackupURL() else { return nil }
        do {
            try exportLibrary(to: url)
            operationMessage = "已创建备份 \(url.deletingPathExtension().lastPathComponent)"
            return url
        } catch { return nil }
    }

    private func automaticBackupURL() -> URL? {
        guard let storageURL else { return nil }
        let folder = storageURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
        let url = folder.appendingPathComponent("library-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))" + ".json")
        return url
    }

    func addQuestion(title: String, question: String) -> UUID {
        let item = ResearchQuestion(
            id: UUID(), shortTitle: title, question: question, status: .exploring,
            paperCount: 0, openGapCount: 0,
            workingAnswer: "尚未形成工作结论。将论文加入这个问题后，ResearchOS 会逐步整理证据。",
            nextMove: "先从 Zotero 或本地 PDF 导入与这个问题最相关的 5–10 篇论文。",
            evidence: []
        )
        questions.insert(item, at: 0)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        return item.id
    }

    func updateQuestion(_ id: UUID, title: String, question: String) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanQuestion.isEmpty else { return }
        questions[index].shortTitle = cleanTitle
        questions[index].question = cleanQuestion
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已更新研究项目"
    }

    func deleteQuestion(_ id: UUID) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        let title = questions[index].shortTitle
        questions.remove(at: index)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已删除研究项目“\(title)”；论文和文稿未受影响"
    }

    func addEvidence(
        to questionID: UUID,
        paperID: UUID,
        quote: String,
        locator: String,
        claim: String,
        role: EvidenceRole,
        kind: EvidenceKind,
        note: String
    ) {
        guard let questionIndex = questions.firstIndex(where: { $0.id == questionID }),
              let paper = papers.first(where: { $0.id == paperID }) else { return }
        let cleanQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanClaim = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuote.isEmpty, !cleanClaim.isEmpty else { return }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = locator.isEmpty ? "《\(paper.title)》" : "《\(paper.title)》· \(locator)"
        let evidence = EvidenceItem(
            id: UUID(),
            kind: kind,
            claim: cleanClaim,
            source: source,
            confidence: cleanNote.isEmpty ? "\(role.title) · PDF 原文摘录" : cleanNote,
            paperID: paperID,
            quote: cleanQuote,
            locator: locator,
            role: role,
            createdAt: Date(),
            reviewStatus: .userConfirmed
        )
        questions[questionIndex].evidence.insert(evidence, at: 0)
        linkPaperWithoutSaving(paperID, toQuestionAt: questionIndex)
        refreshEvidenceMetrics(at: questionIndex)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已保存证据，并更新知识图谱"
    }

    func deleteEvidence(_ evidenceID: UUID, from questionID: UUID) {
        guard let questionIndex = questions.firstIndex(where: { $0.id == questionID }) else { return }
        questions[questionIndex].evidence.removeAll { $0.id == evidenceID }
        refreshEvidenceMetrics(at: questionIndex)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已移除证据卡片"
    }

    func linkPaper(_ paperID: UUID, to questionID: UUID) {
        guard papers.contains(where: { $0.id == paperID }),
              let questionIndex = questions.firstIndex(where: { $0.id == questionID }) else { return }
        linkPaperWithoutSaving(paperID, toQuestionAt: questionIndex)
        refreshEvidenceMetrics(at: questionIndex)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已关联论文"
    }

    func unlinkPaper(_ paperID: UUID, from questionID: UUID) {
        guard let questionIndex = questions.firstIndex(where: { $0.id == questionID }) else { return }
        var ids = questions[questionIndex].resolvedLinkedPaperIDs
        ids.removeAll { $0 == paperID }
        questions[questionIndex].linkedPaperIDs = ids
        refreshEvidenceMetrics(at: questionIndex)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已取消论文关联；已有证据未删除"
    }

    func generateEvidenceSuggestions(for questionID: UUID, paperID: UUID? = nil) {
        guard let questionIndex = questions.firstIndex(where: { $0.id == questionID }) else { return }
        let linkedIDs = Set(questions[questionIndex].resolvedLinkedPaperIDs)
        let targets = papers.filter { paper in
            linkedIDs.contains(paper.id) && (paperID == nil || paper.id == paperID)
        }
        guard !targets.isEmpty else {
            operationMessage = "请先为项目关联至少一篇论文"
            return
        }

        var suggestions: [EvidenceItem] = []
        for paper in targets {
            suggestions.append(contentsOf: makeEvidenceSuggestions(from: paper, existing: questions[questionIndex].evidence + suggestions))
        }
        guard !suggestions.isEmpty else {
            operationMessage = "没有找到同时具备原文和页码的新候选证据"
            return
        }
        questions[questionIndex].evidence.insert(contentsOf: suggestions, at: 0)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "已生成 \(suggestions.count) 条带页码的候选证据，请逐条审核"
    }

    func confirmEvidence(_ evidenceID: UUID, in questionID: UUID) {
        guard let questionIndex = questions.firstIndex(where: { $0.id == questionID }),
              let evidenceIndex = questions[questionIndex].evidence.firstIndex(where: { $0.id == evidenceID }) else { return }
        questions[questionIndex].evidence[evidenceIndex].reviewStatus = .userConfirmed
        if let paperID = questions[questionIndex].evidence[evidenceIndex].paperID {
            linkPaperWithoutSaving(paperID, toQuestionAt: questionIndex)
        }
        refreshEvidenceMetrics(at: questionIndex)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
        operationMessage = "证据已确认，并加入正式论证"
    }

    func rejectEvidence(_ evidenceID: UUID, in questionID: UUID) {
        updateEvidenceReviewStatus(.userRejected, evidenceID: evidenceID, questionID: questionID)
        operationMessage = "已拒绝这条建议；它不会进入正式图谱"
    }

    func restoreEvidenceSuggestion(_ evidenceID: UUID, in questionID: UUID) {
        updateEvidenceReviewStatus(.aiSuggested, evidenceID: evidenceID, questionID: questionID)
        operationMessage = "已移回待审核"
    }

    private func updateEvidenceReviewStatus(_ status: EvidenceReviewStatus, evidenceID: UUID, questionID: UUID) {
        guard let questionIndex = questions.firstIndex(where: { $0.id == questionID }),
              let evidenceIndex = questions[questionIndex].evidence.firstIndex(where: { $0.id == evidenceID }) else { return }
        questions[questionIndex].evidence[evidenceIndex].reviewStatus = status
        refreshEvidenceMetrics(at: questionIndex)
        rebuildKnowledgeGraph(saveAfter: false)
        save()
    }

    private func linkPaperWithoutSaving(_ paperID: UUID, toQuestionAt questionIndex: Int) {
        var ids = questions[questionIndex].resolvedLinkedPaperIDs
        if !ids.contains(paperID) { ids.append(paperID) }
        questions[questionIndex].linkedPaperIDs = ids
    }

    private func refreshEvidenceMetrics(at questionIndex: Int) {
        let confirmed = questions[questionIndex].evidence.filter { $0.resolvedReviewStatus == .userConfirmed }
        let paperIDs = Set(questions[questionIndex].resolvedLinkedPaperIDs).union(confirmed.compactMap(\.paperID))
        questions[questionIndex].paperCount = paperIDs.count
        questions[questionIndex].openGapCount = confirmed.filter { $0.kind == .gap }.count
    }

    private func makeEvidenceSuggestions(from paper: Paper, existing: [EvidenceItem]) -> [EvidenceItem] {
        guard let attachmentPath = paper.attachmentPath,
              let document = PDFDocument(url: URL(fileURLWithPath: attachmentPath)) else { return [] }

        let seeds: [(EvidenceRole, EvidenceKind, String)] = [
            (.claim, .convergence, paper.abstractText),
            (.method, .convergence, paper.method),
            (.finding, .convergence, paper.finding),
            (.limitation, .gap, paper.limitation),
        ]
        var results: [EvidenceItem] = []
        for (role, kind, seed) in seeds where isSubstantiveEvidenceSeed(seed) {
            guard let located = locateEvidenceSeed(seed, in: document) else { continue }
            let duplicate = (existing + results).contains { item in
                guard item.paperID == paper.id, item.resolvedRole == role else { return false }
                return normalizedEvidenceText(item.quote ?? item.claim).prefix(120)
                    == normalizedEvidenceText(located.quote).prefix(120)
            }
            guard !duplicate else { continue }
            let claim = String(normalizedEvidenceText(located.quote).prefix(220))
            results.append(EvidenceItem(
                id: UUID(),
                kind: kind,
                claim: claim,
                source: "《\(paper.title)》· \(located.locator)",
                confidence: "本地规则建议 · 已匹配 PDF 原文，待人工确认",
                paperID: paper.id,
                quote: located.quote,
                locator: located.locator,
                role: role,
                createdAt: Date(),
                reviewStatus: .aiSuggested
            ))
        }
        return results
    }

    private func locateEvidenceSeed(_ seed: String, in document: PDFDocument) -> (quote: String, locator: String)? {
        let normalizedSeed = normalizedEvidenceText(seed)
        guard normalizedSeed.count >= 40 else { return nil }
        let needle = String(normalizedSeed.prefix(min(100, normalizedSeed.count)))
        for pageIndex in 0..<document.pageCount {
            guard let pageText = document.page(at: pageIndex)?.string else { continue }
            let paragraphs = pageText.components(separatedBy: "\n\n")
            if let paragraph = paragraphs.first(where: {
                let normalized = normalizedEvidenceText($0)
                return normalized.count >= 40 && (normalized.contains(needle) || needle.contains(String(normalized.prefix(min(80, normalized.count)))))
            }) {
                let quote = normalizedEvidenceText(paragraph)
                return (String(quote.prefix(1_200)), "第 \(pageIndex + 1) 页")
            }
            if normalizedEvidenceText(pageText).contains(needle) {
                return (String(normalizedSeed.prefix(1_200)), "第 \(pageIndex + 1) 页")
            }
        }
        return nil
    }

    private func isSubstantiveEvidenceSeed(_ text: String) -> Bool {
        let normalized = normalizedEvidenceText(text)
        return normalized.count >= 40
            && !normalized.contains("待整理")
            && !normalized.contains("未在可提取文本中识别出")
            && !normalized.contains("未识别到摘要")
    }

    private func normalizedEvidenceText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func createMarkdownDocument(title: String) -> UUID {
        createWritingDocument(title: title, kind: .note, format: .markdown)
    }

    func createWritingDocument(title: String, kind: WritingDocumentKind, format: WritingDocumentFormat) -> UUID {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? "未命名文稿" : cleanTitle
        let initialContent: String = switch format {
        case .markdown:
            "# \(resolvedTitle)\n\n"
        case .latex:
            "\\documentclass{article}\n\\usepackage{amsmath}\n\\usepackage{ctex}\n\n\\title{\(resolvedTitle)}\n\\author{}\n\\date{}\n\n\\begin{document}\n\\maketitle\n\n\\section{引言}\n\n\\end{document}\n"
        case .word:
            resolvedTitle + "\n\n"
        }
        let richTextData: Data? = format == .word ? makeInitialRichText(title: resolvedTitle) : nil
        let document = MarkdownDocument(
            id: UUID(),
            title: resolvedTitle,
            content: initialContent,
            modifiedAt: Date(),
            kind: kind,
            format: format,
            richTextData: richTextData
        )
        markdownDocuments.insert(document, at: 0)
        save()
        operationMessage = "已新建\(kind.title)“\(resolvedTitle)”"
        return document.id
    }

    @discardableResult
    func importMarkdown(from url: URL) -> UUID? {
        importWritingDocument(from: url, as: .note)
    }

    @discardableResult
    func importWritingDocument(from url: URL, as kind: WritingDocumentKind) -> UUID? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let synchronizedAt = Date()
            let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let document = try makeImportedWritingDocument(
                from: url,
                kind: kind,
                sourceBookmark: bookmark,
                sourceModifiedAt: values?.contentModificationDate,
                sourceFileSize: values?.fileSize.map { Int64($0) },
                lastSyncedAt: synchronizedAt
            )
            markdownDocuments.insert(document, at: 0)
            save()
            operationMessage = "已导入 \(url.lastPathComponent)"
            return document.id
        } catch {
            operationMessage = "文档导入失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importWritingFolder(from folderURL: URL) -> [UUID] {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        guard let sourceURLs = writingSourceFiles(in: folderURL) else {
            operationMessage = "无法读取所选文件夹"
            return []
        }

        guard !sourceURLs.isEmpty else {
            operationMessage = "所选文件夹中没有可导入的写作文档"
            return []
        }

        let folderName = folderURL.lastPathComponent.isEmpty ? "导入的文稿" : folderURL.lastPathComponent
        let folderID: UUID
        let createdFolder: Bool
        let sourceBookmark = try? folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let synchronizedAt = Date()
        if let existing = writingFolders.first(where: {
            $0.name.compare(folderName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            folderID = existing.id
            createdFolder = false
            if let index = writingFolders.firstIndex(where: { $0.id == existing.id }) {
                writingFolders[index].sourceBookmark = sourceBookmark
                writingFolders[index].lastSyncedAt = synchronizedAt
            }
        } else {
            let folder = WritingFolder(
                id: UUID(),
                name: folderName,
                createdAt: Date(),
                sourceBookmark: sourceBookmark,
                lastSyncedAt: synchronizedAt
            )
            writingFolders.append(folder)
            writingFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            folderID = folder.id
            createdFolder = true
        }

        var importedDocuments: [MarkdownDocument] = []
        var failedCount = 0
        for source in sourceURLs {
            do {
                let url = source.url
                let ext = url.pathExtension.lowercased()
                let kind: WritingDocumentKind = (ext == "tex" || ext == "docx") ? .paper : .note
                var document = try makeImportedWritingDocument(
                    from: url,
                    kind: kind,
                    importedRelativePath: source.relativePath,
                    sourceModifiedAt: source.modifiedAt,
                    sourceFileSize: source.fileSize,
                    lastSyncedAt: synchronizedAt
                )
                document.folderID = folderID
                importedDocuments.append(document)
            } catch {
                failedCount += 1
            }
        }

        guard !importedDocuments.isEmpty else {
            if createdFolder {
                writingFolders.removeAll { $0.id == folderID }
            }
            operationMessage = "文件夹中的文档无法读取"
            return []
        }

        markdownDocuments.insert(contentsOf: importedDocuments, at: 0)
        save()
        let failureNote = failedCount == 0 ? "" : "，另有 \(failedCount) 个文件无法读取"
        operationMessage = "已从“\(folderName)”导入 \(importedDocuments.count) 个文稿\(failureNote)"
        return importedDocuments.map(\.id)
    }

    func syncWritingFolder(_ id: UUID, automatic: Bool = false, forceExternal: Bool = false) -> Bool {
        guard let index = writingFolders.firstIndex(where: { $0.id == id }) else { return true }
        guard let bookmark = writingFolders[index].sourceBookmark else {
            if !automatic { operationMessage = "请重新选择“\(writingFolders[index].name)”的来源文件夹" }
            return false
        }

        var isStale = false
        do {
            let folderURL = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessed = folderURL.startAccessingSecurityScopedResource()
            defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: folderURL.path) else {
                if !automatic { operationMessage = "找不到来源文件夹，请重新选择" }
                return false
            }
            if isStale {
                writingFolders[index].sourceBookmark = try? folderURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            return syncWritingFolderContents(id, from: folderURL, automatic: automatic, forceExternal: forceExternal)
        } catch {
            if !automatic { operationMessage = "无法访问来源文件夹，请重新选择" }
            return false
        }
    }

    @discardableResult
    func syncWritingDocument(_ id: UUID, automatic: Bool = false, forceExternal: Bool = false) -> Bool {
        guard let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return true }
        if let folderID = markdownDocuments[index].folderID,
           writingFolders.contains(where: { $0.id == folderID }) {
            return syncWritingFolder(folderID, automatic: automatic, forceExternal: forceExternal)
        }
        guard let bookmark = markdownDocuments[index].sourceBookmark else {
            if !automatic { operationMessage = "请重新选择“\(markdownDocuments[index].title)”的来源文件" }
            return false
        }

        var isStale = false
        do {
            let sourceURL = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                if !automatic { operationMessage = "找不到来源文件，请重新选择" }
                return false
            }
            if isStale {
                markdownDocuments[index].sourceBookmark = try? sourceURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            return syncWritingDocumentContents(id, from: sourceURL, automatic: automatic, forceExternal: forceExternal)
        } catch {
            if !automatic { operationMessage = "无法访问来源文件，请重新选择" }
            return false
        }
    }

    @discardableResult
    func linkAndSyncWritingDocument(_ id: UUID, from sourceURL: URL) -> Bool {
        guard let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return false }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            operationMessage = "无法读取所选文件"
            return false
        }
        markdownDocuments[index].sourceBookmark = try? sourceURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        markdownDocuments[index].importedName = sourceURL.lastPathComponent
        return syncWritingDocumentContents(id, from: sourceURL, automatic: false, relinking: true)
    }

    @discardableResult
    func linkAndSyncWritingFolder(_ id: UUID, from folderURL: URL) -> Bool {
        guard let index = writingFolders.firstIndex(where: { $0.id == id }) else { return false }
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            operationMessage = "无法读取所选文件夹"
            return false
        }
        writingFolders[index].sourceBookmark = try? folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return syncWritingFolderContents(id, from: folderURL, automatic: false)
    }

    func syncWritingSourcesWhenActivated() {
        if let lastWritingSourceSyncAt, Date().timeIntervalSince(lastWritingSourceSyncAt) < 1.5 { return }
        syncWritingSources(automatic: true)
    }

    private func syncWritingSources(automatic: Bool) {
        var added = 0
        var updated = 0
        let individuallyLinkedIDs = markdownDocuments.compactMap { document in
            document.folderID == nil && document.sourceBookmark != nil ? document.id : nil
        }
        for documentID in individuallyLinkedIDs {
            let beforeDate = markdownDocuments.first(where: { $0.id == documentID })?.modifiedAt
            if syncWritingDocument(documentID, automatic: automatic),
               let afterDate = markdownDocuments.first(where: { $0.id == documentID })?.modifiedAt,
               afterDate != beforeDate {
                updated += 1
            }
        }
        for folder in writingFolders where folder.sourceBookmark != nil {
            let beforeIDs = Set(markdownDocuments.map(\.id))
            let beforeDates = Dictionary(uniqueKeysWithValues: markdownDocuments.map { ($0.id, $0.modifiedAt) })
            if syncWritingFolder(folder.id, automatic: true) {
                added += markdownDocuments.filter { !beforeIDs.contains($0.id) }.count
                updated += markdownDocuments.filter {
                    beforeIDs.contains($0.id) && beforeDates[$0.id] != $0.modifiedAt
                }.count
            }
        }
        if added + updated > 0 {
            operationMessage = "已同步外部文稿：新增 \(added) 篇，更新 \(updated) 篇"
        }
        lastWritingSourceSyncAt = Date()
    }

    @discardableResult
    private func syncWritingDocumentContents(
        _ id: UUID,
        from sourceURL: URL,
        automatic: Bool,
        relinking: Bool = false,
        forceExternal: Bool = false
    ) -> Bool {
        guard let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return false }
        do {
            let values = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let sourceModifiedAt = values?.contentModificationDate
            let sourceFileSize = values?.fileSize.map { Int64($0) }
            let current = markdownDocuments[index]
            let sourceChanged = relinking || current.sourceModifiedAt != sourceModifiedAt ||
                current.sourceFileSize != sourceFileSize
            guard sourceChanged else {
                if !automatic { operationMessage = "“\(current.title)”已是最新版本" }
                return true
            }

            let synchronizedAt = Date()
            let incoming = try makeImportedWritingDocument(
                from: sourceURL,
                kind: current.resolvedKind,
                sourceBookmark: current.sourceBookmark,
                sourceModifiedAt: sourceModifiedAt,
                sourceFileSize: sourceFileSize,
                lastSyncedAt: synchronizedAt
            )
            let localChanged = !relinking && current.lastSyncedAt != nil &&
                current.modifiedAt.timeIntervalSince(current.lastSyncedAt ?? .distantPast) > 0.5
            if localChanged && !forceExternal {
                addSyncConflict(for: current)
                if !automatic { operationMessage = "检测到 ResearchOS 内也修改过“\(current.title)”，已跳过覆盖" }
                return true
            }

            markdownDocuments[index] = MarkdownDocument(
                id: current.id,
                title: incoming.title,
                content: incoming.content,
                modifiedAt: incoming.modifiedAt,
                kind: current.kind,
                format: incoming.format,
                richTextData: incoming.richTextData,
                importedName: incoming.importedName,
                folderID: current.folderID,
                sourceBookmark: current.sourceBookmark,
                importedRelativePath: current.importedRelativePath,
                sourceModifiedAt: incoming.sourceModifiedAt,
                sourceFileSize: incoming.sourceFileSize,
                lastSyncedAt: incoming.lastSyncedAt
            )
            save()
            if !automatic { operationMessage = "已从原文件更新“\(incoming.title)”" }
            return true
        } catch {
            if !automatic { operationMessage = "文档同步失败：\(error.localizedDescription)" }
            return false
        }
    }

    @discardableResult
    private func syncWritingFolderContents(_ id: UUID, from folderURL: URL, automatic: Bool, forceExternal: Bool = false) -> Bool {
        guard let folderIndex = writingFolders.firstIndex(where: { $0.id == id }),
              let sources = writingSourceFiles(in: folderURL) else {
            if !automatic { operationMessage = "无法读取来源文件夹" }
            return false
        }

        let synchronizedAt = Date()
        var addedCount = 0
        var updatedCount = 0
        var conflictCount = 0
        var failedCount = 0

        for source in sources {
            do {
                let ext = source.url.pathExtension.lowercased()
                let kind: WritingDocumentKind = (ext == "tex" || ext == "docx") ? .paper : .note
                var incoming = try makeImportedWritingDocument(
                    from: source.url,
                    kind: kind,
                    importedRelativePath: source.relativePath,
                    sourceModifiedAt: source.modifiedAt,
                    sourceFileSize: source.fileSize,
                    lastSyncedAt: synchronizedAt
                )
                incoming.folderID = id

                let exactIndex = markdownDocuments.firstIndex {
                    $0.folderID == id && $0.importedRelativePath == source.relativePath
                }
                let legacyMatches = markdownDocuments.indices.filter {
                    markdownDocuments[$0].folderID == id &&
                    markdownDocuments[$0].importedRelativePath == nil &&
                    markdownDocuments[$0].importedName == source.url.lastPathComponent
                }
                let documentIndex = exactIndex ?? (legacyMatches.count == 1 ? legacyMatches[0] : nil)

                guard let documentIndex else {
                    markdownDocuments.insert(incoming, at: 0)
                    addedCount += 1
                    continue
                }

                let current = markdownDocuments[documentIndex]
                if current.lastSyncedAt == nil {
                    if current.content == incoming.content && current.richTextData == incoming.richTextData {
                        markdownDocuments[documentIndex].importedRelativePath = source.relativePath
                        markdownDocuments[documentIndex].sourceModifiedAt = source.modifiedAt
                        markdownDocuments[documentIndex].sourceFileSize = source.fileSize
                        markdownDocuments[documentIndex].lastSyncedAt = synchronizedAt
                    } else {
                        conflictCount += 1
                    }
                    continue
                }

                let sourceChanged = current.sourceModifiedAt != source.modifiedAt ||
                    current.sourceFileSize != source.fileSize
                guard sourceChanged else { continue }

                let localChanged = current.modifiedAt.timeIntervalSince(current.lastSyncedAt ?? .distantPast) > 0.5
                if localChanged && !forceExternal {
                    addSyncConflict(for: current)
                    conflictCount += 1
                    continue
                }

                markdownDocuments[documentIndex] = MarkdownDocument(
                    id: current.id,
                    title: incoming.title,
                    content: incoming.content,
                    modifiedAt: incoming.modifiedAt,
                    kind: incoming.kind,
                    format: incoming.format,
                    richTextData: incoming.richTextData,
                    importedName: incoming.importedName,
                    folderID: id,
                    sourceBookmark: current.sourceBookmark,
                    importedRelativePath: incoming.importedRelativePath,
                    sourceModifiedAt: incoming.sourceModifiedAt,
                    sourceFileSize: incoming.sourceFileSize,
                    lastSyncedAt: incoming.lastSyncedAt
                )
                updatedCount += 1
            } catch {
                failedCount += 1
            }
        }

        writingFolders[folderIndex].lastSyncedAt = synchronizedAt
        save()
        if !automatic {
            var details = "已同步“\(writingFolders[folderIndex].name)”：新增 \(addedCount) 篇，更新 \(updatedCount) 篇"
            if conflictCount > 0 { details += "，跳过 \(conflictCount) 篇本地已修改文稿" }
            if failedCount > 0 { details += "，\(failedCount) 个文件读取失败" }
            operationMessage = details
        }
        return true
    }

    private struct WritingSourceFile {
        let url: URL
        let relativePath: String
        let modifiedAt: Date?
        let fileSize: Int64?
    }

    private func writingSourceFiles(in folderURL: URL) -> [WritingSourceFile]? {
        let supportedExtensions: Set<String> = ["md", "markdown", "txt", "tex", "rtf", "rtfd", "docx"]
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let rootPath = folderURL.standardizedFileURL.path.hasSuffix("/")
            ? folderURL.standardizedFileURL.path
            : folderURL.standardizedFileURL.path + "/"
        return enumerator.compactMap { item -> WritingSourceFile? in
            guard let url = item as? URL,
                  supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let standardizedPath = url.standardizedFileURL.path
            let relativePath = standardizedPath.hasPrefix(rootPath)
                ? String(standardizedPath.dropFirst(rootPath.count))
                : url.lastPathComponent
            return WritingSourceFile(
                url: url,
                relativePath: relativePath,
                modifiedAt: values?.contentModificationDate,
                fileSize: values?.fileSize.map { Int64($0) }
            )
        }
        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func makeImportedWritingDocument(
        from url: URL,
        kind: WritingDocumentKind,
        sourceBookmark: Data? = nil,
        importedRelativePath: String? = nil,
        sourceModifiedAt: Date? = nil,
        sourceFileSize: Int64? = nil,
        lastSyncedAt: Date? = nil
    ) throws -> MarkdownDocument {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        if ext == "docx" || ext == "rtf" || ext == "rtfd" {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = ext == "docx"
                ? [.documentType: NSAttributedString.DocumentType.officeOpenXML]
                : [.documentType: NSAttributedString.DocumentType.rtf]
            let attributed = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            let rtf = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            return MarkdownDocument(
                id: UUID(), title: title, content: attributed.string, modifiedAt: Date(),
                kind: kind, format: .word, richTextData: rtf, importedName: url.lastPathComponent,
                sourceBookmark: sourceBookmark,
                importedRelativePath: importedRelativePath, sourceModifiedAt: sourceModifiedAt,
                sourceFileSize: sourceFileSize, lastSyncedAt: lastSyncedAt
            )
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let format: WritingDocumentFormat = ext == "tex" ? .latex : .markdown
        return MarkdownDocument(
            id: UUID(), title: title, content: content, modifiedAt: Date(),
            kind: kind, format: format, importedName: url.lastPathComponent,
            sourceBookmark: sourceBookmark,
            importedRelativePath: importedRelativePath, sourceModifiedAt: sourceModifiedAt,
            sourceFileSize: sourceFileSize, lastSyncedAt: lastSyncedAt
        )
    }

    func updateMarkdown(_ id: UUID, title: String? = nil, content: String? = nil) {
        guard let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return }
        captureVersion(of: markdownDocuments[index])
        if let title { markdownDocuments[index].title = title }
        if let content { markdownDocuments[index].content = content }
        markdownDocuments[index].modifiedAt = Date()
        save()
    }

    func updateRichText(_ id: UUID, data: Data, plainText: String) {
        guard let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return }
        captureVersion(of: markdownDocuments[index])
        markdownDocuments[index].richTextData = data
        markdownDocuments[index].content = plainText
        markdownDocuments[index].modifiedAt = Date()
        save()
    }

    func saveWritingDocument(_ id: UUID) {
        guard let document = markdownDocuments.first(where: { $0.id == id }) else { return }
        save()
        operationMessage = "已保存“\(document.title.isEmpty ? "未命名文稿" : document.title)”"
    }

    func renameWritingDocument(_ id: UUID, to name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return }
        markdownDocuments[index].title = cleanName
        markdownDocuments[index].modifiedAt = Date()
        save()
        operationMessage = "已重命名为“\(cleanName)”"
    }

    @discardableResult
    func duplicateWritingDocument(_ id: UUID) -> UUID? {
        guard let source = markdownDocuments.first(where: { $0.id == id }) else { return nil }
        let copyID = UUID()
        let copy = MarkdownDocument(
            id: copyID,
            title: source.title.isEmpty ? "未命名文稿副本" : "\(source.title) 副本",
            content: source.content,
            modifiedAt: Date(),
            kind: source.kind,
            format: source.format,
            richTextData: source.richTextData,
            importedName: nil,
            folderID: source.folderID
        )
        markdownDocuments.insert(copy, at: 0)
        save()
        operationMessage = "已创建“\(copy.title)”"
        return copyID
    }

    func moveWritingDocument(_ id: UUID, to folderID: UUID?) {
        guard folderID == nil || writingFolders.contains(where: { $0.id == folderID }),
              let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return }
        markdownDocuments[index].folderID = folderID
        markdownDocuments[index].modifiedAt = Date()
        save()
        let destination = writingFolders.first(where: { $0.id == folderID })?.name ?? "未分类"
        operationMessage = "已移动到“\(destination)”"
    }

    func deleteWritingDocument(_ id: UUID) {
        guard let index = markdownDocuments.firstIndex(where: { $0.id == id }) else { return }
        let title = markdownDocuments[index].title
        markdownDocuments.remove(at: index)
        save()
        operationMessage = "已删除“\(title.isEmpty ? "未命名文稿" : title)”"
    }

    @discardableResult
    func createWritingFolder(name: String) -> UUID? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        if let existing = writingFolders.first(where: {
            $0.name.compare(cleanName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return existing.id
        }
        let folder = WritingFolder(id: UUID(), name: cleanName, createdAt: Date())
        writingFolders.append(folder)
        writingFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        operationMessage = "已新建文件夹“\(cleanName)”"
        return folder.id
    }

    func renameWritingFolder(_ id: UUID, to name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let index = writingFolders.firstIndex(where: { $0.id == id }) else { return }
        writingFolders[index].name = cleanName
        writingFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        operationMessage = "已重命名文件夹"
    }

    func deleteWritingFolder(_ id: UUID) {
        guard let folder = writingFolders.first(where: { $0.id == id }) else { return }
        for index in markdownDocuments.indices where markdownDocuments[index].folderID == id {
            markdownDocuments[index].folderID = nil
        }
        writingFolders.removeAll { $0.id == id }
        save()
        operationMessage = "已移除文件夹“\(folder.name)”；其中的文稿已移到未分类"
    }

    private func makeInitialRichText(title: String) -> Data? {
        let result = NSMutableAttributedString(
            string: title + "\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: NSColor.textColor,
            ]
        )
        result.append(NSAttributedString(
            string: "开始撰写正文…",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return try? result.data(
            from: NSRange(location: 0, length: result.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    @discardableResult
    func importPDF(from url: URL) -> UUID? {
        importPaperDocuments(from: [url]).first
    }

    @discardableResult
    func importPaperDocuments(from urls: [URL]) -> [UUID] {
        guard !urls.isEmpty else { return [] }
        isBusy = true
        operationMessage = urls.count == 1 ? "正在识别文献信息…" : "正在识别 \(urls.count) 份文献…"
        defer { isBusy = false }

        var importedIDs: [UUID] = []
        var failedCount = 0
        for url in urls {
            guard PDFPaperImporter.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                failedCount += 1
                continue
            }
            do {
                let paper = try PDFPaperImporter.importLocalDocument(from: url)
                importedIDs.append(upsert(paper, saveAfter: false))
            } catch {
                failedCount += 1
            }
        }
        if !importedIDs.isEmpty {
            rebuildKnowledgeGraph(saveAfter: false)
            save()
        }
        if importedIDs.count == 1, let id = importedIDs.first,
           let paper = papers.first(where: { $0.id == id }) {
            operationMessage = "已识别并导入《\(paper.title)》"
        } else {
            var result = "已导入 \(importedIDs.count) 份文献"
            if failedCount > 0 { result += "，\(failedCount) 份无法读取" }
            operationMessage = result
        }
        return importedIDs
    }

    @discardableResult
    func importPaperFolder(from folderURL: URL) -> [UUID] {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            operationMessage = "无法读取所选文件夹"
            return []
        }
        let urls = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  PDFPaperImporter.supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !urls.isEmpty else {
            operationMessage = "文件夹中没有可导入的 PDF 或 Word 文献"
            return []
        }
        return importPaperDocuments(from: urls)
    }

    func connectZotero() {
        guard zoteroAvailable else { return }
        do {
            zoteroCollections = try ZoteroLibrary.collections()
        } catch {
            operationMessage = "暂时无法读取 Zotero：\(error.localizedDescription)"
        }
    }

    func importZoteroCollection(_ collection: ZoteroCollection) {
        isBusy = true
        operationMessage = "正在从 Zotero 读取“\(collection.name)”…"
        defer { isBusy = false }
        do {
            let imported = try ZoteroLibrary.papers(in: collection.id)
            for paper in imported { upsert(paper, saveAfter: false) }
            rebuildKnowledgeGraph(saveAfter: false)
            save()
            operationMessage = "已从 Zotero 导入 \(imported.count) 篇论文"
        } catch {
            operationMessage = "Zotero 导入失败：\(error.localizedDescription)"
        }
    }

    func extractFullText(_ id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }),
              let path = papers[index].attachmentPath else { return }
        isBusy = true
        operationMessage = "正在提取全文…"
        defer { isBusy = false }
        do {
            let parsed = try PDFPaperImporter.parse(url: URL(fileURLWithPath: path))
            papers[index].pageCount = parsed.pageCount
            papers[index].extractedCharacterCount = parsed.text.count
            papers[index].analysisInput = String(parsed.text.prefix(18_000))
            if papers[index].abstractText.isEmpty { papers[index].abstractText = parsed.abstractText }
            let sections = PDFPaperImporter.heuristicSections(from: parsed.text, abstractText: papers[index].abstractText)
            papers[index].researchQuestion = sections.researchQuestion
            papers[index].method = sections.method
            papers[index].finding = sections.finding
            papers[index].limitation = sections.limitation
            papers[index].analysisState = parsed.text.isEmpty ? .needsReview : .extracted
            rebuildKnowledgeGraph(saveAfter: false)
            save()
            operationMessage = parsed.text.isEmpty
                ? "这份 PDF 没有可提取文字，后续需要 OCR"
                : "已提取 \(parsed.pageCount) 页正文"
        } catch {
            operationMessage = "全文提取失败：\(error.localizedDescription)"
        }
    }

    func extractAvailableFullTexts() {
        let candidates = papers.compactMap { paper -> (UUID, String)? in
            guard paper.extractedCharacterCount == 0, let path = paper.attachmentPath,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return (paper.id, path)
        }
        guard !candidates.isEmpty else {
            operationMessage = "所有可用原文都已提取"
            return
        }

        isBusy = true
        operationMessage = "正在提取 \(candidates.count) 份原文…"
        Task {
            let parsedItems = await Task.detached(priority: .userInitiated) {
                candidates.compactMap { id, path -> (UUID, ParsedPDF)? in
                    guard let parsed = try? PDFPaperImporter.parse(url: URL(fileURLWithPath: path)) else { return nil }
                    return (id, parsed)
                }
            }.value

            for (id, parsed) in parsedItems {
                apply(parsed, to: id)
            }
            rebuildKnowledgeGraph(saveAfter: false)
            save()
            isBusy = false
            operationMessage = "已提取 \(parsedItems.count) 份原文；现在可以直接阅读并继续整理"
        }
    }

    func markProcessed(_ id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].status = .processed
        save()
        operationMessage = "已完成整理；论文仍保留在论文库"
    }

    func markReading(_ id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].status = .reading
        save()
        operationMessage = "已加入正在精读"
    }

    func moveBackToInbox(_ id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].status = .unread
        save()
        operationMessage = "已移回处理队列"
    }

    @discardableResult
    private func upsert(_ paper: Paper, saveAfter: Bool = true) -> UUID {
        let duplicateIndex = papers.firstIndex {
            if let key = paper.zoteroKey, let existingKey = $0.zoteroKey { return key == existingKey }
            if let doi = paper.doi, let existingDOI = $0.doi { return doi.caseInsensitiveCompare(existingDOI) == .orderedSame }
            return $0.title.caseInsensitiveCompare(paper.title) == .orderedSame
        }
        if let duplicateIndex {
            papers[duplicateIndex].attachmentPath = paper.attachmentPath ?? papers[duplicateIndex].attachmentPath
            papers[duplicateIndex].importedName = paper.importedName ?? papers[duplicateIndex].importedName
            papers[duplicateIndex].abstractText = paper.abstractText.isEmpty ? papers[duplicateIndex].abstractText : paper.abstractText
            if papers[duplicateIndex].authors == "作者待确认" || papers[duplicateIndex].authors == "待确认" {
                papers[duplicateIndex].authors = paper.authors
            }
            if papers[duplicateIndex].venue == "来源待确认" || papers[duplicateIndex].venue == "本地 PDF" {
                papers[duplicateIndex].venue = paper.venue
            }
            papers[duplicateIndex].doi = paper.doi ?? papers[duplicateIndex].doi
            if paper.extractedCharacterCount > papers[duplicateIndex].extractedCharacterCount {
                papers[duplicateIndex].pageCount = paper.pageCount
                papers[duplicateIndex].extractedCharacterCount = paper.extractedCharacterCount
                papers[duplicateIndex].analysisInput = paper.analysisInput
                papers[duplicateIndex].researchQuestion = paper.researchQuestion
                papers[duplicateIndex].method = paper.method
                papers[duplicateIndex].finding = paper.finding
                papers[duplicateIndex].limitation = paper.limitation
            }
            if papers[duplicateIndex].analysisState == .missingPDF, paper.attachmentPath != nil {
                papers[duplicateIndex].analysisState = paper.analysisState
            }
        } else {
            papers.insert(paper, at: 0)
        }
        if saveAfter {
            rebuildKnowledgeGraph(saveAfter: false)
            save()
        }
        return duplicateIndex.map { papers[$0].id } ?? paper.id
    }

    private func apply(_ parsed: ParsedPDF, to id: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].pageCount = parsed.pageCount
        papers[index].extractedCharacterCount = parsed.text.count
        papers[index].analysisInput = String(parsed.text.prefix(18_000))
        if papers[index].authors == "作者待确认" || papers[index].authors == "待确认" { papers[index].authors = parsed.authors }
        if papers[index].venue == "来源待确认" || papers[index].venue == "本地 PDF" { papers[index].venue = parsed.venue }
        papers[index].doi = parsed.doi ?? papers[index].doi
        if papers[index].abstractText.isEmpty { papers[index].abstractText = parsed.abstractText }
        let sections = PDFPaperImporter.heuristicSections(from: parsed.text, abstractText: papers[index].abstractText)
        papers[index].researchQuestion = sections.researchQuestion
        papers[index].method = sections.method
        papers[index].finding = sections.finding
        papers[index].limitation = sections.limitation
        papers[index].analysisState = parsed.text.isEmpty ? .needsReview : .extracted
    }

    private struct PersistedLibrary: Codable {
        var questions: [ResearchQuestion]
        var papers: [Paper]
        var markdownDocuments: [MarkdownDocument]?
        var writingDocumentVersions: [WritingDocumentVersion]?
        var writingFolders: [WritingFolder]?
        var knowledgeGraph: KnowledgeGraph?
    }

    private var storageURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("ResearchOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("library.json")
    }

    private func load() {
        guard let storageURL, let data = try? Data(contentsOf: storageURL),
              let library = try? JSONDecoder().decode(PersistedLibrary.self, from: data) else { return }
        questions = library.questions
        papers = library.papers
        markdownDocuments = library.markdownDocuments ?? []
        writingDocumentVersions = library.writingDocumentVersions ?? []
        writingFolders = library.writingFolders ?? []
        knowledgeGraph = library.knowledgeGraph ?? .empty
        storageModificationDate = modificationDate(of: storageURL)

        var repairedStoredLibrary = false
        let legacyDemoPaperIDs = Set(papers.filter { $0.source == .demo }.map(\.id))
        if !legacyDemoPaperIDs.isEmpty {
            papers.removeAll { legacyDemoPaperIDs.contains($0.id) }
            questions.removeAll { question in
                question.shortTitle == "长期记忆架构"
                    && question.question == "AI Agent 如何维持长期个人记忆，同时避免噪声不断累积？"
            }
            repairedStoredLibrary = true
        }
        for index in papers.indices where papers[index].source == .zotero && papers[index].pageCount == 0 {
            if papers[index].analysisInput == papers[index].abstractText && papers[index].extractedCharacterCount > 0 {
                papers[index].extractedCharacterCount = 0
                repairedStoredLibrary = true
            }
        }
        let loadedGraph = knowledgeGraph
        rebuildKnowledgeGraph(saveAfter: false)
        if knowledgeGraph != loadedGraph {
            repairedStoredLibrary = true
        }
        if repairedStoredLibrary { save() }
    }

    private func save() {
        guard let storageURL,
              let data = try? JSONEncoder().encode(PersistedLibrary(
                questions: questions,
                papers: papers,
                markdownDocuments: markdownDocuments,
                writingDocumentVersions: writingDocumentVersions,
                writingFolders: writingFolders,
                knowledgeGraph: knowledgeGraph
              )) else { return }
        try? data.write(to: storageURL, options: .atomic)
        storageModificationDate = modificationDate(of: storageURL)
    }

    private func startExternalChangeMonitor() {
        externalChangeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadIfChanged() }
        }
    }

    private func reloadIfChanged() {
        guard !isBusy, let storageURL else { return }
        let currentDate = modificationDate(of: storageURL)
        guard currentDate != storageModificationDate else { return }
        load()
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    func rebuildKnowledgeGraph(saveAfter: Bool = true) {
        let existingNodes = Dictionary(uniqueKeysWithValues: knowledgeGraph.nodes.map { ($0.stableKey, $0) })
        let existingEdges = Dictionary(uniqueKeysWithValues: knowledgeGraph.edges.map { ($0.stableKey, $0) })
        var nodes: [KnowledgeNode] = []
        var edges: [KnowledgeEdge] = []
        var questionNodes: [UUID: KnowledgeNode] = [:]
        var paperNodes: [UUID: KnowledgeNode] = [:]

        func makeNode(
            key: String,
            kind: KnowledgeNodeKind,
            label: String,
            detail: String,
            sourceID: UUID?,
            provenance: String,
            reviewStatus: KnowledgeReviewStatus = .derived
        ) -> KnowledgeNode {
            if var existing = existingNodes[key] {
                existing.kind = kind
                existing.label = label
                existing.detail = detail
                existing.sourceID = sourceID
                existing.provenance = provenance
                existing.reviewStatus = reviewStatus
                return existing
            }
            return KnowledgeNode(
                id: UUID(), stableKey: key, kind: kind, label: label, detail: detail,
                sourceID: sourceID, provenance: provenance, reviewStatus: reviewStatus
            )
        }

        func makeEdge(
            key: String, source: UUID, target: UUID, kind: KnowledgeEdgeKind,
            provenance: String, reviewStatus: KnowledgeReviewStatus = .derived
        ) -> KnowledgeEdge {
            if var existing = existingEdges[key] {
                existing.sourceNodeID = source
                existing.targetNodeID = target
                existing.kind = kind
                existing.provenance = provenance
                existing.reviewStatus = reviewStatus
                return existing
            }
            return KnowledgeEdge(
                id: UUID(), stableKey: key, sourceNodeID: source, targetNodeID: target,
                kind: kind, provenance: provenance, reviewStatus: reviewStatus
            )
        }

        for paper in papers {
            let paperNode = makeNode(
                key: "paper:\(paper.id.uuidString)", kind: .paper,
                label: paper.title, detail: "\(paper.authors) · \(paper.year) · \(paper.venue)",
                sourceID: paper.id, provenance: paper.source.title
            )
            nodes.append(paperNode)
            paperNodes[paper.id] = paperNode
        }

        for question in questions {
            let questionNode = makeNode(
                key: "question:\(question.id.uuidString)", kind: .researchQuestion,
                label: question.shortTitle, detail: question.question, sourceID: question.id,
                provenance: "ResearchOS 研究项目中的核心问题", reviewStatus: .confirmed
            )
            nodes.append(questionNode)
            questionNodes[question.id] = questionNode
            for paperID in question.resolvedLinkedPaperIDs {
                guard let paperNode = paperNodes[paperID] else { continue }
                edges.append(makeEdge(
                    key: "project-paper:\(question.id.uuidString):\(paperID.uuidString)",
                    source: paperNode.id,
                    target: questionNode.id,
                    kind: .candidateFor,
                    provenance: "用户关联到研究项目“\(question.shortTitle)”",
                    reviewStatus: .confirmed
                ))
            }
            for evidence in question.evidence where evidence.resolvedReviewStatus != .userRejected {
                let reviewStatus: KnowledgeReviewStatus = evidence.resolvedReviewStatus == .userConfirmed
                    ? .confirmed
                    : .aiSuggested
                let kind: KnowledgeNodeKind = switch evidence.resolvedRole {
                case .claim: .claim
                case .method: .method
                case .data: .dataset
                case .finding: .finding
                case .limitation: .limitation
                case .gap: .evidenceGap
                }
                let evidenceNode = makeNode(
                    key: "evidence:\(evidence.id.uuidString)", kind: kind,
                    label: evidence.claim,
                    detail: evidence.quote ?? evidence.confidence,
                    sourceID: evidence.paperID ?? question.id,
                    provenance: evidence.source,
                    reviewStatus: reviewStatus
                )
                nodes.append(evidenceNode)
                let edgeKind: KnowledgeEdgeKind = switch evidence.kind {
                case .convergence: .supports
                case .tension: .contradicts
                case .gap: .leavesGap
                }
                edges.append(makeEdge(
                    key: "question-evidence:\(question.id.uuidString):\(evidence.id.uuidString)",
                    source: evidenceNode.id, target: questionNode.id, kind: edgeKind,
                    provenance: evidence.source,
                    reviewStatus: reviewStatus
                ))
                if let paperID = evidence.paperID, let paperNode = paperNodes[paperID] {
                    edges.append(makeEdge(
                        key: "paper-evidence:\(paperID.uuidString):\(evidence.id.uuidString)",
                        source: paperNode.id, target: evidenceNode.id, kind: .contains,
                        provenance: evidence.source,
                        reviewStatus: reviewStatus
                    ))
                }
            }
        }

        knowledgeGraph = KnowledgeGraph(nodes: nodes, edges: edges)
        if saveAfter {
            save()
            operationMessage = "知识图谱已从当前研究库更新"
        }
    }
}
