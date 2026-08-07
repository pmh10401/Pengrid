import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CloudItemAvailabilityTests {
    @Test func batchBuilderReadsOnceBoundsConcurrencyAndPreservesOrder() async throws {
        let urls = (0..<20).map { URL(filePath: "/virtual/\($0).txt") }
        let metadata = RecordingDirectoryEntryMetadataReader()
        let availability = ConcurrencyRecordingAvailabilityReader(result: .onlineOnly)
        let builder = DirectoryEntryBatchBuilder(
            metadataReader: metadata,
            availabilityReader: availability,
            maximumConcurrency: 4
        )

        let items = try await builder.build(urls: urls)

        #expect(items.map(\.url) == urls.map(\.standardizedFileURL))
        #expect(metadata.requestCount == 20)
        #expect(await availability.maximumObservedConcurrency() <= 4)
    }

    @Test func batchBuilderCancellationPropagatesWithoutPartialResults() async throws {
        let urls = (0..<3).map { URL(filePath: "/virtual/\($0).txt") }
        let metadata = RecordingDirectoryEntryMetadataReader()
        let availability = SuspendedAvailabilityReader()
        let builder = DirectoryEntryBatchBuilder(
            metadataReader: metadata,
            availabilityReader: availability,
            maximumConcurrency: 3
        )
        let task = Task { try await builder.build(urls: urls) }

        await availability.waitUntilEntered()
        task.cancel()
        await availability.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

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

    @MainActor
    @Test func filteringAndSortingOnlineOnlyGoogleDriveAndOneDriveMetadataDoesNotMaterialize() async {
        let directory = URL(filePath: "/Cloud", directoryHint: .isDirectory)
        let google = FileItem(
            url: directory.appending(path: "Google Drive/report-19.txt"),
            name: "report-19.txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 19,
            typeDescription: "Text",
            availability: .onlineOnly
        )
        let oneDrive = FileItem(
            url: directory.appending(path: "OneDrive/report-10.txt"),
            name: "report-10.txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 10,
            typeDescription: "Text",
            availability: .onlineOnly
        )
        let materializer = InMemoryCloudMaterializer()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: [google, oneDrive]])
        )

        await pane.navigate(to: directory, recordHistory: false)
        pane.updateFilterQuery("report")
        #expect(await cloudAvailabilityWait { pane.visibleItems.map(\.name) == ["report-10.txt", "report-19.txt"] })
        pane.sort = FileSort(key: .size, direction: .descending)
        #expect(await cloudAvailabilityWait { pane.visibleItems.map(\.name) == ["report-19.txt", "report-10.txt"] })
        #expect(pane.visibleItems.map(\.availability) == [.onlineOnly, .onlineOnly])
        #expect(await materializer.recordedCalls().isEmpty)
    }
}

@MainActor
private func cloudAvailabilityWait(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        await Task.yield()
    }
    return condition()
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

private final class RecordingDirectoryEntryMetadataReader:
    DirectoryEntryMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    func metadata(for url: URL) throws -> DirectoryEntryMetadata {
        lock.withLock { requests += 1 }
        let standardizedURL = url.standardizedFileURL
        return DirectoryEntryMetadata(
            url: standardizedURL,
            name: standardizedURL.lastPathComponent,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "Text"
        )
    }
}

private actor ConcurrencyRecordingAvailabilityReader: CloudItemAvailabilityReading {
    private let result: CloudItemAvailability
    private var active = 0
    private var maximumActive = 0

    init(result: CloudItemAvailability) {
        self.result = result
    }

    func availability(of url: URL) async -> CloudItemAvailability {
        active += 1
        maximumActive = max(maximumActive, active)
        await Task.yield()
        active -= 1
        return result
    }

    func maximumObservedConcurrency() -> Int {
        maximumActive
    }
}

private actor SuspendedAvailabilityReader: CloudItemAvailabilityReading {
    private var didEnter = false
    private var didRelease = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func availability(of url: URL) async -> CloudItemAvailability {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if didRelease { return .availableLocally }
        await withCheckedContinuation { releaseContinuations.append($0) }
        return .availableLocally
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        didRelease = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
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
