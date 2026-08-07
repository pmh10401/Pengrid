import Foundation

struct DirectoryEntryMetadata: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let modifiedAt: Date?
    let byteSize: Int64?
    let typeDescription: String

    func fileItem(availability: CloudItemAvailability) -> FileItem {
        FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            modifiedAt: modifiedAt,
            byteSize: byteSize,
            typeDescription: typeDescription,
            availability: availability
        )
    }
}

protocol DirectoryEntryMetadataReading: Sendable {
    func metadata(for url: URL) throws -> DirectoryEntryMetadata
}

struct LiveDirectoryEntryMetadataReader: DirectoryEntryMetadataReading {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .localizedTypeDescriptionKey
    ]

    func metadata(for url: URL) throws -> DirectoryEntryMetadata {
        let values = try url.resourceValues(forKeys: Self.resourceKeys)
        let standardizedURL = url.standardizedFileURL
        let isDirectory = values.isDirectory == true
        return DirectoryEntryMetadata(
            url: standardizedURL,
            name: standardizedURL.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: values.isPackage == true,
            modifiedAt: values.contentModificationDate,
            byteSize: isDirectory ? nil : values.fileSize.map(Int64.init),
            typeDescription: values.localizedTypeDescription ?? "File"
        )
    }
}

struct DirectoryEntryBatchBuilder: Sendable {
    let metadataReader: any DirectoryEntryMetadataReading
    let availabilityReader: any CloudItemAvailabilityReading
    let maximumConcurrency: Int

    init(
        metadataReader: any DirectoryEntryMetadataReading = LiveDirectoryEntryMetadataReader(),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        maximumConcurrency: Int = 8
    ) {
        precondition(maximumConcurrency > 0, "maximumConcurrency must be greater than zero")
        self.metadataReader = metadataReader
        self.availabilityReader = availabilityReader
        self.maximumConcurrency = maximumConcurrency
    }

    func build(urls: [URL]) async throws -> [FileItem] {
        try await withThrowingTaskGroup(of: (Int, FileItem).self) { group in
            var results = Array<FileItem?>(repeating: nil, count: urls.count)
            var nextIndex = 0

            func submit(_ index: Int) {
                let url = urls[index]
                group.addTask {
                    try Task.checkCancellation()
                    let metadata = try metadataReader.metadata(for: url)
                    try Task.checkCancellation()
                    let availability = await availabilityReader.availability(of: url.standardizedFileURL)
                    try Task.checkCancellation()
                    return (index, metadata.fileItem(availability: availability))
                }
            }

            while nextIndex < min(maximumConcurrency, urls.count) {
                submit(nextIndex)
                nextIndex += 1
            }

            while let (index, item) = try await group.next() {
                results[index] = item
                if nextIndex < urls.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }

            guard results.allSatisfy({ $0 != nil }) else {
                throw CancellationError()
            }
            return results.map { $0! }
        }
    }
}
