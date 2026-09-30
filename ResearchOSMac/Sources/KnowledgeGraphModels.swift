import Foundation
import SwiftUI

enum KnowledgeNodeKind: String, CaseIterable, Codable, Hashable, Sendable {
    case paper
    case researchQuestion
    case claim
    case method
    case dataset
    case finding
    case limitation
    case evidenceGap

    var title: String {
        switch self {
        case .paper: "论文"
        case .researchQuestion: "研究问题"
        case .claim: "证据主张"
        case .method: "方法"
        case .dataset: "数据"
        case .finding: "发现"
        case .limitation: "限制"
        case .evidenceGap: "证据空白"
        }
    }

    var symbol: String {
        switch self {
        case .paper: "doc.text"
        case .researchQuestion: "questionmark.bubble"
        case .claim: "quote.bubble"
        case .method: "hammer"
        case .dataset: "tablecells"
        case .finding: "lightbulb"
        case .limitation: "exclamationmark.triangle"
        case .evidenceGap: "circle.dotted"
        }
    }

    var color: Color {
        switch self {
        case .paper: .blue
        case .researchQuestion: .indigo
        case .claim: .green
        case .method: .purple
        case .dataset: .teal
        case .finding: .orange
        case .limitation: .red
        case .evidenceGap: .cyan
        }
    }
}

enum KnowledgeEdgeKind: String, Codable, Hashable, Sendable {
    case candidateFor
    case contains
    case reports
    case usesMethod
    case limitedBy
    case supports
    case contradicts
    case leavesGap

    var title: String {
        switch self {
        case .candidateFor: "可能相关"
        case .contains: "包含"
        case .reports: "报告"
        case .usesMethod: "使用方法"
        case .limitedBy: "受到限制"
        case .supports: "支持"
        case .contradicts: "存在分歧"
        case .leavesGap: "留下空白"
        }
    }
}

enum KnowledgeReviewStatus: String, Codable, Hashable, Sendable {
    case derived
    case aiSuggested
    case confirmed
    case rejected

    var title: String {
        switch self {
        case .derived: "自动整理"
        case .aiSuggested: "自动提取"
        case .confirmed: "已确认"
        case .rejected: "已拒绝"
        }
    }

    var color: Color {
        switch self {
        case .derived: .secondary
        case .aiSuggested: .orange
        case .confirmed: .green
        case .rejected: .red
        }
    }
}

struct KnowledgeNode: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var stableKey: String
    var kind: KnowledgeNodeKind
    var label: String
    var detail: String
    var sourceID: UUID?
    var provenance: String
    var reviewStatus: KnowledgeReviewStatus
}

struct KnowledgeEdge: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var stableKey: String
    var sourceNodeID: UUID
    var targetNodeID: UUID
    var kind: KnowledgeEdgeKind
    var provenance: String
    var reviewStatus: KnowledgeReviewStatus
}

struct KnowledgeGraph: Hashable, Codable, Sendable {
    var nodes: [KnowledgeNode]
    var edges: [KnowledgeEdge]

    static let empty = KnowledgeGraph(nodes: [], edges: [])
}
