import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct DirectoryReconciliationTests {
    @Test func refreshPreservesExistingSelectionAndDropsMissingURLs() async {
        let kept = URL(filePath: "/folder/kept")
        let removed = URL(filePath: "/folder/removed")
        let service = MutableListingService(items: [makeItem(kept), makeItem(removed)])
        let pane = FilePaneState(directory: URL(filePath: "/folder"), listingService: service)
        await pane.navigate(to: pane.currentDirectory, recordHistory: false)
        pane.selection = [kept, removed]

        service.setItems([makeItem(kept)])
        await pane.refresh()

        #expect(pane.selection == [kept])
        #expect(pane.items == [makeItem(kept)])
    }

    @Test func refreshPublishesOnlyAfterEveryBatchCompletes() async {
        let directory = URL(filePath: "/folder")
        let old = makeItem(directory.appending(path: "old"))
        let first = makeItem(directory.appending(path: "first"))
        let second = makeItem(directory.appending(path: "second"))
        let service = ControlledRefreshListingService(directory: directory, initialItems: [old])
        let pane = FilePaneState(directory: directory, listingService: service)
        await pane.navigate(to: directory, recordHistory: false)

        let refresh = Task { await pane.refresh() }
        await service.waitForRefreshStart()
        service.yieldRefresh([first])
        await Task.yield()

        #expect(pane.items == [old])

        service.yieldRefresh([second])
        await Task.yield()
        #expect(pane.items == [old])

        service.finishRefresh()
        await refresh.value
        #expect(pane.items == [first, second])
    }

    @Test func refreshMatchesSelectionByStandardizedURLAndUsesListedIdentity() async {
        let directory = URL(filePath: "/folder")
        let listed = makeItem(directory.appending(path: "kept"))
        let service = MutableListingService(items: [listed])
        let pane = FilePaneState(directory: directory, listingService: service)
        await pane.navigate(to: directory, recordHistory: false)
        pane.selection = [directory.appending(path: "nested/../kept")]

        await pane.refresh()

        #expect(pane.selection == [listed.url])
    }

    @Test func navigationRejectsARefreshThatFinishesForThePreviousDirectory() async {
        let directory = URL(filePath: "/folder")
        let destination = URL(filePath: "/destination")
        let old = makeItem(directory.appending(path: "old"))
        let stale = makeItem(directory.appending(path: "stale"))
        let fresh = makeItem(destination.appending(path: "fresh"))
        let service = ControlledRefreshListingService(
            directory: directory,
            initialItems: [old],
            otherDirectoryItems: [destination: [fresh]]
        )
        let pane = FilePaneState(directory: directory, listingService: service)
        await pane.navigate(to: directory, recordHistory: false)

        let refresh = Task { await pane.refresh() }
        await service.waitForRefreshStart()
        service.yieldRefresh([stale])
        await pane.navigate(to: destination)
        service.finishRefresh()
        await refresh.value

        #expect(pane.currentDirectory == destination)
        #expect(pane.items == [fresh])
        #expect(pane.selection.isEmpty)
    }

    @Test func refreshRequestedDuringNavigationCannotFinishBeforeAndOverwriteNavigation() async {
        let oldDirectory = URL(filePath: "/old")
        let destination = URL(filePath: "/destination")
        let old = makeItem(oldDirectory.appending(path: "old"))
        let navigated = makeItem(destination.appending(path: "navigated"))
        let rogueRefresh = makeItem(destination.appending(path: "rogue-refresh"))
        let service = RequestControlledListingService(
            immediateValues: [oldDirectory: [old]],
            controlledDirectories: [destination]
        )
        let pane = FilePaneState(directory: oldDirectory, listingService: service)
        await pane.navigate(to: oldDirectory, recordHistory: false)

        let navigation = Task { await pane.navigate(to: destination) }
        await service.waitForRequestCount(1, in: destination)
        let refresh = Task { await pane.refresh() }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(service.requestCount(in: destination) == 1)
        if service.requestCount(in: destination) > 1 {
            service.yield([rogueRefresh], in: destination, request: 1)
            service.finish(in: destination, request: 1)
        }
        await refresh.value
        service.yield([navigated], in: destination, request: 0)
        service.finish(in: destination, request: 0)
        await navigation.value

        #expect(pane.items == [navigated])
        #expect(pane.committedDirectoryForPersistence == destination)
    }

    @Test func refreshRequestedDuringNavigationCannotFinishAfterAndOverwriteNavigation() async {
        let oldDirectory = URL(filePath: "/old")
        let destination = URL(filePath: "/destination")
        let navigated = makeItem(destination.appending(path: "navigated"))
        let rogueRefresh = makeItem(destination.appending(path: "rogue-refresh"))
        let service = RequestControlledListingService(
            immediateValues: [oldDirectory: []],
            controlledDirectories: [destination]
        )
        let pane = FilePaneState(directory: oldDirectory, listingService: service)
        await pane.navigate(to: oldDirectory, recordHistory: false)

        let navigation = Task { await pane.navigate(to: destination) }
        await service.waitForRequestCount(1, in: destination)
        let refresh = Task { await pane.refresh() }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(service.requestCount(in: destination) == 1)
        service.yield([navigated], in: destination, request: 0)
        service.finish(in: destination, request: 0)
        await navigation.value
        if service.requestCount(in: destination) > 1 {
            service.yield([rogueRefresh], in: destination, request: 1)
            service.finish(in: destination, request: 1)
        }
        await refresh.value

        #expect(pane.items == [navigated])
    }

    @Test func refreshRequestedDuringNavigationCannotCorruptFailedNavigationRestore() async {
        let oldDirectory = URL(filePath: "/old")
        let destination = URL(filePath: "/destination")
        let old = makeItem(oldDirectory.appending(path: "old"))
        let rogueRefresh = makeItem(destination.appending(path: "rogue-refresh"))
        let service = RequestControlledListingService(
            immediateValues: [oldDirectory: [old]],
            controlledDirectories: [destination]
        )
        let pane = FilePaneState(directory: oldDirectory, listingService: service)
        await pane.navigate(to: oldDirectory, recordHistory: false)

        let navigation = Task { await pane.navigate(to: destination) }
        await service.waitForRequestCount(1, in: destination)
        let refresh = Task { await pane.refresh() }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(service.requestCount(in: destination) == 1)
        if service.requestCount(in: destination) > 1 {
            service.yield([rogueRefresh], in: destination, request: 1)
            service.finish(in: destination, request: 1)
        }
        await refresh.value
        service.fail(in: destination, request: 0)
        await navigation.value

        #expect(pane.currentDirectory == oldDirectory)
        #expect(pane.items == [old])
        #expect(pane.committedDirectoryForPersistence == oldDirectory)
    }

    @Test func refreshErrorPreservesThePriorListingAndSelection() async {
        let directory = URL(filePath: "/folder")
        let item = makeItem(directory.appending(path: "kept"))
        let service = ControlledRefreshListingService(directory: directory, initialItems: [item])
        let pane = FilePaneState(directory: directory, listingService: service)
        await pane.navigate(to: directory, recordHistory: false)
        pane.selection = [item.url]

        let refresh = Task { await pane.refresh() }
        await service.waitForRefreshStart()
        service.failRefresh()
        await refresh.value

        #expect(pane.items == [item])
        #expect(pane.selection == [item.url])
        #expect(pane.errorMessage != nil)
    }

    @Test func successfulNavigationReplacesTheSingleVisibleDirectoryMonitor() async {
        let first = URL(filePath: "/first")
        let second = URL(filePath: "/second")
        let monitor = RecordingDirectoryMonitor()
        let pane = FilePaneState(
            directory: first,
            listingService: StubDirectoryListingService(values: [:]),
            monitor: monitor
        )

        await pane.navigate(to: first, recordHistory: false)
        #expect(monitor.startedDirectories == [first])
        #expect(monitor.activeDirectories == [first])

        await pane.navigate(to: second)
        await monitor.waitUntilActiveDirectoriesEqual([second])

        #expect(monitor.startedDirectories == [first, second])
        #expect(monitor.activeDirectories == [second])
    }

    @Test func failedNavigationKeepsThePreviousVisibleDirectoryMonitor() async {
        let visible = URL(filePath: "/visible")
        let unavailable = URL(filePath: "/unavailable")
        let monitor = RecordingDirectoryMonitor()
        let service = SelectiveListingService(failingDirectories: [unavailable])
        let pane = FilePaneState(directory: visible, listingService: service, monitor: monitor)
        await pane.navigate(to: visible, recordHistory: false)

        await pane.navigate(to: unavailable)

        #expect(pane.currentDirectory == visible)
        #expect(monitor.startedDirectories == [visible])
        #expect(monitor.activeDirectories == [visible])
    }

    @Test func oldMonitorEventDuringFailedNavigationReconcilesTheRestoredDirectory() async {
        let visible = URL(filePath: "/visible")
        let unavailable = URL(filePath: "/unavailable")
        let old = makeItem(visible.appending(path: "old"))
        let replacement = makeItem(visible.appending(path: "replacement"))
        let monitor = RecordingDirectoryMonitor()
        let service = RequestControlledListingService(
            immediateValues: [visible: [old]],
            controlledDirectories: [unavailable]
        )
        let pane = FilePaneState(directory: visible, listingService: service, monitor: monitor)
        var persistenceChanges = 0
        pane.setPersistenceChangeHandler { persistenceChanges += 1 }
        await pane.navigate(to: visible, recordHistory: false)
        let persistedAfterVisibleNavigation = persistenceChanges

        let navigation = Task { await pane.navigate(to: unavailable) }
        await service.waitForRequestCount(1, in: unavailable)
        service.setImmediateValues([replacement], in: visible)
        monitor.sendEvent(in: visible)
        service.fail(in: unavailable, request: 0)
        await navigation.value
        await waitUntil { pane.items == [replacement] }

        #expect(pane.currentDirectory == visible)
        #expect(pane.items == [replacement])
        #expect(pane.backHistory.isEmpty)
        #expect(persistenceChanges == persistedAfterVisibleNavigation)
        #expect(monitor.activeDirectories == [visible])
    }

    @Test func oldMonitorEventDuringSuccessfulSameDirectoryNavigationReconcilesOnce() async {
        let directory = URL(filePath: "/visible")
        let old = makeItem(directory.appending(path: "old"))
        let replacement = makeItem(directory.appending(path: "replacement"))
        let service = SameDirectoryNavigationListingService(initialItems: [old])
        let monitor = RecordingDirectoryMonitor()
        let pane = FilePaneState(directory: directory, listingService: service, monitor: monitor)
        var persistenceChanges = 0
        pane.setPersistenceChangeHandler { persistenceChanges += 1 }
        await pane.navigate(to: directory, recordHistory: false)

        let navigation = Task { await pane.navigate(to: directory, recordHistory: false) }
        await service.waitForNavigationRequest()
        service.yieldNavigationSnapshot([old])
        service.setPostNavigationItems([replacement])
        monitor.sendEvent(in: directory)
        service.finishNavigation()
        await navigation.value
        #expect(await waitUntil { pane.items == [replacement] })

        #expect(service.requestCount == 3)
        #expect(pane.backHistory.isEmpty)
        #expect(pane.forwardHistory.isEmpty)
        #expect(persistenceChanges == 2)
        #expect(monitor.startedDirectories == [directory, directory])
        #expect(monitor.activeDirectories == [directory])
    }

    @Test func releasingPaneCancelsItsVisibleDirectoryMonitor() async {
        let directory = URL(filePath: "/visible")
        let monitor = RecordingDirectoryMonitor()
        var pane: FilePaneState? = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [:]),
            monitor: monitor
        )
        await pane?.navigate(to: directory, recordHistory: false)
        #expect(monitor.activeDirectories == [directory])

        pane = nil
        await monitor.waitUntilActiveDirectoriesEqual([])

        #expect(monitor.activeDirectories.isEmpty)
    }

    @Test func releasingPaneDuringStalledNavigationCancelsTheListingStream() async {
        let directory = URL(filePath: "/stalled-navigation")
        let service = StallingListingService(immediateResponses: 0)
        var pane: FilePaneState? = FilePaneState(directory: URL(filePath: "/"), listingService: service)
        weak var releasedPane = pane
        let navigation = pane?.beginNavigation(to: directory)
        await service.waitForStalledRequestCount(1)

        pane = nil
        let released = await waitUntil { releasedPane == nil && service.terminationCount == 1 }
        if !released {
            navigation?.cancel()
            await navigation?.value
        }

        #expect(released)
        #expect(releasedPane == nil)
        #expect(service.terminationCount == 1)
        navigation?.cancel()
        await navigation?.value
    }

    @Test func releasingPaneDuringStalledRefreshCancelsTheListingStream() async {
        let directory = URL(filePath: "/stalled-refresh")
        let item = makeItem(directory.appending(path: "initial"))
        let service = StallingListingService(immediateResponses: 1, immediateItems: [item])
        var pane: FilePaneState? = FilePaneState(directory: directory, listingService: service)
        await pane?.navigate(to: directory, recordHistory: false)
        weak var releasedPane = pane
        let refresh = pane?.beginRefresh()
        await service.waitForStalledRequestCount(1)

        pane = nil
        let released = await waitUntil { releasedPane == nil && service.terminationCount == 1 }
        if !released {
            refresh?.cancel()
            await refresh?.value
        }

        #expect(released)
        #expect(releasedPane == nil)
        #expect(service.terminationCount == 1)
        refresh?.cancel()
        await refresh?.value
    }

    @Test func monitorEventRefreshesWithoutChangingHistoryOrPersistence() async {
        let root = URL(filePath: "/")
        let directory = URL(filePath: "/folder")
        let old = makeItem(directory.appending(path: "old"))
        let replacement = makeItem(directory.appending(path: "replacement"))
        let service = MutableListingService(items: [old])
        let monitor = RecordingDirectoryMonitor()
        let pane = FilePaneState(directory: root, listingService: service, monitor: monitor)
        var persistenceChanges = 0
        pane.setPersistenceChangeHandler { persistenceChanges += 1 }
        await pane.navigate(to: directory)
        let navigationPersistenceChanges = persistenceChanges
        let history = pane.backHistory

        service.setItems([replacement])
        monitor.sendEvent(in: directory)
        await waitUntil { pane.items == [replacement] }

        #expect(pane.backHistory == history)
        #expect(pane.forwardHistory.isEmpty)
        #expect(persistenceChanges == navigationPersistenceChanges)
        #expect(pane.committedDirectoryForPersistence == directory)
    }

    @Test func failedMonitorRefreshKeepsTheLastUsableListingAndMonitor() async {
        let directory = URL(filePath: "/folder")
        let item = makeItem(directory.appending(path: "kept"))
        let service = ToggleFailureListingService(items: [item])
        let monitor = RecordingDirectoryMonitor()
        let pane = FilePaneState(directory: directory, listingService: service, monitor: monitor)
        await pane.navigate(to: directory, recordHistory: false)
        pane.selection = [item.url]

        service.shouldFail = true
        monitor.sendEvent(in: directory)
        await waitUntil { pane.errorMessage != nil }

        #expect(pane.items == [item])
        #expect(pane.selection == [item.url])
        #expect(monitor.activeDirectories == [directory])
    }

    @Test func liveMonitorCoalescesRapidDirectoryWrites() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = LockedCounter()
        let stream = LiveDirectoryMonitor(debounceNanoseconds: 200_000_000).events(for: directory)
        let reader = Task {
            for await _ in stream {
                counter.increment()
            }
        }
        try await Task.sleep(for: .milliseconds(30))

        for index in 0..<5 {
            try Data("\(index)".utf8).write(to: directory.appending(path: "\(index).txt"))
        }
        let received = await waitUntil { counter.value >= 1 }

        #expect(received)
        #expect(counter.value == 1)
        #expect(await remainsTrue(for: .milliseconds(250)) { counter.value == 1 })
        reader.cancel()
        await reader.value
    }

    @Test func liveMonitorReconcilesExternalCreateRenameAndDeleteInVisiblePane() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pane = FilePaneState(
            directory: directory,
            listingService: LiveDirectoryListingService(batchSize: 2),
            monitor: LiveDirectoryMonitor(debounceNanoseconds: 30_000_000)
        )
        await pane.navigate(to: directory, recordHistory: false)

        let created = directory.appending(path: "created.txt")
        try Data("created".utf8).write(to: created)
        #expect(await waitUntil { pane.items.map(\.name) == ["created.txt"] })

        let renamed = directory.appending(path: "renamed.txt")
        try FileManager.default.moveItem(at: created, to: renamed)
        #expect(await waitUntil { pane.items.map(\.name) == ["renamed.txt"] })

        try FileManager.default.removeItem(at: renamed)
        #expect(await waitUntil { pane.items.isEmpty })
    }

    @Test func cancellingLiveMonitorStreamClosesItsDescriptorExactlyOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let closeCounter = LockedCounter()
        let monitor = LiveDirectoryMonitor(
            debounceNanoseconds: 10_000_000,
            onFileDescriptorClosed: { _ in closeCounter.increment() }
        )
        let stream = monitor.events(for: directory)
        let reader = Task {
            for await _ in stream {}
        }

        reader.cancel()
        reader.cancel()
        await reader.value
        #expect(await waitUntil { closeCounter.value == 1 })
        try await Task.sleep(for: .milliseconds(30))

        #expect(closeCounter.value == 1)
    }

    @Test func liveMonitorRetainsManualAccessUntilCancellationAndReleasesOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = DirectoryMonitorSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([directory])
        let monitor = LiveDirectoryMonitor(
            debounceNanoseconds: 10_000_000,
            accessCoordinator: accessCoordinator
        )

        let stream = monitor.events(for: directory)

        #expect(driver.startedURLs == [directory])
        #expect(driver.stoppedURLs.isEmpty)

        let reader = Task {
            for await _ in stream {}
        }
        reader.cancel()
        reader.cancel()
        await reader.value
        #expect(await waitUntil { driver.stoppedURLs == [directory] })
        try await Task.sleep(for: .milliseconds(30))

        #expect(driver.stoppedURLs == [directory])
    }

    @Test func replacingAndReleasingPaneBalancesEachManualMonitorLease() async throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let driver = DirectoryMonitorSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([first, second])
        let monitor = LiveDirectoryMonitor(
            debounceNanoseconds: 10_000_000,
            accessCoordinator: accessCoordinator
        )
        var pane: FilePaneState? = FilePaneState(
            directory: first,
            listingService: StubDirectoryListingService(values: [:]),
            monitor: monitor
        )

        await pane?.navigate(to: first, recordHistory: false)
        #expect(driver.startedURLs == [first])
        #expect(driver.stoppedURLs.isEmpty)

        await pane?.navigate(to: second)
        #expect(await waitUntil { driver.stoppedURLs == [first] })
        #expect(driver.startedURLs == [first, second])

        await pane?.goBack()
        #expect(await waitUntil { driver.stoppedURLs == [first, second] })
        #expect(driver.startedURLs == [first, second, first])

        await pane?.goForward()
        #expect(await waitUntil { driver.stoppedURLs == [first, second, first] })
        #expect(driver.startedURLs == [first, second, first, second])

        pane = nil
        #expect(await waitUntil { driver.stoppedURLs == [first, second, first, second] })
        try await Task.sleep(for: .milliseconds(30))

        #expect(driver.stoppedURLs == [first, second, first, second])
    }

    @Test func failedLiveMonitorStartupBalancesManualAccess() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appending(path: "missing", directoryHint: .isDirectory)
        let driver = DirectoryMonitorSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([missing])
        let monitor = LiveDirectoryMonitor(accessCoordinator: accessCoordinator)

        for await _ in monitor.events(for: missing) {}

        #expect(driver.startedURLs == [missing])
        #expect(driver.stoppedURLs == [missing])
    }

    @Test(arguments: [DestructiveDirectoryChange.rename, .delete])
    fileprivate func destructiveDirectoryEventYieldsOnceThenFinishesAndCloses(
        change: DestructiveDirectoryChange
    ) async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: "watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let eventCounter = LockedCounter()
        let closeCounter = LockedCounter()
        let finishedCounter = LockedCounter()
        let driver = DirectoryMonitorSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([directory])
        let monitor = LiveDirectoryMonitor(
            debounceNanoseconds: 30_000_000,
            onFileDescriptorClosed: { _ in closeCounter.increment() },
            accessCoordinator: accessCoordinator
        )
        let stream = monitor.events(for: directory)
        let reader = Task {
            for await _ in stream {
                eventCounter.increment()
            }
            finishedCounter.increment()
        }
        try await Task.sleep(for: .milliseconds(30))

        switch change {
        case .rename:
            try FileManager.default.moveItem(at: directory, to: parent.appending(path: "renamed"))
        case .delete:
            try FileManager.default.removeItem(at: directory)
        }

        let completed = await waitUntil {
            closeCounter.value == 1 && finishedCounter.value == 1
        }
        guard completed else {
            reader.cancel()
            await reader.value
            throw DirectoryMonitorTestError.timedOut
        }
        await reader.value

        #expect(eventCounter.value == 1)
        #expect(closeCounter.value == 1)
        #expect(driver.startedURLs == [directory])
        #expect(driver.stoppedURLs == [directory])
    }
}

private enum DestructiveDirectoryChange: Sendable {
    case rename
    case delete
}

private enum DirectoryMonitorTestError: Error {
    case timedOut
}

private final class ControlledRefreshListingService: DirectoryListingService, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<[FileItem], Error>.Continuation

    private let lock = NSLock()
    private let directory: URL
    private let initialItems: [FileItem]
    private let otherDirectoryItems: [URL: [FileItem]]
    private var directoryRequestCount = 0
    private var refreshContinuation: Continuation?

    init(
        directory: URL,
        initialItems: [FileItem],
        otherDirectoryItems: [URL: [FileItem]] = [:]
    ) {
        self.directory = directory
        self.initialItems = initialItems
        self.otherDirectoryItems = otherDirectoryItems
    }

    func batches(in requestedDirectory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        if requestedDirectory != directory {
            let items = otherDirectoryItems[requestedDirectory] ?? []
            return AsyncThrowingStream { continuation in
                continuation.yield(items)
                continuation.finish()
            }
        }

        let isInitial = lock.withLock {
            directoryRequestCount += 1
            return directoryRequestCount == 1
        }
        if isInitial {
            return AsyncThrowingStream { continuation in
                continuation.yield(initialItems)
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            lock.withLock {
                refreshContinuation = continuation
            }
        }
    }

    func waitForRefreshStart() async {
        await waitUntil { self.lock.withLock { self.refreshContinuation != nil } }
    }

    func yieldRefresh(_ items: [FileItem]) {
        lock.withLock { refreshContinuation }?.yield(items)
    }

    func finishRefresh() {
        lock.withLock { refreshContinuation }?.finish()
    }

    func failRefresh() {
        lock.withLock { refreshContinuation }?.finish(throwing: TestListingError.failed)
    }
}

private final class RequestControlledListingService: DirectoryListingService, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<[FileItem], Error>.Continuation

    private let lock = NSLock()
    private var immediateValues: [URL: [FileItem]]
    private let controlledDirectories: Set<URL>
    private var continuations: [URL: [Continuation]] = [:]

    init(immediateValues: [URL: [FileItem]], controlledDirectories: Set<URL>) {
        self.immediateValues = immediateValues
        self.controlledDirectories = controlledDirectories
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        guard controlledDirectories.contains(directory) else {
            let items = lock.withLock { immediateValues[directory] ?? [] }
            return AsyncThrowingStream { continuation in
                continuation.yield(items)
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            lock.withLock {
                continuations[directory, default: []].append(continuation)
            }
        }
    }

    func requestCount(in directory: URL) -> Int {
        lock.withLock { continuations[directory, default: []].count }
    }

    func waitForRequestCount(_ count: Int, in directory: URL) async {
        await waitUntil { self.requestCount(in: directory) >= count }
    }

    func setImmediateValues(_ items: [FileItem], in directory: URL) {
        lock.withLock { immediateValues[directory] = items }
    }

    func yield(_ items: [FileItem], in directory: URL, request: Int) {
        lock.withLock { continuations[directory]?[request] }?.yield(items)
    }

    func finish(in directory: URL, request: Int) {
        lock.withLock { continuations[directory]?[request] }?.finish()
    }

    func fail(in directory: URL, request: Int) {
        lock.withLock { continuations[directory]?[request] }?.finish(throwing: TestListingError.failed)
    }
}

private final class SameDirectoryNavigationListingService: DirectoryListingService, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<[FileItem], Error>.Continuation

    private let lock = NSLock()
    private let initialItems: [FileItem]
    private var postNavigationItems: [FileItem]
    private var calls = 0
    private var navigationContinuation: Continuation?

    init(initialItems: [FileItem]) {
        self.initialItems = initialItems
        postNavigationItems = initialItems
    }

    var requestCount: Int { lock.withLock { calls } }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let request = lock.withLock {
            defer { calls += 1 }
            return calls
        }
        if request == 0 {
            return AsyncThrowingStream { continuation in
                continuation.yield(initialItems)
                continuation.finish()
            }
        }
        if request == 1 {
            return AsyncThrowingStream { continuation in
                lock.withLock { navigationContinuation = continuation }
            }
        }

        let items = lock.withLock { postNavigationItems }
        return AsyncThrowingStream { continuation in
            continuation.yield(items)
            continuation.finish()
        }
    }

    func waitForNavigationRequest() async {
        await waitUntil { self.lock.withLock { self.navigationContinuation != nil } }
    }

    func yieldNavigationSnapshot(_ items: [FileItem]) {
        lock.withLock { navigationContinuation }?.yield(items)
    }

    func finishNavigation() {
        lock.withLock { navigationContinuation }?.finish()
    }

    func setPostNavigationItems(_ items: [FileItem]) {
        lock.withLock { postNavigationItems = items }
    }
}

private final class StallingListingService: DirectoryListingService, @unchecked Sendable {
    private let lock = NSLock()
    private let immediateResponses: Int
    private let immediateItems: [FileItem]
    private var requestCount = 0
    private var stalledRequests = 0
    private var terminations = 0

    init(immediateResponses: Int, immediateItems: [FileItem] = []) {
        self.immediateResponses = immediateResponses
        self.immediateItems = immediateItems
    }

    var terminationCount: Int { lock.withLock { terminations } }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let shouldRespondImmediately = lock.withLock {
            defer { requestCount += 1 }
            return requestCount < immediateResponses
        }
        if shouldRespondImmediately {
            return AsyncThrowingStream { continuation in
                continuation.yield(immediateItems)
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            lock.withLock { stalledRequests += 1 }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.terminations += 1
                }
            }
        }
    }

    func waitForStalledRequestCount(_ count: Int) async {
        await waitUntil { self.lock.withLock { self.stalledRequests >= count } }
    }
}

private struct SelectiveListingService: DirectoryListingService {
    let failingDirectories: Set<URL>

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            if failingDirectories.contains(directory) {
                continuation.finish(throwing: TestListingError.failed)
            } else {
                continuation.yield([])
                continuation.finish()
            }
        }
    }
}

private final class ToggleFailureListingService: DirectoryListingService, @unchecked Sendable {
    private let lock = NSLock()
    private let items: [FileItem]
    var shouldFail: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    private var failure = false

    init(items: [FileItem]) {
        self.items = items
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let shouldFail = lock.withLock { failure }
        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(throwing: TestListingError.failed)
            } else {
                continuation.yield(items)
                continuation.finish()
            }
        }
    }
}

private enum TestListingError: Error {
    case failed
}

private final class RecordingDirectoryMonitor: DirectoryMonitor, @unchecked Sendable {
    typealias Continuation = AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var continuations: [URL: [UUID: Continuation]] = [:]
    private var starts: [URL] = []

    var startedDirectories: [URL] {
        lock.withLock { starts }
    }

    var activeDirectories: Set<URL> {
        lock.withLock { Set(continuations.compactMap { $0.value.isEmpty ? nil : $0.key }) }
    }

    func events(for directory: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                starts.append(directory)
                continuations[directory, default: [:]][id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.continuations[directory]?[id] = nil
                }
            }
        }
    }

    func sendEvent(in directory: URL) {
        let current = lock.withLock { Array(continuations[directory, default: [:]].values) }
        current.forEach { $0.yield() }
    }

    func waitUntilActiveDirectoriesEqual(_ expected: Set<URL>) async {
        await waitUntil { self.activeDirectories == expected }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class DirectoryMonitorSecurityScopeDriver:
    SecurityScopedResourceAccessing,
    @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops: [URL] = []

    var startedURLs: [URL] {
        lock.withLock { starts }
    }

    var stoppedURLs: [URL] {
        lock.withLock { stops }
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts.append(url) }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops.append(url) }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BloomDirectoryMonitor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@discardableResult
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
private func remainsTrue(
    for duration: Duration,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while clock.now < deadline {
        guard condition() else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func makeItem(_ url: URL) -> FileItem {
    FileItem(
        url: url,
        name: url.lastPathComponent,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: 1,
        typeDescription: "File"
    )
}
