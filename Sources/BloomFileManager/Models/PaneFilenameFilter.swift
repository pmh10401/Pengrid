import Foundation

struct PaneFilenameFilter: Equatable, Sendable {
    let query: String

    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apply(to items: [FileItem]) -> [FileItem] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(normalizedQuery) }
    }
}
