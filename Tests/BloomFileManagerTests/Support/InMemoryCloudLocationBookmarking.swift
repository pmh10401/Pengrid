import Foundation
@testable import BloomFileManager

final class InMemoryCloudLocationBookmarking: CloudLocationBookmarking, @unchecked Sendable {
    private struct Payload: Codable {
        let path: String
        let generation: Int
    }

    private let lock = NSLock()
    private var stalePaths: Set<String>
    private var resolvedPaths: [String: String]
    private var generation = 0
    private var createdPaths: [String] = []

    init(
        stalePaths: Set<String> = [],
        resolvedPaths: [String: String] = [:]
    ) {
        self.stalePaths = stalePaths
        self.resolvedPaths = resolvedPaths
    }

    var bookmarkCreationBasenames: [String] {
        lock.withLock { createdPaths.map { URL(filePath: $0).lastPathComponent } }
    }

    func setStalePaths(_ paths: Set<String>) {
        lock.withLock { stalePaths = paths }
    }

    func setResolvedPaths(_ paths: [String: String]) {
        lock.withLock { resolvedPaths = paths }
    }

    func create(for url: URL) throws -> Data {
        let path = url.standardizedFileURL.path
        let payload = lock.withLock {
            generation += 1
            createdPaths.append(path)
            return Payload(path: path, generation: generation)
        }
        return try JSONEncoder().encode(payload)
    }

    func resolve(_ data: Data) throws -> ResolvedCloudLocationBookmark {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return lock.withLock {
            let resolvedPath = resolvedPaths[payload.path] ?? payload.path
            return ResolvedCloudLocationBookmark(
                url: URL(filePath: resolvedPath, directoryHint: .isDirectory).standardizedFileURL,
                isStale: stalePaths.contains(payload.path)
            )
        }
    }
}
