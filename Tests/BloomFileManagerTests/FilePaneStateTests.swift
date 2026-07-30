import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FilePaneStateTests {
    @Test func navigationMaintainsIndependentHistoryAndClearsSelection() async {
        let home = URL(filePath: "/private/test-home")
        let documents = home.appending(path: "Documents")
        let selected = home.appending(path: "selected.txt")
        let pane = FilePaneState(directory: home, listingService: StubDirectoryListingService(values: [:]))

        pane.selection = [selected]
        await pane.navigate(to: documents)

        #expect(pane.currentDirectory == documents)
        #expect(pane.selection.isEmpty)
        #expect(pane.backHistory == [home])
        #expect(pane.forwardHistory.isEmpty)
        #expect(pane.canGoBack)
        #expect(!pane.canGoForward)
    }

    @Test func backAndForwardRestoreNavigationHistory() async {
        let home = URL(filePath: "/private/test-home")
        let documents = home.appending(path: "Documents")
        let downloads = home.appending(path: "Downloads")
        let pane = FilePaneState(directory: home, listingService: StubDirectoryListingService(values: [:]))

        await pane.navigate(to: documents)
        await pane.navigate(to: downloads)
        await pane.goBack()

        #expect(pane.currentDirectory == documents)
        #expect(pane.backHistory == [home])
        #expect(pane.forwardHistory == [downloads])

        await pane.goForward()

        #expect(pane.currentDirectory == downloads)
        #expect(pane.backHistory == [home, documents])
        #expect(pane.forwardHistory.isEmpty)
    }

    @Test func successfulNavigationsKeepOnlyTheNewestHundredBackEntries() async {
        let root = URL(filePath: "/history-root")
        let pane = FilePaneState(directory: root, listingService: StubDirectoryListingService(values: [:]))

        for index in 1...105 {
            await pane.navigate(to: root.appending(path: "\(index)"))
        }

        #expect(pane.backHistory.count == 100)
    }

    @Test func failedBackNavigationRestoresThePreviousHistory() async {
        let home = URL(filePath: "/private/test-home")
        let documents = home.appending(path: "Documents")
        let downloads = home.appending(path: "Downloads")
        let pane = FilePaneState(
            directory: home,
            listingService: FailingDirectoryListingService(failingDirectories: [home])
        )

        await pane.navigate(to: documents)
        await pane.navigate(to: downloads)
        await pane.goBack()
        await pane.goBack()

        #expect(pane.currentDirectory == documents)
        #expect(pane.backHistory == [home])
        #expect(pane.forwardHistory == [downloads])
        #expect(pane.errorMessage != nil)
    }

    @Test func staleBatchesFromCancelledLoadsAreRejected() async {
        let home = URL(filePath: "/private/test-home")
        let slow = home.appending(path: "Slow")
        let fresh = home.appending(path: "Fresh")
        let staleItem = makeItem(named: "stale.txt", in: slow)
        let freshItem = makeItem(named: "fresh.txt", in: fresh)
        let pane = FilePaneState(
            directory: home,
            listingService: DelayedDirectoryListingService(
                delayedDirectory: slow,
                delayedItems: [staleItem],
                immediateDirectory: fresh,
                immediateItems: [freshItem]
            )
        )

        let slowLoad = Task { await pane.navigate(to: slow) }
        try? await Task.sleep(for: .milliseconds(10))
        await pane.navigate(to: fresh)
        await slowLoad.value

        #expect(pane.currentDirectory == fresh)
        #expect(pane.items == [freshItem])
        #expect(!pane.isLoading)
    }

    @Test func failingReplacementRestoresTheLastCommittedPaneState() async {
        let root = URL(filePath: "/")
        let home = URL(filePath: "/private/test-home")
        let slow = home.appending(path: "Slow")
        let fresh = home.appending(path: "Fresh")
        let homeItem = makeItem(named: "home.txt", in: home)
        let selected = homeItem.url
        let control = ControlledListingControl()
        let pane = FilePaneState(directory: root, listingService: ControlledDirectoryListingService(control: control))

        let homeLoad = Task { await pane.navigate(to: home) }
        await control.waitForStart(in: home, count: 1)
        await control.yield([homeItem], in: home, request: 0)
        await control.finish(in: home, request: 0)
        await homeLoad.value
        pane.selection = [selected]

        let slowLoad = Task { await pane.navigate(to: slow) }
        await control.waitForStart(in: slow, count: 1)

        let freshLoad = Task { await pane.navigate(to: fresh) }
        await control.waitForStart(in: fresh, count: 1)
        await control.fail(in: fresh, request: 0)
        await freshLoad.value
        await control.finish(in: slow, request: 0)
        await slowLoad.value

        #expect(pane.currentDirectory == home)
        #expect(pane.items == [homeItem])
        #expect(pane.selection == [selected])
        #expect(pane.backHistory == [root])
        #expect(pane.forwardHistory.isEmpty)
    }

    @Test func failedNavigationRollbackPreservesScrollAnchorForLaterReturn() async {
        // Catches rollback snapshots that omit the committed scroll anchor and
        // allow the next navigation to overwrite its cache entry with nil.
        let home = URL(filePath: "/rollback-home", directoryHint: .isDirectory)
        let blocked = URL(filePath: "/blocked", directoryHint: .isDirectory)
        let other = URL(filePath: "/other", directoryHint: .isDirectory)
        let anchor = makeItem(named: "anchor.txt", in: home)
        let pane = FilePaneState(
            directory: home,
            listingService: PartiallyFailingDirectoryListingService(
                values: [
                    home: [anchor],
                    other: [makeItem(named: "other.txt", in: other)]
                ],
                failingDirectories: [blocked]
            )
        )
        await pane.navigate(to: home, recordHistory: false)
        pane.recordFirstVisibleItem(anchor.url)

        await pane.navigate(to: blocked)
        await pane.navigate(to: other)
        await pane.goBack()

        #expect(pane.currentDirectory == home)
        #expect(pane.scrollRestoreRequest?.anchor == anchor.url)
    }

    @Test func cancelledSameDirectoryLoadCannotClearTheNewerLoadState() async {
        let root = URL(filePath: "/")
        let directory = URL(filePath: "/private/test-home")
        let latestItem = makeItem(named: "latest.txt", in: directory)
        let control = ControlledListingControl()
        let pane = FilePaneState(directory: root, listingService: ControlledDirectoryListingService(control: control))

        let firstLoad = Task { await pane.navigate(to: directory) }
        await control.waitForStart(in: directory, count: 1)

        let secondLoad = Task { await pane.navigate(to: directory) }
        await control.waitForStart(in: directory, count: 2)
        await firstLoad.value

        #expect(pane.currentDirectory == directory)
        #expect(pane.isLoading)

        await control.yield([latestItem], in: directory, request: 1)
        await control.finish(in: directory, request: 1)
        await secondLoad.value

        #expect(pane.items == [latestItem])
        #expect(!pane.isLoading)
    }

    @Test func cancellingNavigationStopsActiveLoadAndRejectsLateBatch() async {
        let home = URL(filePath: "/private/test-home")
        let slow = home.appending(path: "Slow")
        let lateItem = makeItem(named: "late.txt", in: slow)
        let control = ControlledListingControl()
        let pane = FilePaneState(directory: home, listingService: ControlledDirectoryListingService(control: control))

        let load = Task { await pane.navigate(to: slow) }
        await control.waitForStart(in: slow, count: 1)
        load.cancel()
        await control.yield([lateItem], in: slow, request: 0)
        await control.finish(in: slow, request: 0)
        await load.value

        #expect(pane.currentDirectory == home)
        #expect(pane.items.isEmpty)
        #expect(!pane.isLoading)
    }

    @Test func cancelledCallerCannotCleanUpReplacementNavigation() async {
        let home = URL(filePath: "/private/test-home")
        let cancelledDirectory = home.appending(path: "Cancelled")
        let replacementDirectory = home.appending(path: "Replacement")
        let replacementItem = makeItem(named: "replacement.txt", in: replacementDirectory)
        let control = ControlledListingControl()
        let cancellationHook = CancellationHook()
        let replacementTask = ReplacementTaskBox()
        let pane = FilePaneState(
            directory: home,
            listingService: CancellationHookListingService(control: control, hook: cancellationHook)
        )
        cancellationHook.setHandler { directory in
            guard directory == cancelledDirectory else { return }
            Task { @MainActor in
                replacementTask.task = Task {
                    await pane.navigate(to: replacementDirectory)
                }
            }
        }

        let cancelledLoad = Task { await pane.navigate(to: cancelledDirectory) }
        await control.waitForStart(in: cancelledDirectory, count: 1)
        cancelledLoad.cancel()
        await control.waitForStart(in: replacementDirectory, count: 1)
        await cancelledLoad.value

        #expect(pane.currentDirectory == replacementDirectory)
        #expect(pane.isLoading)

        await control.yield([replacementItem], in: replacementDirectory, request: 0)
        await control.finish(in: replacementDirectory, request: 0)
        await replacementTask.task?.value

        #expect(pane.currentDirectory == replacementDirectory)
        #expect(pane.items == [replacementItem])
        #expect(!pane.isLoading)
    }

    @Test func filterSessionUsesLoadedItemsAndRestoresCapturedSelection() async {
        let root = URL(filePath: "/filter-root", directoryHint: .isDirectory)
        let alpha = makeItem(named: "alpha.txt", in: root)
        let resume = makeItem(named: "Résumé.pdf", in: root)
        let korean = makeItem(named: "한글보고서.pdf", in: root)
        let listing = CountingDirectoryListingService(values: [root: [alpha, resume, korean]])
        let pane = FilePaneState(directory: root, listingService: listing)
        await pane.navigate(to: root, recordHistory: false)
        pane.selection = [resume.url]

        pane.beginFiltering()
        pane.updateFilterQuery("한글")

        #expect(pane.visibleItems.map(\.name) == ["한글보고서.pdf"])
        #expect(pane.selection.isEmpty)
        #expect(pane.filterResultCount == 1)
        #expect(listing.callCount(for: root) == 1)

        pane.dismissFiltering()

        #expect(pane.visibleItems.count == 3)
        #expect(pane.selection == [resume.url])
        #expect(pane.filterQuery.isEmpty)
        #expect(!pane.isFilterPresented)
    }

    @Test func navigationClearsPaneFilterWithoutRestoringOldDirectorySelection() async {
        let root = URL(filePath: "/filter-root", directoryHint: .isDirectory)
        let next = root.appending(path: "Next", directoryHint: .isDirectory)
        let selected = makeItem(named: "selected.txt", in: root)
        let pane = FilePaneState(
            directory: root,
            listingService: StubDirectoryListingService(values: [
                root: [selected],
                next: [makeItem(named: "next.txt", in: next)]
            ])
        )
        await pane.navigate(to: root, recordHistory: false)
        pane.selection = [selected.url]
        pane.beginFiltering()
        pane.updateFilterQuery("selected")

        await pane.navigate(to: next)

        #expect(!pane.isFilterPresented)
        #expect(pane.filterQuery.isEmpty)
        #expect(pane.selection.isEmpty)
    }

    @Test func returningToDirectoryRestoresExistingSelectionAndScrollAnchor() async {
        let a = URL(filePath: "/a", directoryHint: .isDirectory)
        let b = URL(filePath: "/b", directoryHint: .isDirectory)
        let first = makeItem(named: "first.txt", in: a)
        let middle = makeItem(named: "middle.txt", in: a)
        let pane = FilePaneState(
            directory: a,
            listingService: StubDirectoryListingService(values: [
                a: [first, middle],
                b: [makeItem(named: "other.txt", in: b)]
            ])
        )
        await pane.navigate(to: a, recordHistory: false)
        pane.selection = [middle.url]
        pane.recordFirstVisibleItem(first.url)

        await pane.navigate(to: b)
        await pane.goBack()

        #expect(pane.selection == [middle.url])
        #expect(pane.scrollRestoreRequest?.anchor == first.url)
    }

    @Test func missingRestorationTargetsAreSilentlyDiscarded() async {
        let a = URL(filePath: "/a", directoryHint: .isDirectory)
        let b = URL(filePath: "/b", directoryHint: .isDirectory)
        let disappearing = makeItem(named: "gone.txt", in: a)
        let listing = MutableDirectoryListingService(values: [
            a: [disappearing],
            b: []
        ])
        let pane = FilePaneState(directory: a, listingService: listing)
        await pane.navigate(to: a, recordHistory: false)
        pane.selection = [disappearing.url]
        pane.recordFirstVisibleItem(disappearing.url)

        await pane.navigate(to: b)
        listing.set([], for: a)
        await pane.goBack()

        #expect(pane.selection.isEmpty)
        #expect(pane.scrollRestoreRequest == nil)
        #expect(pane.errorMessage == nil)
    }
}

private struct FailingDirectoryListingService: DirectoryListingService {
    let failingDirectories: Set<URL>

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            if failingDirectories.contains(directory) {
                continuation.finish(throwing: ListingError.unavailable)
            } else {
                continuation.finish()
            }
        }
    }

    private enum ListingError: Error {
        case unavailable
    }
}

private struct PartiallyFailingDirectoryListingService: DirectoryListingService {
    let values: [URL: [FileItem]]
    let failingDirectories: Set<URL>

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            if failingDirectories.contains(directory) {
                continuation.finish(throwing: ListingError.unavailable)
            } else {
                continuation.yield(values[directory] ?? [])
                continuation.finish()
            }
        }
    }

    private enum ListingError: Error {
        case unavailable
    }
}

private struct DelayedDirectoryListingService: DirectoryListingService {
    let delayedDirectory: URL
    let delayedItems: [FileItem]
    let immediateDirectory: URL
    let immediateItems: [FileItem]

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            if directory == delayedDirectory {
                Task {
                    try? await Task.sleep(for: .milliseconds(30))
                    continuation.yield(delayedItems)
                    continuation.finish()
                }
            } else if directory == immediateDirectory {
                continuation.yield(immediateItems)
                continuation.finish()
            } else {
                continuation.finish()
            }
        }
    }
}

private final class CountingDirectoryListingService:
    DirectoryListingService,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values: [URL: [FileItem]]
    private var counts: [URL: Int] = [:]

    init(values: [URL: [FileItem]]) {
        self.values = values
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        lock.withLock { counts[directory, default: 0] += 1 }
        let items = values[directory] ?? []
        return AsyncThrowingStream { continuation in
            continuation.yield(items)
            continuation.finish()
        }
    }

    func callCount(for directory: URL) -> Int {
        lock.withLock { counts[directory, default: 0] }
    }
}

private final class MutableDirectoryListingService:
    DirectoryListingService,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [URL: [FileItem]]

    init(values: [URL: [FileItem]]) {
        self.values = values
    }

    func set(_ items: [FileItem], for directory: URL) {
        lock.withLock { values[directory] = items }
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let items = lock.withLock { values[directory] ?? [] }
        return AsyncThrowingStream { continuation in
            continuation.yield(items)
            continuation.finish()
        }
    }
}

private struct ControlledDirectoryListingService: DirectoryListingService {
    let control: ControlledListingControl

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            Task {
                await control.register(continuation, in: directory)
            }
        }
    }
}

private struct CancellationHookListingService: DirectoryListingService {
    let control: ControlledListingControl
    let hook: CancellationHook

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    hook.fire(directory)
                }
            }
            Task {
                await control.register(continuation, in: directory)
            }
        }
    }
}

private final class CancellationHook: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URL) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (URL) -> Void) {
        lock.withLock {
            self.handler = handler
        }
    }

    func fire(_ directory: URL) {
        let callback: (@Sendable (URL) -> Void)? = lock.withLock { self.handler }
        callback?(directory)
    }
}

@MainActor
private final class ReplacementTaskBox {
    var task: Task<Void, Never>?
}

private actor ControlledListingControl {
    typealias Continuation = AsyncThrowingStream<[FileItem], Error>.Continuation

    private var continuations: [URL: [Continuation]] = [:]
    private var startCounts: [URL: Int] = [:]
    private var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func register(_ continuation: Continuation, in directory: URL) {
        continuations[directory, default: []].append(continuation)
        startCounts[directory, default: 0] += 1
        startWaiters.removeValue(forKey: directory)?.forEach { $0.resume() }
    }

    func waitForStart(in directory: URL, count: Int) async {
        guard startCounts[directory, default: 0] < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters[directory, default: []].append(continuation)
        }
    }

    func yield(_ items: [FileItem], in directory: URL, request: Int) {
        continuations[directory]?[request].yield(items)
    }

    func finish(in directory: URL, request: Int) {
        continuations[directory]?[request].finish()
    }

    func fail(in directory: URL, request: Int) {
        continuations[directory]?[request].finish(throwing: ControlledListingError.failed)
    }

    private enum ControlledListingError: Error {
        case failed
    }
}

private func makeItem(named name: String, in directory: URL) -> FileItem {
    FileItem(
        url: directory.appending(path: name),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: 1,
        typeDescription: "Text"
    )
}
