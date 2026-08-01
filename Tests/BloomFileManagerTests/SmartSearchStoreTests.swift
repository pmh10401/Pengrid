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
