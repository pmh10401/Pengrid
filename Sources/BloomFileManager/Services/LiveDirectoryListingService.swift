import Foundation

struct LiveDirectoryListingService: DirectoryListingService {
    let batchSize: Int
    private let visibility: DirectoryVisibilityPolicy
    private let availabilityReader: any CloudItemAvailabilityReading
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let cursorFactory: any ImmediateDirectoryEntryCursorFactory

    init(
        batchSize: Int = 256,
        visibility: DirectoryVisibilityPolicy = .baseline,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        cursorFactory: any ImmediateDirectoryEntryCursorFactory = LiveImmediateDirectoryEntryCursorFactory()
    ) {
        precondition(batchSize > 0, "batchSize must be greater than zero")
        self.batchSize = batchSize
        self.visibility = visibility
        self.availabilityReader = availabilityReader
        self.accessCoordinator = accessCoordinator
        self.cursorFactory = cursorFactory
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let producer = DirectoryListingBatchProducer(
            directory: directory,
            batchSize: batchSize,
            visibility: visibility,
            availabilityReader: availabilityReader,
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
    private let availabilityReader: any CloudItemAvailabilityReading
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let cursorFactory: any ImmediateDirectoryEntryCursorFactory
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .contentModificationDateKey,
        .fileSizeKey
    ]
    private var accessLease: CloudLocationScopedAccessLease?
    private var cursor: (any ImmediateDirectoryEntryCursor)?

    init(
        directory: URL,
        batchSize: Int,
        visibility: DirectoryVisibilityPolicy,
        availabilityReader: any CloudItemAvailabilityReading,
        accessCoordinator: CloudLocationScopedAccessCoordinator,
        cursorFactory: any ImmediateDirectoryEntryCursorFactory
    ) {
        self.directory = directory
        self.batchSize = batchSize
        self.visibility = visibility
        self.availabilityReader = availabilityReader
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

        var batch: [FileItem] = []
        batch.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            let typeDescription = try? url.resourceValues(
                forKeys: [.localizedTypeDescriptionKey]
            ).localizedTypeDescription
            let standardizedURL = url.standardizedFileURL
            let availability = await availabilityReader.availability(of: standardizedURL)
            batch.append(FileItem(
                url: standardizedURL,
                name: url.lastPathComponent,
                isDirectory: values.isDirectory == true,
                isPackage: values.isPackage == true,
                modifiedAt: values.contentModificationDate,
                byteSize: values.isDirectory == true ? nil : values.fileSize.map(Int64.init),
                typeDescription: typeDescription ?? "File",
                availability: availability
            ))
        }
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
