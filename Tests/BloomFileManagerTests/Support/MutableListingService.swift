import Foundation
@testable import BloomFileManager

final class MutableListingService: DirectoryListingService, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FileItem]

    init(items: [FileItem]) {
        self.items = items
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let snapshot = lock.withLock { items }
        return AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func setItems(_ items: [FileItem]) {
        lock.withLock {
            self.items = items
        }
    }
}
