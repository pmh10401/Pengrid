import Foundation
import Testing
@testable import BloomFileManager

@Suite("Shelf state and retention", .serialized)
@MainActor
struct ShelfStoreTests {
    @Test func failedRestoreRetryPreservesSnapshotUntilAValidRestore() async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        fixture.defaults.set(true, forKey: ShelfStore.enabledKey)
        fixture.defaults.set(ShelfRetention.keepBetweenLaunches.rawValue, forKey: ShelfStore.retentionKey)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        let damaged = Data("damaged snapshot fixture".utf8)
        try damaged.write(to: fixture.snapshot)
        let store = fixture.makeStore()
        await store.start()
        store.retryPersistence()
        #expect(await store.flushPersistence() == false)
        #expect(try Data(contentsOf: fixture.snapshot) == damaged)
        #expect(await store.prepareForTermination() == false)
        let items = [ShelfItem(content: .text("repaired fixture"))]
        try await ShelfPersistence(root: fixture.root).save(items)
        store.retryPersistence()
        #expect(await store.flushPersistence())
        #expect(store.entries == items)
    }

    @Test func prepareForTerminationStartsOptInStoreAndPreservesSnapshot() async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        fixture.defaults.set(true, forKey: ShelfStore.enabledKey)
        fixture.defaults.set(ShelfRetention.keepBetweenLaunches.rawValue, forKey: ShelfStore.retentionKey)
        let item = ShelfItem(
            id: UUID(uuidString: "D4C0B5B7-0B7B-4A5B-8D55-7CF2B15A2D8F")!,
            content: .text("saved before explicit start"),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        try await ShelfPersistence(root: fixture.root).save([item])
        let originalSnapshot = try PropertyListDecoder().decode(
            ShelfSnapshotValues.self,
            from: Data(contentsOf: fixture.snapshot)
        )

        let store = fixture.makeStore()
        #expect(await store.prepareForTermination())
        #expect(FileManager.default.fileExists(atPath: fixture.snapshot.path))
        let preservedSnapshot = try PropertyListDecoder().decode(
            ShelfSnapshotValues.self,
            from: Data(contentsOf: fixture.snapshot)
        )
        #expect(preservedSnapshot.version == originalSnapshot.version)
        #expect(preservedSnapshot.items == originalSnapshot.items)

        let reopened = fixture.makeStore()
        await reopened.start()
        #expect(reopened.entries == [item])
    }

    @Test func clearDuringPendingRestoreCannotResurrectSnapshot() async throws {
        try await assertPendingRestoreMutation(.clear, expectedEnabled: true)
    }

    @Test func disableDuringPendingRestoreCannotResurrectSnapshot() async throws {
        try await assertPendingRestoreMutation(.disable, expectedEnabled: false)
    }

    @Test func clearDuringPendingSaveCannotCommitSnapshot() async throws {
        try await assertPendingSaveMutation(.clear, expectedEnabled: true)
    }

    @Test func disableDuringPendingSaveCannotCommitSnapshot() async throws {
        try await assertPendingSaveMutation(.disable, expectedEnabled: false)
    }

    @Test func defaultSessionModeDoesNotSaveAndRestartIsEmpty() async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.start()
        #expect(!store.isEnabled)
        store.setEnabled(true)
        await store.add([ShelfItem(content: .text("session fixture"))])
        #expect(store.entries.count == 1)
        #expect(await store.flushPersistence())
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        let reopened = fixture.makeStore()
        await reopened.start()
        #expect(reopened.isEnabled)
        #expect(reopened.entries.isEmpty)
        #expect(reopened.retention == .clearOnQuit)
    }

    @Test func retentionRestoresThenSwitchToClearErasesDiskButKeepsSession() async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.start()
        store.setEnabled(true)
        store.setRetention(.keepBetweenLaunches)
        let item = ShelfItem(content: .text("saved fixture"))
        await store.add([item])
        #expect(await store.flushPersistence())
        let reopened = fixture.makeStore()
        await reopened.start()
        #expect(reopened.entries == [item])
        reopened.setRetention(.clearOnQuit)
        #expect(await reopened.flushPersistence())
        #expect(reopened.entries == [item])
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    @Test func clearAndDisableWinOverPendingImportAndQueuedSaves() async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.start()
        store.setEnabled(true)
        store.setRetention(.keepBetweenLaunches)
        await store.add([ShelfItem(content: .text("one"))])
        let token = try #require(store.beginImport())
        store.clear()
        await store.completeImport([ShelfItem(content: .text("must not return"))], token: token)
        #expect(await store.flushPersistence())
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        await store.add([ShelfItem(content: .text("two"))])
        store.setEnabled(false)
        #expect(await store.flushPersistence())
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    @Test func searchKeepsOnlyLatestQueryAndKind() async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.start()
        store.setEnabled(true)
        let text = ShelfItem(content: .text("보고서 final"))
        let file = ShelfItem(content: .file(URL(fileURLWithPath: "/tmp/보고서.txt")))
        await store.add([text, file])
        store.query = "missing"
        store.query = "ㅂㄱㅅ"
        store.kind = .text
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.isSearching && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.filteredEntries.map(\.id) == [text.id])
        store.clear()
        #expect(store.filteredEntries.isEmpty)
        #expect(store.query.isEmpty)
    }

    @Test func failedPersistencePreventsSilentQuitAndCanRetry() async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        try Data("not a directory".utf8).write(to: fixture.root)
        let store = fixture.makeStore()
        await store.start()
        store.setEnabled(true)
        store.setRetention(.keepBetweenLaunches)
        await store.add([ShelfItem(content: .text("save failure fixture"))])
        #expect(await store.prepareForTermination() == false)
        #expect(store.persistenceError != nil)
        #expect(store.entries.count == 1)
        try FileManager.default.removeItem(at: fixture.root)
        store.retryPersistence()
        #expect(await store.prepareForTermination())
        #expect(store.persistenceError == nil)
    }

    private func assertPendingRestoreMutation(
        _ mutation: ShelfMutation,
        expectedEnabled: Bool
    ) async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        fixture.defaults.set(true, forKey: ShelfStore.enabledKey)
        fixture.defaults.set(ShelfRetention.keepBetweenLaunches.rawValue, forKey: ShelfStore.retentionKey)

        let item = ShelfItem(content: .text("restore gate fixture"))
        let disk = ShelfPersistence(root: fixture.root)
        try await disk.save([item])
        let gated = GatedShelfPersistence(disk: disk, gateLoad: true)

        let store = fixture.makeStore(persistence: gated)
        let startTask = Task { await store.start() }
        await gated.waitForLoadEntry()
        #expect(await gated.loadedItems() == [item])

        apply(mutation, to: store)
        await gated.releaseLoad()
        await startTask.value
        #expect(await store.flushPersistence())
        #expect(store.entries.isEmpty)
        #expect(store.isEnabled == expectedEnabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    private func assertPendingSaveMutation(
        _ mutation: ShelfMutation,
        expectedEnabled: Bool
    ) async throws {
        let fixture = try ShelfStoreFixture()
        defer { fixture.remove() }
        fixture.defaults.set(true, forKey: ShelfStore.enabledKey)
        fixture.defaults.set(ShelfRetention.keepBetweenLaunches.rawValue, forKey: ShelfStore.retentionKey)

        let disk = ShelfPersistence(root: fixture.root)
        let gated = GatedShelfPersistence(disk: disk, gateLoad: false)
        let store = fixture.makeStore(persistence: gated)
        await store.start()
        await store.add([ShelfItem(content: .text("save gate fixture"))])
        await gated.waitForSaveEntry()

        apply(mutation, to: store)
        await gated.releaseSave()
        #expect(await store.flushPersistence())
        #expect(store.entries.isEmpty)
        #expect(store.isEnabled == expectedEnabled)
        #expect(await gated.saveCommitCount() == 0)
        #expect(await gated.removeCallCount() > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    private func apply(_ mutation: ShelfMutation, to store: ShelfStore) {
        switch mutation {
        case .clear:
            store.clear()
        case .disable:
            store.setEnabled(false)
        }
    }
}

@MainActor
private struct ShelfStoreFixture {
    let outer: URL
    let suite: String
    let defaults: UserDefaults
    var root: URL { outer.appendingPathComponent("Shelf") }
    var snapshot: URL { root.appendingPathComponent("snapshot.plist") }
    init() throws {
        outer = FileManager.default.temporaryDirectory.appendingPathComponent("pengrid-shelf-store-test-\(UUID())")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: false)
        suite = "pengrid.shelf.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    func makeStore() -> ShelfStore { ShelfStore(defaults: defaults, persistence: ShelfPersistence(root: root)) }
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: outer)
    }
    func makeStore(persistence: any ShelfPersisting) -> ShelfStore {
        ShelfStore(defaults: defaults, persistence: persistence)
    }
}

private enum ShelfMutation {
    case clear
    case disable
}

private struct ShelfSnapshotValues: Codable {
    let version: Int
    let items: [ShelfItem]
}

private actor GatedShelfPersistence: ShelfPersisting {
    private let disk: ShelfPersistence
    private let gateLoad: Bool
    private var loadEntered = false
    private var loadReleased = false
    private var loadEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var capturedItems: [ShelfItem] = []
    private var saveEntered = false
    private var saveReleased = false
    private var saveEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var committedSaveCount = 0
    private var completedRemoveCount = 0

    init(disk: ShelfPersistence, gateLoad: Bool) {
        self.disk = disk
        self.gateLoad = gateLoad
    }

    func load() async throws -> [ShelfItem] {
        let items = try await disk.load()
        guard gateLoad else { return items }

        capturedItems = items
        loadEntered = true
        resume(&loadEntryWaiters)
        await waitForLoadRelease()
        return items
    }

    func save(_ items: [ShelfItem]) async throws {
        if !items.isEmpty, !saveEntered {
            saveEntered = true
            resume(&saveEntryWaiters)
            await waitForSaveRelease()
        }
        try Task.checkCancellation()
        try await disk.save(items)
        if !items.isEmpty { committedSaveCount += 1 }
    }

    func remove() async throws {
        try Task.checkCancellation()
        try await disk.remove()
        completedRemoveCount += 1
    }

    func waitForLoadEntry() async {
        if loadEntered { return }
        await withCheckedContinuation { continuation in
            if loadEntered { continuation.resume() }
            else { loadEntryWaiters.append(continuation) }
        }
    }

    func releaseLoad() {
        loadReleased = true
        resume(&loadReleaseWaiters)
    }

    func loadedItems() -> [ShelfItem] { capturedItems }

    func waitForSaveEntry() async {
        if saveEntered { return }
        await withCheckedContinuation { continuation in
            if saveEntered { continuation.resume() }
            else { saveEntryWaiters.append(continuation) }
        }
    }

    func releaseSave() {
        saveReleased = true
        resume(&saveReleaseWaiters)
    }

    func saveCommitCount() -> Int { committedSaveCount }
    func removeCallCount() -> Int { completedRemoveCount }

    private func waitForLoadRelease() async {
        if loadReleased { return }
        await withCheckedContinuation { continuation in
            if loadReleased { continuation.resume() }
            else { loadReleaseWaiters.append(continuation) }
        }
    }

    private func waitForSaveRelease() async {
        if saveReleased { return }
        await withCheckedContinuation { continuation in
            if saveReleased { continuation.resume() }
            else { saveReleaseWaiters.append(continuation) }
        }
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
