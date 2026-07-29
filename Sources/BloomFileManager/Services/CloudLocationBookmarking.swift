import Foundation

struct ResolvedCloudLocationBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol CloudLocationBookmarking: Sendable {
    func create(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedCloudLocationBookmark
}

struct LiveCloudLocationBookmarking: CloudLocationBookmarking {
    func create(for url: URL) throws -> Data {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(_ data: Data) throws -> ResolvedCloudLocationBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedCloudLocationBookmark(url: url, isStale: isStale)
    }
}
