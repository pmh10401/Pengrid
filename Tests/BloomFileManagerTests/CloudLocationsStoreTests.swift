import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct CloudLocationsStoreTests {
    @Test func overlappingRescansRejectAnOlderOutOfOrderResult() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let discovery = SequencedCloudLocationDiscovery()
        let store = fixture.store(discovery: discovery)
        let older = Task { try await store.rescan() }
        await discovery.waitForRequestCount(1)

        let newer = Task { try await store.rescan() }
        await discovery.waitForRequestCount(2)
        await discovery.completeRequest(1, with: [fixture.discovered("Newer", identity: Data([2]))])
        try await newer.value
        await discovery.completeRequest(0, with: [fixture.discovered("Older", identity: Data([1]))])
        try await older.value

        #expect(store.visibleLocations.map(\.displayName) == ["Newer"])
    }

    @Test func cancelledRescanCannotPublishAfterDiscoveryReturns() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let discovery = SequencedCloudLocationDiscovery()
        let store = fixture.store(discovery: discovery)
        let scan = Task { try await store.rescan() }
        await discovery.waitForRequestCount(1)

        scan.cancel()
        await discovery.completeRequest(0, with: [
            fixture.discovered("Cancelled", identity: Data([3]))
        ])

        await #expect(throws: CancellationError.self) {
            try await scan.value
        }
        #expect(store.visibleLocations.isEmpty)
    }

    @Test func initialScanIsIdempotentAcrossConcurrentWindowTasks() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let discovery = SequencedCloudLocationDiscovery()
        let store = fixture.store(discovery: discovery)
        let firstWindow = Task { try await store.scanInitially() }
        let secondWindow = Task { try await store.scanInitially() }
        await discovery.waitForRequestCount(1)

        await discovery.completeRequest(0, with: [
            fixture.discovered("Initial", identity: Data([4]))
        ])
        try await firstWindow.value
        try await secondWindow.value
        try await store.scanInitially()

        #expect(await discovery.requestCount == 1)
        #expect(store.visibleLocations.map(\.displayName) == ["Initial"])
    }

    @Test func manualBookmarkRegistersItsRootWithTheSharedAccessCoordinator() throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let driver = StoreSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let root = fixture.directory("Scoped Root")
        let store = fixture.store(
            discovery: MutableCloudLocationDiscovery([]),
            accessCoordinator: accessCoordinator
        )

        try store.addManualLocation(root)
        let acquiredLease = try accessCoordinator.acquireAccess(
            for: root.appending(path: "Child", directoryHint: .isDirectory)
        )
        let lease = try #require(acquiredLease)
        lease.finish()

        #expect(driver.startCount == 1)
        #expect(driver.stopCount == 1)
    }

    @Test func rescanMergesDiscoveryWithoutUnhidingAHiddenLocation() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let alpha = fixture.discovered("Alpha", identity: Data([1]))
        let beta = fixture.discovered("Beta", identity: Data([2]))
        let discovery = MutableCloudLocationDiscovery([alpha, beta])
        let store = fixture.store(discovery: discovery)

        try await store.rescan()
        try store.hide(alpha.id)
        discovery.setLocations([alpha, beta])
        try await store.rescan()

        #expect(store.visibleLocations.map(\.displayName) == ["Beta"])
        #expect(store.hiddenLocations.map(\.displayName) == ["Alpha"])

        let restored = fixture.store(discovery: discovery)
        try await restored.rescan()
        #expect(restored.visibleLocations.map(\.displayName) == ["Beta"])
        #expect(restored.hiddenLocations.map(\.displayName) == ["Alpha"])
    }

    @Test func renamedRootRefreshesPresentationWhenStableIdentityMatches() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let identity = Data([4, 2])
        let original = fixture.discovered("Original Root", identity: identity)
        let renamed = fixture.discovered("Renamed Root", identity: identity)
        let discovery = MutableCloudLocationDiscovery([original])
        let store = fixture.store(discovery: discovery)

        try await store.rescan()
        discovery.setLocations([renamed])
        try await store.rescan()

        #expect(store.visibleLocations.map(\.displayName) == ["Renamed Root"])
        #expect(store.visibleLocations.map(\.rootURL.lastPathComponent) == ["Renamed Root"])
        #expect(store.visibleLocations.count == 1)
    }

    @Test func unavailableKnownRootRemainsVisibleAfterRescan() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let known = fixture.discovered("Known Root", identity: Data([7]))
        let discovery = MutableCloudLocationDiscovery([known])
        let store = fixture.store(discovery: discovery)

        try await store.rescan()
        discovery.setLocations([])
        try await store.rescan()

        #expect(store.visibleLocations.map(\.displayName) == ["Known Root"])
        #expect(store.visibleLocations.map(\.rootURL.lastPathComponent) == ["Known Root"])
        #expect(store.visibleLocations.map(\.isAvailable) == [false])
    }

    @Test func manualBookmarkSurvivesRelaunchAndRefreshesWhenStale() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let original = fixture.directory("Manual Original")
        let refreshed = fixture.directory("Manual Refreshed")
        let bookmarking = InMemoryCloudLocationBookmarking()
        let discovery = MutableCloudLocationDiscovery([])
        let store = fixture.store(discovery: discovery, bookmarking: bookmarking)

        try store.addManualLocation(original)
        bookmarking.setResolvedPaths([original.path: refreshed.path])
        bookmarking.setStalePaths([original.path])

        let restored = fixture.store(discovery: discovery, bookmarking: bookmarking)
        try await restored.rescan()

        #expect(restored.visibleLocations.map(\.rootURL.lastPathComponent) == ["Manual Refreshed"])
        #expect(bookmarking.bookmarkCreationBasenames == ["Manual Original", "Manual Refreshed"])

        bookmarking.setStalePaths([])
        let relaunched = fixture.store(discovery: discovery, bookmarking: bookmarking)
        #expect(relaunched.visibleLocations.map(\.rootURL.lastPathComponent) == ["Manual Refreshed"])
    }

    @Test func duplicateManualRootDoesNotCreateASecondRecord() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let root = fixture.directory("Manual Root")
        let bookmarking = InMemoryCloudLocationBookmarking()
        let store = fixture.store(
            discovery: MutableCloudLocationDiscovery([]),
            bookmarking: bookmarking
        )

        try store.addManualLocation(root)
        try store.addManualLocation(root)

        #expect(store.visibleLocations.map(\.rootURL.lastPathComponent) == ["Manual Root"])
        let restored = fixture.store(
            discovery: MutableCloudLocationDiscovery([]),
            bookmarking: bookmarking
        )
        #expect(restored.visibleLocations.map(\.rootURL.lastPathComponent) == ["Manual Root"])
    }

    @Test func userDisplayOverrideSurvivesDiscoveryRenameAndRelaunch() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let identity = Data([9])
        let original = fixture.discovered("System Original", identity: identity)
        let renamed = fixture.discovered("System Renamed", identity: identity)
        let discovery = MutableCloudLocationDiscovery([original])
        let store = fixture.store(discovery: discovery)

        try await store.rescan()
        try store.renameLocation(original.id, to: "My Cloud")
        discovery.setLocations([renamed])
        try await store.rescan()

        #expect(store.visibleLocations.map(\.displayName) == ["My Cloud"])
        #expect(store.visibleLocations.map(\.rootURL.lastPathComponent) == ["System Renamed"])

        let restored = fixture.store(discovery: discovery)
        try await restored.rescan()
        #expect(restored.visibleLocations.map(\.displayName) == ["My Cloud"])
        #expect(restored.visibleLocations.map(\.rootURL.lastPathComponent) == ["System Renamed"])
    }

    @Test func reorderAndHidePersistAtomically() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let alpha = fixture.discovered("Alpha", identity: Data([1]))
        let beta = fixture.discovered("Beta", identity: Data([2]))
        let gamma = fixture.discovered("Gamma", identity: Data([3]))
        let discovery = MutableCloudLocationDiscovery([alpha, beta, gamma])
        let store = fixture.store(discovery: discovery)

        try await store.rescan()
        try store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        try store.hide(beta.id)

        #expect(store.visibleLocations.map(\.displayName) == ["Gamma", "Alpha"])
        #expect(store.hiddenLocations.map(\.displayName) == ["Beta"])

        let restored = fixture.store(discovery: discovery)
        try await restored.rescan()
        #expect(restored.visibleLocations.map(\.displayName) == ["Gamma", "Alpha"])
        #expect(restored.hiddenLocations.map(\.displayName) == ["Beta"])
    }

    @Test func malformedStorageFallsBackToDiscoveredLocations() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.storageURL)
        let discovered = fixture.discovered("Recovered Root", identity: Data([8]))
        let discovery = MutableCloudLocationDiscovery([discovered])
        let store = fixture.store(discovery: discovery)

        try await store.rescan()

        #expect(store.visibleLocations.map(\.displayName) == ["Recovered Root"])
        #expect(store.visibleLocations.map(\.rootURL.lastPathComponent) == ["Recovered Root"])
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.storageURL))
                as? [String: Any]
        )
        #expect(json["version"] as? Int == 1)
    }

    @Test func explicitUnhidePersistsWithoutAnotherDiscoveryResult() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let alpha = fixture.discovered("Alpha", identity: Data([1]))
        let discovery = MutableCloudLocationDiscovery([alpha])
        let store = fixture.store(discovery: discovery)
        try await store.rescan()
        try store.hide(alpha.id)

        try store.unhide(alpha.id)

        #expect(store.visibleLocations.map(\.displayName) == ["Alpha"])
        #expect(store.hiddenLocations.isEmpty)
        let restored = fixture.store(discovery: discovery)
        try await restored.rescan()
        #expect(restored.visibleLocations.map(\.displayName) == ["Alpha"])
        #expect(restored.hiddenLocations.isEmpty)
    }

    @Test func removingManualLocationPersistsAndUnregistersScopedAccess() throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let root = fixture.directory("Manual Removal")
        let bookmarking = InMemoryCloudLocationBookmarking()
        let driver = StoreSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let store = fixture.store(
            discovery: MutableCloudLocationDiscovery([]),
            bookmarking: bookmarking,
            accessCoordinator: accessCoordinator
        )
        try store.addManualLocation(root)
        let location = try #require(store.visibleLocations.first)
        #expect(try accessCoordinator.acquireAccess(for: root) != nil)

        try store.removeManualLocation(location.id)

        #expect(store.visibleLocations.isEmpty)
        #expect(try accessCoordinator.acquireAccess(for: root) == nil)
        let restored = fixture.store(
            discovery: MutableCloudLocationDiscovery([]),
            bookmarking: bookmarking
        )
        #expect(restored.visibleLocations.isEmpty)
        #expect(restored.hiddenLocations.isEmpty)
    }

    @Test func removingDiscoveredLocationIsRejectedWithoutChangingState() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let discovered = fixture.discovered("Discovered", identity: Data([0x55]))
        let store = fixture.store(discovery: MutableCloudLocationDiscovery([discovered]))
        try await store.rescan()

        #expect(throws: CloudLocationRemovalError.notManualLocation) {
            try store.removeManualLocation(discovered.id)
        }

        #expect(store.visibleLocations.map(\.id) == [discovered.id])
        #expect(store.hiddenLocations.isEmpty)
    }

    @Test func knownCloudIntersectionUsesBidirectionalPathComponentBoundaries() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let cloudRoot = fixture.directory("Cloud")
        let discovered = fixture.discovered("Cloud", identity: Data([0x66]))
        let store = fixture.store(discovery: MutableCloudLocationDiscovery([discovered]))
        try await store.rescan()

        #expect(store.intersectsKnownLocation(cloudRoot))
        #expect(store.intersectsKnownLocation(cloudRoot.deletingLastPathComponent()))
        #expect(store.intersectsKnownLocation(
            cloudRoot.appending(path: "Nested", directoryHint: .isDirectory)
        ))
        #expect(store.intersectsKnownLocation(
            fixture.directory("Cloud Backup")
        ) == false)
    }

    @Test func discoveredReadOnlyCapabilitySurvivesStorePresentation() async throws {
        let fixture = try CloudLocationsFixture()
        defer { fixture.remove() }
        let discovered = fixture.discovered(
            "Read Only",
            identity: Data([0x77]),
            capabilities: [.browse, .materialize]
        )
        let store = fixture.store(
            discovery: MutableCloudLocationDiscovery([discovered]),
            localFileOperationsSupported: { _ in true }
        )

        try await store.rescan()

        let location = try #require(store.visibleLocations.first)
        #expect(location.capabilities.contains(.localFileOperations) == false)
        #expect(store.batchRenameCapability(for: location.rootURL) == .readOnly)
    }
}

private actor SequencedCloudLocationDiscovery: CloudLocationDiscovering {
    private var continuations: [
        CheckedContinuation<[StorageLocation], Never>?
    ] = []

    var requestCount: Int {
        continuations.count
    }

    func waitForRequestCount(_ expected: Int) async {
        while continuations.count < expected {
            await Task.yield()
        }
    }

    func completeRequest(_ index: Int, with locations: [StorageLocation]) {
        continuations[index]?.resume(returning: locations)
        continuations[index] = nil
    }

    func discover() async -> [StorageLocation] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private final class MutableCloudLocationDiscovery: CloudLocationDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [StorageLocation]

    init(_ locations: [StorageLocation]) {
        self.locations = locations
    }

    func setLocations(_ locations: [StorageLocation]) {
        lock.withLock { self.locations = locations }
    }

    func discover() async -> [StorageLocation] {
        lock.withLock { locations }
    }
}

private final class StoreSecurityScopeDriver: SecurityScopedResourceAccessing, @unchecked Sendable {
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

@MainActor
private struct CloudLocationsFixture {
    let temporaryDirectory: TemporaryDirectory
    let storageURL: URL
    private let rootsURL: URL

    init() throws {
        temporaryDirectory = try TemporaryDirectory()
        storageURL = temporaryDirectory.url.appending(path: "cloud-locations.json")
        rootsURL = temporaryDirectory.url.appending(path: "roots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootsURL, withIntermediateDirectories: false)
    }

    func remove() {
        temporaryDirectory.remove()
    }

    func directory(_ basename: String) -> URL {
        rootsURL.appending(path: basename, directoryHint: .isDirectory)
    }

    func discovered(
        _ basename: String,
        identity: Data,
        domain: String = "com.example.files",
        capabilities: StorageCapabilities = [.browse, .materialize, .localFileOperations]
    ) -> StorageLocation {
        StorageLocation(
            id: .fileProvider(domainIdentifier: domain, rootIdentity: identity),
            provider: .other("Example"),
            displayName: basename,
            rootURL: directory(basename),
            isAvailable: true,
            capabilities: capabilities,
            source: .discovered
        )
    }

    func store(
        discovery: any CloudLocationDiscovering,
        bookmarking: any CloudLocationBookmarking = InMemoryCloudLocationBookmarking(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        localFileOperationsSupported: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) -> CloudLocationsStore {
        CloudLocationsStore(
            storageURL: storageURL,
            discovery: discovery,
            bookmarking: bookmarking,
            accessCoordinator: accessCoordinator,
            localFileOperationsSupported: localFileOperationsSupported
        )
    }
}
