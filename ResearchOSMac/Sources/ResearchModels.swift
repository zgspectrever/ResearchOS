import Foundation
import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case questions
    case writing
    case knowledgeGraph
    case inbox
    case library
    case zotero

    var id: String { rawValue }
    var title: String {
        switch self {
        case .questions: "研究项目"
        case .writing: "写作"
        case .knowledgeGraph: "知识图谱"
        case .inbox: "处理队列"
        case .library: "论文库"
        case .zotero: "Zotero"
        }
    }
    var symbol: String {
        switch self {
        case .questions: "questionmark.bubble"
        case .writing: "doc.richtext"
        case .knowledgeGraph: "point.3.connected.trianglepath.dotted"
        case .inbox: "tray"
        case .library: "books.vertical"
        case .zotero: "externaldrive.connected.to.line.below"
        }
    }
}

enum WritingDocumentKind: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case note
    case paper

    var id: String { rawValue }
    var title: String { self == .note ? "笔记" : "论文" }
    var symbol: String { self == .note ? "note.text" : "doc.text" }
}

enum WritingDocumentFormat: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case markdown
    case latex
    case word

    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .latex: "LaTeX"
        case .word: "Word"
        }
    }
    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .latex: "tex"
        case .word: "docx"
        }
    }
    var symbol: String {
        switch self {
        case .markdown: "text.document"
        case .latex: "function"
        case .word: "doc.richtext"
        }
    }
}

struct MarkdownDocument: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var modifiedAt: Date
    var kind: WritingDocumentKind? = nil
    var format: WritingDocumentFormat? = nil
    var richTextData: Data? = nil
    var importedName: String? = nil
    var folderID: UUID? = nil
    var sourceBookmark: Data? = nil
    var importedRelativePath: String? = nil
    var sourceModifiedAt: Date? = nil
    var sourceFileSize: Int64? = nil
    var lastSyncedAt: Date? = nil
    var tags: [String] = []

    var resolvedKind: WritingDocumentKind { kind ?? .note }
    var resolvedFormat: WritingDocumentFormat { format ?? .markdown }
}

struct WritingDocumentVersion: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let documentID: UUID
    let title: String
    let content: String
    let richTextData: Data?
    let createdAt: Date
}

struct WritingSyncConflict: Identifiable, Hashable, Sendable {
    let id: UUID
    let documentID: UUID
    let title: String
    let detectedAt: Date
}

struct WritingFolder: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var sourceBookmark: Data? = nil
    var lastSyncedAt: Date? = nil
}

enum QuestionStatus: String, Hashable, Codable, Sendable {
    case active
    case exploring
    case stable

    var title: String {
        switch self {
        case .active: "正在推进"
        case .exploring: "探索中"
        case .stable: "已有结论"
        }
    }
    var color: Color {
        switch self {
        case .active: .blue
        case .exploring: .orange
        case .stable: .green
        }
    }
}

struct ResearchQuestion: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var shortTitle: String
    var question: String
    var status: QuestionStatus
    var paperCount: Int
    var openGapCount: Int
    var workingAnswer: String
    var nextMove: String
    var evidence: [EvidenceItem]
    var linkedPaperIDs: [UUID]? = nil

    var resolvedLinkedPaperIDs: [UUID] { linkedPaperIDs ?? [] }
}

enum EvidenceKind: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case convergence
    case tension
    case gap

    var id: String { rawValue }
    var title: String {
        switch self {
        case .convergence: "形成共识"
        case .tension: "仍有分歧"
        case .gap: "证据空白"
        }
    }
    var symbol: String {
        switch self {
        case .convergence: "checkmark.seal"
        case .tension: "arrow.left.arrow.right"
        case .gap: "circle.dotted"
        }
    }
    var color: Color {
        switch self {
        case .convergence: .green
        case .tension: .orange
        case .gap: .blue
        }
    }
}

enum EvidenceRole: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case claim
    case method
    case data
    case finding
    case limitation
    case gap

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claim: "核心主张"
        case .method: "方法"
        case .data: "数据"
        case .finding: "研究结果"
        case .limitation: "限制"
        case .gap: "研究空白"
        }
    }
    var symbol: String {
        switch self {
        case .claim: "quote.bubble"
        case .method: "hammer"
        case .data: "tablecells"
        case .finding: "lightbulb"
        case .limitation: "exclamationmark.triangle"
        case .gap: "circle.dotted"
        }
    }
}

enum EvidenceReviewStatus: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case aiSuggested = "ai_suggested"
    case userConfirmed = "user_confirmed"
    case userRejected = "user_rejected"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .aiSuggested: "待审核提取"
        case .userConfirmed: "已确认"
        case .userRejected: "已拒绝"
        }
    }
    var symbol: String {
        switch self {
        case .aiSuggested: "doc.text.magnifyingglass"
        case .userConfirmed: "checkmark.seal.fill"
        case .userRejected: "xmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .aiSuggested: .orange
        case .userConfirmed: .green
        case .userRejected: .secondary
        }
    }
}

struct EvidenceItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: EvidenceKind
    var claim: String
    var source: String
    var confidence: String
    var paperID: UUID? = nil
    var quote: String? = nil
    var locator: String? = nil
    var role: EvidenceRole? = nil
    var createdAt: Date? = nil
    var reviewStatus: EvidenceReviewStatus? = nil

    var resolvedRole: EvidenceRole { role ?? (kind == .gap ? .gap : .claim) }
    var resolvedReviewStatus: EvidenceReviewStatus { reviewStatus ?? .userConfirmed }
}

enum ReadingStatus: String, Hashable, Codable, Sendable {
    case unread
    case reading
    case processed

    var title: String {
        switch self {
        case .unread: "待处理"
        case .reading: "阅读中"
        case .processed: "已整理"
        }
    }
    var symbol: String {
        switch self {
        case .unread: "circle"
        case .reading: "circle.lefthalf.filled"
        case .processed: "checkmark.circle.fill"
        }
    }
}

enum PaperSource: String, Codable, Hashable, Sendable {
    case localPDF
    case localDocument
    case zotero
    case demo

    var title: String {
        switch self {
        case .localPDF: "本地 PDF"
        case .localDocument: "本地文档"
        case .zotero: "Zotero"
        case .demo: "示例"
        }
    }
}

enum PaperAnalysisState: String, Codable, Hashable, Sendable {
    case extracted
    case needsReview
    case analyzed
    case missingPDF

    var title: String {
        switch self {
        case .extracted: "已规则整理"
        case .needsReview: "待提取全文"
        case .analyzed: "待确认"
        case .missingPDF: "未找到 PDF"
        }
    }
}

struct Paper: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var authors: String
    var year: Int
    var venue: String
    var status: ReadingStatus
    var researchQuestion: String
    var method: String
    var finding: String
    var limitation: String
    var importedName: String?
    var abstractText: String = ""
    var source: PaperSource = .localPDF
    var analysisState: PaperAnalysisState = .needsReview
    var doi: String? = nil
    var attachmentPath: String? = nil
    var zoteroKey: String? = nil
    var pageCount: Int = 0
    var extractedCharacterCount: Int = 0
    var analysisInput: String = ""
    var dateAdded: Date = Date()
    var tags: [String] = []
}

struct ZoteroCollection: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let parentID: Int64?
    let itemCount: Int
}
