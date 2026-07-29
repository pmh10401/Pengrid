import Foundation
@testable import BloomFileManager

final class InMemoryFavoriteBookmarking: FavoriteBookmarking, @unchecked Sendable {
    private struct Payload: Codable {
        let path: String
        let generation: Int
    }

    private let lock = NSLock()
    private var unavailablePaths: Set<String>
    private var stalePaths: Set<String>
    private var resolvedPaths: [String: String]
    private var bookmarkCreationFailurePaths: Set<String> = []
    private var generation = 0
    private var createdPaths: [String] = []

    init(
        unavailablePaths: Set<String> = [],
        stalePaths: Set<String> = [],
        resolvedPaths: [String: String] = [:]
    ) {
        self.unavailablePaths = unavailablePaths
        self.stalePaths = stalePaths
        self.resolvedPaths = resolvedPaths
    }

    var bookmarkCreationPaths: [String] {
        lock.withLock { createdPaths }
    }

    func setStalePaths(_ paths: Set<String>) {
        lock.withLock { stalePaths = paths }
    }

    func setBookmarkCreationFailurePaths(_ paths: Set<String>) {
        lock.withLock { bookmarkCreationFailurePaths = paths }
    }

    func createBookmark(for url: URL) throws -> Data {
        let path = url.standardizedFileURL.path
        let payload = try lock.withLock { () throws -> Payload in
            guard !bookmarkCreationFailurePaths.contains(path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            generation += 1
            createdPaths.append(path)
            return Payload(path: path, generation: generation)
        }
        return try JSONEncoder().encode(payload)
    }

    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return try lock.withLock {
            guard !unavailablePaths.contains(payload.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let resolvedPath = resolvedPaths[payload.path] ?? payload.path
            return ResolvedBookmark(
                url: URL(filePath: resolvedPath).standardizedFileURL,
                isStale: stalePaths.contains(payload.path)
            )
        }
    }
}
