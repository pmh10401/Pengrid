import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FilePaneStateTests {
    @Test func projectionAcceptanceHandlerRunsAfterProjectionStateIsAssigned() async {
        let directory = URL(filePath: "/acceptance")
        let item = makeItem(named: "accepted.txt", byteSize: 1, in: directory)
        let pane = FilePaneState(directory: directory, listingService: StubDirectoryListingService(values: [directory: [item]]))
        var observed = false
        pane.projectionAcceptanceHandler = { _ in
            observed = pane.visibleItems == [item]
                && pane.visibleIndexByURL[item.url] == 0
                && pane.selection.isEmpty
                && pane.acceptedProjectionToken != nil
                && pane.acceptedProjectionDiagnostics.path == .activeOrderFullScan
        }
        await pane.navigate(to: directory, recordHistory: false)
        #expect(observed)
    }

    @Test func acceptedPaneProjectionStateReplacesOnlyTheRequestedAggregateMembers() {
        // Catches a projection aggregate replacement that accidentally drops
        // indexes, immutable metadata, or the current selection.
        let directory = URL(filePath: "/accepted-projection-state", directoryHint: .isDirectory)
        let item = makeItem(named: "visible.txt", in: directory)
        let key = PaneProjectionKey(itemsRevision: 3, normalizedQuery: "visible", sort: .init())
        let token = PaneProjectionToken(navigationGeneration: 7, projectionGeneration: 11)
        let diagnostics = PaneProjectionDiagnostics(
            path: .activeOrderFullScan,
            visitedASCIIPositions: 1,
            visitedLocalizedPositions: 0
        )
        let state = AcceptedPaneProjectionState(
            directoryKey: PaneEntryPath.normalize(directory),
            key: key,
            token: token,
            visibleItems: [item],
            indexByURL: [item.url.standardizedFileURL: 0],
            urlByEntryPath: [PaneEntryPath.normalize(item.url): item.url],
            selection: [item.url],
            activeOrder: nil,
            search: nil,
            diagnostics: diagnostics
        )

        let clearedSelection = state.replacing(selection: [])
        let replacementMetadata = state.replacing(activeOrder: nil, search: nil)

        #expect(clearedSelection.selection.isEmpty)
        #expect(clearedSelection.visibleItems == [item])
        #expect(clearedSelection.indexByURL == [item.url.standardizedFileURL: 0])
        #expect(clearedSelection.urlByEntryPath == [PaneEntryPath.normalize(item.url): item.url])
        #expect(clearedSelection.key == key)
        #expect(clearedSelection.token == token)
        #expect(clearedSelection.diagnostics == diagnostics)
        #expect(replacementMetadata == state)
    }

    @Test func filteredOutPendingRenameIsCancelledByTheAcceptedSelectionReplacement() async {
        // Catches a projection publication that changes membership without
        // running the existing pending-rename identity validation.
        let directory = URL(filePath: "/filtered-rename", directoryHint: .isDirectory)
        let selected = makeItem(named: "selected.txt", in: directory)
        let other = makeItem(named: "other.txt", in: directory)
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: [selected, other]])
        )
        await pane.navigate(to: directory, recordHistory: false)
        pane.selection = [selected.url]
        #expect(pane.requestInlineRename())

        pane.updateFilterQuery("other")

        #expect(await waitForPaneCondition {
            pane.visibleItems == [other]
                && pane.selection.isEmpty
                && pane.pendingRenameTarget == nil
                && pane.renameRequestID == nil
        })
    }

    @Test func acceptProjectionPublishesOneAggregateInsteadOfIndependentProjectionFields() throws {
        // This deliberately protects the atomic-publication boundary specified
        // for the pane, where a partial assignment exposes mixed rows/indexes.
        let source = try String(contentsOf: filePaneStateSourceURL(), encoding: .utf8)
        let body = try #require(
            source.components(separatedBy: "private func acceptProjection(").dropFirst().first?
                .components(separatedBy: "private func replaceAcceptedProjectionMetadata").first
        )
        let assignments = body.components(separatedBy: "acceptedProjectionState =").count - 1

        #expect(assignments == 1)
        #expect(!body.contains("visibleItems ="))
        #expect(!body.contains("visibleIndexByURL ="))
        #expect(!body.contains("visibleURLByEntryPath ="))
        #expect(!body.contains("acceptedProjectionKey ="))
    }
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

    @Test func failedBackNavigationDropsOnlyTheAttemptedDestination() async {
        let home = URL(filePath: "/private/test-home")
        let stale = home.appending(path: "Stale")
        let documents = home.appending(path: "Documents")
        let downloads = home.appending(path: "Downloads")
        let listing = MutableFailingDirectoryListingService()
        let pane = FilePaneState(
            directory: home,
            listingService: listing
        )

        await pane.navigate(to: stale)
        await pane.navigate(to: documents)
        await pane.navigate(to: downloads)
        await pane.goBack()
        listing.fail(stale)
        await pane.goBack()

        #expect(pane.currentDirectory == documents)
        #expect(pane.backHistory == [home])
        #expect(pane.forwardHistory == [downloads])
        #expect(pane.errorMessage != nil)

        await pane.goBack()

        #expect(pane.currentDirectory == home)
        #expect(pane.backHistory.isEmpty)
        #expect(pane.forwardHistory == [downloads, documents])
    }

    @Test func failedForwardNavigationDropsOnlyTheAttemptedDestination() async {
        let home = URL(filePath: "/private/test-home")
        let documents = home.appending(path: "Documents")
        let stale = home.appending(path: "Stale")
        let downloads = home.appending(path: "Downloads")
        let listing = MutableFailingDirectoryListingService()
        let pane = FilePaneState(
            directory: home,
            listingService: listing
        )

        await pane.navigate(to: documents)
        await pane.navigate(to: stale)
        await pane.navigate(to: downloads)
        await pane.goBack()
        await pane.goBack()
        listing.fail(stale)
        await pane.goForward()

        #expect(pane.currentDirectory == documents)
        #expect(pane.backHistory == [home])
        #expect(pane.forwardHistory == [downloads])
        #expect(pane.errorMessage != nil)

        await pane.goForward()

        #expect(pane.currentDirectory == downloads)
        #expect(pane.backHistory == [home, documents])
        #expect(pane.forwardHistory.isEmpty)
    }

    @Test func cancelledBackNavigationRestoresCompletePriorHistory() async {
        let home = URL(filePath: "/private/test-home")
        let documents = home.appending(path: "Documents")
        let downloads = home.appending(path: "Downloads")
        let control = ControlledListingControl()
        let pane = FilePaneState(
            directory: home,
            listingService: ControlledDirectoryListingService(control: control)
        )

        let documentsLoad = Task { await pane.navigate(to: documents) }
        await control.waitForStart(in: documents, count: 1)
        await control.finish(in: documents, request: 0)
        await documentsLoad.value
        let downloadsLoad = Task { await pane.navigate(to: downloads) }
        await control.waitForStart(in: downloads, count: 1)
        await control.finish(in: downloads, request: 0)
        await downloadsLoad.value

        let backLoad = Task { await pane.goBack() }
        await control.waitForStart(in: documents, count: 2)
        backLoad.cancel()
        await control.finish(in: documents, request: 1)
        await backLoad.value

        #expect(pane.currentDirectory == downloads)
        #expect(pane.backHistory == [home, documents])
        #expect(pane.forwardHistory.isEmpty)
    }

    @Test func supersededForwardNavigationRestoresCompletePriorHistory() async {
        let home = URL(filePath: "/private/test-home")
        let documents = home.appending(path: "Documents")
        let downloads = home.appending(path: "Downloads")
        let replacement = home.appending(path: "Replacement")
        let control = ControlledListingControl()
        let pane = FilePaneState(
            directory: home,
            listingService: ControlledDirectoryListingService(control: control)
        )

        let documentsLoad = Task { await pane.navigate(to: documents) }
        await control.waitForStart(in: documents, count: 1)
        await control.finish(in: documents, request: 0)
        await documentsLoad.value
        let downloadsLoad = Task { await pane.navigate(to: downloads) }
        await control.waitForStart(in: downloads, count: 1)
        await control.finish(in: downloads, request: 0)
        await downloadsLoad.value
        let backLoad = Task { await pane.goBack() }
        await control.waitForStart(in: documents, count: 2)
        await control.finish(in: documents, request: 1)
        await backLoad.value

        let forwardLoad = Task { await pane.goForward() }
        await control.waitForStart(in: downloads, count: 2)
        let replacementLoad = Task {
            await pane.navigate(to: replacement, recordHistory: false)
        }
        await control.waitForStart(in: replacement, count: 1)
        await control.finish(in: downloads, request: 1)
        await control.finish(in: replacement, request: 0)
        await forwardLoad.value
        await replacementLoad.value

        #expect(pane.currentDirectory == replacement)
        #expect(pane.backHistory == [home])
        #expect(pane.forwardHistory == [downloads])
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

    @Test func firstNavigationBatchPublishesBeforeTheListingCompletes() async {
        let home = URL(filePath: "/first-batch-home", directoryHint: .isDirectory)
        let destination = URL(filePath: "/first-batch", directoryHint: .isDirectory)
        let first = makeItem(named: "first.txt", in: destination)
        let control = ControlledListingControl()
        let pane = FilePaneState(
            directory: home,
            listingService: ControlledDirectoryListingService(control: control)
        )

        let load = Task { await pane.navigate(to: destination) }
        await control.waitForStart(in: destination, count: 1)
        await control.yield([first], in: destination, request: 0)

        #expect(await waitForPaneCondition { pane.visibleItems == [first] })
        #expect(pane.isLoading)
        #expect(pane.visibleIndexByURL == [first.url.standardizedFileURL: 0])

        await control.finish(in: destination, request: 0)
        await load.value
    }

    @Test func laterNavigationBatchesCoalesceUntilTheControlledFlushAdvances() async {
        let home = URL(filePath: "/coalescing-home", directoryHint: .isDirectory)
        let destination = URL(filePath: "/coalescing", directoryHint: .isDirectory)
        let first = makeItem(named: "first.txt", in: destination)
        let second = makeItem(named: "second.txt", in: destination)
        let third = makeItem(named: "third.txt", in: destination)
        let control = ControlledListingControl()
        let sleeper = ControlledPaneBatchSleeper()
        let pane = FilePaneState(
            directory: home,
            listingService: ControlledDirectoryListingService(control: control),
            batchSleeper: sleeper
        )

        let load = Task { await pane.navigate(to: destination) }
        await control.waitForStart(in: destination, count: 1)
        await control.yield([first], in: destination, request: 0)
        #expect(await waitForPaneCondition { pane.visibleItems == [first] })

        await control.yield([second], in: destination, request: 0)
        await control.yield([third], in: destination, request: 0)
        await sleeper.waitForSleepCount(1)
        #expect(await sleeper.sleepCount == 1)
        #expect(await sleeper.requestedDurations == [.milliseconds(60)])
        #expect(pane.visibleItems == [first])

        await sleeper.advance()
        #expect(await waitForPaneCondition {
            pane.visibleItems.map(\.name) == ["first.txt", "second.txt", "third.txt"]
        })

        await control.finish(in: destination, request: 0)
        await load.value
    }

    @Test func navigationCompletionFlushesPendingBatchesBeforeReturning() async {
        let home = URL(filePath: "/completion-home", directoryHint: .isDirectory)
        let destination = URL(filePath: "/completion", directoryHint: .isDirectory)
        let first = makeItem(named: "first.txt", in: destination)
        let second = makeItem(named: "second.txt", in: destination)
        let control = ControlledListingControl()
        let sleeper = ControlledPaneBatchSleeper()
        let pane = FilePaneState(
            directory: home,
            listingService: ControlledDirectoryListingService(control: control),
            batchSleeper: sleeper
        )

        let load = Task { await pane.navigate(to: destination) }
        await control.waitForStart(in: destination, count: 1)
        await control.yield([first], in: destination, request: 0)
        #expect(await waitForPaneCondition { pane.visibleItems == [first] })
        await control.yield([second], in: destination, request: 0)
        await sleeper.waitForSleepCount(1)

        await control.finish(in: destination, request: 0)
        await load.value

        #expect(pane.items.map(\.name) == ["first.txt", "second.txt"])
        #expect(pane.visibleItems.map(\.name) == ["first.txt", "second.txt"])
        await sleeper.advance()
    }

    @Test func rapidQueryAndSortChangesPublishOnlyTheNewestProjection() async {
        let directory = URL(filePath: "/projection-generation", directoryHint: .isDirectory)
        let item = makeItem(named: "item.txt", byteSize: 10, in: directory)
        let beta = makeItem(named: "beta.txt", byteSize: 30, in: directory)
        let projector = ControlledPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: [item, beta]]),
            projector: projector
        )
        await pane.navigate(to: directory, recordHistory: false)

        await projector.suspendNextProjection()
        pane.updateFilterQuery("item")
        #expect(await waitForProjectionStart(projector, count: 2))

        pane.sort = FileSort(key: .size, direction: .descending)
        pane.updateFilterQuery("beta")
        #expect(await waitForProjectionStart(projector, count: 3))

        #expect(await waitForPaneCondition { pane.visibleItems == [beta] })
        #expect(!(await projector.hasCompleted(request: 1)))
        let acceptedToken = pane.acceptedProjectionToken
        let acceptedDiagnostics = pane.acceptedProjectionDiagnostics

        await projector.resumeProjection(request: 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(!(await projector.hasCompleted(request: 1)))
        #expect(pane.visibleItems == [beta])
        #expect(pane.visibleIndexByURL == [beta.url.standardizedFileURL: 0])
        #expect(pane.acceptedProjectionToken == acceptedToken)
        #expect(pane.acceptedProjectionDiagnostics == acceptedDiagnostics)
    }

    @Test func matchingActiveOrderFiltersWithoutResorting() async {
        let directory = URL(filePath: "/active-order-route", directoryHint: .isDirectory)
        let items = (0..<20).map { makeItem(named: "report-\($0).txt", byteSize: Int64($0), in: directory) }
        let projector = ControlledPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: items]),
            projector: projector
        )

        await pane.navigate(to: directory, recordHistory: false)
        #expect(await projector.activeOrderBuildCount == 1)

        pane.updateFilterQuery("report-1")

        #expect(await waitForPaneCondition {
            pane.visibleItems == FileSort().apply(to: PaneFilenameFilter(query: "report-1").apply(to: items))
        })
        #expect(await projector.latestProjectionPath == .activeOrderFullScan)
        #expect(await projector.sortedSubsetCount == 0)
    }

    @Test func nonemptySortChangeUsesOnlyAcceptedVisibleMembershipThenWarmsTheOrder() async {
        let directory = URL(filePath: "/subset-sort-route", directoryHint: .isDirectory)
        let items = (0..<100).map { makeItem(named: "report-\($0).txt", byteSize: Int64(100 - $0), in: directory) }
        let projector = ControlledPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: items]),
            projector: projector
        )
        await pane.navigate(to: directory, recordHistory: false)
        pane.updateFilterQuery("report-1")
        #expect(await waitForPaneCondition { pane.visibleItems.count == 11 })
        let acceptedToken = pane.acceptedProjectionToken

        pane.sort = FileSort(key: .size, direction: .descending)

        let expected = pane.sort.apply(to: PaneFilenameFilter(query: "report-1").apply(to: items))
        #expect(await waitForPaneCondition { pane.visibleItems == expected })
        #expect(await projector.sortedSubsetCount == 1)
        #expect(await projector.lastSubsetInputCount == 11)
        #expect(pane.acceptedProjectionDiagnostics.path == .sortedVisibleSubset)
        #expect(pane.acceptedProjectionToken != acceptedToken)
        #expect(await projector.activeOrderBuildCount == 2)
    }

    @Test func queryDuringWarmUpFallsBackThenStartsOneReplacementWarmUp() async {
        let directory = URL(filePath: "/warm-up-replacement", directoryHint: .isDirectory)
        let items = (0..<10_000).map { makeItem(named: "report-\($0).txt", byteSize: Int64($0), in: directory) }
        let projector = ControlledPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: items]),
            projector: projector
        )
        await pane.navigate(to: directory, recordHistory: false)
        pane.updateFilterQuery("19")
        #expect(await waitForPaneCondition { pane.visibleItems.count == 299 })

        await projector.suspendNextActiveOrderBuild()
        pane.sort = FileSort(key: .size, direction: .descending)
        #expect(await projector.waitForWarmUpStart(count: 1))

        pane.updateFilterQuery("199")

        #expect(await projector.warmUpCancellationCount == 1)
        #expect(await waitForPaneCondition {
            pane.visibleItems == pane.sort.apply(to: PaneFilenameFilter(query: "199").apply(to: items))
        })
        #expect(await projector.latestProjectionPath == .fallbackFilterThenSort)
        #expect(await projector.activeOrderBuildCount == 3)
    }

    @Test func replacementQueryCancelsTheOwnedDetachedWorker() async {
        let directory = URL(filePath: "/owned-projection-cancellation", directoryHint: .isDirectory)
        let items = (0..<10_000).map { makeItem(named: "report-\($0).txt", in: directory) }
        let projector = CancellationRecordingPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: items]),
            projector: projector
        )
        await pane.navigate(to: directory, recordHistory: false)
        pane.errorMessage = "previous projection error"

        await projector.suspendNextProjection()
        pane.updateFilterQuery("report")
        #expect(await waitForCancellationProjectionStart(projector, count: 2))

        pane.updateFilterQuery("report-1999")

        #expect(await projector.waitForCancellation(request: 1))
        #expect(await waitForPaneCondition { pane.filterQuery == "report-1999" })
        #expect(!(await projector.didPublish(request: 1)))
        #expect(pane.errorMessage == "previous projection error")
    }

    @Test func cancelledProjectionNeverPublishesItsStaleResult() async {
        let directory = URL(filePath: "/stale-projection-cancellation", directoryHint: .isDirectory)
        let old = makeItem(named: "report-old.txt", in: directory)
        let replacement = makeItem(named: "report-new.txt", in: directory)
        let projector = CancellationRecordingPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: [old, replacement]]),
            projector: projector
        )
        await pane.navigate(to: directory, recordHistory: false)

        await projector.suspendNextProjection()
        pane.updateFilterQuery("old")
        #expect(await waitForCancellationProjectionStart(projector, count: 2))
        pane.updateFilterQuery("new")

        #expect(await projector.waitForCancellation(request: 1))
        #expect(await waitForPaneCondition { pane.visibleItems == [replacement] })
        #expect(!(await projector.didPublish(request: 1)))
    }

    @Test func rapidTwentyQueryBurstDrainsCancelledProjectionWorkers() async {
        let directory = URL(filePath: "/projection-burst-drain", directoryHint: .isDirectory)
        let items = (0..<10_000).map { makeItem(named: "report-\($0).txt", in: directory) }
        let projector = CooperativeCancellationPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: items]),
            projector: projector
        )
        await pane.navigate(to: directory, recordHistory: false)

        for query in (0..<20).map({ "report-\($0)" }) {
            pane.updateFilterQuery(query)
            #expect(await projector.waitUntilStarted(request: query))
        }
        pane.updateFilterQuery("report-final")
        #expect(await projector.waitUntilStarted(request: "report-final"))

        #expect(await projector.waitForCancellations(count: 20))
        #expect(await projector.waitForDrain())
        #expect(await projector.cancelledRequestCount == 20)
        let cancelledRequests = await projector.cancelledRequests
        for request in cancelledRequests {
            #expect(
                await projector.postCancellationVisits(for: request)
                    <= PaneFilenameFilter.cancellationCheckStride
            )
        }
        #expect(await projector.activeWorkerCount == 0)
        #expect(await projector.retainedSnapshotCount == 0)
        #expect(await projector.retainedResultCount == 0)
    }

    @Test func navigationCancelsTheProjectionScheduledWhileResettingTheOldDirectory() async {
        let oldDirectory = URL(filePath: "/old-projection-navigation", directoryHint: .isDirectory)
        let newDirectory = URL(filePath: "/new-projection-navigation", directoryHint: .isDirectory)
        let oldItem = makeItem(named: "old.txt", in: oldDirectory)
        let projector = ControlledPaneItemProjector()
        let listing = ControlledListingControl()
        let pane = FilePaneState(
            directory: oldDirectory,
            listingService: ControlledDirectoryListingService(control: listing),
            projector: projector
        )

        let initial = Task { await pane.navigate(to: oldDirectory, recordHistory: false) }
        await listing.waitForStart(in: oldDirectory, count: 1)
        await listing.yield([oldItem], in: oldDirectory, request: 0)
        await listing.finish(in: oldDirectory, request: 0)
        await initial.value

        await projector.suspendNextProjection()
        pane.updateFilterQuery("old")
        #expect(await waitForProjectionStart(projector, count: 2))

        let navigation = pane.beginNavigation(to: newDirectory)

        #expect(await projector.waitForCancellation(request: 1))
        #expect(pane.currentDirectory == newDirectory)
        #expect(pane.items.isEmpty)
        #expect(pane.errorMessage == nil)
        #expect(!(await projector.hasCompleted(request: 1)))

        await listing.waitForStart(in: newDirectory, count: 1)
        await listing.finish(in: newDirectory, request: 0)
        await navigation.value
    }

    @Test func cancelledLoadRejectsItsPendingBatchFlush() async {
        let home = URL(filePath: "/cancelled-flush-home", directoryHint: .isDirectory)
        let destination = URL(filePath: "/cancelled-flush", directoryHint: .isDirectory)
        let committed = makeItem(named: "committed.txt", in: home)
        let first = makeItem(named: "first.txt", in: destination)
        let late = makeItem(named: "late.txt", in: destination)
        let control = ControlledListingControl()
        let sleeper = ControlledPaneBatchSleeper()
        let pane = FilePaneState(
            directory: home,
            listingService: ControlledDirectoryListingService(control: control),
            batchSleeper: sleeper
        )

        let initialLoad = Task { await pane.navigate(to: home, recordHistory: false) }
        await control.waitForStart(in: home, count: 1)
        await control.yield([committed], in: home, request: 0)
        await control.finish(in: home, request: 0)
        await initialLoad.value

        let cancelledLoad = Task { await pane.navigate(to: destination) }
        await control.waitForStart(in: destination, count: 1)
        await control.yield([first], in: destination, request: 0)
        #expect(await waitForPaneCondition { pane.visibleItems == [first] })
        await control.yield([late], in: destination, request: 0)
        await sleeper.waitForSleepCount(1)

        cancelledLoad.cancel()
        await control.finish(in: destination, request: 0)
        await cancelledLoad.value
        await sleeper.advance()
        for _ in 0..<100 { await Task.yield() }

        #expect(pane.currentDirectory == home)
        #expect(pane.items == [committed])
        #expect(pane.visibleItems == [committed])
        #expect(pane.visibleIndexByURL == [committed.url.standardizedFileURL: 0])
    }

    @Test func failedRefreshPreservesRawAndAcceptedVisibleStateAtomically() async {
        let directory = URL(filePath: "/atomic-refresh", directoryHint: .isDirectory)
        let old = makeItem(named: "old.txt", in: directory)
        let replacement = makeItem(named: "replacement.txt", in: directory)
        let control = ControlledListingControl()
        let pane = FilePaneState(
            directory: directory,
            listingService: ControlledDirectoryListingService(control: control)
        )

        let initialLoad = Task { await pane.navigate(to: directory, recordHistory: false) }
        await control.waitForStart(in: directory, count: 1)
        await control.yield([old], in: directory, request: 0)
        await control.finish(in: directory, request: 0)
        await initialLoad.value
        pane.selection = [old.url]
        let acceptedToken = pane.acceptedProjectionToken
        let acceptedDiagnostics = pane.acceptedProjectionDiagnostics

        let refresh = Task { await pane.refresh() }
        await control.waitForStart(in: directory, count: 2)
        await control.yield([replacement], in: directory, request: 1)
        await Task.yield()
        #expect(pane.items == [old])
        #expect(pane.visibleItems == [old])

        await control.fail(in: directory, request: 1)
        await refresh.value

        #expect(pane.items == [old])
        #expect(pane.visibleItems == [old])
        #expect(pane.visibleIndexByURL == [old.url.standardizedFileURL: 0])
        #expect(pane.selection == [old.url])
        #expect(pane.acceptedProjectionToken == acceptedToken)
        #expect(pane.acceptedProjectionDiagnostics == acceptedDiagnostics)
        #expect(pane.errorMessage != nil)
    }

    @Test func refreshReprojectsStagedItemsWhenFilterAndSortSupersedeItsProjection() async {
        let directory = URL(filePath: "/refresh-projection-race", directoryHint: .isDirectory)
        let selectedURL = directory.appending(path: "selected-small.txt")
        let obsolete = makeItem(named: "obsolete.txt", byteSize: 4, in: directory)
        let oldSelected = FileItem(
            url: selectedURL,
            name: "selected-small.txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "Text"
        )
        let refreshedSelected = FileItem(
            url: selectedURL,
            name: "selected-small.txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 2,
            typeDescription: "Text"
        )
        let refreshedLarge = makeItem(named: "selected-large.txt", byteSize: 20, in: directory)
        let listing = ControlledListingControl()
        let projector = ControlledPaneItemProjector()
        let pane = FilePaneState(
            directory: directory,
            listingService: ControlledDirectoryListingService(control: listing),
            projector: projector
        )

        let initialLoad = Task { await pane.navigate(to: directory, recordHistory: false) }
        await listing.waitForStart(in: directory, count: 1)
        await listing.yield([oldSelected, obsolete], in: directory, request: 0)
        await listing.finish(in: directory, request: 0)
        await initialLoad.value
        pane.selection = [oldSelected.url, obsolete.url]

        await projector.suspendNextProjection()
        let refresh = Task { await pane.refresh() }
        await listing.waitForStart(in: directory, count: 2)
        await listing.yield([refreshedSelected, refreshedLarge], in: directory, request: 1)
        await listing.finish(in: directory, request: 1)
        await projector.waitForStartCount(2)

        pane.updateFilterQuery("selected")
        pane.sort = FileSort(key: .size, direction: .descending)
        #expect(pane.items == [oldSelected, obsolete])

        await projector.resumeProjection(request: 1)
        await refresh.value

        #expect(pane.items == [refreshedSelected, refreshedLarge])
        #expect(pane.visibleItems == [refreshedLarge, refreshedSelected])
        #expect(pane.visibleIndexByURL == [
            refreshedLarge.url.standardizedFileURL: 0,
            refreshedSelected.url.standardizedFileURL: 1,
        ])
        #expect(pane.selection == [refreshedSelected.url])
        let refreshRequests = await projector.requests.filter {
            $0.itemNames == [refreshedSelected.name, refreshedLarge.name]
        }
        #expect(refreshRequests.count == 2)
        #expect(refreshRequests.last?.key.normalizedQuery == "selected")
        #expect(refreshRequests.last?.key.sort == FileSort(key: .size, direction: .descending))
    }

    @Test func acceptedProjectionIntersectsSelectionAndPublishesItsIndexTogether() async {
        let directory = URL(filePath: "/selection-projection", directoryHint: .isDirectory)
        let alpha = makeItem(named: "alpha.txt", in: directory)
        let beta = makeItem(named: "beta.txt", in: directory)
        let filler = (0..<300).map {
            makeItem(named: "filler-\($0).txt", in: directory)
        }
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: [alpha, beta] + filler])
        )
        await pane.navigate(to: directory, recordHistory: false)
        pane.selection = [alpha.url, beta.url]

        pane.updateFilterQuery("beta")

        #expect(await waitForPaneCondition {
            pane.visibleItems == [beta]
                && pane.visibleIndexByURL == [beta.url.standardizedFileURL: 0]
                && pane.selection == [beta.url]
        })
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

        #expect(await waitForPaneCondition {
            pane.visibleItems.map(\.name) == ["한글보고서.pdf"]
                && pane.selection.isEmpty
                && pane.filterResultCount == 1
        })
        #expect(listing.callCount(for: root) == 1)

        pane.dismissFiltering()

        #expect(await waitForPaneCondition {
            pane.visibleItems.count == 3
                && pane.selection == [resume.url]
        })
        #expect(pane.filterQuery.isEmpty)
        #expect(!pane.isFilterPresented)
    }

    @Test func inlineRenameSelectionUsesVisibleEntryPathIndex() async {
        let root = URL(filePath: "/rename-root", directoryHint: .isDirectory)
        let listedURL = root.appending(path: "Report.txt")
        let pane = FilePaneState(
            directory: root,
            listingService: StubDirectoryListingService(values: [
                root: [makeItem(named: listedURL.lastPathComponent, in: root)]
            ])
        )
        await pane.navigate(to: root, recordHistory: false)

        let equivalentURL = URL(filePath: "\(root.path)/./Report.txt")
        #expect(pane.selectForInlineRename(equivalentURL))
        #expect(pane.selection == [listedURL])
        #expect(pane.renameRequestID != nil)
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

private final class MutableFailingDirectoryListingService:
    DirectoryListingService,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var failingDirectories: Set<URL> = []

    func fail(_ directory: URL) {
        _ = lock.withLock {
            failingDirectories.insert(directory)
        }
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let shouldFail = lock.withLock { failingDirectories.contains(directory) }
        return AsyncThrowingStream { continuation in
            if shouldFail {
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

private actor ControlledPaneBatchSleeper: PaneBatchSleeping {
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    private var sleepWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var requestedDurations: [Duration] = []

    var sleepCount: Int { continuations.count }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            requestedDurations.append(duration)
            continuations.append(continuation)
            resumeSatisfiedWaiters()
        }
    }

    func waitForSleepCount(_ count: Int) async {
        guard continuations.count < count else { return }
        await withCheckedContinuation { continuation in
            sleepWaiters.append((count, continuation))
        }
    }

    func advance() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    private func resumeSatisfiedWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in sleepWaiters {
            if continuations.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        sleepWaiters = pending
    }
}

private struct ControlledPaneProjectionRequest: Sendable {
    let itemNames: [String]
    let key: PaneProjectionKey
}

private actor ControlledPaneItemProjector: PaneItemProjecting {
    private var suspensionBudget = 0
    private var suspended: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var activeOrderSuspensionBudget = 0
    private var suspendedActiveOrderBuild: CheckedContinuation<Void, any Error>?
    private var warmUpStartCount = 0
    private(set) var warmUpCancellationCount = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completedRequests: Set<Int> = []
    private var cancelledRequests: Set<Int> = []
    private(set) var requests: [ControlledPaneProjectionRequest] = []
    private(set) var activeOrderBuildCount = 0
    private(set) var sortedSubsetCount = 0
    private(set) var lastSubsetInputCount: Int?
    private(set) var latestProjectionPath: PaneProjectionPath?

    var requestCount: Int { requests.count }

    func suspendNextProjection() {
        suspensionBudget += 1
    }

    func suspendNextActiveOrderBuild() {
        activeOrderSuspensionBudget += 1
    }

    func project(_ input: PaneProjectionInput) async throws -> PaneItemProjection {
        let request = requests.count
        requests.append(ControlledPaneProjectionRequest(
            itemNames: input.items.map(\.name),
            key: input.key
        ))
        resumeSatisfiedStartWaiters()
        if suspensionBudget > 0 {
            suspensionBudget -= 1
            try await suspend(request: request)
        }
        let projection: PaneItemProjection
        if input.activeOrder != nil {
            projection = try await PaneItemProjector().projectActiveOrder(input)
        } else {
            projection = try await PaneItemProjector().projectFallback(
                items: input.items,
                key: input.key
            )
        }
        latestProjectionPath = projection.diagnostics.path
        completedRequests.insert(request)
        return projection
    }

    func buildActiveOrder(
        items: [FileItem],
        directoryKey: String,
        key: PaneProjectionKey
    ) async throws -> ActiveOrderSnapshot? {
        activeOrderBuildCount += 1
        if activeOrderSuspensionBudget > 0 {
            activeOrderSuspensionBudget -= 1
            warmUpStartCount += 1
            try await suspendActiveOrderBuild()
        }
        return try await PaneItemProjector().buildActiveOrder(
            items: items,
            directoryKey: directoryKey,
            key: key
        )
    }

    func projectSortedSubset(
        items: [FileItem],
        key: PaneProjectionKey
    ) async throws -> PaneItemProjection {
        sortedSubsetCount += 1
        lastSubsetInputCount = items.count
        return try await PaneItemProjector().projectSortedSubset(items: items, key: key)
    }

    func waitForStartCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func resumeProjection(request: Int) {
        suspended.removeValue(forKey: request)?.resume()
    }

    func hasCompleted(request: Int) -> Bool {
        completedRequests.contains(request)
    }

    func waitForCancellation(request: Int) async -> Bool {
        for _ in 0..<10_000 {
            if cancelledRequests.contains(request) { return true }
            await Task.yield()
        }
        return cancelledRequests.contains(request)
    }

    func waitForWarmUpStart(count: Int) async -> Bool {
        for _ in 0..<10_000 {
            if warmUpStartCount >= count { return true }
            await Task.yield()
        }
        return warmUpStartCount >= count
    }

    private func suspend(request: Int) async throws {
        if Task.isCancelled {
            cancelledRequests.insert(request)
            throw CancellationError()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                suspended[request] = continuation
            }
        } onCancel: {
            Task { await self.cancelSuspension(request: request) }
        }
    }

    private func cancelSuspension(request: Int) {
        cancelledRequests.insert(request)
        suspended.removeValue(forKey: request)?.resume(throwing: CancellationError())
    }

    private func suspendActiveOrderBuild() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                suspendedActiveOrderBuild = continuation
            }
        } onCancel: {
            Task { await self.cancelActiveOrderBuild() }
        }
    }

    private func cancelActiveOrderBuild() {
        guard let continuation = suspendedActiveOrderBuild else { return }
        suspendedActiveOrderBuild = nil
        warmUpCancellationCount += 1
        continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedStartWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in startWaiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        startWaiters = pending
    }
}

private actor CooperativeCancellationPaneItemProjector: PaneItemProjecting {
    private var startedRequests: Set<String> = []
    private var activeRequests: Set<String> = []
    private var cancelledRequestSet: Set<String> = []
    private var postCancellationVisitCounts: [String: Int] = [:]
    private var retainedSnapshots: [String: [FileItem]] = [:]
    private var retainedResults: [String: PaneItemProjection] = [:]

    var cancelledRequestCount: Int { cancelledRequestSet.count }
    var cancelledRequests: [String] { cancelledRequestSet.sorted() }
    var activeWorkerCount: Int { activeRequests.count }
    var retainedSnapshotCount: Int { retainedSnapshots.count }
    var retainedResultCount: Int { retainedResults.count }

    func project(_ input: PaneProjectionInput) async throws -> PaneItemProjection {
        let request = input.key.normalizedQuery
        startedRequests.insert(request)
        activeRequests.insert(request)
        retainedSnapshots[request] = input.items
        defer {
            activeRequests.remove(request)
            retainedSnapshots.removeValue(forKey: request)
            retainedResults.removeValue(forKey: request)
        }

        do {
            for (index, item) in input.items.enumerated() {
                _ = item.name
                if Task.isCancelled {
                    postCancellationVisitCounts[request, default: 0] += 1
                }
                if (index + 1).isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            try Task.checkCancellation()
            let result = try await PaneItemProjector().projectFallback(items: input.items, key: input.key)
            try Task.checkCancellation()
            retainedResults[request] = result
            return result
        } catch is CancellationError {
            cancelledRequestSet.insert(request)
            throw CancellationError()
        }
    }

    func buildActiveOrder(
        items: [FileItem], directoryKey: String, key: PaneProjectionKey
    ) async throws -> ActiveOrderSnapshot? {
        try await PaneItemProjector().buildActiveOrder(items: items, directoryKey: directoryKey, key: key)
    }

    func projectSortedSubset(items: [FileItem], key: PaneProjectionKey) async throws -> PaneItemProjection {
        try await PaneItemProjector().projectSortedSubset(items: items, key: key)
    }

    func waitUntilStarted(request: String) async -> Bool {
        if startedRequests.contains(request) { return true }
        for _ in 0..<10_000 {
            if startedRequests.contains(request) { return true }
            await Task.yield()
        }
        return startedRequests.contains(request)
    }

    func waitForCancellations(count: Int) async -> Bool {
        for _ in 0..<10_000 {
            if cancelledRequestSet.count >= count { return true }
            await Task.yield()
        }
        return cancelledRequestSet.count >= count
    }

    func postCancellationVisits(for request: String) -> Int {
        postCancellationVisitCounts[request, default: 0]
    }

    func waitForDrain() async -> Bool {
        for _ in 0..<1_000 {
            if activeRequests.isEmpty && retainedSnapshots.isEmpty && retainedResults.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return activeRequests.isEmpty && retainedSnapshots.isEmpty && retainedResults.isEmpty
    }
}

private actor CancellationRecordingPaneItemProjector: PaneItemProjecting {
    private var suspensionBudget = 0
    private var suspended: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledRequests: Set<Int> = []
    private var publishedRequests: Set<Int> = []
    private var activeRequests: Set<Int> = []
    private var retainedSnapshots: [Int: [FileItem]] = [:]
    private var retainedResults: [Int: PaneItemProjection] = [:]
    private var requests: [PaneProjectionInput] = []
    var requestCount: Int { requests.count }
    var activeWorkerCount: Int { activeRequests.count }
    var retainedSnapshotCount: Int { retainedSnapshots.count }
    var retainedResultCount: Int { retainedResults.count }

    func suspendNextProjection() {
        suspensionBudget += 1
    }

    func project(_ input: PaneProjectionInput) async throws -> PaneItemProjection {
        let request = requests.count
        requests.append(input)
        activeRequests.insert(request)
        retainedSnapshots[request] = input.items
        defer {
            activeRequests.remove(request)
            retainedSnapshots.removeValue(forKey: request)
            retainedResults.removeValue(forKey: request)
        }

        if suspensionBudget > 0 {
            suspensionBudget -= 1
            try await suspend(request: request)
        }
        try Task.checkCancellation()
        let result = try await PaneItemProjector().projectFallback(items: input.items, key: input.key)
        try Task.checkCancellation()
        retainedResults[request] = result
        publishedRequests.insert(request)
        return result
    }

    func buildActiveOrder(
        items: [FileItem], directoryKey: String, key: PaneProjectionKey
    ) async throws -> ActiveOrderSnapshot? {
        try await PaneItemProjector().buildActiveOrder(items: items, directoryKey: directoryKey, key: key)
    }

    func projectSortedSubset(items: [FileItem], key: PaneProjectionKey) async throws -> PaneItemProjection {
        try await PaneItemProjector().projectSortedSubset(items: items, key: key)
    }

    func waitForCancellation(request: Int) async -> Bool {
        for _ in 0..<10_000 {
            if cancelledRequests.contains(request) { return true }
            await Task.yield()
        }
        return cancelledRequests.contains(request)
    }

    func didPublish(request: Int) -> Bool { publishedRequests.contains(request) }

    func resumeAll() {
        suspensionBudget = 0
        let continuations = suspended.values
        suspended.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForDrain() async -> Bool {
        for _ in 0..<1_000 {
            if activeRequests.isEmpty && retainedSnapshots.isEmpty && retainedResults.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return activeRequests.isEmpty && retainedSnapshots.isEmpty && retainedResults.isEmpty
    }

    private func suspend(request: Int) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                suspended[request] = continuation
            }
        } onCancel: {
            Task { await self.cancelSuspension(request: request) }
        }
    }

    private func cancelSuspension(request: Int) {
        guard let continuation = suspended.removeValue(forKey: request) else { return }
        cancelledRequests.insert(request)
        continuation.resume(throwing: CancellationError())
    }
}

private func waitForProjectionStart(
    _ projector: ControlledPaneItemProjector,
    count: Int
) async -> Bool {
    for _ in 0..<10_000 {
        if await projector.requestCount >= count { return true }
        await Task.yield()
    }
    return await projector.requestCount >= count
}

private func waitForCancellationProjectionStart(
    _ projector: CancellationRecordingPaneItemProjector,
    count: Int
) async -> Bool {
    for _ in 0..<10_000 {
        if await projector.requestCount >= count { return true }
        await Task.yield()
    }
    return await projector.requestCount >= count
}

private func waitForProjectionCompletion(
    _ projector: ControlledPaneItemProjector,
    request: Int
) async -> Bool {
    for _ in 0..<10_000 {
        if await projector.hasCompleted(request: request) { return true }
        await Task.yield()
    }
    return await projector.hasCompleted(request: request)
}

@MainActor
private func waitForPaneCondition(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func makeItem(named name: String, in directory: URL) -> FileItem {
    makeItem(named: name, byteSize: 1, in: directory)
}

private func makeItem(named name: String, byteSize: Int64, in directory: URL) -> FileItem {
    FileItem(
        url: directory.appending(path: name),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: byteSize,
        typeDescription: "Text"
    )
}

private func filePaneStateSourceURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/BloomFileManager/Stores/FilePaneState.swift")
}
