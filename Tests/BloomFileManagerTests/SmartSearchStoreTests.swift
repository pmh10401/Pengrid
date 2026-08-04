import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct SmartSearchStoreTests {
    @Test func staleSearchCannotReplaceNewerResults() async throws {
        let service = ReplacingSearchService()
        let persistence = RecordingSmartSearchPersistence(data: nil)
        let store = SmartSearchStore(service: service, persistence: persistence)
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "old"
        store.submit()
        await service.waitForRequestCount(1)
        store.queryText = "new"
        store.submit()
        await service.waitForRequestCount(2)

        let oldResult = searchResult(name: "old.txt")
        let newResult = searchResult(name: "new.txt")
        await service.finish(request: 1, with: [newResult])
        await waitForStore { store.results == [newResult] }
        await service.finish(request: 0, with: [oldResult])
        await Task.yield()

        #expect(store.results == [newResult])
        #expect(store.phase == .results)
    }

    @Test func cancellationDoesNotPublishCompletedPartialResults() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "partial"
        store.submit()
        await service.waitForRequestCount(1)

        store.cancel()
        await service.finish(request: 0, with: [searchResult(name: "partial.txt")])
        await waitForStore { store.phase == .cancelled }

        #expect(store.results.isEmpty)
        #expect(store.phase == .cancelled)
    }

    @Test func dismissalPreservesSearchDraftAndResults() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        let root = URL(fileURLWithPath: "/new")
        let result = searchResult(name: "kept.txt")
        store.present(initialRoot: root)
        store.queryText = "kept"
        store.submit()
        await service.waitForRequestCount(1)
        await service.finish(request: 0, with: [result])
        await waitForStore { store.results == [result] }

        store.dismiss()

        #expect(!store.isPresented)
        #expect(store.queryText == "kept")
        #expect(store.roots == [root.standardizedFileURL])
        #expect(store.results == [result])
    }

    @Test func reopeningAfterDismissalRestoresTheRetainedSearchState() async throws {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        let initialRoot = URL(fileURLWithPath: "/initial")
        let additionalRoot = URL(fileURLWithPath: "/additional")
        let filter = try SmartSearchMetadataFilter(kind: .files, extensionText: "pdf")
        let result = searchResult(name: "kept.pdf")
        store.present(initialRoot: initialRoot)
        store.addRoots([additionalRoot])
        store.queryText = "kept"
        store.metadata = filter
        store.sort = .size
        store.submit()
        await service.waitForRequestCount(1)
        await service.finish(request: 0, with: [result])
        await waitForStore { store.phase == .results }

        store.dismiss()
        store.present(initialRoot: URL(fileURLWithPath: "/replacement"))

        #expect(store.isPresented)
        #expect(store.queryText == "kept")
        #expect(store.roots == [initialRoot.standardizedFileURL, additionalRoot.standardizedFileURL])
        #expect(store.metadata == filter)
        #expect(store.sort == .size)
        #expect(store.results == [result])
    }

    @Test func staleErrorAndProgressCannotReplaceNewerResultState() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "old"
        store.submit()
        await service.waitForRequestCount(1)
        await service.reportProgress(3, forRequest: 0)
        await waitForStore { store.examinedEntryCount == 3 }

        store.queryText = "new"
        store.submit()
        await service.waitForRequestCount(2)
        let result = searchResult(name: "new.txt")
        await service.finish(request: 1, with: [result])
        await waitForStore { store.phase == .results }
        await service.reportProgress(99, forRequest: 0)
        await service.fail(request: 0)
        await Task.yield()

        #expect(store.results == [result])
        #expect(store.phase == .results)
        #expect(store.examinedEntryCount == 0)
        #expect(store.errorMessage == nil)
    }

    @Test func dismissCancelsAnActiveSearchWithoutPublishingItsResult() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "active"
        store.submit()
        await service.waitForRequestCount(1)

        store.dismiss()
        await service.finish(request: 0, with: [searchResult(name: "late.txt")])
        await Task.yield()

        #expect(!store.isPresented)
        #expect(store.phase == .cancelled)
        #expect(store.results.isEmpty)
    }

    @Test func undecodableSavedSearchBytesRemainUntouched() {
        let invalidData = Data("{".utf8)
        let persistence = RecordingSmartSearchPersistence(data: invalidData)
        let store = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)

        #expect(store.savedSearches.isEmpty)
        #expect(persistence.savedData == invalidData)
    }

    @Test func savingSearchIsTheExplicitMutationThatReplacesCorruptBytes() throws {
        let persistence = RecordingSmartSearchPersistence(data: Data("{".utf8))
        let store = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "report"

        let record = try #require(store.saveCurrentSearch(named: "Reports"))

        #expect(store.savedSearches == [record])
        #expect(try JSONDecoder().decode([SmartSearchRecord].self, from: try #require(persistence.savedData)) == [record])
    }

    @Test func metadataFilterEditsOverrideTheLegacyDirectoryToggleWhenSaving() throws {
        let store = SmartSearchStore(
            service: ReplacingSearchService(),
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "folder"
        store.includeDirectories = false
        store.metadata = try SmartSearchMetadataFilter(kind: .folders, extensionText: "")

        let saved = try #require(store.saveCurrentSearch(named: "Folders"))

        #expect(saved.query.metadata.kind == .folders)
        #expect(saved.query.includeDirectories)
    }

    @Test func openingAFolderSavedSearchRetainsItsMetadataAfterLegacyToggleWasChanged() throws {
        let store = SmartSearchStore(
            service: ReplacingSearchService(),
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.includeDirectories = false
        let record = SmartSearchRecord(
            displayName: "Folders",
            query: try SmartSearchQuery(
                text: "folder",
                roots: [URL(fileURLWithPath: "/new")],
                metadata: try SmartSearchMetadataFilter(kind: .folders, extensionText: "")
            )
        )

        store.openSavedSearch(record)
        store.dismiss()
        store.present(initialRoot: URL(fileURLWithPath: "/replacement"))

        #expect(store.metadata.kind == .folders)
        #expect(store.roots == [URL(fileURLWithPath: "/new").standardizedFileURL])
    }

    @Test func changingSortReordersCompletedResults() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: RecordingSmartSearchPersistence(data: nil)
        )
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "match"
        store.submit()
        await service.waitForRequestCount(1)
        let lowerScore = searchResult(name: "zebra.txt", score: 1)
        let higherScore = searchResult(name: "apple.txt", score: 2)
        await service.finish(request: 0, with: [lowerScore, higherScore])
        await waitForStore { store.phase == .results }

        store.sort = .name

        #expect(store.results.map(\.item.name) == ["apple.txt", "zebra.txt"])
    }

    @Test func everySortModeUsesItsPrimaryValueAndDeterministicTieBreakers() async {
        let values = [
            searchResult(name: "zebra.txt", relativePath: "same", score: 1, modifiedAt: .distantPast, byteSize: 1, path: "/fixture/zebra.txt", identity: "zebra"),
            searchResult(name: "apple.txt", relativePath: "same", score: 2, modifiedAt: .distantFuture, byteSize: 2, path: "/fixture/apple.txt", identity: "apple")
        ]
        let expectations: [(SmartSearchSort, [String])] = [
            (.score, ["apple.txt", "zebra.txt"]),
            (.name, ["apple.txt", "zebra.txt"]),
            (.modifiedAt, ["apple.txt", "zebra.txt"]),
            (.size, ["apple.txt", "zebra.txt"])
        ]

        for (sort, names) in expectations {
            let store = SmartSearchStore(
                service: StaticSearchService(values: values),
                persistence: RecordingSmartSearchPersistence(data: nil)
            )
            store.present(initialRoot: URL(fileURLWithPath: "/new"))
            store.queryText = "match"
            store.sort = sort
            store.submit()
            await waitForStore { store.phase == .results }
            #expect(store.results.map(\.item.name) == names)
        }

        let tied = [
            searchResult(name: "same", relativePath: "same", score: 1, modifiedAt: .distantPast, byteSize: 1, path: "/fixture/z", identity: "z"),
            searchResult(name: "same", relativePath: "same", score: 1, modifiedAt: .distantPast, byteSize: 1, path: "/fixture/a", identity: "z"),
            searchResult(name: "same", relativePath: "same", score: 1, modifiedAt: .distantPast, byteSize: 1, path: "/fixture/same", identity: "z"),
            searchResult(name: "same", relativePath: "same", score: 1, modifiedAt: .distantPast, byteSize: 1, path: "/fixture/same", identity: "a")
        ]
        let expectedTieOrder = ["/fixture/a:z", "/fixture/same:a", "/fixture/same:z", "/fixture/z:z"]

        for sort in SmartSearchSort.allCases {
            let store = SmartSearchStore(
                service: StaticSearchService(values: tied),
                persistence: RecordingSmartSearchPersistence(data: nil)
            )
            store.present(initialRoot: URL(fileURLWithPath: "/new"))
            store.queryText = "match"
            store.sort = sort
            store.submit()
            await waitForStore { store.phase == .results }
            #expect(store.results.map { "\($0.item.url.path):\($0.identity.entryIdentifier)" } == expectedTieOrder)
        }
    }

    @Test func progressRelayRetainsOnlyTheNewestQueuedValue() async {
        let relay = SmartSearchProgressRelay()
        for count in 1...10_000 {
            relay.yield(count)
        }
        relay.finish()

        var received: [Int] = []
        for await count in relay.stream {
            received.append(count)
        }

        #expect(received == [10_000])
    }

    @Test func finishingProgressRelayTerminatesAnAwaitingConsumer() async {
        let relay = SmartSearchProgressRelay()
        let consumer = Task {
            var iterator = relay.stream.makeAsyncIterator()
            _ = await iterator.next()
            return await iterator.next() == nil
        }
        relay.yield(1)
        await Task.yield()

        relay.finish()

        #expect(await consumer.value)
    }

    @Test func storeDeinitializationCancelsAnOwnerlessActiveSearch() async {
        let service = LifetimeSearchService()
        weak var releasedStore: SmartSearchStore?
        do {
            var store: SmartSearchStore? = SmartSearchStore(
                service: service,
                persistence: RecordingSmartSearchPersistence(data: nil)
            )
            releasedStore = store
            store?.present(initialRoot: URL(fileURLWithPath: "/new"))
            store?.queryText = "active"
            store?.submit()
            await service.waitForRequest()
            store = nil
        }

        await waitUntil { releasedStore == nil }
        await service.waitForCancellation()

        #expect(releasedStore == nil)
        #expect(await service.wasCancelled())
    }

    @Test func renamedAndDeletedSavedSearchesPersistAcrossRelaunch() throws {
        let persistence = RecordingSmartSearchPersistence(data: nil)
        let store = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)
        store.present(initialRoot: URL(fileURLWithPath: "/new"))
        store.queryText = "first"
        let first = try #require(store.saveCurrentSearch(named: "First"))
        store.queryText = "second"
        let second = try #require(store.saveCurrentSearch(named: "Second"))

        #expect(store.renameSavedSearch(id: first.id, to: "Renamed"))
        #expect(store.deleteSavedSearch(id: first.id))

        let relaunched = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)
        #expect(relaunched.savedSearches == [second])
    }
}

private actor ReplacingSearchService: SmartSearching {
    private var continuations: [CheckedContinuation<[SmartSearchResult], any Error>] = []
    private var progressCallbacks: [@Sendable (Int) -> Void] = []

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        progressCallbacks.append(progress)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitForRequestCount(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func finish(request index: Int, with results: [SmartSearchResult]) {
        continuations[index].resume(returning: results)
    }

    func fail(request index: Int) {
        continuations[index].resume(throwing: TestSearchError.failed)
    }

    func reportProgress(_ count: Int, forRequest index: Int) {
        progressCallbacks[index](count)
    }
}

private struct StaticSearchService: SmartSearching {
    let values: [SmartSearchResult]

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        values
    }
}

private actor LifetimeSearchService: SmartSearching {
    private var hasRequest = false
    private var cancellationObserved = false
    private var continuation: CheckedContinuation<Void, Never>?

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        hasRequest = true
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation = $0 }
        }, onCancel: {
            Task { await self.recordCancellation() }
        })
        return []
    }

    func waitForRequest() async {
        while !hasRequest { await Task.yield() }
    }

    func waitForCancellation() async {
        while !cancellationObserved { await Task.yield() }
    }

    func wasCancelled() -> Bool {
        cancellationObserved
    }

    private func recordCancellation() {
        cancellationObserved = true
    }
}

private enum TestSearchError: Error, Sendable {
    case failed
}

private final class RecordingSmartSearchPersistence: SmartSearchPersisting, @unchecked Sendable {
    private(set) var savedData: Data?

    init(data: Data?) {
        savedData = data
    }

    func load() -> Data? {
        savedData
    }

    func save(_ data: Data) {
        savedData = data
    }
}

private func searchResult(
    name: String,
    relativePath: String? = nil,
    score: Double = 1,
    modifiedAt: Date? = nil,
    byteSize: Int64 = 1,
    path: String? = nil,
    identity: String? = nil
) -> SmartSearchResult {
    let url = URL(filePath: path ?? "/fixture/\(name)")
    let identity = identity ?? name
    return SmartSearchResult(
        item: FileItem(url: url, name: name, isDirectory: false, isPackage: false, modifiedAt: modifiedAt, byteSize: byteSize, typeDescription: "File"),
        relativePath: relativePath ?? name,
        score: score,
        identity: FileIdentity(entryIdentifier: identity, resolvedIdentifier: identity)
    )
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for condition")
}

@MainActor
private func waitForStore(
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for smart search store state")
}
