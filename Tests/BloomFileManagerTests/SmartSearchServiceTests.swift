import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SmartSearchServiceTests {
    @Test func serviceCapturesExactIdentityAndAppliesMetadataBeforeRetention() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let textURL = root.url.appending(path: "alpha.txt")
        try Data(repeating: 1, count: 12).write(to: textURL)
        try Data(repeating: 1, count: 30).write(to: root.url.appending(path: "alpha.pdf"))
        let fileSystem = LiveFileSystemAccess()
        let service = LocalSmartSearchService(fileSystem: fileSystem)
        let query = try SmartSearchQuery(
            text: "alpha",
            roots: [root.url],
            metadata: try .init(kind: .files, extensionText: "txt", minimumBytes: 10, maximumBytes: 20)
        )

        let results = try await service.search(query)
        let expectedIdentity = try await fileSystem.identity(of: textURL)

        #expect(results.map(\.item.name) == ["alpha.txt"])
        #expect(results.first?.identity == expectedIdentity)
    }

    @Test func itemReplacedDuringMetadataReadIsNotRetained() async throws {
        let root = try TemporaryDirectory()
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
            try SmartSearchQuery(text: "replace-me", roots: [root.url])
        )

        #expect(results.isEmpty)
    }

    @Test func smartSearchServiceHasNoMaterializationOrContentReadDependency() throws {
        let implementation = try source(named: "Services/SmartSearchService.swift")

        #expect(!implementation.contains("CloudMaterializing"))
        #expect(!implementation.contains("materialize("))
        #expect(!implementation.contains("NSFileCoordinator"))
    }

    @Test func prunesDuplicateAndDescendantRootsBeforeRecursiveEnumeration() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let child = root.url.appending(path: "child", directoryHint: .isDirectory)
        try write("report", to: child.appending(path: "report.txt"))

        let results = try await LocalSmartSearchService().search(
            try SmartSearchQuery(text: "report", roots: [child, root.url, root.url])
        )

        #expect(results.map(\.relativePath) == ["child/report.txt"])
    }

    @Test func doesNotTraverseSymlinksAndRespectsHiddenAndPackageBoundaries() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let target = try TemporaryDirectory()
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
            try SmartSearchQuery(text: "report", roots: [root.url])
        )
        let optedIn = try await LocalSmartSearchService().search(
            try SmartSearchQuery(text: "report", roots: [root.url], includeHidden: true, includePackages: true)
        )

        #expect(defaults.map(\.item.name) == ["report-regular.txt"])
        #expect(Set(optedIn.map(\.item.name)) == ["report-hidden.txt", "report-package.txt", "report-regular.txt"])
    }

    @Test func metadataNonmatchesDoNotReadAvailabilityAndProgressCountsExaminedEntries() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        try write("report", to: root.url.appending(path: "report-match.txt"))
        try write("report", to: root.url.appending(path: "report-skip.pdf"))
        let availability = RecordingAvailabilityReader()
        let progress = LockedValues<Int>()
        let service = LocalSmartSearchService(availabilityReader: availability)

        let results = try await service.search(
            try SmartSearchQuery(
                text: "report",
                roots: [root.url],
                metadata: try .init(kind: .files, extensionText: "txt")
            ),
            progress: { progress.append($0) }
        )

        #expect(results.map(\.item.name) == ["report-match.txt"])
        #expect(await availability.requestedURLs() == [root.url.appending(path: "report-match.txt").standardizedFileURL])
        #expect(progress.values == [1, 2])
    }

    @Test func invalidRootsFailInsteadOfBeingSilentlySkipped() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let missing = root.url.appending(path: "missing")

        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await LocalSmartSearchService().search(
                try SmartSearchQuery(text: "report", roots: [missing])
            )
        }
    }

    @Test func candidateAndResultCapsBoundMetadataWork() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        for index in 0...2_000 {
            try write("report", to: root.url.appending(path: "report-\(index).txt"))
        }
        let availability = RecordingAvailabilityReader()

        let results = try await LocalSmartSearchService(availabilityReader: availability).search(
            try SmartSearchQuery(
                text: "report",
                roots: [root.url],
                includeDirectories: false,
                maximumResults: 1
            )
        )

        #expect(results.count == 1)
        #expect(await availability.requestedURLs().count == SmartSearchQuery.minimumCandidateBudget)
    }

    @Test func cancellationAfterAnAvailabilityWaitStopsTheSearch() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        try write("report", to: root.url.appending(path: "report.txt"))
        let availability = DelayingAvailabilityReader()
        let service = LocalSmartSearchService(availabilityReader: availability)
        let task = Task {
            try await service.search(try SmartSearchQuery(text: "report", roots: [root.url]))
        }
        await availability.waitUntilStarted()

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func scopedAccessLeaseIsReleasedAfterSearch() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        try write("report", to: root.url.appending(path: "report.txt"))
        let driver = RecordingScopedAccessDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([root.url])

        _ = try await LocalSmartSearchService(scopedAccessCoordinator: coordinator).search(
            try SmartSearchQuery(text: "report", roots: [root.url])
        )

        #expect(driver.startCount == 1)
        #expect(driver.stopCount == 1)
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

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
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
