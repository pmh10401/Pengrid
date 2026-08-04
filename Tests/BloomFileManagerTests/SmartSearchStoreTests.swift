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

        #expect(store.metadata.kind == .folders)
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
}

private actor ReplacingSearchService: SmartSearching {
    private var continuations: [CheckedContinuation<[SmartSearchResult], any Error>] = []

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitForRequestCount(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func finish(request index: Int, with results: [SmartSearchResult]) {
        continuations[index].resume(returning: results)
    }
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

private func searchResult(name: String, score: Double = 1) -> SmartSearchResult {
    let url = URL(filePath: "/fixture/\(name)")
    return SmartSearchResult(
        item: FileItem(url: url, name: name, isDirectory: false, isPackage: false, modifiedAt: nil, byteSize: 1, typeDescription: "File"),
        relativePath: name,
        score: score,
        identity: FileIdentity(entryIdentifier: name, resolvedIdentifier: name)
    )
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
