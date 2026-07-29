import Foundation
@testable import BloomFileManager

actor InMemoryComparisonListingService: ComparisonListingService {
    var batchesByRoot: [URL: [ComparisonListingBatch]]
    private(set) var requests: [ComparisonListingRequest] = []

    init(_ batchesByRoot: [URL: [ComparisonListingBatch]]) {
        self.batchesByRoot = batchesByRoot
    }

    func identity(of root: URL) -> FileIdentity {
        let token = "memory:\(root.standardizedFileURL.path)"
        return FileIdentity(entryIdentifier: token, resolvedIdentifier: token)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(request)
                for batch in await batchesByRoot[request.root, default: []] {
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }
    }

    private func record(_ request: ComparisonListingRequest) {
        requests.append(request)
    }
}
