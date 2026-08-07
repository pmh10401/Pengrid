import Foundation
import Observation

@MainActor @Observable
final class FilePaneState {
    private static let sameTurnProjectionLimit = 256

    private let listingService: any DirectoryListingService
    private let monitor: any DirectoryMonitor
    private nonisolated let taskLifecycle = PaneTaskLifecycle()
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var batchFlushTask: Task<Void, Never>?
    private var currentRequestID: UInt64?
    private var nextRequestID: UInt64 = 0
    private var currentRefreshID: UInt64?
    private var nextRefreshID: UInt64 = 0
    private var pendingMonitorRefreshDirectory: URL?
    private var committedState: PaneSnapshot
    private var currentNavigationIntent: PaneNavigationIntent?
    private var persistenceChangeHandler: (@MainActor () -> Void)?
    private var selectionBeforeFiltering: Set<URL> = []
    private var navigationHistory = PaneNavigationHistory(capacity: 100)
    private var viewStateCache = PaneViewStateCache(capacity: 100)
    private var firstVisibleItem: URL?
    private var itemsRevision: UInt64 = 0
    private var projectionGeneration: UInt64 = 0
    private var acceptedProjectionKey: PaneProjectionKey?
    private var batchBuffer = PaneBatchBuffer()
    private let batchSleeper: any PaneBatchSleeping
    private let batchFlushDelay: Duration
    private var visibleURLByEntryPath: [String: URL] = [:]

    private(set) var currentDirectory: URL
    private(set) var items: [FileItem] = []
    private(set) var visibleItems: [FileItem] = []
    private(set) var visibleIndexByURL: [URL: Int] = [:]
    var backHistory: [URL] { navigationHistory.backward }
    var forwardHistory: [URL] { navigationHistory.forward }
    var selection: Set<URL> = [] {
        didSet {
            guard let pendingRenameTarget else { return }
            let targetPath = Self.entryPath(pendingRenameTarget.url)
            guard selection.count == 1,
                  selection.contains(where: { Self.entryPath($0) == targetPath })
            else {
                clearPendingRename()
                return
            }
        }
    }
    var sort: FileSort {
        didSet {
            guard sort != oldValue else { return }
            persistenceChangeHandler?()
            scheduleProjection()
        }
    }
    var isEditingPath = false
    var isLoading = false
    var errorMessage: String?
    private(set) var isFilterPresented = false
    private(set) var filterQuery = ""
    private(set) var filterFocusRequestID: UUID?
    private(set) var focusRequestID: UUID?
    private(set) var renameRequestID: UUID?
    private(set) var pendingRenameTarget: IdentifiedFileRequest?
    private(set) var scrollRestoreRequest: PaneScrollRequest?

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var filterResultCount: Int { visibleItems.count }
    var committedDirectoryForPersistence: URL { committedState.directory }

    func requestTableFocus() {
        focusRequestID = UUID()
    }

    func beginFiltering() {
        if !isFilterPresented {
            selectionBeforeFiltering = selection
            isFilterPresented = true
        }
    }

    func requestFilterFocus() {
        beginFiltering()
        filterFocusRequestID = UUID()
    }

    func updateFilterQuery(_ query: String) {
        guard query != filterQuery else { return }
        filterQuery = query
        scheduleProjection()
    }

    func dismissFiltering() {
        let captured = selectionBeforeFiltering
        isFilterPresented = false
        filterQuery = ""
        selectionBeforeFiltering.removeAll()
        let loadedURLs = Set(items.map(\.url))
        selection = captured.intersection(loadedURLs)
        scheduleProjection()
    }

    @discardableResult
    func requestInlineRename() -> Bool {
        guard selection.count == 1 else { return false }
        renameRequestID = UUID()
        if pendingRenameTarget == nil, let url = selection.first {
            pendingRenameTarget = IdentifiedFileRequest(
                url: url,
                identity: FileIdentity(entryIdentifier: "uncaptured", resolvedIdentifier: "uncaptured")
            )
        }
        return true
    }

    @discardableResult
    func requestInlineRename(_ target: IdentifiedFileRequest) -> Bool {
        guard selection.count == 1, selection.contains(target.url) else { return false }
        pendingRenameTarget = target
        renameRequestID = UUID()
        return true
    }

    func takePendingRenameTarget() -> IdentifiedFileRequest? {
        defer { clearPendingRename() }
        return pendingRenameTarget
    }

    func cancelPendingRename() {
        clearPendingRename()
    }

    func finishPendingRenameWithoutChange() {
        clearPendingRename()
    }

    @discardableResult
    func selectForInlineRename(_ url: URL) -> Bool {
        guard let listedURL = visibleItems.first(where: {
            Self.entryPath($0.url) == Self.entryPath(url)
        })?.url else { return false }
        selection = [listedURL]
        return requestInlineRename()
    }

    @discardableResult
    func selectForInlineRename(_ target: IdentifiedFileRequest) -> Bool {
        guard let listedURL = visibleItems.first(where: {
            Self.entryPath($0.url) == Self.entryPath(target.url)
        })?.url else { return false }
        selection = [listedURL]
        return requestInlineRename(IdentifiedFileRequest(
            url: listedURL,
            identity: target.identity
        ))
    }

    func consumeInlineRenameRequest(_ requestID: UUID) {
        guard renameRequestID == requestID else { return }
        renameRequestID = nil
    }

    func recordFirstVisibleItem(_ url: URL?) {
        firstVisibleItem = url
    }

    func consumeScrollRestoreRequest(_ id: UUID) {
        guard scrollRestoreRequest?.id == id else { return }
        scrollRestoreRequest = nil
    }

    private func clearPendingRename() {
        renameRequestID = nil
        pendingRenameTarget = nil
    }

    init(
        directory: URL,
        sort: FileSort = FileSort(),
        listingService: any DirectoryListingService,
        monitor: any DirectoryMonitor = LiveDirectoryMonitor(),
        batchSleeper: any PaneBatchSleeping = LivePaneBatchSleeper(),
        batchFlushDelay: Duration = .milliseconds(60)
    ) {
        let initialProjectionKey = PaneProjectionKey(
            itemsRevision: 0,
            normalizedQuery: "",
            sort: sort
        )
        currentDirectory = directory
        self.sort = sort
        self.listingService = listingService
        self.monitor = monitor
        self.batchSleeper = batchSleeper
        self.batchFlushDelay = batchFlushDelay
        acceptedProjectionKey = initialProjectionKey
        committedState = PaneSnapshot(
            directory: directory,
            items: [],
            visibleItems: [],
            visibleIndexByURL: [:],
            visibleURLByEntryPath: [:],
            acceptedProjectionKey: initialProjectionKey,
            itemsRevision: 0,
            selection: [],
            firstVisibleItem: nil,
            navigationHistory: PaneNavigationHistory(capacity: 100)
        )
    }

    deinit {
        taskLifecycle.cancelAll()
    }

    func setPersistenceChangeHandler(_ handler: (@MainActor () -> Void)?) {
        persistenceChangeHandler = handler
    }

    func navigate(to directory: URL, recordHistory: Bool = true) async {
        let task = beginNavigation(to: directory, recordHistory: recordHistory)
        await Self.awaitTask(task)
    }

    @discardableResult
    func beginNavigation(
        to directory: URL,
        recordHistory: Bool = true
    ) -> Task<Void, Never> {
        prepareForNavigation()
        committedState = snapshot()
        return startNavigation(
            to: directory,
            intent: .user(from: currentDirectory, recordsHistory: recordHistory)
        )
    }

    private func prepareForNavigation() {
        cancelRefresh()
        cancelLoading(recoverDirtyMonitor: false)
        resetFilterForNavigation()
    }

    private func resetFilterForNavigation() {
        isFilterPresented = false
        filterQuery = ""
        selectionBeforeFiltering.removeAll()
        scheduleProjection()
    }

    func cancelLoading() {
        cancelLoading(recoverDirtyMonitor: true)
    }

    private func cancelLoading(recoverDirtyMonitor: Bool) {
        guard isLoading else { return }
        loadTask?.cancel()
        taskLifecycle.setLoad(nil)
        discardPendingBatchWork()
        invalidateProjectionWork()
        restore(committedState)
        currentRequestID = nil
        currentNavigationIntent = nil
        loadTask = nil
        isLoading = false
        scheduleProjection()
        if recoverDirtyMonitor {
            reconcilePendingMonitorRefreshIfNeeded()
        }
    }

    private func startNavigation(
        to directory: URL,
        intent: PaneNavigationIntent
    ) -> Task<Void, Never> {
        storeCurrentDirectoryViewState()

        currentDirectory = directory
        selection.removeAll()
        firstVisibleItem = nil
        scrollRestoreRequest = nil
        clearPendingRename()
        items.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)
        visibleIndexByURL.removeAll(keepingCapacity: true)
        visibleURLByEntryPath.removeAll(keepingCapacity: true)
        acceptedProjectionKey = nil
        itemsRevision &+= 1
        batchBuffer = PaneBatchBuffer()
        errorMessage = nil
        isLoading = true

        nextRequestID += 1
        let requestID = nextRequestID
        currentRequestID = requestID
        currentNavigationIntent = intent
        let listingService = listingService
        let task = Task { @MainActor [weak self, listingService] in
            do {
                for try await batch in listingService.batches(in: directory) {
                    guard !Task.isCancelled else {
                        await self?.cancelLoading(requestID: requestID)
                        return
                    }
                    guard await self?.receiveNavigationBatch(
                        batch,
                        requestID: requestID,
                        directory: directory
                    ) == true else {
                        return
                    }
                }
            } catch is CancellationError {
                await self?.cancelLoading(requestID: requestID)
                return
            } catch {
                await self?.failNavigation(error, requestID: requestID)
                return
            }

            guard !Task.isCancelled else {
                await self?.cancelLoading(requestID: requestID)
                return
            }
            guard await self?.flushPendingNavigationBatches(
                requestID: requestID,
                directory: directory
            ) == true else { return }
            await self?.ensureCurrentProjection(
                navigationGeneration: requestID,
                directory: directory
            )
            self?.completeNavigation(to: directory, requestID: requestID)
        }
        loadTask = task
        taskLifecycle.setLoad(task)
        return task
    }

    func goBack() async {
        prepareForNavigation()
        committedState = snapshot()
        guard let target = navigationHistory.backward.last else { return }
        let task = startNavigation(
            to: target,
            intent: .backward(from: currentDirectory, destination: target)
        )
        await Self.awaitTask(task)
    }

    func goForward() async {
        prepareForNavigation()
        committedState = snapshot()
        guard let target = navigationHistory.forward.last else { return }
        let task = startNavigation(
            to: target,
            intent: .forward(from: currentDirectory, destination: target)
        )
        await Self.awaitTask(task)
    }

    func goToParent() async {
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent != currentDirectory else { return }
        await navigate(to: parent)
    }

    func refresh() async {
        guard let task = beginRefresh() else { return }
        await Self.awaitTask(task)
    }

    @discardableResult
    func beginRefresh() -> Task<Void, Never>? {
        beginRefresh(preservingErrorMessage: nil)
    }

    @discardableResult
    private func beginRefresh(
        preservingErrorMessage preservedErrorMessage: String?
    ) -> Task<Void, Never>? {
        guard !isLoading, currentRequestID == nil else { return nil }
        cancelRefresh()
        let directory = currentDirectory
        let navigationGeneration = nextRequestID
        nextRefreshID += 1
        let refreshID = nextRefreshID
        currentRefreshID = refreshID

        let listingService = listingService
        let task = Task { @MainActor [weak self, listingService] in
            var refreshedItems: [FileItem] = []

            do {
                for try await batch in listingService.batches(in: directory) {
                    guard !Task.isCancelled else {
                        self?.finishRefresh(refreshID)
                        return
                    }
                    guard self?.isCurrentRefresh(
                        refreshID,
                        directory: directory,
                        navigationGeneration: navigationGeneration
                    ) == true else {
                        return
                    }
                    refreshedItems.append(contentsOf: batch)
                }
            } catch is CancellationError {
                self?.finishRefresh(refreshID)
                return
            } catch {
                self?.completeRefreshFailure(
                    error,
                    refreshID: refreshID,
                    directory: directory,
                    navigationGeneration: navigationGeneration
                )
                return
            }

            guard !Task.isCancelled else {
                self?.finishRefresh(refreshID)
                return
            }
            await self?.completeRefresh(
                refreshedItems,
                refreshID: refreshID,
                directory: directory,
                navigationGeneration: navigationGeneration,
                preservedErrorMessage: preservedErrorMessage
            )
        }
        refreshTask = task
        taskLifecycle.setRefresh(task)
        return task
    }

    private func replaceMonitor(for directory: URL) {
        monitorTask?.cancel()
        taskLifecycle.setMonitor(nil)
        let events = monitor.events(for: directory)
        let task = Task { @MainActor [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                self?.receiveMonitorEvent(for: directory)
            }
        }
        monitorTask = task
        taskLifecycle.setMonitor(task)
    }

    private func receiveMonitorEvent(for directory: URL) {
        if isLoading {
            if Self.entryPath(committedState.directory) == Self.entryPath(directory) {
                pendingMonitorRefreshDirectory = committedState.directory
            }
            return
        }
        guard Self.entryPath(currentDirectory) == Self.entryPath(directory) else { return }
        beginRefresh()
    }

    private func isCurrentRefresh(
        _ refreshID: UInt64,
        directory: URL,
        navigationGeneration: UInt64
    ) -> Bool {
        currentRefreshID == refreshID
            && !isLoading
            && currentRequestID == nil
            && nextRequestID == navigationGeneration
            && Self.entryPath(currentDirectory) == Self.entryPath(directory)
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        taskLifecycle.setRefresh(nil)
        currentRefreshID = nil
    }

    private func finishRefresh(_ refreshID: UInt64) {
        guard currentRefreshID == refreshID else { return }
        refreshTask = nil
        taskLifecycle.setRefresh(nil)
        currentRefreshID = nil
    }

    private func completeRefreshFailure(
        _ error: Error,
        refreshID: UInt64,
        directory: URL,
        navigationGeneration: UInt64
    ) {
        guard isCurrentRefresh(
            refreshID,
            directory: directory,
            navigationGeneration: navigationGeneration
        ) else { return }
        errorMessage = error.localizedDescription
        finishRefresh(refreshID)
    }

    private func completeRefresh(
        _ refreshedItems: [FileItem],
        refreshID: UInt64,
        directory: URL,
        navigationGeneration: UInt64,
        preservedErrorMessage: String?
    ) async {
        guard isCurrentRefresh(
            refreshID,
            directory: directory,
            navigationGeneration: navigationGeneration
        ) else { return }
        let selectedPaths = Set(selection.map(Self.entryPath))
        let previousRevision = itemsRevision
        let replacementRevision = previousRevision &+ 1
        let projection = await stageRefreshProjection(
            items: refreshedItems,
            itemsRevision: replacementRevision,
            refreshID: refreshID,
            directory: directory,
            navigationGeneration: navigationGeneration,
            previousItemsRevision: previousRevision
        )
        guard let projection else {
            finishRefresh(refreshID)
            return
        }
        guard isCurrentRefresh(
            refreshID,
            directory: directory,
            navigationGeneration: navigationGeneration
        ), itemsRevision == previousRevision else { return }
        items = refreshedItems
        itemsRevision = replacementRevision
        selection = Set(selectedPaths.compactMap { projection.urlByEntryPath[$0] })
        acceptProjection(projection)
        errorMessage = preservedErrorMessage
        committedState = snapshot()
        finishRefresh(refreshID)
    }

    private func isCurrentRequest(_ requestID: UInt64) -> Bool {
        currentRequestID == requestID
    }

    private func cancelLoading(requestID: UInt64) async {
        guard isCurrentRequest(requestID) else { return }
        cancelLoading()
        await ensureCurrentProjection(
            navigationGeneration: requestID,
            directory: currentDirectory
        )
    }

    private func receiveNavigationBatch(
        _ batch: [FileItem],
        requestID: UInt64,
        directory: URL
    ) async -> Bool {
        guard isCurrentRequest(requestID),
              Self.entryPath(currentDirectory) == Self.entryPath(directory)
        else { return false }

        switch batchBuffer.receive(batch) {
        case let .publish(firstBatch):
            items.reserveCapacity(items.count + firstBatch.count)
            items.append(contentsOf: firstBatch)
            itemsRevision &+= 1
            await rebuildProjection(
                navigationGeneration: requestID,
                directory: directory
            )
        case .scheduleFlush:
            scheduleBatchFlush(requestID: requestID, directory: directory)
        case .none:
            break
        }
        return isCurrentRequest(requestID)
            && Self.entryPath(currentDirectory) == Self.entryPath(directory)
    }

    private func scheduleBatchFlush(requestID: UInt64, directory: URL) {
        let sleeper = batchSleeper
        let delay = batchFlushDelay
        let task = Task { @MainActor [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.finishBatchFlushTimer(requestID: requestID, directory: directory)
            _ = await self.drainPendingNavigationBatches(
                requestID: requestID,
                directory: directory
            )
        }
        batchFlushTask = task
        taskLifecycle.setBatchFlush(task)
    }

    private func finishBatchFlushTimer(requestID: UInt64, directory: URL) {
        guard isCurrentRequest(requestID),
              Self.entryPath(currentDirectory) == Self.entryPath(directory)
        else { return }
        batchFlushTask = nil
        taskLifecycle.setBatchFlush(nil)
    }

    private func flushPendingNavigationBatches(
        requestID: UInt64,
        directory: URL
    ) async -> Bool {
        cancelBatchFlushTimer()
        return await drainPendingNavigationBatches(
            requestID: requestID,
            directory: directory
        )
    }

    private func drainPendingNavigationBatches(
        requestID: UInt64,
        directory: URL
    ) async -> Bool {
        guard isCurrentRequest(requestID),
              Self.entryPath(currentDirectory) == Self.entryPath(directory)
        else { return false }
        let pending = batchBuffer.drain()
        guard !pending.isEmpty else { return true }
        items.reserveCapacity(items.count + pending.count)
        items.append(contentsOf: pending)
        itemsRevision &+= 1
        await rebuildProjection(
            navigationGeneration: requestID,
            directory: directory
        )
        return isCurrentRequest(requestID)
            && Self.entryPath(currentDirectory) == Self.entryPath(directory)
    }

    private func cancelBatchFlushTimer() {
        batchFlushTask?.cancel()
        batchFlushTask = nil
        taskLifecycle.setBatchFlush(nil)
    }

    private func discardPendingBatchWork() {
        cancelBatchFlushTimer()
        batchBuffer = PaneBatchBuffer()
    }

    private func scheduleProjection() {
        let revision = itemsRevision
        let key = projectionKey(itemsRevision: revision)
        guard acceptedProjectionKey != key else { return }
        let snapshot = items
        let directory = currentDirectory
        let navigationGeneration = nextRequestID
        let generation = beginProjectionGeneration()
        let intersectsSelection = projectionChangesMembership(key)
        // Existing command and table routes read the result in the same main-actor
        // turn for a single listing batch. Keep that bounded compatibility path
        // synchronous; large-directory work always uses the detached path below.
        if snapshot.count <= Self.sameTurnProjectionLimit {
            let result = PaneItemProjector().project(items: snapshot, key: key)
            if canAcceptProjection(
                navigationGeneration: navigationGeneration,
                directory: directory,
                itemsRevision: revision,
                projectionGeneration: generation
            ) {
                acceptProjection(result, intersectsSelection: intersectsSelection)
            }
            return
        }
        let task = Task { @MainActor [weak self] in
            let result = await Self.project(items: snapshot, key: key)
            guard !Task.isCancelled, let self else { return }
            if self.canAcceptProjection(
                navigationGeneration: navigationGeneration,
                directory: directory,
                itemsRevision: revision,
                projectionGeneration: generation
            ) {
                self.acceptProjection(result, intersectsSelection: intersectsSelection)
            }
            self.finishScheduledProjection(generation: generation)
        }
        projectionTask = task
        taskLifecycle.setProjection(task)
    }

    private func ensureCurrentProjection(
        navigationGeneration: UInt64,
        directory: URL
    ) async {
        let key = projectionKey(itemsRevision: itemsRevision)
        guard acceptedProjectionKey != key else { return }
        await rebuildProjection(
            navigationGeneration: navigationGeneration,
            directory: directory
        )
    }

    private func rebuildProjection(
        navigationGeneration: UInt64,
        directory: URL
    ) async {
        let snapshot = items
        let revision = itemsRevision
        let key = projectionKey(itemsRevision: revision)
        let generation = beginProjectionGeneration()
        let intersectsSelection = projectionChangesMembership(key)
        let result = await Self.project(items: snapshot, key: key)
        guard !Task.isCancelled,
              canAcceptProjection(
                navigationGeneration: navigationGeneration,
                directory: directory,
                itemsRevision: revision,
                projectionGeneration: generation
              )
        else { return }
        acceptProjection(result, intersectsSelection: intersectsSelection)
    }

    private func stageRefreshProjection(
        items: [FileItem],
        itemsRevision: UInt64,
        refreshID: UInt64,
        directory: URL,
        navigationGeneration: UInt64,
        previousItemsRevision: UInt64
    ) async -> PaneItemProjection? {
        let key = projectionKey(itemsRevision: itemsRevision)
        let generation = beginProjectionGeneration()
        let result = await Self.project(items: items, key: key)
        guard !Task.isCancelled,
              isCurrentRefresh(
                refreshID,
                directory: directory,
                navigationGeneration: navigationGeneration
              ),
              self.itemsRevision == previousItemsRevision,
              projectionGeneration == generation
        else { return nil }
        return result
    }

    private func projectionKey(itemsRevision: UInt64) -> PaneProjectionKey {
        PaneProjectionKey(
            itemsRevision: itemsRevision,
            normalizedQuery: PaneFilenameFilter.normalize(filterQuery),
            sort: sort
        )
    }

    private func beginProjectionGeneration() -> UInt64 {
        projectionTask?.cancel()
        projectionTask = nil
        taskLifecycle.setProjection(nil)
        projectionGeneration &+= 1
        return projectionGeneration
    }

    private func invalidateProjectionWork() {
        _ = beginProjectionGeneration()
    }

    private func finishScheduledProjection(generation: UInt64) {
        guard projectionGeneration == generation else { return }
        projectionTask = nil
        taskLifecycle.setProjection(nil)
    }

    private func canAcceptProjection(
        navigationGeneration: UInt64,
        directory: URL,
        itemsRevision: UInt64,
        projectionGeneration: UInt64
    ) -> Bool {
        nextRequestID == navigationGeneration
            && Self.entryPath(currentDirectory) == Self.entryPath(directory)
            && self.itemsRevision == itemsRevision
            && self.projectionGeneration == projectionGeneration
    }

    private func projectionChangesMembership(_ key: PaneProjectionKey) -> Bool {
        guard let acceptedProjectionKey else { return true }
        return acceptedProjectionKey.itemsRevision != key.itemsRevision
            || acceptedProjectionKey.normalizedQuery != key.normalizedQuery
    }

    private func acceptProjection(
        _ projection: PaneItemProjection,
        intersectsSelection: Bool = true
    ) {
        visibleItems = projection.items
        visibleIndexByURL = projection.indexByURL
        visibleURLByEntryPath = projection.urlByEntryPath
        acceptedProjectionKey = projection.key
        if intersectsSelection {
            selection.formIntersection(projection.indexByURL.keys)
        }
    }

    private nonisolated static func project(
        items: [FileItem],
        key: PaneProjectionKey
    ) async -> PaneItemProjection {
        await Task.detached(priority: .userInitiated) {
            PaneItemProjector().project(items: items, key: key)
        }.value
    }

    private func failNavigation(_ error: Error, requestID: UInt64) async {
        guard isCurrentRequest(requestID) else { return }
        let intent = currentNavigationIntent
        discardPendingBatchWork()
        invalidateProjectionWork()
        restore(committedState)
        await ensureCurrentProjection(
            navigationGeneration: requestID,
            directory: committedState.directory
        )
        discardFailedHistoryDestination(for: intent)
        committedState = snapshot()
        let navigationErrorMessage = error.localizedDescription
        errorMessage = navigationErrorMessage
        finishRequest(requestID)
        reconcilePendingMonitorRefreshIfNeeded(preservingErrorMessage: navigationErrorMessage)
    }

    private func completeNavigation(to directory: URL, requestID: UInt64) {
        guard isCurrentRequest(requestID) else { return }
        discardPendingBatchWork()
        commitNavigationHistory(for: currentNavigationIntent, destination: directory)
        restoreDirectoryViewState(for: directory)
        committedState = snapshot()
        finishRequest(requestID)
        let shouldReconcileVisibleDirectory = pendingMonitorRefreshDirectory.map {
            Self.entryPath($0) == Self.entryPath(directory)
        } ?? false
        pendingMonitorRefreshDirectory = nil
        replaceMonitor(for: directory)
        if shouldReconcileVisibleDirectory {
            beginRefresh()
        }
        persistenceChangeHandler?()
    }

    private func storeCurrentDirectoryViewState() {
        viewStateCache.store(
            PaneDirectoryViewState(
                selection: selection,
                scrollAnchor: firstVisibleItem
            ),
            for: currentDirectory
        )
    }

    private func restoreDirectoryViewState(for directory: URL) {
        guard let saved = viewStateCache.value(for: directory) else {
            firstVisibleItem = nil
            scrollRestoreRequest = nil
            return
        }
        let loadedByPath = Dictionary(uniqueKeysWithValues: items.map {
            (Self.entryPath($0.url), $0.url)
        })
        selection = Set(saved.selection.compactMap {
            loadedByPath[Self.entryPath($0)]
        })
        firstVisibleItem = saved.scrollAnchor.flatMap {
            loadedByPath[Self.entryPath($0)]
        }
        scrollRestoreRequest = firstVisibleItem.map {
            PaneScrollRequest(id: UUID(), anchor: $0)
        }
    }

    private func reconcilePendingMonitorRefreshIfNeeded(
        preservingErrorMessage: String? = nil
    ) {
        guard let pendingMonitorRefreshDirectory else { return }
        self.pendingMonitorRefreshDirectory = nil
        guard Self.entryPath(currentDirectory) == Self.entryPath(pendingMonitorRefreshDirectory) else {
            return
        }
        beginRefresh(preservingErrorMessage: preservingErrorMessage)
    }

    private func finishRequest(_ requestID: UInt64) {
        guard isCurrentRequest(requestID) else { return }
        currentRequestID = nil
        currentNavigationIntent = nil
        loadTask = nil
        taskLifecycle.setLoad(nil)
        isLoading = false
    }

    private nonisolated static func awaitTask(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func snapshot() -> PaneSnapshot {
        PaneSnapshot(
            directory: currentDirectory,
            items: items,
            visibleItems: visibleItems,
            visibleIndexByURL: visibleIndexByURL,
            visibleURLByEntryPath: visibleURLByEntryPath,
            acceptedProjectionKey: acceptedProjectionKey,
            itemsRevision: itemsRevision,
            selection: selection,
            firstVisibleItem: firstVisibleItem,
            navigationHistory: navigationHistory
        )
    }

    private func restore(_ snapshot: PaneSnapshot) {
        currentDirectory = snapshot.directory
        items = snapshot.items
        visibleItems = snapshot.visibleItems
        visibleIndexByURL = snapshot.visibleIndexByURL
        visibleURLByEntryPath = snapshot.visibleURLByEntryPath
        acceptedProjectionKey = snapshot.acceptedProjectionKey
        itemsRevision = snapshot.itemsRevision
        selection = snapshot.selection
        firstVisibleItem = snapshot.firstVisibleItem.flatMap { anchor in
            snapshot.items.first {
                Self.entryPath($0.url) == Self.entryPath(anchor)
            }?.url
        }
        scrollRestoreRequest = firstVisibleItem.map {
            PaneScrollRequest(id: UUID(), anchor: $0)
        }
        navigationHistory = snapshot.navigationHistory
    }

    private func commitNavigationHistory(
        for intent: PaneNavigationIntent?,
        destination: URL
    ) {
        switch intent {
        case let .user(origin, recordsHistory):
            if recordsHistory {
                navigationHistory.recordUserNavigation(from: origin, to: destination)
            }
        case let .backward(origin, expectedDestination):
            navigationHistory.commitBackwardNavigation(
                from: origin,
                to: expectedDestination
            )
        case let .forward(origin, expectedDestination):
            navigationHistory.commitForwardNavigation(
                from: origin,
                to: expectedDestination
            )
        case nil:
            break
        }
    }

    private func discardFailedHistoryDestination(for intent: PaneNavigationIntent?) {
        switch intent {
        case let .backward(_, destination):
            navigationHistory.discardBackwardDestination(destination)
        case let .forward(_, destination):
            navigationHistory.discardForwardDestination(destination)
        case .user, nil:
            break
        }
    }

    private static func entryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

private final class PaneTaskLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var batchFlushTask: Task<Void, Never>?

    func setLoad(_ task: Task<Void, Never>?) {
        lock.withLock { loadTask = task }
    }

    func setRefresh(_ task: Task<Void, Never>?) {
        lock.withLock { refreshTask = task }
    }

    func setMonitor(_ task: Task<Void, Never>?) {
        lock.withLock { monitorTask = task }
    }

    func setProjection(_ task: Task<Void, Never>?) {
        lock.withLock { projectionTask = task }
    }

    func setBatchFlush(_ task: Task<Void, Never>?) {
        lock.withLock { batchFlushTask = task }
    }

    func cancelAll() {
        let tasks = lock.withLock {
            let tasks = [loadTask, refreshTask, monitorTask, projectionTask, batchFlushTask]
            loadTask = nil
            refreshTask = nil
            monitorTask = nil
            projectionTask = nil
            batchFlushTask = nil
            return tasks
        }
        tasks.forEach { $0?.cancel() }
    }
}

private struct PaneSnapshot {
    let directory: URL
    let items: [FileItem]
    let visibleItems: [FileItem]
    let visibleIndexByURL: [URL: Int]
    let visibleURLByEntryPath: [String: URL]
    let acceptedProjectionKey: PaneProjectionKey?
    let itemsRevision: UInt64
    let selection: Set<URL>
    let firstVisibleItem: URL?
    let navigationHistory: PaneNavigationHistory
}

private enum PaneNavigationIntent {
    case user(from: URL, recordsHistory: Bool)
    case backward(from: URL, destination: URL)
    case forward(from: URL, destination: URL)
}
