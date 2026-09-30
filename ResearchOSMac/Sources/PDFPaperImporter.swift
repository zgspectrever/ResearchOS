import AppKit
import Foundation
import PDFKit

struct ParsedPDF: Sendable {
    let title: String
    let authors: String
    let year: Int
    let venue: String
    let doi: String?
    let pageCount: Int
    let text: String
    let abstractText: String
}

struct PaperSectionExtraction: Sendable {
    let researchQuestion: String
    let method: String
    let finding: String
    let limitation: String
}

enum PDFImportError: LocalizedError {
    case unreadable
    case noText
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法打开这份文献"
        case .noText: "文献中没有可提取的文字，PDF 可能需要 OCR"
        case .unsupported: "暂不支持这种文档格式"
        }
    }
}

enum PDFPaperImporter {
    static let supportedExtensions: Set<String> = ["pdf", "doc", "docx", "rtf", "rtfd"]

    static func importLocalPDF(from sourceURL: URL) throws -> Paper {
        try importLocalDocument(from: sourceURL)
    }

    static func importLocalDocument(from sourceURL: URL) throws -> Paper {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let parsed = try parse(url: sourceURL)
        let destination = try copyIntoLibrary(sourceURL)
        let sections = heuristicSections(from: parsed.text, abstractText: parsed.abstractText)
        let isPDF = sourceURL.pathExtension.lowercased() == "pdf"
        return Paper(
            id: UUID(),
            title: parsed.title,
            authors: parsed.authors,
            year: parsed.year,
            venue: parsed.venue,
            status: .unread,
            researchQuestion: sections.researchQuestion,
            method: sections.method,
            finding: sections.finding,
            limitation: sections.limitation,
            importedName: sourceURL.lastPathComponent,
            abstractText: parsed.abstractText,
            source: isPDF ? .localPDF : .localDocument,
            analysisState: parsed.text.isEmpty ? .needsReview : .extracted,
            doi: parsed.doi,
            attachmentPath: destination.path,
            pageCount: parsed.pageCount,
            extractedCharacterCount: parsed.text.count,
            analysisInput: String(parsed.text.prefix(18_000))
        )
    }

    static func parse(url: URL) throws -> ParsedPDF {
        switch url.pathExtension.lowercased() {
        case "pdf": return try parsePDF(url: url)
        case "doc", "docx", "rtf", "rtfd": return try parseWordDocument(url: url)
        default: throw PDFImportError.unsupported
        }
    }

    private static func parsePDF(url: URL) throws -> ParsedPDF {
        guard let document = PDFDocument(url: url) else { throw PDFImportError.unreadable }
        let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let attributes = document.documentAttributes ?? [:]
        let metadataTitle = attributes[PDFDocumentAttribute.titleAttribute] as? String
        let metadataAuthor = attributes[PDFDocumentAttribute.authorAttribute] as? String
        let title = cleanTitle(metadataTitle) ?? inferredTitle(from: text, fallback: url.deletingPathExtension().lastPathComponent)
        let authors = cleanAuthor(metadataAuthor) ?? inferredAuthors(from: text)
        let metadataDate = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
        let year = text.isEmpty
            ? metadataDate.map { Calendar.current.component(.year, from: $0) } ?? Calendar.current.component(.year, from: Date())
            : inferredYear(from: text)
        let doi = firstMatch(in: String(text.prefix(12_000)), pattern: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#)
        let abstractText = extractAbstract(from: text)
        let venue = inferredVenue(from: text)

        return ParsedPDF(
            title: title, authors: authors, year: year, venue: venue, doi: doi,
            pageCount: document.pageCount, text: text, abstractText: abstractText
        )
    }

    private static func parseWordDocument(url: URL) throws -> ParsedPDF {
        let ext = url.pathExtension.lowercased()
        let documentType: NSAttributedString.DocumentType
        switch ext {
        case "docx": documentType = .officeOpenXML
        case "rtf": documentType = .rtf
        case "rtfd": documentType = .rtfd
        default: documentType = .docFormat
        }
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: documentType],
            documentAttributes: nil
        )
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PDFImportError.noText }
        return ParsedPDF(
            title: inferredTitle(from: text, fallback: url.deletingPathExtension().lastPathComponent),
            authors: inferredAuthors(from: text),
            year: inferredYear(from: text),
            venue: inferredVenue(from: text),
            doi: firstMatch(in: String(text.prefix(12_000)), pattern: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#),
            pageCount: 0,
            text: text,
            abstractText: extractAbstract(from: text)
        )
    }

    static func heuristicSections(from text: String, abstractText: String) -> PaperSectionExtraction {
        let abstract = abstractText.isEmpty ? section(in: text, headings: ["abstract"], fallback: "未识别到摘要段落") : abstractText
        let question = abstract.prefixText(900)
        let method = section(
            in: text,
            headings: ["methods", "method", "methodology", "data and methods", "model formulation", "research design"],
            fallback: "未在可提取文本中识别出明确的方法段落"
        )
        let finding = section(
            in: text,
            headings: ["results", "findings", "conclusion", "conclusions", "discussion and conclusions"],
            fallback: "未在可提取文本中识别出明确的结果或结论段落"
        )
        let limitation = section(
            in: text,
            headings: ["limitations", "limitation", "limitations and future work", "discussion"],
            fallback: "未在可提取文本中识别出明确的限制段落"
        )
        return PaperSectionExtraction(researchQuestion: question, method: method, finding: finding, limitation: limitation)
    }

    private static func copyIntoLibrary(_ sourceURL: URL) throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PDFImportError.unreadable
        }
        let folder = base.appendingPathComponent("ResearchOS/Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "pdf" : sourceURL.pathExtension.lowercased()
        let destination = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private static func cleanTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 8,
              !["untitled", "document", "microsoft word"].contains(where: clean.lowercased().contains) else { return nil }
        return clean
    }

    private static func cleanAuthor(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count >= 3 ? clean : nil
    }

    private static func inferredTitle(from text: String, fallback: String) -> String {
        let lines = text.prefix(5_000).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var candidates: [String] = []
        for index in lines.indices.prefix(24) {
            candidates.append(lines[index])
            if index + 1 < lines.count { candidates.append(lines[index] + " " + lines[index + 1]) }
            if index + 2 < lines.count { candidates.append(lines[index] + " " + lines[index + 1] + " " + lines[index + 2]) }
        }
        return candidates
            .filter(isPlausibleTitle)
            .max { titleScore($0) < titleScore($1) } ?? fallback
    }

    private static func inferredAuthors(from text: String) -> String {
        let lines = text.prefix(4_000).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return "待确认" }
        for line in lines.prefix(18) {
            let lower = line.lowercased()
            let excluded = ["university", "department", "institute", "college", "abstract", "keyword", "doi", "http", "journal", "received", "accepted", "copyright"]
            let hasNameSeparator = line.contains(",") || lower.contains(" and ") || line.contains("·")
            if line.count >= 5, line.count < 220, hasNameSeparator,
               !excluded.contains(where: lower.contains),
               line.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) == nil {
                return line
            }
        }
        return "作者待确认"
    }

    private static func inferredYear(from text: String) -> Int {
        let prefix = String(text.prefix(8_000))
        if let value = firstMatch(in: prefix, pattern: #"\b(19|20)\d{2}\b"#), let year = Int(value) { return year }
        return Calendar.current.component(.year, from: Date())
    }

    private static func inferredVenue(from text: String) -> String {
        let lines = text.prefix(6_000).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count < 180 }
        let venueWords = ["journal", "proceedings", "transactions", "review", "letters", "conference", "symposium"]
        if let venue = lines.prefix(28).first(where: { line in
            let lower = line.lowercased()
            return venueWords.contains(where: lower.contains) &&
                !lower.contains("copyright") && !lower.contains("downloaded")
        }) {
            return venue
        }
        return "来源待确认"
    }

    private static func isPlausibleTitle(_ candidate: String) -> Bool {
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 18, clean.count <= 260 else { return false }
        let lower = clean.lowercased()
        let rejected = ["abstract", "keywords", "doi:", "http://", "https://", "downloaded", "copyright", "received:", "accepted:", "available online"]
        guard !rejected.contains(where: lower.hasPrefix) else { return false }
        let words = clean.split(whereSeparator: \Character.isWhitespace)
        guard words.count >= 4, words.count <= 36 else { return false }
        let letters = clean.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters * 2 >= clean.unicodeScalars.count
    }

    private static func titleScore(_ candidate: String) -> Int {
        let lower = candidate.lowercased()
        let words = candidate.split(whereSeparator: \Character.isWhitespace).count
        var score = min(candidate.count, 150) + min(words, 18) * 5
        if candidate.count >= 35 && candidate.count <= 190 { score += 35 }
        if candidate.hasSuffix(".") { score -= 15 }
        if lower.contains("journal of") || lower.contains("vol.") || lower.contains("volume ") { score -= 45 }
        if candidate.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil { score -= 30 }
        if candidate.contains(",") && words < 12 { score -= 25 }
        return score
    }

    private static func extractAbstract(from text: String) -> String {
        let prefix = String(text.prefix(30_000))
        guard let abstractRange = prefix.range(of: #"(?i)\babstract\b\s*[:—-]?"#, options: .regularExpression) else { return "" }
        let remainder = String(prefix[abstractRange.upperBound...])
        let stopPatterns = [#"(?i)\bkeywords?\b\s*[:—-]?"#, #"(?i)\b1\.?\s+introduction\b"#, #"(?i)\bintroduction\b"#]
        var end = remainder.endIndex
        for pattern in stopPatterns {
            if let range = remainder.range(of: pattern, options: .regularExpression), range.lowerBound < end { end = range.lowerBound }
        }
        return String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines).prefixText(2_500)
    }

    private static func section(in text: String, headings: [String], fallback: String) -> String {
        let searchable = String(text.prefix(100_000))
        for heading in headings {
            let escaped = NSRegularExpression.escapedPattern(for: heading)
            let pattern = "(?im)^\\s*(?:[0-9]+(?:\\.[0-9]+)*[.)]?\\s+)?\(escaped)\\s*[:—-]?\\s*$"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: searchable, range: NSRange(searchable.startIndex..., in: searchable)),
                  let range = Range(match.range, in: searchable) else { continue }
            let tail = searchable[range.upperBound...]
            let excerpt = String(tail.prefix(1_600))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if excerpt.count > 40 { return excerpt }
        }
        return fallback
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
    }
}

private extension String {
    func prefixText(_ length: Int) -> String { String(prefix(length)) }
}
