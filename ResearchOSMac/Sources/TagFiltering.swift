import Foundation

enum TagFiltering {
    static func parse(_ query: String) -> (tag: String?, text: String) {
        let parts = query.split(separator: " ")
        guard let token = parts.first(where: { $0.lowercased().hasPrefix("tag:") }) else { return (nil, query) }
        let tag = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = parts.filter { !$0.lowercased().hasPrefix("tag:") }.joined(separator: " ")
        return (tag.isEmpty ? nil : tag, text)
    }

    static func matches(tags: [String], tag: String?) -> Bool {
        guard let tag else { return true }
        return tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
    }
}
