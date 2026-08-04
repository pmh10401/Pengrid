import Foundation

struct LiveDirectoryListingService: DirectoryListingService {
    let batchSize: Int
    private let visibility: DirectoryVisibilityPolicy
    private let availabilityReader: any CloudItemAvailabilityReading
    private let accessCoordinator: CloudLocationScopedAccessCoordinator

    init(
        batchSize: Int = 256,
        visibility: DirectoryVisibilityPolicy = .baseline,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.batchSize = batchSize
        self.visibility = visibility
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
                        .fileSizeKey
                    ]
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(keys),
                        options: visibility.fileManagerOptions
                    )
                    var batch: [FileItem] = []
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
