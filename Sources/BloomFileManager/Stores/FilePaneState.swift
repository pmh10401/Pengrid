import Foundation
import Observation

@MainActor @Observable
final class FilePaneState {
    private let listingService: any DirectoryListingService
    private let monitor: any DirectoryMonitor
    private nonisolated let taskLifecycle = PaneTaskLifecycle()
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var currentRequestID: UInt64?
    private var nextRequestID: UInt64 = 0
    private var currentRefreshID: UInt64?
    private var nextRefreshID: UInt64 = 0
    private var pendingMonitorRefreshDirectory: URL?
    private var committedState: PaneSnapshot
    private var persistenceChangeHandler: (@MainActor () -> Void)?
    private var selectionBeforeFiltering: Set<URL> = []
    private var navigationHistory = PaneNavigationHistory(capacity: 100)
    private var viewStateCache = PaneViewStateCache(capacity: 100)
    private var firstVisibleItem: URL?

    private(set) var currentDirectory: URL
    private(set) var items: [FileItem] = []
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
    var visibleItems: [FileItem] {
        sort.apply(to: PaneFilenameFilter(query: filterQuery).apply(to: items))
    }
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
        filterQuery = query
        let visibleURLs = Set(visibleItems.map(\.url))
        selection.formIntersection(visibleURLs)
    }

    func dismissFiltering() {
        let captured = selectionBeforeFiltering
        isFilterPresented = false
        filterQuery = ""
        selectionBeforeFiltering.removeAll()
        let loadedURLs = Set(items.map(\.url))
        selection = captured.intersection(loadedURLs)
        requestTableFocus()
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
        monitor: any DirectoryMonitor = LiveDirectoryMonitor()
    ) {
        currentDirectory = directory
        self.sort = sort
        self.listingService = listingService
        self.monitor = monitor
        committedState = PaneSnapshot(
            directory: directory,
            items: [],
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
        return startNavigation(to: directory, recordHistory: recordHistory)
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
    }

    func cancelLoading() {
        cancelLoading(recoverDirtyMonitor: true)
    }

    private func cancelLoading(recoverDirtyMonitor: Bool) {
        guard isLoading else { return }
        loadTask?.cancel()
        taskLifecycle.setLoad(nil)
        restore(committedState)
        currentRequestID = nil
        loadTask = nil
        isLoading = false
        if recoverDirtyMonitor {
            reconcilePendingMonitorRefreshIfNeeded()
        }
    }

    private func startNavigation(
        to directory: URL,
        recordHistory: Bool
    ) -> Task<Void, Never> {
        storeCurrentDirectoryViewState()
        if recordHistory {
            navigationHistory.recordUserNavigation(from: currentDirectory, to: directory)
        }

        currentDirectory = directory
        selection.removeAll()
        firstVisibleItem = nil
        scrollRestoreRequest = nil
        clearPendingRename()
        items.removeAll(keepingCapacity: true)
        errorMessage = nil
        isLoading = true

        nextRequestID += 1
        let requestID = nextRequestID
        currentRequestID = requestID
        let listingService = listingService
        let task = Task { @MainActor [weak self, listingService] in
            do {
                for try await batch in listingService.batches(in: directory) {
                    guard !Task.isCancelled else {
                        self?.cancelLoading(requestID: requestID)
                        return
                    }
                    guard self?.appendNavigationBatch(batch, requestID: requestID) == true else {
                        return
                    }
                }
            } catch is CancellationError {
                self?.cancelLoading(requestID: requestID)
                return
            } catch {
                self?.failNavigation(error, requestID: requestID)
                return
            }

            guard !Task.isCancelled else {
                self?.cancelLoading(requestID: requestID)
                return
            }
            self?.completeNavigation(to: directory, requestID: requestID)
        }
        loadTask = task
        taskLifecycle.setLoad(task)
        return task
    }

    func goBack() async {
        prepareForNavigation()
        let previousState = snapshot()
        guard let target = navigationHistory.popBackward(from: currentDirectory) else { return }
        committedState = previousState
        let task = startNavigation(to: target, recordHistory: false)
        await Self.awaitTask(task)
    }

    func goForward() async {
        prepareForNavigation()
        let previousState = snapshot()
        guard let target = navigationHistory.popForward(from: currentDirectory) else { return }
        committedState = previousState
        let task = startNavigation(to: target, recordHistory: false)
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
            self?.completeRefresh(
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
    ) {
        guard isCurrentRefresh(
            refreshID,
            directory: directory,
            navigationGeneration: navigationGeneration
        ) else { return }
        let selectedPaths = Set(selection.map(Self.entryPath))
        items = refreshedItems
        selection = Set(refreshedItems.lazy
            .filter { selectedPaths.contains(Self.entryPath($0.url)) }
            .map(\.url))
        errorMessage = preservedErrorMessage
        committedState = snapshot()
        finishRefresh(refreshID)
    }

    private func isCurrentRequest(_ requestID: UInt64) -> Bool {
        currentRequestID == requestID
    }

    private func cancelLoading(requestID: UInt64) {
        guard isCurrentRequest(requestID) else { return }
        cancelLoading()
    }

    private func appendNavigationBatch(_ batch: [FileItem], requestID: UInt64) -> Bool {
        guard isCurrentRequest(requestID) else { return false }
        items.append(contentsOf: batch)
        return true
    }

    private func failNavigation(_ error: Error, requestID: UInt64) {
        guard isCurrentRequest(requestID) else { return }
        restore(committedState)
        let navigationErrorMessage = error.localizedDescription
        errorMessage = navigationErrorMessage
        finishRequest(requestID)
        reconcilePendingMonitorRefreshIfNeeded(preservingErrorMessage: navigationErrorMessage)
    }

    private func completeNavigation(to directory: URL, requestID: UInt64) {
        guard isCurrentRequest(requestID) else { return }
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
            selection: selection,
            firstVisibleItem: firstVisibleItem,
            navigationHistory: navigationHistory
        )
    }

    private func restore(_ snapshot: PaneSnapshot) {
        currentDirectory = snapshot.directory
        items = snapshot.items
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

    func setLoad(_ task: Task<Void, Never>?) {
        lock.withLock { loadTask = task }
    }

    func setRefresh(_ task: Task<Void, Never>?) {
        lock.withLock { refreshTask = task }
    }

    func setMonitor(_ task: Task<Void, Never>?) {
        lock.withLock { monitorTask = task }
    }

    func cancelAll() {
        let tasks = lock.withLock {
            let tasks = [loadTask, refreshTask, monitorTask]
            loadTask = nil
            refreshTask = nil
            monitorTask = nil
            return tasks
        }
        tasks.forEach { $0?.cancel() }
    }
}

private struct PaneSnapshot {
    let directory: URL
    let items: [FileItem]
    let selection: Set<URL>
    let firstVisibleItem: URL?
    let navigationHistory: PaneNavigationHistory
}
