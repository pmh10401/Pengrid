import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct SmartSearchStoreTests {
    @Test func newerSearchReplacesOlderGenerationAndIgnoresItsLateResults() async throws {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(service: service, persistence: WorkspacePersistence(defaults: isolatedDefaults()))
        let root = URL(filePath: "/search", directoryHint: .isDirectory)

        store.present(for: root)
        store.queryText = "old"
        store.search()
        await service.waitForFirstRequest()

        store.queryText = "new"
        store.search()
        await waitForStore { store.results.map(\.item.name) == ["new.txt"] }
        await service.releaseFirstRequest()
        await Task.yield()

        #expect(store.results.map(\.item.name) == ["new.txt"])
        #expect(store.state == .results)
    }

    @Test func emptyQueryClearsResultsWithoutCallingService() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(service: service, persistence: WorkspacePersistence(defaults: isolatedDefaults()))

        store.present(for: URL(filePath: "/search", directoryHint: .isDirectory))
        store.queryText = "   "
        store.search()
        await Task.yield()

        #expect(await service.requestCount() == 0)
        #expect(store.results.isEmpty)
        #expect(store.state == .idle)
    }

    @Test func overlyComplexQueryFailsClearlyWithoutCallingService() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: WorkspacePersistence(defaults: isolatedDefaults())
        )
        store.present(for: URL(filePath: "/search", directoryHint: .isDirectory))
        store.queryText = String(
            repeating: "a",
            count: SmartSearchQuery.maximumTextScalarCount + 1
        )

        store.search()
        await Task.yield()

        #expect(await service.requestCount() == 0)
        #expect(store.state == .failed)
        #expect(store.errorMessage == "Search is too long. Use fewer terms.")
    }

    @Test func queryWithoutSearchableTermsFailsBeforeCallingService() async {
        let service = ReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: WorkspacePersistence(defaults: isolatedDefaults())
        )
        store.present(for: URL(filePath: "/search", directoryHint: .isDirectory))
        store.queryText = "---"

        store.search()
        await Task.yield()

        #expect(await service.requestCount() == 0)
        #expect(store.state == .failed)
        #expect(store.errorMessage == "Search needs a filename, path, or Korean initials.")
    }

    @Test func invalidQueriesCannotBeSaved() {
        let store = SmartSearchStore(
            service: ReplacingSearchService(),
            persistence: WorkspacePersistence(defaults: isolatedDefaults())
        )
        store.present(for: URL(filePath: "/search", directoryHint: .isDirectory))

        for text in [
            "---",
            String(repeating: "a", count: SmartSearchQuery.maximumTextScalarCount + 1)
        ] {
            store.queryText = text
            #expect(!store.canSaveCurrentSearch)
            #expect(store.saveCurrentSearch(named: "Keep this draft") == nil)
        }
        #expect(store.savedSearches.isEmpty)
    }

    @Test func cancellationAndFailureProduceVisibleTerminalStates() async {
        let service = CancellingThenFailingSearchService()
        let store = SmartSearchStore(service: service, persistence: WorkspacePersistence(defaults: isolatedDefaults()))

        store.present(for: URL(filePath: "/search", directoryHint: .isDirectory))
        store.queryText = "cancel"
        store.search()
        await waitForStore { store.state == .searching }
        #expect(store.progressMessage == "Searching files…")
        store.cancelSearch()
        await waitForStore { store.state == .cancelled }
        #expect(store.progressMessage == nil)

        store.queryText = "fail"
        store.search()
        await waitForStore { store.errorMessage != nil }

        #expect(store.state == .failed)
        #expect(store.errorMessage == "Search failed.")
    }

    @Test func examinedEntryProgressIsPublishedAndStaleGenerationProgressIsRejected() async {
        let service = ProgressReplacingSearchService()
        let store = SmartSearchStore(
            service: service,
            persistence: WorkspacePersistence(defaults: isolatedDefaults())
        )
        store.present(for: URL(filePath: "/search", directoryHint: .isDirectory))
        store.queryText = "old"
        store.search()
        await service.waitForFirstRequest()
        await service.reportProgress(3, forRequest: 1)
        await waitForStore { store.examinedEntryCount == 3 }

        #expect(store.progressMessage == "Examined 3 entries…")

        store.queryText = "new"
        store.search()
        await waitForStore { store.results.map(\.item.name) == ["new.txt"] }
        await service.reportProgress(99, forRequest: 1)
        await Task.yield()

        #expect(store.examinedEntryCount == 7)
        #expect(store.results.map(\.item.name) == ["new.txt"])
        await service.releaseFirstRequest()
    }

    @Test func burstProgressKeepsOnlyTheNewestPendingCount() async {
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

    @Test func openingPersistedSavedSearchRestoresAndUsesItsNonDefaultResultCap() async throws {
        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let savingStore = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)
        savingStore.present(for: URL(filePath: "/search", directoryHint: .isDirectory))
        savingStore.queryText = "report"
        savingStore.maximumResults = 37
        _ = try #require(savingStore.saveCurrentSearch(named: "Capped reports"))

        let service = QueryCapturingSearchService()
        let relaunchedStore = SmartSearchStore(service: service, persistence: persistence)
        let record = try #require(relaunchedStore.savedSearches.first)
        relaunchedStore.openSavedSearch(record)
        await service.waitForRequest()

        #expect(relaunchedStore.maximumResults == 37)
        #expect(await service.lastQuery()?.maximumResults == 37)
    }

    @Test func addingAndRemovingRootsKeepsOnlyExplicitExactSelections() {
        let store = SmartSearchStore(
            service: ReplacingSearchService(),
            persistence: WorkspacePersistence(defaults: isolatedDefaults())
        )
        let parent = URL(filePath: "/search", directoryHint: .isDirectory)
        let child = parent.appending(path: "nested", directoryHint: .isDirectory)
        store.present(for: parent)

        store.addRoots([child, child.appending(path: ".", directoryHint: .isDirectory)])
        #expect(store.roots == [parent.standardizedFileURL, child.standardizedFileURL])

        store.removeRoot(parent)
        #expect(store.roots == [child.standardizedFileURL])
    }

    @Test func savedSearchCrudPreservesInsertionOrderAcrossRelaunch() throws {
        let persistence = WorkspacePersistence(defaults: isolatedDefaults())
        let root = URL(filePath: "/search", directoryHint: .isDirectory)
        let store = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)
        store.present(for: root)
        store.queryText = "first"
        let first = try #require(store.saveCurrentSearch(named: "First"))
        store.queryText = "second"
        let second = try #require(store.saveCurrentSearch(named: "Second"))

        #expect(store.renameSavedSearch(id: first.id, to: "Renamed"))
        #expect(store.savedSearches.map(\.displayName) == ["Renamed", "Second"])
        #expect(store.deleteSavedSearch(id: first.id))
        #expect(store.savedSearches.map(\.id) == [second.id])

        let relaunched = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)
        #expect(relaunched.savedSearches.map(\.displayName) == ["Second"])
    }
}

private actor ReplacingSearchService: SmartSearching {
    private var count = 0
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRequestStarted = false

    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        count += 1
        if count == 1 {
            firstRequestStarted = true
            await withCheckedContinuation { firstRequestWaiters.append($0) }
            return [searchResult(named: "old.txt")]
        }
        return [searchResult(named: "new.txt")]
    }

    func requestCount() -> Int { count }

    func waitForFirstRequest() async {
        while !firstRequestStarted { await Task.yield() }
    }

    func releaseFirstRequest() {
        firstRequestWaiters.forEach { $0.resume() }
        firstRequestWaiters = []
    }
}

private actor CancellingThenFailingSearchService: SmartSearching {
    private var count = 0

    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        count += 1
        if count == 1 {
            try await Task.sleep(for: .seconds(30))
            return []
        }
        throw SmartSearchServiceError.invalidRoot
    }
}

private actor ProgressReplacingSearchService: SmartSearching {
    private var requestCount = 0
    private var progressCallbacks: [Int: @Sendable (Int) -> Void] = [:]
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        []
    }

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        requestCount += 1
        let request = requestCount
        progressCallbacks[request] = progress
        if request == 1 {
            await withCheckedContinuation { firstRequestWaiters.append($0) }
            return [searchResult(named: "old.txt")]
        }
        progress(7)
        return [searchResult(named: "new.txt")]
    }

    func waitForFirstRequest() async {
        while progressCallbacks[1] == nil { await Task.yield() }
    }

    func reportProgress(_ count: Int, forRequest request: Int) {
        progressCallbacks[request]?(count)
    }

    func releaseFirstRequest() {
        firstRequestWaiters.forEach { $0.resume() }
        firstRequestWaiters = []
    }
}

private actor QueryCapturingSearchService: SmartSearching {
    private var queries: [SmartSearchQuery] = []

    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        queries.append(query)
        return []
    }

    func waitForRequest() async {
        while queries.isEmpty { await Task.yield() }
    }

    func lastQuery() -> SmartSearchQuery? {
        queries.last
    }
}

private func searchResult(named name: String) -> SmartSearchResult {
    SmartSearchResult(
        item: FileItem(url: URL(filePath: "/search/\(name)"), name: name, isDirectory: false, isPackage: false, modifiedAt: nil, byteSize: nil, typeDescription: "Text"),
        relativePath: name,
        score: 1
    )
}

private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "SmartSearchStoreTests.\(UUID().uuidString)")!
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
