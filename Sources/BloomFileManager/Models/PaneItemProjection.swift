import Foundation

struct ActiveOrderSnapshot: Equatable, Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let orderedItems: [FileItem]
    let asciiLiteralSafePositions: [Int]
    let localizedFallbackPositions: [Int]
}

struct AcceptedSearchSnapshot: Equatable, Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let normalizedQuery: String
    let matchedASCIIPositions: [Int]
    let matchedLocalizedPositions: [Int]
}

struct PaneProjectionKey: Equatable, Sendable {
    let itemsRevision: UInt64
    let normalizedQuery: String
    let sort: FileSort

    init(itemsRevision: UInt64, normalizedQuery: String, sort: FileSort) {
        self.itemsRevision = itemsRevision
        self.normalizedQuery = PaneFilenameFilter.normalize(normalizedQuery)
        self.sort = sort
    }
}

struct PaneItemProjection: Equatable, Sendable {
    let key: PaneProjectionKey
    let items: [FileItem]
    let indexByURL: [URL: Int]
    let urlByEntryPath: [String: URL]
}

enum PaneEntryPath {
    static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

struct PaneItemProjector: Sendable {
    func buildActiveOrder(
        items: [FileItem],
        directoryKey: String,
        key: PaneProjectionKey
    ) -> ActiveOrderSnapshot? {
        guard Self.hasUniqueFinalTieBreakIdentities(in: items) else { return nil }

        let orderedItems = key.sort.apply(to: items)
        var asciiLiteralSafePositions: [Int] = []
        var localizedFallbackPositions: [Int] = []
        for (index, item) in orderedItems.enumerated() {
            if PaneFilenameFilter.isPrintableASCII(item.name) {
                asciiLiteralSafePositions.append(index)
            } else {
                localizedFallbackPositions.append(index)
            }
        }
        return .init(
            directoryKey: directoryKey,
            itemsRevision: key.itemsRevision,
            sort: key.sort,
            orderedItems: orderedItems,
            asciiLiteralSafePositions: asciiLiteralSafePositions,
            localizedFallbackPositions: localizedFallbackPositions
        )
    }

    static func hasUniqueFinalTieBreakIdentities(in items: [FileItem]) -> Bool {
        Set(items.map { $0.url.standardizedFileURL }).count == items.count
            && Set(items.map { PaneEntryPath.normalize($0.url) }).count == items.count
    }

    func project(items: [FileItem], key: PaneProjectionKey) -> PaneItemProjection {
        let filtered = PaneFilenameFilter(query: key.normalizedQuery).apply(to: items)
        let projected = key.sort.apply(to: filtered)
        var indexByURL: [URL: Int] = [:]
        var urlByEntryPath: [String: URL] = [:]
        for (index, item) in projected.enumerated() {
            let url = item.url.standardizedFileURL
            indexByURL[url] = index
            urlByEntryPath[PaneEntryPath.normalize(url)] = url
        }
        return .init(
            key: key,
            items: projected,
            indexByURL: indexByURL,
            urlByEntryPath: urlByEntryPath
        )
    }
}
