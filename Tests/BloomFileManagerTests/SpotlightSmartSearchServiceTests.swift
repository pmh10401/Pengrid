import Foundation
import Testing
@testable import BloomFileManager

@Suite(.serialized) struct SpotlightSmartSearchServiceTests {
    @Test func contentResultsOutsideRootsAndChangedIdentitiesAreDiscarded() async throws {
        let root = try SpotlightTemporaryDirectory()
        defer { root.remove() }
        let outside = try SpotlightTemporaryDirectory()
        defer { outside.remove() }
        let valid = try writeSpotlightFixture("valid", named: "annual-valid.txt", in: root.url)
        let changed = try writeSpotlightFixture("before", named: "annual-changed.txt", in: root.url)
        let outsideFile = try writeSpotlightFixture("outside", named: "annual-outside.txt", in: outside.url)
        let runner = StubSpotlightMetadataRunner(urls: [outsideFile, changed, valid])
        let availability = ReplacingSpotlightAvailabilityReader(target: changed)
        let service = LiveSpotlightSmartSearchService(
            runner: runner,
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: availability
        )
        let physicalRoot = physicalSpotlightURL(root.url)

        let results = try await service.searchIndexedContents(
            try SmartSearchQuery(text: "annual", roots: [physicalRoot], searchIndexedContents: true)
        )

        #expect(results.map(\.item.name) == ["annual-valid.txt"])
        #expect(results.map(\.relativePath) == ["annual-valid.txt"])
        let request = await runner.lastRequest()
        #expect(request?.tokens == ["annual"])
        #expect(request?.roots == [physicalRoot])
        #expect(await availability.didReplaceTarget())
    }

    @Test func indexedCandidatesRespectMetadataAndTraversalBoundaries() async throws {
        let root = try SpotlightTemporaryDirectory()
        defer { root.remove() }
        let outside = try SpotlightTemporaryDirectory()
        defer { outside.remove() }
        let regular = try writeSpotlightFixture("regular", named: "report-regular.txt", in: root.url)
        let wrongExtension = try writeSpotlightFixture("pdf", named: "report.pdf", in: root.url)
        let hidden = try writeSpotlightFixture("hidden", named: ".hidden/report-hidden.txt", in: root.url)
        let packaged = try writeSpotlightFixture("package", named: "Report.app/report-package.txt", in: root.url)
        let linkedTarget = try writeSpotlightFixture("linked", named: "report-linked.txt", in: outside.url)
        let link = root.url.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
        let throughLink = link.appending(path: linkedTarget.lastPathComponent)
        let availability = RecordingSpotlightAvailabilityReader()
        let service = LiveSpotlightSmartSearchService(
            runner: StubSpotlightMetadataRunner(
                urls: [hidden, packaged, throughLink, wrongExtension, regular]
            ),
            availabilityReader: availability
        )

        let results = try await service.searchIndexedContents(
            try SmartSearchQuery(
                text: "report",
                roots: [physicalSpotlightURL(root.url)],
                metadata: try .init(kind: .files, extensionText: "txt")
            )
        )

        #expect(results.map(\.item.name) == ["report-regular.txt"])
        #expect(await availability.requestedURLs() == [regular.standardizedFileURL])
    }

    @Test func scopedAccessLeaseIsReleasedAfterIndexedHydration() async throws {
        let root = try SpotlightTemporaryDirectory()
        defer { root.remove() }
        let file = try writeSpotlightFixture("report", named: "report.txt", in: root.url)
        let physicalRoot = physicalSpotlightURL(root.url)
        let driver = SpotlightScopedAccessDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([physicalRoot])
        let service = LiveSpotlightSmartSearchService(
            runner: StubSpotlightMetadataRunner(urls: [file]),
            scopedAccessCoordinator: coordinator
        )

        _ = try await service.searchIndexedContents(
            try SmartSearchQuery(text: "report", roots: [physicalRoot])
        )

        #expect(driver.startCount == 1)
        #expect(driver.stopCount == 1)
    }

    @Test func filesystemRootScopeHydratesADescendantCandidate() async throws {
        let fixture = try SpotlightTemporaryDirectory()
        defer { fixture.remove() }
        let file = try writeSpotlightFixture("report", named: "report.txt", in: fixture.url)
        let service = LiveSpotlightSmartSearchService(
            runner: StubSpotlightMetadataRunner(urls: [file])
        )

        let results = try await service.searchIndexedContents(
            try SmartSearchQuery(
                text: "report",
                roots: [URL(filePath: "/", directoryHint: .isDirectory)],
                includeHidden: true,
                includePackages: true
            )
        )

        #expect(results.map(\.item.url) == [file.standardizedFileURL])
        #expect(results.map(\.relativePath) == [String(file.path.dropFirst())])
    }

    @Test func rootReplacementWithSymlinkDuringGatherInvalidatesTheSearch() async throws {
        let fixture = try SpotlightTemporaryDirectory()
        defer { fixture.remove() }
        let root = fixture.url.appending(path: "search-root", directoryHint: .isDirectory)
        let file = try writeSpotlightFixture("report", named: "report.txt", in: root)
        let relocatedRoot = fixture.url.appending(
            path: "relocated-root",
            directoryHint: .isDirectory
        )
        let runner = StubSpotlightMetadataRunner(urls: [file]) {
            try FileManager.default.moveItem(at: root, to: relocatedRoot)
            try FileManager.default.createSymbolicLink(
                at: root,
                withDestinationURL: relocatedRoot
            )
        }
        let availability = RecordingSpotlightAvailabilityReader()
        let service = LiveSpotlightSmartSearchService(
            runner: runner,
            availabilityReader: availability
        )

        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await service.searchIndexedContents(
                try SmartSearchQuery(
                    text: "report",
                    roots: [physicalSpotlightURL(root)]
                )
            )
        }
        #expect(await availability.requestedURLs().isEmpty)
    }

    @Test func rootAncestorReplacementDuringGatherInvalidatesUnchangedRootIdentity() async throws {
        let fixture = try SpotlightTemporaryDirectory()
        defer { fixture.remove() }
        let container = fixture.url.appending(path: "container", directoryHint: .isDirectory)
        let root = container.appending(path: "search-root", directoryHint: .isDirectory)
        let file = try writeSpotlightFixture("report", named: "report.txt", in: root)
        let relocatedContainer = fixture.url.appending(
            path: "relocated-container",
            directoryHint: .isDirectory
        )
        let runner = StubSpotlightMetadataRunner(urls: [file]) {
            try FileManager.default.moveItem(at: container, to: relocatedContainer)
            try FileManager.default.createSymbolicLink(
                at: container,
                withDestinationURL: relocatedContainer
            )
        }
        let service = LiveSpotlightSmartSearchService(runner: runner)

        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await service.searchIndexedContents(
                try SmartSearchQuery(
                    text: "report",
                    roots: [physicalSpotlightURL(root)]
                )
            )
        }
    }

    @Test func candidateAncestorReplacementDuringHydrationDiscardsUnchangedLeaf() async throws {
        let fixture = try SpotlightTemporaryDirectory()
        defer { fixture.remove() }
        let ancestor = fixture.url.appending(path: "section", directoryHint: .isDirectory)
        let file = try writeSpotlightFixture("report", named: "report.txt", in: ancestor)
        let relocatedAncestor = fixture.url.appending(
            path: "relocated-section",
            directoryHint: .isDirectory
        )
        let availability = RelinkingSpotlightAvailabilityReader(
            ancestor: ancestor,
            relocatedAncestor: relocatedAncestor
        )
        let service = LiveSpotlightSmartSearchService(
            runner: StubSpotlightMetadataRunner(urls: [file]),
            availabilityReader: availability
        )

        let results = try await service.searchIndexedContents(
            try SmartSearchQuery(
                text: "report",
                roots: [physicalSpotlightURL(fixture.url)]
            )
        )

        #expect(results.isEmpty)
        #expect(await availability.didRelink())
    }
}

private actor StubSpotlightMetadataRunner: SpotlightMetadataQueryRunning {
    struct Request: Sendable {
        let tokens: [String]
        let roots: [URL]
    }

    private let urls: [URL]
    private let beforeReturn: @Sendable () throws -> Void
    private var requests: [Request] = []

    init(
        urls: [URL],
        beforeReturn: @escaping @Sendable () throws -> Void = {}
    ) {
        self.urls = urls
        self.beforeReturn = beforeReturn
    }

    func matchingURLs(tokens: [String], roots: [URL]) async throws -> [URL] {
        requests.append(.init(tokens: tokens, roots: roots))
        try beforeReturn()
        return urls
    }

    func lastRequest() -> Request? {
        requests.last
    }
}

private actor ReplacingSpotlightAvailabilityReader: CloudItemAvailabilityReading {
    private let target: URL
    private var didReplace = false

    init(target: URL) {
        self.target = target.standardizedFileURL
    }

    func availability(of url: URL) async -> CloudItemAvailability {
        if url.standardizedFileURL == target, !didReplace {
            didReplace = true
            try? FileManager.default.removeItem(at: target)
            try? Data("after".utf8).write(to: target)
        }
        return .availableLocally
    }

    func didReplaceTarget() -> Bool {
        didReplace
    }
}

private actor RecordingSpotlightAvailabilityReader: CloudItemAvailabilityReading {
    private var urls: [URL] = []

    func availability(of url: URL) -> CloudItemAvailability {
        urls.append(url.standardizedFileURL)
        return .availableLocally
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private actor RelinkingSpotlightAvailabilityReader: CloudItemAvailabilityReading {
    private let ancestor: URL
    private let relocatedAncestor: URL
    private var relinked = false

    init(ancestor: URL, relocatedAncestor: URL) {
        self.ancestor = ancestor
        self.relocatedAncestor = relocatedAncestor
    }

    func availability(of _: URL) -> CloudItemAvailability {
        if !relinked {
            relinked = true
            try? FileManager.default.moveItem(at: ancestor, to: relocatedAncestor)
            try? FileManager.default.createSymbolicLink(
                at: ancestor,
                withDestinationURL: relocatedAncestor
            )
        }
        return .availableLocally
    }

    func didRelink() -> Bool {
        relinked
    }
}

private final class SpotlightScopedAccessDriver: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func startAccessing(_: URL) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func stopAccessing(_: URL) {
        lock.withLock { stops += 1 }
    }
}

private struct SpotlightTemporaryDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: ".spotlight-search-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func writeSpotlightFixture(_ contents: String, named name: String, in root: URL) throws -> URL {
    let url = root.appending(path: name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    return physicalSpotlightURL(url)
}

private func physicalSpotlightURL(_ url: URL) -> URL {
    guard let resolvedPath = realpath(url.path, nil) else {
        return url.standardizedFileURL
    }
    defer { free(resolvedPath) }
    return URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: url.hasDirectoryPath)
}
