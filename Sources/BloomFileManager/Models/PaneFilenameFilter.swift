import Foundation

struct PaneFilenameFilter: Equatable, Sendable {
    let query: String

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apply(to items: [FileItem]) -> [FileItem] {
        guard !trimmedQuery.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(trimmedQuery) }
    }
}
