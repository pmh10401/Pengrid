import Foundation

struct ResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol FavoriteBookmarking: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedBookmark
}

struct LiveFavoriteBookmarking: FavoriteBookmarking {
    func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedBookmark(url: url, isStale: isStale)
    }
}
