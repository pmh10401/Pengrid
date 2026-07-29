import Foundation

struct LiveDirectoryListingService: DirectoryListingService {
    let batchSize: Int
    private let availabilityReader: any CloudItemAvailabilityReading
    private let accessCoordinator: CloudLocationScopedAccessCoordinator

    init(
        batchSize: Int = 256,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.batchSize = batchSize
        self.availabilityReader = availabilityReader
        self.accessCoordinator = accessCoordinator
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let lease = try accessCoordinator.acquireAccess(for: directory)
                    defer { lease?.finish() }
                    let keys: Set<URLResourceKey> = [
                        .isDirectoryKey,
                        .isPackageKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .localizedTypeDescriptionKey
                    ]
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(keys),
                        options: []
                    )
                    var batch: [FileItem] = []
                    for url in urls {
                        try Task.checkCancellation()
                        let values = try url.resourceValues(forKeys: keys)
                        let standardizedURL = url.standardizedFileURL
                        let availability = await availabilityReader.availability(of: standardizedURL)
                        batch.append(FileItem(
                            url: standardizedURL,
                            name: url.lastPathComponent,
                            isDirectory: values.isDirectory == true,
                            isPackage: values.isPackage == true,
                            modifiedAt: values.contentModificationDate,
                            byteSize: values.isDirectory == true ? nil : values.fileSize.map(Int64.init),
                            typeDescription: values.localizedTypeDescription ?? "File",
                            availability: availability
                        ))
                        if batch.count == batchSize {
                            continuation.yield(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty {
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
