import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CloudMaterializationServiceTests {
    @Test func archivePurposePreservesSelectedSymbolicLinkWithoutReadingItsTarget() async throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let target = temporaryDirectory.url.appending(path: "Target.txt")
        let selectedLink = temporaryDirectory.url.appending(path: "Selected Link.txt")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: selectedLink.path,
            withDestinationPath: target.lastPathComponent
        )
        let identity = try #require(
            try await LiveFileSystemAccess().identity(of: selectedLink)
        )
        let request = IdentifiedFileRequest(url: selectedLink, identity: identity)
        let coordinator = ArchivePurposeReadCoordinator()
        let service = LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: ArchivePurposeAvailabilityReader(values: [:]),
            coordinator: coordinator,
            maximumPollAttempts: 1,
            pollInterval: .zero
        )

        let result = await service.materialize([request], purpose: .archive) { _ in }

        #expect(result.isReady)
        #expect(result.preparedRequests == [request])
        #expect(result.failures.isEmpty)
        #expect(await coordinator.coordinatedURLs().isEmpty)
    }

    @Test func archivePurposeMaterializesDirectoryDescendants() async throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let root = temporaryDirectory.url.appending(
            path: "Folder",
            directoryHint: .isDirectory
        )
        let child = root.appending(path: "cloud.txt")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try Data("cloud".utf8).write(to: child)
        let identity = try #require(
            try await LiveFileSystemAccess().identity(of: root)
        )
        let availability = ArchivePurposeAvailabilityReader(
            values: [child: [.onlineOnly, .availableLocally]]
        )
        let coordinator = ArchivePurposeReadCoordinator()
        let service = LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: availability,
            coordinator: coordinator,
            maximumPollAttempts: 4,
            pollInterval: .zero
        )

        let result = await service.materialize(
            [IdentifiedFileRequest(url: root, identity: identity)],
            purpose: .archive
        ) { _ in }

        #expect(result.isReady)
        #expect(await coordinator.coordinatedURLs() == [child.standardizedFileURL])
    }
}

private actor ArchivePurposeAvailabilityReader: CloudItemAvailabilityReading {
    private var values: [URL: [CloudItemAvailability]]

    init(values: [URL: [CloudItemAvailability]]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map {
            ($0.key.standardizedFileURL, $0.value)
        })
    }

    func availability(of url: URL) -> CloudItemAvailability {
        let key = url.standardizedFileURL
        guard var sequence = values[key], !sequence.isEmpty else {
            return .availableLocally
        }
        let value = sequence.removeFirst()
        values[key] = sequence
        return value
    }
}

private actor ArchivePurposeReadCoordinator: CloudReadCoordinating {
    private var urls: [URL] = []

    func coordinateReading(
        at url: URL,
        expectedIdentity: FileIdentity,
        kind: CloudCoordinatedReadKind
    ) {
        urls.append(url.standardizedFileURL)
    }

    func coordinatedURLs() -> [URL] {
        urls
    }
}
