import AppKit
import SwiftUI
import Testing
@testable import BloomFileManager

@Suite struct ComparisonPresentationTests {
    @Test func everyStatusPresentationHasSymbolLabelAndSpokenValue() {
        let statuses: [ComparisonStatus] = [
            .identical(.quick),
            .identical(.checksum),
            .metadataChanged,
            .contentChanged,
            .leftOnly,
            .rightOnly,
            .typeConflict,
            .nameConflict,
            .checking(nil),
            .checking(0.42),
            .unstable,
            .error("Permission denied")
        ]

        for status in statuses {
            let presentation = ComparisonStatusPresentation(status)
            #expect(!presentation.symbolName.isEmpty)
            #expect(!presentation.label.isEmpty)
            #expect(!presentation.value.isEmpty)
        }

        #expect(ComparisonStatusPresentation(.identical(.quick)).value.contains("quick"))
        #expect(ComparisonStatusPresentation(.identical(.checksum)).value.contains("checksum"))
        #expect(ComparisonStatusPresentation(.checking(0.42)).value == "Checking, 42 percent")
        #expect(ComparisonStatusPresentation(.error("Permission denied")).value == "Permission denied")
    }

    @Test func checkingProgressIsFiniteAndClampedBeforeFormatting() {
        #expect(ComparisonStatusPresentation(.checking(-0.5)).value == "Checking, 0 percent")
        #expect(ComparisonStatusPresentation(.checking(0)).value == "Checking, 0 percent")
        #expect(ComparisonStatusPresentation(.checking(1)).value == "Checking, 100 percent")
        #expect(ComparisonStatusPresentation(.checking(1.5)).value == "Checking, 100 percent")
        #expect(ComparisonStatusPresentation(.checking(.nan)).value == "Checking")
        #expect(ComparisonStatusPresentation(.checking(.infinity)).value == "Checking")
        #expect(ComparisonStatusPresentation(.checking(-.infinity)).value == "Checking")
    }

    @Test func filtersReturnOnlyExpectedRows() throws {
        let rows = try presentationRows()

        #expect(ComparisonFilter.differences.apply(rows).allSatisfy {
            $0.status != .identical(.quick) && $0.status != .identical(.checksum)
        })
        #expect(ComparisonFilter.leftOnly.apply(rows).allSatisfy { $0.status == .leftOnly })
        #expect(ComparisonFilter.rightOnly.apply(rows).allSatisfy { $0.status == .rightOnly })
        #expect(ComparisonFilter.contentChanged.apply(rows).allSatisfy {
            $0.status == .contentChanged || $0.status == .metadataChanged
        })
        #expect(ComparisonFilter.errors.apply(rows).allSatisfy {
            if case .error = $0.status { true }
            else { $0.status == .unstable || $0.status == .nameConflict }
        })
    }

    @MainActor @Test func exitCommandLeavesOrdinaryPaneSelectionAndSortUntouched() async {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/comparison/left", directoryHint: .isDirectory),
            rightURL: URL(filePath: "/comparison/right", directoryHint: .isDirectory),
            listingService: StubDirectoryListingService(values: [:])
        )
        let leftSelection: Set<URL> = [URL(filePath: "/comparison/left/selected.txt")]
        let rightSelection: Set<URL> = [URL(filePath: "/comparison/right/other.txt")]
        let leftSort = FileSort(key: .size, direction: .descending)
        let rightSort = FileSort(key: .modifiedAt, direction: .ascending)
        workspace.left.selection = leftSelection
        workspace.right.selection = rightSelection
        workspace.left.sort = leftSort
        workspace.right.sort = rightSort
        workspace.activate(.right)
        let comparison = comparisonCoordinator()

        ComparisonCommandActions.toggle(workspace: workspace, comparison: comparison)
        #expect(await waitForPresentation { comparison.isActive })
        ComparisonCommandActions.toggle(workspace: workspace, comparison: comparison)

        #expect(!comparison.isActive)
        #expect(workspace.left.selection == leftSelection)
        #expect(workspace.right.selection == rightSelection)
        #expect(workspace.left.sort == leftSort)
        #expect(workspace.right.sort == rightSort)
        #expect(workspace.activePaneID == .right)
    }

    @MainActor @Test func tableReloadRestoresStablePathSelectionAfterReorder() throws {
        let originalRows = try [
            presentationRow("A/first.txt", status: .leftOnly),
            presentationRow("B/second.txt", status: .contentChanged),
            presentationRow("C/third.txt", status: .rightOnly)
        ]
        let retainedPath = originalRows[2].id
        let selection = ComparisonSelectionRecorder(value: [retainedPath])
        let view = ComparisonTableView(rows: originalRows, selection: selection.binding)
        let coordinator = view.makeCoordinator()
        let table = ComparisonReloadNotifyingTableView()
        for column in ComparisonColumn.allCases {
            table.addTableColumn(NSTableColumn(identifier: column.identifier))
        }
        table.dataSource = coordinator
        table.delegate = coordinator
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let reorderedRows = [originalRows[2], originalRows[0]]
        coordinator.parent = ComparisonTableView(rows: reorderedRows, selection: selection.binding)
        selection.writes.removeAll()
        coordinator.apply(rows: reorderedRows, selection: [retainedPath], to: table)

        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(selection.value == [retainedPath])
        #expect(!selection.writes.contains([]))
        #expect(table.fullReloadCount == 1)
        #expect(table.partialReloads.isEmpty)
    }

    @MainActor @Test func progressUpdateReloadsOnlyOneStatusCell() throws {
        let original = try presentationRow("report.bin", status: .checking(nil))
        var progressed = original
        progressed.status = .checking(0.25)
        let selection = ComparisonSelectionRecorder(value: [original.id])
        let view = ComparisonTableView(rows: [original], selection: selection.binding)
        let coordinator = view.makeCoordinator()
        let table = comparisonRecordingTable(coordinator: coordinator)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        coordinator.parent = ComparisonTableView(rows: [progressed], selection: selection.binding)
        coordinator.apply(rows: [progressed], selection: [original.id], to: table)

        #expect(table.fullReloadCount == 0)
        #expect(table.partialReloads == [ComparisonPartialReload(
            rows: IndexSet(integer: 0),
            columns: IndexSet(integer: ComparisonColumn.status.index)
        )])
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
    }

    @MainActor @Test func targetedStatusReloadUpdatesRetainedVisibleRowAccessibility() throws {
        let original = try presentationRow("report.bin", status: .checking(nil))
        var failed = original
        failed.status = .error("Permission denied")
        let selection = ComparisonSelectionRecorder(value: [original.id])
        let view = ComparisonTableView(rows: [original], selection: selection.binding)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 160)
        scroll.layoutSubtreeIfNeeded()
        let table = try #require(scroll.documentView as? NSTableView)
        let retainedRowView = try #require(table.rowView(
            atRow: 0,
            makeIfNecessary: true
        ))
        _ = try #require(table.view(
            atColumn: ComparisonColumn.status.index,
            row: 0,
            makeIfNecessary: true
        ))

        #expect(retainedRowView.accessibilityValue() as? String == "Checking")
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))

        coordinator.parent = ComparisonTableView(rows: [failed], selection: selection.binding)
        coordinator.apply(rows: [failed], selection: [original.id], to: table)

        let updatedRowView = try #require(table.rowView(
            atRow: 0,
            makeIfNecessary: false
        ))
        #expect(updatedRowView === retainedRowView)
        #expect(updatedRowView.accessibilityIdentifier() == "comparison.row.report.bin")
        #expect(updatedRowView.accessibilityLabel() == ComparisonAccessibility.row(failed))
        #expect(updatedRowView.accessibilityValue() as? String == "Permission denied")
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(selection.value == [original.id])
    }

    @MainActor @Test func leftEntryChangeReloadsLeftAndStatusCellsOnly() throws {
        let original = try presentationRow("report.bin", status: .leftOnly)
        let oldEntry = try #require(original.left)
        var changed = original
        changed.left = ComparisonEntry(
            relativePath: oldEntry.relativePath,
            url: oldEntry.url.deletingLastPathComponent().appending(path: "renamed.bin"),
            kind: oldEntry.kind,
            fingerprint: oldEntry.fingerprint,
            symbolicLinkTarget: oldEntry.symbolicLinkTarget,
            typeDescription: oldEntry.typeDescription
        )
        let selection = ComparisonSelectionRecorder(value: [])
        let view = ComparisonTableView(rows: [original], selection: selection.binding)
        let coordinator = view.makeCoordinator()
        let table = comparisonRecordingTable(coordinator: coordinator)

        coordinator.parent = ComparisonTableView(rows: [changed], selection: selection.binding)
        coordinator.apply(rows: [changed], selection: [], to: table)

        #expect(table.fullReloadCount == 0)
        #expect(table.partialReloads == [ComparisonPartialReload(
            rows: IndexSet(integer: 0),
            columns: IndexSet([
                ComparisonColumn.left.index,
                ComparisonColumn.status.index
            ])
        )])
    }

    @MainActor @Test func tableBuildsAlignedColumnsAndAccessibleRowAndStatusCell() throws {
        let row = try presentationRow("Reports/Q2.pdf", status: .contentChanged)
        let selection = ComparisonSelectionRecorder(value: [row.id])
        let view = ComparisonTableView(rows: [row], selection: selection.binding)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let table = try #require(scroll.documentView as? NSTableView)

        #expect(table.tableColumns.map(\.identifier.rawValue) == ["left", "status", "right"])
        #expect(table.tableColumns.map(\.title) == ["Left", "Status", "Right"])
        #expect(table.numberOfRows == 1)
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(table.accessibilityIdentifier() == "comparisonTable")

        let leftCell = try #require(coordinator.tableView(
            table,
            viewFor: table.tableColumns[0],
            row: 0
        ))
        let statusCell = try #require(coordinator.tableView(
            table,
            viewFor: table.tableColumns[1],
            row: 0
        ))
        let rowView = try #require(coordinator.tableView(table, rowViewForRow: 0))
        let leftText = descendantText(leftCell)

        #expect(leftText.contains("Q2.pdf"))
        #expect(leftText.contains("Reports"))
        #expect(statusCell.accessibilityIdentifier() == "comparison.status.Reports/Q2.pdf")
        #expect(statusCell.accessibilityValue() as? String
            == ComparisonAccessibility.status(row).value)
        #expect(rowView.accessibilityIdentifier() == "comparison.row.Reports/Q2.pdf")
        #expect(rowView.accessibilityValue() as? String
            == ComparisonAccessibility.status(row).value)
    }

    @MainActor @Test func changingAnOptionRestartsWithANewGeneration() async {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/comparison/left", directoryHint: .isDirectory),
            rightURL: URL(filePath: "/comparison/right", directoryHint: .isDirectory),
            listingService: StubDirectoryListingService(values: [:])
        )
        let listing = InMemoryComparisonListingService([:])
        let comparison = ComparisonCoordinator(
            listings: listing,
            checksums: PresentationNoopChecksumService()
        )
        comparison.start(workspace: workspace)
        #expect(await waitForPresentation { comparison.session != nil })
        let firstGeneration = comparison.session?.generation

        ComparisonOptionChange.setIncludeSubfolders(
            true,
            comparison: comparison,
            workspace: workspace
        )

        #expect(await waitForPresentation {
            comparison.session?.generation != nil
                && comparison.session?.generation != firstGeneration
        })
        #expect(comparison.options.includeSubfolders)
        let restartedGeneration = comparison.session?.generation

        ComparisonOptionChange.setIncludeSubfolders(
            true,
            comparison: comparison,
            workspace: workspace
        )
        await Task.yield()
        #expect(comparison.session?.generation == restartedGeneration)
        comparison.stop()
    }

    @MainActor @Test func exitDuringStalledNavigationNeverRestartsComparison() async {
        let fixture = await activeNavigationFixture()
        let navigation = ComparisonNavigationState()
        let gate = NonCooperativeNavigationGate()
        var root = fixture.workspace.left.currentDirectory
        var restartCount = 0

        navigation.navigate(
            side: .left,
            comparison: fixture.comparison,
            currentRoot: { root },
            operation: {
                await gate.wait()
                root = URL(filePath: "/comparison/late", directoryHint: .isDirectory)
            },
            restart: { restartCount += 1 }
        )
        #expect(await waitForPresentation { await gate.isWaiting })

        fixture.comparison.stop()
        navigation.cancelAll()
        await gate.release()
        #expect(await waitForPresentation { await gate.hasFinished })

        #expect(restartCount == 0)
        #expect(!fixture.comparison.isActive)
    }

    @MainActor @Test func failedNavigationWithUnchangedRootDoesNotRestartComparison() async {
        let fixture = await activeNavigationFixture()
        let navigation = ComparisonNavigationState()
        let root = fixture.workspace.left.currentDirectory
        var restartCount = 0

        navigation.navigate(
            side: .left,
            comparison: fixture.comparison,
            currentRoot: { root },
            operation: {},
            restart: { restartCount += 1 }
        )
        #expect(await waitForPresentation { !navigation.isNavigating })

        #expect(restartCount == 0)
        fixture.comparison.stop()
    }

    @MainActor @Test func staleOlderNavigationCompletionCannotRestartAfterNewerRequest() async {
        let fixture = await activeNavigationFixture()
        let navigation = ComparisonNavigationState()
        let olderGate = NonCooperativeNavigationGate()
        var root = fixture.workspace.left.currentDirectory
        var restartCount = 0

        navigation.navigate(
            side: .left,
            comparison: fixture.comparison,
            currentRoot: { root },
            operation: {
                await olderGate.wait()
                root = URL(filePath: "/comparison/older", directoryHint: .isDirectory)
            },
            restart: { restartCount += 1 }
        )
        #expect(await waitForPresentation { await olderGate.isWaiting })

        navigation.navigate(
            side: .left,
            comparison: fixture.comparison,
            currentRoot: { root },
            operation: {
                root = URL(filePath: "/comparison/newer", directoryHint: .isDirectory)
            },
            restart: { restartCount += 1 }
        )
        #expect(await waitForPresentation { !navigation.isNavigating })
        #expect(restartCount == 1)

        await olderGate.release()
        #expect(await waitForPresentation { await olderGate.hasFinished })
        #expect(restartCount == 1)
        fixture.comparison.stop()
    }

    @MainActor @Test func simultaneousOppositePaneNavigationRestartsOnlyForChangedRoot() async {
        let fixture = await activeNavigationFixture()
        let navigation = ComparisonNavigationState()
        let leftGate = NonCooperativeNavigationGate()
        let rightGate = NonCooperativeNavigationGate()
        var leftRoot = fixture.workspace.left.currentDirectory
        let rightRoot = fixture.workspace.right.currentDirectory
        var restartCount = 0

        navigation.navigate(
            side: .left,
            comparison: fixture.comparison,
            currentRoot: { leftRoot },
            operation: {
                await leftGate.wait()
                leftRoot = URL(filePath: "/comparison/left-success", directoryHint: .isDirectory)
            },
            restart: { restartCount += 1 }
        )
        navigation.navigate(
            side: .right,
            comparison: fixture.comparison,
            currentRoot: { rightRoot },
            operation: { await rightGate.wait() },
            restart: { restartCount += 1 }
        )
        #expect(await waitForPresentation {
            let leftIsWaiting = await leftGate.isWaiting
            let rightIsWaiting = await rightGate.isWaiting
            return leftIsWaiting && rightIsWaiting
        })

        await rightGate.release()
        #expect(await waitForPresentation { await rightGate.hasFinished })
        #expect(navigation.isNavigating)
        #expect(restartCount == 0)

        await leftGate.release()
        #expect(await waitForPresentation { !navigation.isNavigating })
        #expect(restartCount == 1)
        fixture.comparison.stop()
    }

    @Test func syncActionBarLabelsAreSelectionIndependentAndDispatchDirection() throws {
        let actionBar = try bloomSource(named: "Views/Comparison/ComparisonActionBar.swift")
        #expect(actionBar.contains("Button(\"Sync Left to Right…\")"))
        #expect(actionBar.contains("Button(\"Sync Right to Left…\")"))
        #expect(actionBar.contains("requestFolderSynchronization(.leftToRight)"))
        #expect(actionBar.contains("requestFolderSynchronization(.rightToLeft)"))
        if let left = actionBar.range(of: "Button(\"Sync Left to Right…\")"),
           let right = actionBar.range(of: "Button(\"Sync Right to Left…\")") {
            let syncButtons = String(actionBar[left.lowerBound..<right.upperBound])
                + String(actionBar[right.upperBound...].prefix(280))
            #expect(!syncButtons.contains("selection.count"))
            #expect(!syncButtons.contains("visibleRows"))
            #expect(!syncButtons.contains("canCopy"))
            #expect(!syncButtons.contains("canMove"))
        }

        let workspace = try bloomSource(named: "Views/Comparison/ComparisonWorkspaceView.swift")
        #expect(workspace.contains("FolderSynchronizationReviewSheet"))
        #expect(workspace.contains("synchronizationReviewBinding"))
    }

    @Test func readySynchronizationReviewShowsBasenamesCountsAndAtMostEightRelativePaths() throws {
        let review = try makeReadySynchronizationReview(pathCount: 10, trashCount: 1)
        let presentation = FolderSynchronizationReviewSheetPresentation(
            state: .ready(review),
            canAdmit: true,
            currentGeneration: review.comparisonGeneration
        )

        #expect(presentation.title == "Synchronize Left to Right")
        #expect(presentation.sourceBasename == "SecretSource")
        #expect(presentation.destinationBasename == "SecretDestination")
        #expect(presentation.copyCountLabel == "Copy 8")
        #expect(presentation.replaceCountLabel == "Replace 1")
        #expect(presentation.trashCountLabel.contains("Move to Trash"))
        #expect(presentation.skipCountLabel == "Skip 2")
        #expect(presentation.estimatedSizeLabel != nil)
        #expect(presentation.representativePaths.count == 8)
        #expect(presentation.isConfirmEnabled)
        #expect(presentation.destructiveWarning.contains("Trash"))
        let visible = presentation.visibleStrings.joined(separator: "\n")
        #expect(!visible.contains("/private/SecretSource"))
        #expect(!visible.contains("/private/SecretDestination"))
        #expect(visible.contains("copy-1.txt"))
        #expect(presentation.accessibilityLabel.contains("left to right"))
        #expect(!presentation.accessibilityLabel.contains("/private"))
    }

    @Test func synchronizationReviewConfirmIsDisabledWhenNotReadyOrAdmissionIsClosed() throws {
        let review = try makeReadySynchronizationReview(pathCount: 1, trashCount: 0)
        let blocked = FolderSynchronizationReviewSheetPresentation(
            state: .plannerBlocked([.init(reason: .unsupportedEntryKind)]),
            canAdmit: true,
            currentGeneration: review.comparisonGeneration
        )
        let already = FolderSynchronizationReviewSheetPresentation(
            state: .alreadySynchronized(try FolderSynchronizationPlanSummary(
                direction: .leftToRight,
                comparisonGeneration: review.comparisonGeneration,
                sourceRoot: review.preparedPlan.draft.sourceRoot,
                destinationRoot: review.preparedPlan.draft.destinationRoot,
                sourceRootIdentity: review.preparedPlan.draft.sourceRootIdentity,
                destinationRootIdentity: review.preparedPlan.draft.destinationRootIdentity,
                skipCount: 3
            )),
            canAdmit: true,
            currentGeneration: review.comparisonGeneration
        )
        let preparing = FolderSynchronizationReviewSheetPresentation(
            state: .preparing(direction: .leftToRight, comparisonGeneration: review.comparisonGeneration),
            canAdmit: true,
            currentGeneration: review.comparisonGeneration
        )
        let stale = FolderSynchronizationReviewSheetPresentation(
            state: .ready(review),
            canAdmit: true,
            currentGeneration: UUID()
        )
        let closed = FolderSynchronizationReviewSheetPresentation(
            state: .ready(review),
            canAdmit: false,
            currentGeneration: review.comparisonGeneration
        )

        #expect(!blocked.isConfirmEnabled)
        #expect(!already.isConfirmEnabled)
        #expect(!preparing.isConfirmEnabled)
        #expect(!stale.isConfirmEnabled)
        #expect(!closed.isConfirmEnabled)
        #expect(already.statusText.contains("Already Synchronized"))
        #expect(!blocked.statusText.contains("/private"))
    }

    @Test func comparisonCommandPolicyNamesAndEnablesOnlyValidActions() {
        let inactive = ComparisonCommandPolicy(isActive: false, canVerifySelected: false)
        #expect(inactive.toggleTitle == "Compare Folders")
        #expect(!inactive.canVerifySelectedContents)
        #expect(!inactive.canVerifyAllContents)

        let active = ComparisonCommandPolicy(isActive: true, canVerifySelected: true)
        #expect(active.toggleTitle == "Exit Comparison")
        #expect(active.canVerifySelectedContents)
        #expect(active.canVerifyAllContents)
    }

    @Test func comparisonOverlayKeepsOrdinaryWorkspaceMountedAndCommandsHaveNoShortcut() throws {
        let workspaceSource = try bloomSource(named: "Views/WorkspaceView.swift")
        #expect(workspaceSource.contains("ordinaryWorkspace"))
        #expect(workspaceSource.contains(
            "let hasOverlay = comparison.isActive || storage.isActive"
        ))
        #expect(workspaceSource.contains(".opacity(hasOverlay ? 0 : 1)"))
        #expect(workspaceSource.contains(".allowsHitTesting(!hasOverlay)"))
        #expect(workspaceSource.contains(".accessibilityHidden(hasOverlay)"))
        #expect(!workspaceSource.contains(".opacity(comparison.isActive ? 0 : 1)"))
        #expect(!workspaceSource.contains(".allowsHitTesting(!comparison.isActive)"))
        #expect(!workspaceSource.contains(".accessibilityHidden(comparison.isActive)"))
        let ordinary = try #require(workspaceSource.range(of: "ordinaryWorkspace\n"))
        let comparisonConditional = try #require(workspaceSource.range(
            of: "if comparison.isActive {"
        ))
        #expect(ordinary.lowerBound < comparisonConditional.lowerBound)
        #expect(!workspaceSource.contains("if !comparison.isActive"))

        let commandsSource = try bloomSource(named: "Support/WorkspaceCommands.swift")
        let compareMenu = try #require(commandsSource.range(of: "CommandMenu(\"Compare\")"))
        let menuBlock = try #require(bracedBlock(
            in: commandsSource,
            startingAt: compareMenu.lowerBound
        ))
        #expect(!menuBlock.contains("keyboardShortcut"))
    }
}

@MainActor
private final class ComparisonSelectionRecorder {
    var value: Set<ComparisonRelativePath>
    var writes: [Set<ComparisonRelativePath>] = []

    init(value: Set<ComparisonRelativePath>) {
        self.value = value
    }

    var binding: Binding<Set<ComparisonRelativePath>> {
        Binding(
            get: { self.value },
            set: {
                self.value = $0
                self.writes.append($0)
            }
        )
    }
}

@MainActor
private final class ComparisonReloadNotifyingTableView: NSTableView {
    private(set) var fullReloadCount = 0
    private(set) var partialReloads: [ComparisonPartialReload] = []

    override func reloadData() {
        fullReloadCount += 1
        super.reloadData()
        delegate?.tableViewSelectionDidChange?(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: self
        ))
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        partialReloads.append(ComparisonPartialReload(
            rows: rowIndexes,
            columns: columnIndexes
        ))
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }
}

private struct ComparisonPartialReload: Equatable {
    let rows: IndexSet
    let columns: IndexSet
}

private actor NonCooperativeNavigationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    private(set) var hasFinished = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
        hasFinished = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PresentationNoopChecksumService: ChecksumService {
    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        await progress(1)
        return ChecksumResult(digest: Data(request.url.path.utf8))
    }
}

private func makeReadySynchronizationReview(
    pathCount: Int,
    trashCount: Int
) throws -> FolderSynchronizationReview {
    let source = URL(filePath: "/private/SecretSource", directoryHint: .isDirectory)
    let destination = URL(filePath: "/private/SecretDestination", directoryHint: .isDirectory)
    let sourceIdentity = FileIdentity(entryIdentifier: "source-root", resolvedIdentifier: "source-root")
    let destinationIdentity = FileIdentity(
        entryIdentifier: "destination-root",
        resolvedIdentifier: "destination-root"
    )
    var actions: [FolderSynchronizationAction] = []
    let copyCount = max(pathCount - trashCount - 1, 0)
    for index in 0..<copyCount {
        let path = try ComparisonRelativePath(components: ["copy-\(index + 1).txt"])
        let entry = ComparisonEntry(
            relativePath: path,
            url: source.appending(path: path.string),
            kind: .regularFile,
            fingerprint: .init(
                identity: .init(entryIdentifier: "copy-\(index)", resolvedIdentifier: "copy-\(index)"),
                byteSize: 4,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "regularFile"
        )
        actions.append(try FolderSynchronizationAction(
            relativePath: path,
            kind: .copy,
            source: entry,
            destination: nil
        ))
    }
    if pathCount > trashCount {
        let path = try ComparisonRelativePath(components: ["replace.txt"])
        let left = ComparisonEntry(
            relativePath: path,
            url: source.appending(path: path.string),
            kind: .regularFile,
            fingerprint: .init(
                identity: .init(entryIdentifier: "replace-s", resolvedIdentifier: "replace-s"),
                byteSize: 4,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "regularFile"
        )
        let right = ComparisonEntry(
            relativePath: path,
            url: destination.appending(path: path.string),
            kind: .regularFile,
            fingerprint: .init(
                identity: .init(entryIdentifier: "replace-d", resolvedIdentifier: "replace-d"),
                byteSize: 3,
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "regularFile"
        )
        actions.append(try FolderSynchronizationAction(
            relativePath: path,
            kind: .replace,
            source: left,
            destination: right
        ))
    }
    if trashCount > 0 {
        let path = try ComparisonRelativePath(components: ["trash.txt"])
        let trash = ComparisonEntry(
            relativePath: path,
            url: destination.appending(path: path.string),
            kind: .regularFile,
            fingerprint: .init(
                identity: .init(entryIdentifier: "trash", resolvedIdentifier: "trash"),
                byteSize: 1,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "regularFile"
        )
        actions.append(try FolderSynchronizationAction(
            relativePath: path,
            kind: .moveDestinationToTrash,
            source: nil,
            destination: trash
        ))
    }
    let ordered = actions.sorted(by: FolderSynchronizationAction.deterministicOrder)
    let bytes = ordered.reduce(into: Int64(0)) { total, action in
        total += action.source?.fingerprint.byteSize ?? 0
    }
    let draft = try FolderSynchronizationPlanDraft(
        direction: .leftToRight,
        comparisonGeneration: UUID(uuidString: "00000000-0000-0000-0000-000000000060")!,
        sourceRoot: source,
        destinationRoot: destination,
        sourceRootIdentity: sourceIdentity,
        destinationRootIdentity: destinationIdentity,
        actions: ordered,
        skipCount: 2,
        estimatedRegularFileCopyBytes: bytes
    )
    let prepared = PreparedFolderSynchronizationPlan(
        draft: draft,
        sourceFingerprints: [:],
        destinationFingerprints: [:],
        expectedAbsentDestinations: Set(ordered.filter { $0.kind == .copy }.map(\.relativePath)),
        requiredCapacityBytes: bytes,
        destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
        rootAuthority: .init(
            source: .init(
                identity: sourceIdentity,
                canonicalURL: source,
                volumeIdentifier: "fixture",
                mountIdentifier: "fixture:/"
            ),
            destination: .init(
                identity: destinationIdentity,
                canonicalURL: destination,
                volumeIdentifier: "fixture",
                mountIdentifier: "fixture:/"
            )
        )
    )
    return FolderSynchronizationReview(
        preparedPlan: prepared,
        direction: .leftToRight,
        comparisonGeneration: draft.comparisonGeneration,
        summary: .init(
            copyCount: ordered.count(where: { $0.kind == .copy }),
            replaceCount: ordered.count(where: { $0.kind == .replace }),
            moveToTrashCount: ordered.count(where: { $0.kind == .moveDestinationToTrash }),
            skipCount: 2,
            estimatedCopyBytes: bytes,
            requiredCapacityBytes: bytes
        ),
        representativeRelativePaths: Array(ordered.prefix(8).map(\.relativePath))
    )
}

@MainActor
private func comparisonCoordinator() -> ComparisonCoordinator {
    ComparisonCoordinator(
        listings: InMemoryComparisonListingService([:]),
        checksums: PresentationNoopChecksumService()
    )
}

@MainActor
private func activeNavigationFixture() async -> (
    workspace: WorkspaceState,
    comparison: ComparisonCoordinator
) {
    let workspace = WorkspaceState(
        leftURL: URL(filePath: "/comparison/left", directoryHint: .isDirectory),
        rightURL: URL(filePath: "/comparison/right", directoryHint: .isDirectory),
        listingService: StubDirectoryListingService(values: [:])
    )
    let comparison = comparisonCoordinator()
    comparison.start(workspace: workspace)
    _ = await waitForPresentation { comparison.session != nil }
    return (workspace, comparison)
}

@MainActor
private func comparisonRecordingTable(
    coordinator: ComparisonTableView.Coordinator
) -> ComparisonReloadNotifyingTableView {
    let table = ComparisonReloadNotifyingTableView()
    for column in ComparisonColumn.allCases {
        table.addTableColumn(NSTableColumn(identifier: column.identifier))
    }
    table.dataSource = coordinator
    table.delegate = coordinator
    return table
}

private func presentationRows() throws -> [ComparisonRow] {
    try [
        presentationRow("identical-quick", status: .identical(.quick)),
        presentationRow("identical-checksum", status: .identical(.checksum)),
        presentationRow("metadata", status: .metadataChanged),
        presentationRow("content", status: .contentChanged),
        presentationRow("left", status: .leftOnly),
        presentationRow("right", status: .rightOnly),
        presentationRow("type", status: .typeConflict),
        presentationRow("name", status: .nameConflict),
        presentationRow("checking", status: .checking(nil)),
        presentationRow("unstable", status: .unstable),
        presentationRow("error", status: .error("Failed"))
    ]
}

private func presentationRow(
    _ relativePath: String,
    status: ComparisonStatus
) throws -> ComparisonRow {
    let path = try ComparisonRelativePath(
        components: relativePath.split(separator: "/").map(String.init)
    )
    let left = ComparisonEntry(
        relativePath: path,
        url: URL(filePath: "/comparison/left").appending(path: path.string),
        kind: .regularFile,
        fingerprint: ComparisonFingerprint(
            identity: FileIdentity(entryIdentifier: "left:\(path.string)", resolvedIdentifier: "left:\(path.string)"),
            byteSize: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        ),
        symbolicLinkTarget: nil,
        typeDescription: "Document"
    )
    let right = ComparisonEntry(
        relativePath: path,
        url: URL(filePath: "/comparison/right").appending(path: path.string),
        kind: .regularFile,
        fingerprint: ComparisonFingerprint(
            identity: FileIdentity(entryIdentifier: "right:\(path.string)", resolvedIdentifier: "right:\(path.string)"),
            byteSize: 2,
            modifiedAt: Date(timeIntervalSince1970: 2)
        ),
        symbolicLinkTarget: nil,
        typeDescription: "Document"
    )
    return ComparisonRow(relativePath: path, left: left, right: right, status: status)
}

@MainActor
private func waitForPresentation(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

@MainActor
private func descendantText(_ view: NSView) -> [String] {
    var values: [String] = []
    if let field = view as? NSTextField {
        values.append(field.stringValue)
    }
    for child in view.subviews {
        values.append(contentsOf: descendantText(child))
    }
    return values
}

private func bloomSource(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot
            .appending(path: "Sources/BloomFileManager", directoryHint: .isDirectory)
            .appending(path: relativePath),
        encoding: .utf8
    )
}

private func bracedBlock(
    in source: String,
    startingAt start: String.Index
) -> Substring? {
    guard let open = source[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < source.endIndex {
        switch source[index] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return source[open ... index]
            }
        default: break
        }
        index = source.index(after: index)
    }
    return nil
}
