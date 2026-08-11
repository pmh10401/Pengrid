import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SmartSearchServiceTests {
    @Test func serviceCapturesExactIdentityAndAppliesMetadataBeforeRetention() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let textURL = root.url.appending(path: "alpha.txt")
        try Data(repeating: 1, count: 12).write(to: textURL)
        try Data(repeating: 1, count: 30).write(to: root.url.appending(path: "alpha.pdf"))
        let fileSystem = LiveFileSystemAccess()
        let service = LocalSmartSearchService(fileSystem: fileSystem)
        let query = try SmartSearchQuery(
            text: "alpha",
            roots: [physicalURL(root.url)],
            metadata: try .init(kind: .files, extensionText: "txt", minimumBytes: 10, maximumBytes: 20)
        )

        let results = try await service.search(query)
        let expectedIdentity = try await fileSystem.identity(of: textURL)

        #expect(results.map(\.item.name) == ["alpha.txt"])
        #expect(results.first?.identity == expectedIdentity)
    }

    @Test func itemReplacedDuringMetadataReadIsNotRetained() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let url = root.url.appending(path: "replace-me.txt")
        try Data([1]).write(to: url)
        let replacement = ReplacementOnce()
        let service = LocalSmartSearchService(
            fileSystem: LiveFileSystemAccess(),
            typeDescriptionReader: { candidate in
                try replacement.replace(candidate)
                return "File"
            }
        )

        let results = try await service.search(
            try SmartSearchQuery(text: "replace-me", roots: [physicalURL(root.url)])
        )

        #expect(results.isEmpty)
    }

    @Test func smartSearchServiceHasNoMaterializationOrContentReadDependency() throws {
        let implementation = try source(named: "Services/SmartSearchService.swift")

        #expect(!implementation.contains("CloudMaterializing"))
        #expect(!implementation.contains("materialize("))
        #expect(!implementation.contains("NSFileCoordinator"))
        #expect(!implementation.contains("Data(contentsOf:"))
        #expect(!implementation.contains("String(contentsOf:"))
        #expect(!implementation.contains("FileHandle"))
        #expect(!implementation.contains("contents(atPath:"))
        #expect(!implementation.contains("contentsOfDirectory("))
    }

    @Test func prunesDuplicateAndDescendantRootsBeforeRecursiveEnumeration() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let child = root.url.appending(path: "child", directoryHint: .isDirectory)
        try write("report", to: child.appending(path: "report.txt"))

        let results = try await LocalSmartSearchService().search(
            try SmartSearchQuery(
                text: "report",
                roots: [physicalURL(child), physicalURL(root.url), physicalURL(root.url)]
            )
        )

        #expect(results.map(\.relativePath) == ["child/report.txt"])
    }

    @Test func doesNotTraverseSymlinksAndRespectsHiddenAndPackageBoundaries() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let target = try ServiceTemporaryDirectory()
        defer { target.remove() }
        try write("hidden", to: root.url.appending(path: ".hidden/report-hidden.txt"))
        try write("package", to: root.url.appending(path: "Report.app/report-package.txt"))
        try write("linked", to: target.url.appending(path: "report-linked.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.url.appending(path: "linked", directoryHint: .isDirectory),
            withDestinationURL: target.url
        )
        try write("regular", to: root.url.appending(path: "report-regular.txt"))

        let defaults = try await LocalSmartSearchService().search(
            try SmartSearchQuery(text: "report", roots: [physicalURL(root.url)])
        )
        let optedIn = try await LocalSmartSearchService().search(
            try SmartSearchQuery(text: "report", roots: [physicalURL(root.url)], includeHidden: true, includePackages: true)
        )

        #expect(defaults.map(\.item.name) == ["report-regular.txt"])
        #expect(Set(optedIn.map(\.item.name)) == ["report-hidden.txt", "report-package.txt", "report-regular.txt"])
    }

    @Test func metadataNonmatchesDoNotReadAvailabilityAndProgressCountsExaminedEntries() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        try write("report", to: root.url.appending(path: "report-match.txt"))
        try write("report", to: root.url.appending(path: "report-skip.pdf"))
        let availability = RecordingAvailabilityReader()
        let progress = LockedValues<Int>()
        let service = LocalSmartSearchService(availabilityReader: availability)

        let results = try await service.search(
            try SmartSearchQuery(
                text: "report",
                roots: [physicalURL(root.url)],
                metadata: try .init(kind: .files, extensionText: "txt")
            ),
            progress: { progress.append($0) }
        )

        #expect(results.map(\.item.name) == ["report-match.txt"])
        #expect(await availability.requestedURLs() == [physicalURL(root.url).appending(path: "report-match.txt").standardizedFileURL])
        #expect(progress.values == [1, 2])
    }

    @Test func invalidRootsFailInsteadOfBeingSilentlySkipped() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let missing = root.url.appending(path: "missing")

        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await LocalSmartSearchService().search(
                try SmartSearchQuery(text: "report", roots: [missing])
            )
        }
    }

    @Test func candidateAndResultCapsBoundMetadataWork() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        for index in 0...2_000 {
            try write("report", to: root.url.appending(path: "report-\(index).txt"))
        }
        let availability = RecordingAvailabilityReader()

        let results = try await LocalSmartSearchService(availabilityReader: availability).search(
            try SmartSearchQuery(
                text: "report",
                roots: [physicalURL(root.url)],
                includeDirectories: false,
                maximumResults: 1
            )
        )

        #expect(results.count == 1)
        #expect(await availability.requestedURLs().count == SmartSearchQuery.minimumCandidateBudget)
    }

    @Test func cancellationAfterAnAvailabilityWaitStopsTheSearch() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        try write("report", to: root.url.appending(path: "report.txt"))
        let availability = DelayingAvailabilityReader()
        let service = LocalSmartSearchService(availabilityReader: availability)
        let task = Task {
            try await service.search(try SmartSearchQuery(text: "report", roots: [physicalURL(root.url)]))
        }
        await availability.waitUntilStarted()

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func scopedAccessLeaseIsReleasedAfterSearch() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        try write("report", to: root.url.appending(path: "report.txt"))
        let driver = RecordingScopedAccessDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([physicalURL(root.url)])

        _ = try await LocalSmartSearchService(scopedAccessCoordinator: coordinator).search(
            try SmartSearchQuery(text: "report", roots: [physicalURL(root.url)])
        )

        #expect(driver.startCount == 1)
        #expect(driver.stopCount == 1)
    }

    @Test func postIdentityMetadataSnapshotDrivesFilteringAndRetainedItem() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let candidate = root.url.appending(path: "report-item", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let fileSystem = FirstIdentityMutatingFileSystem { url in
            try FileManager.default.removeItem(at: url)
            try Data([1]).write(to: url)
        }

        let results = try await LocalSmartSearchService(fileSystem: fileSystem).search(
            try SmartSearchQuery(
                text: "report",
                roots: [physicalURL(root.url)],
                metadata: try .init(kind: .files)
            )
        )

        #expect(results.map(\.item.name) == ["report-item"])
        #expect(results.first?.item.isDirectory == false)
        #expect(results.first?.item.isPackage == false)
    }

    @Test func retainedRegularResultsReportThatTheyAreNotSymbolicLinks() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let file = root.url.appending(path: "report.txt")
        try Data([1]).write(to: file)

        let results = try await LocalSmartSearchService().search(
            try SmartSearchQuery(text: "report", roots: [physicalURL(root.url)])
        )

        #expect(results.map(\.item.isSymbolicLink) == [false])
    }

    @Test func symlinkRootsAndSymlinkAncestorsAreRejectedWithoutFollowingThem() async throws {
        let fixture = try ServiceTemporaryDirectory()
        defer { fixture.remove() }
        let base = physicalURL(fixture.url)
        let target = base.appending(path: "target", directoryHint: .isDirectory)
        let child = target.appending(path: "child", directoryHint: .isDirectory)
        try write("report", to: child.appending(path: "report.txt"))
        let directLink = base.appending(path: "direct-link", directoryHint: .isDirectory)
        let ancestorLink = base.appending(path: "ancestor-link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: directLink, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: target)

        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await LocalSmartSearchService().search(
                try SmartSearchQuery(text: "report", roots: [directLink])
            )
        }
        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await LocalSmartSearchService().search(
                try SmartSearchQuery(text: "report", roots: [ancestorLink.appending(path: "child")])
            )
        }
    }

    @Test func itemReplacedDuringAvailabilityReadIsNotRetained() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let url = root.url.appending(path: "replace-during-availability.txt")
        try Data([1]).write(to: url)
        let replacement = ReplacementOnce()
        let availability = ReplacingAvailabilityReader(replacement: replacement)

        let results = try await LocalSmartSearchService(availabilityReader: availability).search(
            try SmartSearchQuery(text: "replace-during-availability", roots: [physicalURL(root.url)])
        )

        #expect(results.isEmpty)
        #expect(await availability.didReadAvailability())
    }

    @Test func activeBoundsRejectItemsWhoseMetadataBecomesUnavailableAfterIdentity() async throws {
        let root = try ServiceTemporaryDirectory()
        defer { root.remove() }
        let candidate = root.url.appending(path: "report-item.txt")
        try Data([1]).write(to: candidate)
        let fileSystem = FirstIdentityMutatingFileSystem { url in
            try FileManager.default.removeItem(at: url)
        }

        let results = try await LocalSmartSearchService(fileSystem: fileSystem).search(
            try SmartSearchQuery(
                text: "report",
                roots: [physicalURL(root.url)],
                metadata: try .init(kind: .files, minimumBytes: 1)
            )
        )

        #expect(results.isEmpty)
    }
}

private final class ReplacementOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didReplace = false

    func replace(_ url: URL) throws {
        lock.lock()
        guard !didReplace else {
            lock.unlock()
            return
        }
        didReplace = true
        lock.unlock()

        try FileManager.default.removeItem(at: url)
        try Data([2]).write(to: url)
    }
}

private actor ReplacingAvailabilityReader: CloudItemAvailabilityReading {
    private let replacement: ReplacementOnce
    private var readAvailability = false

    init(replacement: ReplacementOnce) {
        self.replacement = replacement
    }

    func availability(of url: URL) async -> CloudItemAvailability {
        readAvailability = true
        try? replacement.replace(url)
        return .availableLocally
    }

    func didReadAvailability() -> Bool {
        readAvailability
    }
}

private actor FirstIdentityMutatingFileSystem: FileSystemAccess {
    private let mutation: @Sendable (URL) throws -> Void
    private var didMutate = false
    private let identity = FileIdentity(entryIdentifier: "stable-entry", resolvedIdentifier: "stable-resolved")

    init(mutation: @escaping @Sendable (URL) throws -> Void) {
        self.mutation = mutation
    }

    func exists(_: URL) async -> Bool { true }
    func createDirectory(_: URL) async throws { throw FixtureError.unsupported }
    func createEmptyItemAndCaptureIdentity(
        _: URL,
        kind _: EmptyFileSystemItemKind,
        parentIdentifiedBy _: FileIdentity
    ) async throws -> OpenedEmptyFileSystemItem { throw FixtureError.unsupported }
    func copyAndCaptureIdentity(_: URL, to _: URL) async throws -> FileIdentity { throw FixtureError.unsupported }
    func move(_: URL, to _: URL) async throws { throw FixtureError.unsupported }
    func moveExclusively(_: URL, to _: URL) async throws { throw FixtureError.unsupported }
    func remove(_: URL) async throws { throw FixtureError.unsupported }
    func replace(_: URL, with _: URL) async throws { throw FixtureError.unsupported }

    func identity(of url: URL) async throws -> FileIdentity? {
        if !didMutate {
            didMutate = true
            try mutation(url)
        }
        return identity
    }

    func move(_: URL, identifiedBy _: FileIdentity, to _: URL) async throws { throw FixtureError.unsupported }
    func remove(_: URL, identifiedBy _: FileIdentity) async throws { throw FixtureError.unsupported }
    func replace(
        _: URL,
        identifiedBy _: FileIdentity,
        with _: URL,
        identifiedBy _: FileIdentity
    ) async throws { throw FixtureError.unsupported }
    func reserveStagingDirectory(beside _: URL) async throws -> StagingReservation { throw FixtureError.unsupported }
    func removeStagingDirectory(_: StagingReservation) async throws { throw FixtureError.unsupported }
    func fingerprint(of _: URL) async throws -> SourceFingerprint { throw FixtureError.unsupported }
    func trash(_: URL) async throws { throw FixtureError.unsupported }
    func trash(_: URL, identifiedBy _: FileIdentity) async throws { throw FixtureError.unsupported }
    func quarantineForTrash(
        _: URL,
        identifiedBy _: FileIdentity
    ) async throws -> StorageTrashQuarantine { throw FixtureError.unsupported }
    func rollbackTrashQuarantine(_: StorageTrashQuarantine) async throws { throw FixtureError.unsupported }
    func moveTrashQuarantineAtomically(_: StorageTrashQuarantine) async throws -> URL { throw FixtureError.unsupported }
    func names(in _: URL) async throws -> Set<String> { throw FixtureError.unsupported }
    func volumeIdentifier(for _: URL) async throws -> String { throw FixtureError.unsupported }
    func byteSize(of _: URL) async throws -> Int64? { throw FixtureError.unsupported }
    func availableCapacity(at _: URL) async throws -> Int64? { throw FixtureError.unsupported }
    func prepareDirectoryHierarchy(
        root _: URL,
        identifiedBy _: FileIdentity,
        relativeComponents _: [String]
    ) async throws -> PreparedDirectoryHierarchy { throw FixtureError.unsupported }
    func removeEmptyOwnedDirectories(
        root _: URL,
        identifiedBy _: FileIdentity,
        directories _: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) async throws { throw FixtureError.unsupported }

    private enum FixtureError: Error {
        case unsupported
    }
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func physicalURL(_ url: URL) -> URL {
    guard let resolvedPath = realpath(url.path, nil) else {
        return url.standardizedFileURL
    }
    defer { free(resolvedPath) }
    return URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: url.hasDirectoryPath)
}

private struct ServiceTemporaryDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: ".smart-search-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

private actor RecordingAvailabilityReader: CloudItemAvailabilityReading {
    private var urls: [URL] = []

    func availability(of url: URL) -> CloudItemAvailability {
        urls.append(url.standardizedFileURL)
        return .availableLocally
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private actor DelayingAvailabilityReader: CloudItemAvailabilityReading {
    private var started = false

    func availability(of url: URL) async -> CloudItemAvailability {
        started = true
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            return .availableLocally
        }
        return .availableLocally
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private final class RecordingScopedAccessDriver: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}
