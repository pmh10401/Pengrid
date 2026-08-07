import Foundation

struct LiveDirectoryListingService: DirectoryListingService {
    let batchSize: Int
    private let visibility: DirectoryVisibilityPolicy
    private let batchBuilder: DirectoryEntryBatchBuilder
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let cursorFactory: any ImmediateDirectoryEntryCursorFactory

    init(
        batchSize: Int = 256,
        visibility: DirectoryVisibilityPolicy = .baseline,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        metadataReader: any DirectoryEntryMetadataReading = LiveDirectoryEntryMetadataReader(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        cursorFactory: any ImmediateDirectoryEntryCursorFactory = LiveImmediateDirectoryEntryCursorFactory()
    ) {
        precondition(batchSize > 0, "batchSize must be greater than zero")
        self.batchSize = batchSize
        self.visibility = visibility
        self.batchBuilder = DirectoryEntryBatchBuilder(
            metadataReader: metadataReader,
            availabilityReader: availabilityReader
        )
        self.accessCoordinator = accessCoordinator
        self.cursorFactory = cursorFactory
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let producer = DirectoryListingBatchProducer(
            directory: directory,
            batchSize: batchSize,
            visibility: visibility,
            batchBuilder: batchBuilder,
            accessCoordinator: accessCoordinator,
            cursorFactory: cursorFactory
        )
        return AsyncThrowingStream(unfolding: { try await producer.nextBatch() })
    }
}

private actor DirectoryListingBatchProducer {
    private let directory: URL
    private let batchSize: Int
    private let visibility: DirectoryVisibilityPolicy
    private let batchBuilder: DirectoryEntryBatchBuilder
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let cursorFactory: any ImmediateDirectoryEntryCursorFactory
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .localizedTypeDescriptionKey
    ]
    private var accessLease: CloudLocationScopedAccessLease?
    private var cursor: (any ImmediateDirectoryEntryCursor)?

    init(
        directory: URL,
        batchSize: Int,
        visibility: DirectoryVisibilityPolicy,
        batchBuilder: DirectoryEntryBatchBuilder,
        accessCoordinator: CloudLocationScopedAccessCoordinator,
        cursorFactory: any ImmediateDirectoryEntryCursorFactory
    ) {
        self.directory = directory
        self.batchSize = batchSize
        self.visibility = visibility
        self.batchBuilder = batchBuilder
        self.accessCoordinator = accessCoordinator
        self.cursorFactory = cursorFactory
    }

    func nextBatch() async throws -> [FileItem]? {
        if accessLease == nil {
            accessLease = try accessCoordinator.acquireAccess(for: directory)
        }
        do {
            try Task.checkCancellation()
            let batch = try await produceNextBatch()
            if batch == nil {
                finishAccess()
            }
            return batch
        } catch {
            finishAccess()
            throw error
        }
    }

    private func produceNextBatch() async throws -> [FileItem]? {
        let cursor = try cursorForListing()
        var urls: [URL] = []
        urls.reserveCapacity(batchSize)
        while urls.count < batchSize {
            try Task.checkCancellation()
            guard let url = try cursor.next() else { break }
            urls.append(url)
        }
        guard !urls.isEmpty else { return nil }

        let batch = try await batchBuilder.build(urls: urls)
        try Task.checkCancellation()
        return batch
    }

    private func cursorForListing() throws -> any ImmediateDirectoryEntryCursor {
        if let cursor { return cursor }
        let cursor = try cursorFactory.makeCursor(
            in: directory,
            includingPropertiesForKeys: keys,
            options: visibility.fileManagerOptions
        )
        self.cursor = cursor
        return cursor
    }

    private func finishAccess() {
        accessLease?.finish()
        accessLease = nil
    }
}
