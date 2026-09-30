import Foundation
import SQLite3

enum ZoteroReadError: LocalizedError {
    case libraryNotFound
    case snapshotFailed
    case database(String)

    var errorDescription: String? {
        switch self {
        case .libraryNotFound: "未找到本机 Zotero 数据库"
        case .snapshotFailed: "无法创建 Zotero 的只读快照"
        case .database(let message): "Zotero 数据库读取失败：\(message)"
        }
    }
}

enum ZoteroLibrary {
    private static var zoteroFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Zotero", isDirectory: true)
    }

    private static var databaseURL: URL { zoteroFolder.appendingPathComponent("zotero.sqlite") }

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    static func collections() throws -> [ZoteroCollection] {
        try withSnapshot { database in
            let sql = """
            SELECT c.collectionID, c.collectionName, c.parentCollectionID,
                   COUNT(DISTINCT ci.itemID)
            FROM collections c
            LEFT JOIN collectionItems ci ON ci.collectionID = c.collectionID
            GROUP BY c.collectionID, c.collectionName, c.parentCollectionID
            ORDER BY c.collectionName COLLATE NOCASE;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(database)
            }
            defer { sqlite3_finalize(statement) }
            var result: [ZoteroCollection] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let name = string(statement, 1)
                let parent = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2)
                let count = Int(sqlite3_column_int(statement, 3))
                result.append(ZoteroCollection(id: id, name: name, parentID: parent, itemCount: count))
            }
            return result
        }
    }

    static func papers(in collectionID: Int64) throws -> [Paper] {
        try withSnapshot { database in
            let sql = """
            SELECT i.itemID,
                   i.key,
                   it.typeName,
                   COALESCE((SELECT v.value FROM itemData d JOIN fields f ON f.fieldID=d.fieldID JOIN itemDataValues v ON v.valueID=d.valueID WHERE d.itemID=i.itemID AND f.fieldName='title' LIMIT 1), ''),
                   COALESCE((SELECT group_concat(name, ', ') FROM (SELECT trim(c.firstName || ' ' || c.lastName) AS name FROM itemCreators ic JOIN creators c ON c.creatorID=ic.creatorID WHERE ic.itemID=i.itemID ORDER BY ic.orderIndex)), ''),
                   COALESCE((SELECT v.value FROM itemData d JOIN fields f ON f.fieldID=d.fieldID JOIN itemDataValues v ON v.valueID=d.valueID WHERE d.itemID=i.itemID AND f.fieldName='date' LIMIT 1), ''),
                   COALESCE((SELECT v.value FROM itemData d JOIN fields f ON f.fieldID=d.fieldID JOIN itemDataValues v ON v.valueID=d.valueID WHERE d.itemID=i.itemID AND f.fieldName='publicationTitle' LIMIT 1), ''),
                   COALESCE((SELECT v.value FROM itemData d JOIN fields f ON f.fieldID=d.fieldID JOIN itemDataValues v ON v.valueID=d.valueID WHERE d.itemID=i.itemID AND f.fieldName='DOI' LIMIT 1), ''),
                   COALESCE((SELECT v.value FROM itemData d JOIN fields f ON f.fieldID=d.fieldID JOIN itemDataValues v ON v.valueID=d.valueID WHERE d.itemID=i.itemID AND f.fieldName='abstractNote' LIMIT 1), ''),
                   COALESCE((SELECT ai.key FROM itemAttachments ia JOIN items ai ON ai.itemID=ia.itemID WHERE ia.parentItemID=i.itemID AND ia.contentType='application/pdf' LIMIT 1), ''),
                   COALESCE((SELECT ia.path FROM itemAttachments ia WHERE ia.parentItemID=i.itemID AND ia.contentType='application/pdf' LIMIT 1), ''),
                   i.dateAdded
            FROM collectionItems ci
            JOIN items i ON i.itemID=ci.itemID
            JOIN itemTypes it ON it.itemTypeID=i.itemTypeID
            WHERE ci.collectionID = ?
              AND it.typeName NOT IN ('attachment', 'note', 'annotation')
              AND i.itemID NOT IN (SELECT itemID FROM deletedItems)
            ORDER BY i.dateAdded DESC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(database)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, collectionID)

            var result: [Paper] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let key = string(statement, 1)
                let title = string(statement, 3)
                guard !title.isEmpty else { continue }
                let authors = string(statement, 4)
                let date = string(statement, 5)
                let venue = string(statement, 6)
                let doi = string(statement, 7)
                let abstractText = string(statement, 8)
                let attachmentKey = string(statement, 9)
                let attachmentValue = string(statement, 10)
                let attachmentPath = resolveAttachment(key: attachmentKey, value: attachmentValue)

                result.append(Paper(
                    id: UUID(), title: title,
                    authors: authors.isEmpty ? "作者待确认" : authors,
                    year: year(from: date), venue: venue.isEmpty ? "来源待确认" : venue,
                    status: .unread,
                    researchQuestion: "待整理",
                    method: "待整理",
                    finding: "待整理",
                    limitation: "待整理",
                    importedName: attachmentPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                    abstractText: abstractText,
                    source: .zotero,
                    analysisState: attachmentPath == nil ? .missingPDF : .needsReview,
                    doi: doi.isEmpty ? nil : doi,
                    attachmentPath: attachmentPath,
                    zoteroKey: key,
                    pageCount: 0,
                    extractedCharacterCount: 0,
                    analysisInput: abstractText
                ))
            }
            return result
        }
    }

    private static func withSnapshot<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard isAvailable else { throw ZoteroReadError.libraryNotFound }
        let snapshotFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchOS-Zotero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshotFolder) }

        for name in ["zotero.sqlite", "zotero.sqlite-wal", "zotero.sqlite-shm"] {
            let source = zoteroFolder.appendingPathComponent(name)
            let destination = snapshotFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }

        var database: OpaquePointer?
        let snapshotDB = snapshotFolder.appendingPathComponent("zotero.sqlite")
        guard sqlite3_open_v2(snapshotDB.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw ZoteroReadError.snapshotFailed }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private static func databaseError(_ database: OpaquePointer?) -> ZoteroReadError {
        ZoteroReadError.database(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "未知错误")
    }

    private static func resolveAttachment(key: String, value: String) -> String? {
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("storage:") {
            let filename = String(value.dropFirst("storage:".count))
            let url = zoteroFolder.appendingPathComponent("storage/\(key)/\(filename)")
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
        if value.hasPrefix("/") && FileManager.default.fileExists(atPath: value) { return value }
        return nil
    }

    private static func year(from value: String) -> Int {
        let pattern = #"\b(19|20)\d{2}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value),
              let year = Int(value[range]) else {
            return Calendar.current.component(.year, from: Date())
        }
        return year
    }
}
