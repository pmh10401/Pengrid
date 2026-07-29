import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CloudItemAvailabilityTests {
    @Test func ordinaryLocalFileIsAvailableWithoutMaterialization() async {
        let url = URL(filePath: "/fixture/local.txt")
        let reader = StubCloudItemMetadataReader(metadata: [
            url: CloudItemResourceMetadata(
                isUbiquitousItem: false,
                isDownloading: false,
                downloadingStatus: nil,
                percentDownloaded: nil,
                isInsideKnownCloudRoot: false
            )
        ])

        let availability = await LiveCloudItemAvailabilityService(
            metadataReader: reader
        ).availability(of: url)

        #expect(availability == .availableLocally)
        #expect(!availability.requiresMaterialization)
    }

    @Test func ubiquitousNotDownloadedFileIsOnlineOnly() async {
        let url = URL(filePath: "/fixture/cloud.txt")
        let reader = StubCloudItemMetadataReader(metadata: [
            url: CloudItemResourceMetadata(
                isUbiquitousItem: true,
                isDownloading: false,
                downloadingStatus: .notDownloaded,
                percentDownloaded: nil,
                isInsideKnownCloudRoot: true
            )
        ])

        let availability = await LiveCloudItemAvailabilityService(
            metadataReader: reader
        ).availability(of: url)

        #expect(availability == .onlineOnly)
    }

    @Test func downloadingMetadataProducesBoundedOptionalProgress() async {
        let highURL = URL(filePath: "/fixture/high.txt")
        let lowURL = URL(filePath: "/fixture/low.txt")
        let unknownURL = URL(filePath: "/fixture/unknown.txt")
        let reader = StubCloudItemMetadataReader(metadata: [
            highURL: .downloading(percentDownloaded: 175),
            lowURL: .downloading(percentDownloaded: -20),
            unknownURL: .downloading(percentDownloaded: nil)
        ])
        let service = LiveCloudItemAvailabilityService(metadataReader: reader)

        #expect(await service.availability(of: highURL) == .downloading(progress: 1))
        #expect(await service.availability(of: lowURL) == .downloading(progress: 0))
        #expect(await service.availability(of: unknownURL) == .downloading(progress: nil))
    }

    @Test func unknownProviderMetadataIsUnknownAndThereforeGated() async {
        let url = URL(filePath: "/fixture/CloudStorage/Acme/item.txt")
        let reader = StubCloudItemMetadataReader(metadata: [
            url: CloudItemResourceMetadata(
                isUbiquitousItem: nil,
                isDownloading: nil,
                downloadingStatus: nil,
                percentDownloaded: nil,
                isInsideKnownCloudRoot: true
            )
        ])

        let availability = await LiveCloudItemAvailabilityService(
            metadataReader: reader
        ).availability(of: url)

        #expect(availability == .unknown)
        #expect(availability.requiresMaterialization)
    }

    @Test func directoryListingDoesNotCallTheMaterializer() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "placeholder.txt")
        try Data().write(to: file)
        let availability = StubCloudItemAvailabilityReader(defaultValue: .onlineOnly)
        let materializer = InMemoryCloudMaterializer()

        let items = try await LiveDirectoryListingService(
            batchSize: 8,
            availabilityReader: availability
        ).batches(in: directory.url).reduce(into: [FileItem]()) {
            $0.append(contentsOf: $1)
        }

        #expect(items.map(\.availability) == [.onlineOnly])
        #expect(await availability.requestedURLs() == [file.standardizedFileURL])
        #expect(await materializer.recordedCalls().isEmpty)
    }
}

private actor StubCloudItemMetadataReader: CloudItemMetadataReading {
    private let metadata: [URL: CloudItemResourceMetadata]

    init(metadata: [URL: CloudItemResourceMetadata]) {
        self.metadata = metadata
    }

    func metadata(of url: URL) throws -> CloudItemResourceMetadata {
        metadata[url] ?? CloudItemResourceMetadata(
            isUbiquitousItem: nil,
            isDownloading: nil,
            downloadingStatus: nil,
            percentDownloaded: nil,
            isInsideKnownCloudRoot: false
        )
    }
}

private actor StubCloudItemAvailabilityReader: CloudItemAvailabilityReading {
    private let defaultValue: CloudItemAvailability
    private var requests: [URL] = []

    init(defaultValue: CloudItemAvailability) {
        self.defaultValue = defaultValue
    }

    func availability(of url: URL) -> CloudItemAvailability {
        requests.append(url)
        return defaultValue
    }

    func requestedURLs() -> [URL] {
        requests
    }
}

private extension CloudItemResourceMetadata {
    static func downloading(percentDownloaded: Double?) -> Self {
        Self(
            isUbiquitousItem: true,
            isDownloading: true,
            downloadingStatus: .notDownloaded,
            percentDownloaded: percentDownloaded,
            isInsideKnownCloudRoot: true
        )
    }
}
