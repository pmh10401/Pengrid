import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ContentAwareSmartSearchServiceTests {
    @Test func optedOutQueryUsesOnlyLocalBackend() async throws {
        let local = RecordingLocalSmartSearchService(
            results: [contentAwareResult(name: "annual.txt", path: "/search/annual.txt")],
            progressValues: [1, 2]
        )
        let spotlight = RecordingSpotlightContentSearch()
        let progress = LockedContentAwareValues<Int>()
        let coverage = LockedContentAwareValues<SmartSearchCoverage>()
        let service = ContentAwareSmartSearchService(local: local, spotlight: spotlight)

        let results = try await service.search(
            try SmartSearchQuery(text: "annual", roots: [URL(filePath: "/search")]),
            progress: { progress.append($0) },
            coverage: { coverage.append($0) }
        )

        #expect(results.map(\.item.name) == ["annual.txt"])
        #expect(progress.values == [1, 2])
        #expect(coverage.values == [.namesAndPathsOnly])
        #expect(await local.searchCount == 1)
        #expect(await spotlight.searchCount == 0)
    }

    @Test func literalOptInMergesDeduplicatesAndRanksLocalAndIndexedResults() async throws {
        let localDuplicate = contentAwareResult(
            name: "annual.txt",
            path: "/search/folder/../folder/annual.txt",
            identity: "local"
        )
        let indexedDuplicate = contentAwareResult(
            name: "annual.txt",
            path: "/search/folder/annual.txt",
            identity: "indexed"
        )
        let indexedOnly = contentAwareResult(
            name: "notes.txt",
            path: "/search/folder/notes.txt",
            identity: "content"
        )
        let local = RecordingLocalSmartSearchService(results: [localDuplicate])
        let spotlight = RecordingSpotlightContentSearch(results: [indexedDuplicate, indexedOnly])
        let coverage = LockedContentAwareValues<SmartSearchCoverage>()
        let service = ContentAwareSmartSearchService(
            local: local,
            spotlight: spotlight,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        let query = try SmartSearchQuery(
            text: "annual",
            roots: [URL(filePath: "/search")],
            searchIndexedContents: true
        )

        let results = try await service.search(
            query,
            progress: { _ in },
            coverage: { coverage.append($0) }
        )

        #expect(results.map(\.item.name) == ["annual.txt", "notes.txt"])
        #expect(results.first?.identity.entryIdentifier == "local")
        #expect((results.first?.score ?? 0) > (results.last?.score ?? 0))
        #expect(coverage.values == [.indexedContentsIncluded])
        #expect(await spotlight.searchCount == 1)
    }

    @Test func fullLocalCandidateBudgetCannotStarveAnIndexedExactMatch() async throws {
        let localResults = (0..<2_000).map { index in
            contentAwareResult(
                name: "local-\(index).txt",
                path: "/search/local-\(index).txt"
            )
        }
        let indexedExactMatch = contentAwareResult(
            name: "annual",
            path: "/search/indexed-result.txt",
            identity: "indexed-exact-match"
        )
        let service = ContentAwareSmartSearchService(
            local: RecordingLocalSmartSearchService(results: localResults),
            spotlight: RecordingSpotlightContentSearch(results: [indexedExactMatch]),
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        let results = try await service.search(
            try SmartSearchQuery(
                text: "annual",
                roots: [URL(filePath: "/search")],
                maximumResults: 1,
                searchIndexedContents: true
            )
        )

        #expect(results.map(\.identity.entryIdentifier) == ["indexed-exact-match"])
    }

    @Test func initialQuerySkipsSpotlightAndPublishesSkippedCoverage() async throws {
        let expected = contentAwareResult(name: "보고서.txt", path: "/search/보고서.txt")
        let local = RecordingLocalSmartSearchService(results: [expected])
        let spotlight = RecordingSpotlightContentSearch()
        let coverage = LockedContentAwareValues<SmartSearchCoverage>()
        let service = ContentAwareSmartSearchService(local: local, spotlight: spotlight)

        let results = try await service.search(
            try SmartSearchQuery(
                text: "annual ㅂㄱ",
                roots: [URL(filePath: "/search")],
                searchIndexedContents: true
            ),
            progress: { _ in },
            coverage: { coverage.append($0) }
        )

        #expect(results == [expected])
        #expect(coverage.values == [.indexedContentsSkippedForInitialQuery])
        #expect(await spotlight.searchCount == 0)
    }

    @Test func spotlightFailureReturnsLocalResultsAndUnavailableCoverage() async throws {
        let expected = contentAwareResult(name: "annual.txt", path: "/search/annual.txt")
        let local = RecordingLocalSmartSearchService(results: [expected])
        let spotlight = RecordingSpotlightContentSearch(error: ContentAwareFixtureError.spotlightUnavailable)
        let coverage = LockedContentAwareValues<SmartSearchCoverage>()
        let service = ContentAwareSmartSearchService(local: local, spotlight: spotlight)

        let results = try await service.search(
            try SmartSearchQuery(
                text: "annual",
                roots: [URL(filePath: "/search")],
                searchIndexedContents: true
            ),
            progress: { _ in },
            coverage: { coverage.append($0) }
        )

        #expect(results == [expected])
        #expect(coverage.values == [.indexedContentsUnavailable])
    }

    @Test func timeoutCancelsSpotlightAndReturnsLocalResults() async throws {
        let expected = contentAwareResult(name: "annual.txt", path: "/search/annual.txt")
        let local = RecordingLocalSmartSearchService(results: [expected])
        let spotlight = SuspendedSpotlightContentSearch()
        let sleptDurations = LockedContentAwareValues<Duration>()
        let coverage = LockedContentAwareValues<SmartSearchCoverage>()
        let service = ContentAwareSmartSearchService(
            local: local,
            spotlight: spotlight,
            sleep: { duration in
                sleptDurations.append(duration)
                await spotlight.waitUntilStarted()
            }
        )

        let results = try await service.search(
            try SmartSearchQuery(
                text: "annual",
                roots: [URL(filePath: "/search")],
                searchIndexedContents: true
            ),
            progress: { _ in },
            coverage: { coverage.append($0) }
        )

        #expect(results == [expected])
        #expect(sleptDurations.values == [.seconds(5)])
        #expect(await spotlight.wasCancelled)
        #expect(coverage.values == [.indexedContentsUnavailable])
    }

    @Test func callerCancellationCancelsBothBackendsAndThrows() async throws {
        let local = SuspendedLocalSmartSearchService()
        let spotlight = SuspendedSpotlightContentSearch()
        let service = ContentAwareSmartSearchService(
            local: local,
            spotlight: spotlight,
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        let query = try SmartSearchQuery(
            text: "annual",
            roots: [URL(filePath: "/search")],
            searchIndexedContents: true
        )
        let task = Task {
            try await service.search(
                query,
                progress: { _ in },
                coverage: { _ in }
            )
        }
        await local.waitUntilStarted()
        await spotlight.waitUntilStarted()

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await local.wasCancelled)
        #expect(await spotlight.wasCancelled)
    }
}

private actor RecordingLocalSmartSearchService: SmartSearching {
    private let results: [SmartSearchResult]
    private let progressValues: [Int]
    private(set) var searchCount = 0

    init(results: [SmartSearchResult], progressValues: [Int] = []) {
        self.results = results
        self.progressValues = progressValues
    }

    func search(
        _: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        searchCount += 1
        progressValues.forEach(progress)
        return results
    }
}

private actor RecordingSpotlightContentSearch: SpotlightContentSearching {
    private let results: [SmartSearchResult]
    private let error: (any Error & Sendable)?
    private(set) var searchCount = 0

    init(
        results: [SmartSearchResult] = [],
        error: (any Error & Sendable)? = nil
    ) {
        self.results = results
        self.error = error
    }

    func searchIndexedContents(_: SmartSearchQuery) async throws -> [SmartSearchResult] {
        searchCount += 1
        if let error { throw error }
        return results
    }
}

private actor SuspendedLocalSmartSearchService: SmartSearching {
    private(set) var started = false
    private(set) var wasCancelled = false

    func search(
        _: SmartSearchQuery,
        progress _: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            return []
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private actor SuspendedSpotlightContentSearch: SpotlightContentSearching {
    private(set) var started = false
    private(set) var wasCancelled = false

    func searchIndexedContents(_: SmartSearchQuery) async throws -> [SmartSearchResult] {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            return []
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private final class LockedContentAwareValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Value] = []

    var values: [Value] {
        lock.withLock { storedValues }
    }

    func append(_ value: Value) {
        lock.withLock { storedValues.append(value) }
    }
}

private enum ContentAwareFixtureError: Error, Sendable {
    case spotlightUnavailable
}

private func contentAwareResult(
    name: String,
    path: String,
    identity: String? = nil
) -> SmartSearchResult {
    let url = URL(filePath: path)
    let identifier = identity ?? path
    return SmartSearchResult(
        item: FileItem(
            url: url,
            name: name,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        ),
        relativePath: name,
        score: 0,
        identity: FileIdentity(
            entryIdentifier: identifier,
            resolvedIdentifier: identifier
        )
    )
}
