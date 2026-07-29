import Foundation

protocol SecurityScopedResourceAccessing: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct LiveSecurityScopedResourceAccessor: SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum CloudLocationScopedAccessError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        "The selected cloud folder is not currently accessible."
    }
}

final class CloudLocationScopedAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let driver: any SecurityScopedResourceAccessing
    private var isFinished = false

    init(root: URL, driver: any SecurityScopedResourceAccessing) {
        self.root = root
        self.driver = driver
    }

    func finish() {
        let shouldStop = lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
        if shouldStop {
            driver.stopAccessing(root)
        }
    }

    deinit {
        finish()
    }
}

final class CloudLocationScopedAccessCoordinator: @unchecked Sendable {
    private struct RegisteredRoot {
        let url: URL
        let standardizedPath: String
    }

    private let lock = NSLock()
    private let driver: any SecurityScopedResourceAccessing
    private var manualRoots: [RegisteredRoot] = []

    init(
        driver: any SecurityScopedResourceAccessing = LiveSecurityScopedResourceAccessor()
    ) {
        self.driver = driver
    }

    func replaceManualRoots(_ roots: [URL]) {
        var unique: [String: URL] = [:]
        for root in roots {
            unique[root.standardizedFileURL.path] = unique[root.standardizedFileURL.path] ?? root
        }
        lock.withLock {
            manualRoots = unique.map {
                RegisteredRoot(url: $0.value, standardizedPath: $0.key)
            }.sorted { $0.standardizedPath.count > $1.standardizedPath.count }
        }
    }

    func acquireAccess(for url: URL) throws -> CloudLocationScopedAccessLease? {
        try acquireAccess(for: [url]).first
    }

    func acquireAccess(for urls: [URL]) throws -> [CloudLocationScopedAccessLease] {
        let requestedURLs = urls.map(\.standardizedFileURL)
        let roots = lock.withLock { () -> [URL] in
            var unique: [String: URL] = [:]
            for requestedURL in requestedURLs {
                guard let root = manualRoots.first(where: {
                    Self.contains(requestedURL, rootPath: $0.standardizedPath)
                }) else { continue }
                unique[root.standardizedPath] = root.url
            }
            return unique.sorted { $0.key < $1.key }.map(\.value)
        }
        var leases: [CloudLocationScopedAccessLease] = []
        do {
            for root in roots {
                guard driver.startAccessing(root) else {
                    throw CloudLocationScopedAccessError.accessDenied
                }
                leases.append(CloudLocationScopedAccessLease(root: root, driver: driver))
            }
            return leases
        } catch {
            leases.forEach { $0.finish() }
            throw error
        }
    }

    func withAccess<T>(
        to url: URL,
        operation: () async throws -> T
    ) async throws -> T {
        let lease = try acquireAccess(for: url)
        defer { lease?.finish() }
        return try await operation()
    }

    private static func contains(_ url: URL, rootPath: String) -> Bool {
        let path = url.path
        guard rootPath != "/" else { return path.hasPrefix("/") }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
