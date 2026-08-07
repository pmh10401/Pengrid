import Foundation

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
