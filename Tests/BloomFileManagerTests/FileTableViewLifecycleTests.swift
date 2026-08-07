import AppKit
import SwiftUI
import Testing
@testable import BloomFileManager

@MainActor
struct FileTableViewLifecycleTests {
    @Test func newFolderCommandFlowsThroughCoordinatorReturnWithCapturedIdentity() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let left = root.url.appending(path: "left", directoryHint: .isDirectory)
        let right = root.url.appending(path: "right", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: false)
        let workspace = WorkspaceState(
            leftURL: left,
            rightURL: right,
            listingService: LiveDirectoryListingService(batchSize: 64)
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess())
        )
        await workspace.loadInitialDirectories()
        #expect(await WorkspaceCommandActions.createFolder(
            in: workspace.left,
            workspace: workspace,
            operationController: controller
        ))
        workspace.activate(.right)
        while controller.isRunning { await Task.yield() }

        let item = try #require(workspace.left.visibleItems.first { $0.name == "New Folder" })
        let requestID = try #require(workspace.left.renameRequestID)
        let selection = Binding<Set<URL>>(
            get: { workspace.left.selection },
            set: { workspace.left.selection = $0 }
        )
        let view = FileTableView(
            items: workspace.left.visibleItems,
            selection: selection,
            renameRequestID: requestID,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onConsumeRenameRequest: workspace.left.consumeInlineRenameRequest,
            onDiscardRename: workspace.left.cancelPendingRename,
            onCommitRename: { _, name in
                controller.commitPendingRename(in: workspace.left, to: name, workspace: workspace)
            }
        )
        let coordinator = view.makeCoordinator()
        let table = RenameRecordingTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        coordinator.apply(items: workspace.left.visibleItems, selection: [item.url], to: table)
        await Task.yield()
        let textField = NSTextField(string: item.name)
        #expect(coordinator.control(textField, textShouldBeginEditing: NSTextView()))
        coordinator.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: textField
        ))
        textField.stringValue = "Renamed Folder"
        coordinator.controlTextDidEndEditing(textEditingNotification(textField, movement: .return))
        while controller.isRunning { await Task.yield() }

        #expect(controller.lastResult?.hasFailures == false)
        #expect(FileManager.default.fileExists(atPath: left.appending(path: "Renamed Folder").path))
    }

    @Test func coordinatorConsumeThenReturnCommitsTheCapturedLiveRenameIdentity() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Original.txt")
        let destination = root.url.appending(path: "Renamed.txt")
        try Data("data".utf8).write(to: source)
        let item = makeTableItem(named: source.lastPathComponent, in: root.url)
        let workspace = WorkspaceState(
            leftURL: root.url,
            rightURL: root.url,
            listingService: StubDirectoryListingService(values: [root.url: [item]])
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess())
        )
        await workspace.left.navigate(to: root.url, recordHistory: false)
        workspace.left.selection = [source]
        #expect(await controller.requestRename(in: workspace))
        let requestID = try #require(workspace.left.renameRequestID)
        let selection = Binding<Set<URL>>(
            get: { workspace.left.selection },
            set: { workspace.left.selection = $0 }
        )
        let view = FileTableView(
            items: [item],
            selection: selection,
            renameRequestID: requestID,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onConsumeRenameRequest: workspace.left.consumeInlineRenameRequest,
            onDiscardRename: workspace.left.cancelPendingRename,
            onCommitRename: { _, name in
                controller.commitPendingRename(in: workspace.left, to: name, workspace: workspace)
            }
        )
        let coordinator = view.makeCoordinator()
        let tableView = RenameRecordingTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        coordinator.apply(items: [item], selection: [source], to: tableView)
        await Task.yield()

        #expect(workspace.left.renameRequestID == nil)
        #expect(workspace.left.pendingRenameTarget?.url == source)
        let textField = NSTextField(string: item.name)
        let editor = NSTextView()
        #expect(coordinator.control(textField, textShouldBeginEditing: editor))
        coordinator.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: textField
        ))
        textField.stringValue = destination.lastPathComponent
        coordinator.controlTextDidEndEditing(textEditingNotification(textField, movement: .return))
        while controller.isRunning { await Task.yield() }

        #expect(controller.lastResult?.hasFailures == false)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(workspace.left.pendingRenameTarget == nil)
    }

    @Test func restoredSortSynchronizesTableHeaderWithoutReplayingCallback() {
        let selection = SelectionRecorder(value: [])
        let restoredSort = FileSort(key: .size, direction: .descending)
        var callbackSorts: [FileSort] = []
        let view = FileTableView(
            items: [],
            selection: selection.binding,
            sort: restoredSort,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { callbackSorts.append($0) }
        )
        let coordinator = view.makeCoordinator()
        let tableView = NSTableView()
        for identifier in ["name", "modifiedAt", "kind", "size"] {
            tableView.addTableColumn(NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(identifier)
            ))
        }
        tableView.delegate = coordinator

        coordinator.apply(sort: restoredSort, to: tableView)
        coordinator.tableView(tableView, sortDescriptorsDidChange: [])

        let descriptor = tableView.sortDescriptors.first
        #expect(tableView.sortDescriptors.count == 1)
        #expect(descriptor?.key == "size")
        #expect(descriptor?.ascending == false)
        #expect(callbackSorts.isEmpty)
    }

    @Test func reloadKeepsStableURLSelectedWithoutClearingBinding() {
        let directory = URL(filePath: "/tmp/table-test")
        let originalItems = ["a", "b", "c"].map { makeTableItem(named: $0, in: directory) }
        let retainedURL = originalItems[2].url
        let selection = SelectionRecorder(value: [retainedURL])
        let originalView = makeTableView(items: originalItems, selection: selection)
        let coordinator = originalView.makeCoordinator()
        let tableView = ReloadNotifyingTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let reindexedItems = [originalItems[2], originalItems[0]]
        coordinator.parent = makeTableView(items: reindexedItems, selection: selection)
        selection.writes.removeAll()
        coordinator.apply(items: reindexedItems, selection: [retainedURL], to: tableView)

        #expect(tableView.selectedRowIndexes == IndexSet(integer: 0))
        #expect(selection.value == [retainedURL])
        #expect(!selection.writes.contains([]))
    }

    @Test func sortedBatchInsertionUsesOneBoundedUpdateWithoutReloadingAllRows() {
        let directory = URL(filePath: "/table", directoryHint: .isDirectory)
        let oldItems = ["b", "d"].map { makeTableItem(named: $0, in: directory) }
        let newItems = ["a", "b", "c", "d"].map { makeTableItem(named: $0, in: directory) }
        let selection = SelectionRecorder(value: [])
        let coordinator = makeTableView(items: oldItems, selection: selection).makeCoordinator()
        let tableView = UpdateRecordingTableView()

        coordinator.apply(items: newItems, selection: [], to: tableView)

        #expect(tableView.updateCalls == [
            .begin,
            .insert(IndexSet([0, 2])),
            .end
        ])
    }

    @Test func changedRowValueReloadsOnlyThatRow() {
        let oldItems = [makeTableItem(named: "a", in: URL(filePath: "/table"))]
        let changedItems = [FileItem(
            url: oldItems[0].url,
            name: "renamed-a",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        )]
        let selection = SelectionRecorder(value: [])
        let coordinator = makeTableView(items: oldItems, selection: selection).makeCoordinator()
        let tableView = UpdateRecordingTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))

        coordinator.apply(items: changedItems, selection: [], to: tableView)

        #expect(tableView.updateCalls == [.reload(IndexSet(integer: 0))])
    }

    @Test func pureReorderAppliesSequentialMovesInOneBoundedUpdate() {
        let directory = URL(filePath: "/table", directoryHint: .isDirectory)
        let oldItems = ["a", "b", "c", "d"].map { makeTableItem(named: $0, in: directory) }
        let newItems = [oldItems[3], oldItems[1], oldItems[0], oldItems[2]]
        let selection = SelectionRecorder(value: [])
        let coordinator = makeTableView(items: oldItems, selection: selection).makeCoordinator()
        let tableView = UpdateRecordingTableView()

        coordinator.apply(items: newItems, selection: [], to: tableView)

        #expect(tableView.updateCalls == [
            .begin,
            .move(FileTableRowMove(from: 3, to: 0)),
            .move(FileTableRowMove(from: 2, to: 1)),
            .end
        ])
    }

    @Test func subsequenceRemovalUsesOneBoundedUpdateWithoutReloadingAllRows() {
        let directory = URL(filePath: "/table", directoryHint: .isDirectory)
        let oldItems = ["a", "b", "c", "d"].map { makeTableItem(named: $0, in: directory) }
        let newItems = [oldItems[1], oldItems[3]]
        let selection = SelectionRecorder(value: [])
        let coordinator = makeTableView(items: oldItems, selection: selection).makeCoordinator()
        let tableView = UpdateRecordingTableView()

        coordinator.apply(items: newItems, selection: [], to: tableView)

        #expect(tableView.updateCalls == [
            .begin,
            .remove(IndexSet([0, 2])),
            .end
        ])
    }

    @Test func ambiguousMixedChangeReloadsAllRowsExactlyOnce() {
        let directory = URL(filePath: "/table", directoryHint: .isDirectory)
        let oldItems = ["a", "b", "c"].map { makeTableItem(named: $0, in: directory) }
        let newItems = ["a", "d", "c"].map { makeTableItem(named: $0, in: directory) }
        let selection = SelectionRecorder(value: [])
        let coordinator = makeTableView(items: oldItems, selection: selection).makeCoordinator()
        let tableView = UpdateRecordingTableView()

        coordinator.apply(items: newItems, selection: [], to: tableView)

        #expect(tableView.updateCalls == [.reloadAll])
    }

    @Test func insertionRestoresStandardizedURLSelectionFromOneIndexMap() {
        let directory = URL(filePath: "/table", directoryHint: .isDirectory)
        let oldItems = ["b", "d"].map { makeTableItem(named: $0, in: directory) }
        let newItems = ["a", "b", "c", "d"].map { makeTableItem(named: $0, in: directory) }
        let selectedAlias = URL(filePath: "/table/folder/../d")
        let selection = SelectionRecorder(value: [selectedAlias])
        let coordinator = makeTableView(items: oldItems, selection: selection).makeCoordinator()
        let tableView = UpdateRecordingTableView()

        coordinator.apply(items: newItems, selection: [selectedAlias], to: tableView)

        #expect(tableView.selectionRequests == [IndexSet(integer: 3)])
        #expect(selection.value == [selectedAlias])
    }

    @Test func renameRequestResolvesAStandardizedSelectionIdentity() {
        let item = makeTableItem(named: "a", in: URL(filePath: "/table"))
        let selectedAlias = URL(filePath: "/table/folder/../a")
        let selection = SelectionRecorder(value: [selectedAlias])
        let view = FileTableView(
            items: [item],
            selection: selection.binding,
            renameRequestID: UUID(),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let tableView = RenameRecordingTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))

        coordinator.apply(items: [item], selection: [selectedAlias], to: tableView)

        #expect(tableView.editRequests == [RenameEditRequest(column: 0, row: 0)])
    }

    @Test func scrollRequestResolvesAStandardizedAnchorIdentity() {
        let item = makeTableItem(named: "a", in: URL(filePath: "/table"))
        let request = PaneScrollRequest(id: UUID(), anchor: URL(filePath: "/table/folder/../a"))
        var consumed: [UUID] = []
        let view = FileTableView(
            items: [item],
            selection: .constant([]),
            scrollRequest: request,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onConsumeScrollRequest: { consumed.append($0) }
        )
        let coordinator = view.makeCoordinator()

        coordinator.applyScrollRequest(to: NSTableView())

        #expect(consumed == [request.id])
    }

    @Test func insertionPreservesTheFirstVisibleRowByStableIdentity() throws {
        let directory = URL(filePath: "/table-scroll", directoryHint: .isDirectory)
        let oldItems = (0..<30).map {
            makeTableItem(named: String(format: "item-%02d", $0), in: directory)
        }
        let inserted = makeTableItem(named: "item-before", in: directory)
        let view = FileTableView(
            items: [],
            selection: .constant([]),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let scrollView = view.makeScrollView(coordinator: coordinator)
        scrollView.hasVerticalScroller = false
        scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 140)
        let tableView = try #require(scrollView.documentView as? NSTableView)
        tableView.frame = NSRect(x: 0, y: 0, width: 500, height: 31 * 28)
        coordinator.apply(items: oldItems, selection: [], to: tableView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 20 * 28))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let originalFirstRow = tableView.rows(in: tableView.visibleRect).location
        let originalFirstIdentity = oldItems[originalFirstRow].url.standardizedFileURL

        coordinator.apply(items: [inserted] + oldItems, selection: [], to: tableView)

        let updatedFirstRow = tableView.rows(in: tableView.visibleRect).location
        #expect(coordinator.items[updatedFirstRow].url.standardizedFileURL == originalFirstIdentity)
    }

    @Test func insertionRestoresTableFocusWhenAppKitDropsTheResponder() throws {
        let directory = URL(filePath: "/table-focus", directoryHint: .isDirectory)
        let oldItems = [makeTableItem(named: "b", in: directory)]
        let newItems = [makeTableItem(named: "a", in: directory)] + oldItems
        let selection = SelectionRecorder(value: [])
        let coordinator = makeTableView(items: oldItems, selection: selection).makeCoordinator()
        let tableView = FocusDisruptingUpdateTableView()
        let window = FocusStateRecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = tableView
        #expect(window.makeFirstResponder(tableView))
        #expect(window.firstResponder === tableView)

        coordinator.apply(items: newItems, selection: [], to: tableView)

        #expect(window.firstResponder === tableView)
    }

    @Test func tableUpdateThreshold128Measurement() {
        measureTableUpdateThreshold(128, expectsIncrementalBatch: false)
    }

    @Test func tableUpdateThreshold256Measurement() {
        measureTableUpdateThreshold(256, expectsIncrementalBatch: true)
    }

    @Test func tableUpdateThreshold512Measurement() {
        measureTableUpdateThreshold(512, expectsIncrementalBatch: true)
    }

    @Test func tableUpdateThreshold1024Measurement() {
        measureTableUpdateThreshold(1_024, expectsIncrementalBatch: true)
    }

    @Test func oversizedInitialPopulationFallsBackBeforeIdentityPlanningOverhead() {
        let directory = URL(filePath: "/table-initial", directoryHint: .isDirectory)
        let items = (0..<10_000).map {
            makeTableItem(named: String(format: "item-%05d", $0), in: directory)
        }

        let sample = measureFirstRenderedTableState(firstNonemptyItems: items)

        #expect(sample.rowCount == items.count)
        #expect(
            sample.coordinatorApplication < .milliseconds(30),
            "oversized fallback spent too long building identities: \(sample.coordinatorApplication)"
        )
    }

    @Test func unchangedSelectionClickStillActivatesPane() {
        let item = makeTableItem(named: "selected", in: URL(filePath: "/tmp/table-test"))
        let selection = SelectionRecorder(value: [item.url])
        var activationCount = 0
        let view = FileTableView(
            items: [item],
            selection: selection.binding,
            onActivatePane: { activationCount += 1 },
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let tableView = NSTableView()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        coordinator.activatePane(tableView)

        #expect(activationCount == 1)
        #expect(selection.value == [item.url])
    }

    @Test func renameRequestEditsExactlyOnceUntilTheRequestIDChanges() {
        let item = makeTableItem(named: "Report.pdf", in: URL(filePath: "/tmp/table-test"))
        let selection = SelectionRecorder(value: [item.url])
        let firstRequest = UUID()
        var view = FileTableView(
            items: [item],
            selection: selection.binding,
            renameRequestID: firstRequest,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let tableView = RenameRecordingTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator

        coordinator.apply(items: [item], selection: [item.url], to: tableView)
        coordinator.apply(items: [item], selection: [item.url], to: tableView)

        #expect(tableView.editRequests == [RenameEditRequest(column: 0, row: 0)])

        view = FileTableView(
            items: [item],
            selection: selection.binding,
            renameRequestID: UUID(),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        coordinator.parent = view
        coordinator.apply(items: [item], selection: [item.url], to: tableView)

        #expect(tableView.editRequests == [
            RenameEditRequest(column: 0, row: 0),
            RenameEditRequest(column: 0, row: 0)
        ])
    }

    @Test func directCellEditingIsRejectedButRequestedRenameCommitsAndEscapeRestores() {
        let item = makeTableItem(named: "Report.pdf", in: URL(filePath: "/tmp/table-test"))
        let selection = SelectionRecorder(value: [item.url])
        var commits: [(URL, String)] = []
        var editingEvents: [InlineTextEditingEvent] = []
        var discardedRenames = 0
        var view = FileTableView(
            items: [item],
            selection: selection.binding,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onInlineEditingEvent: { editingEvents.append($0) },
            onDiscardRename: { discardedRenames += 1 },
            onCommitRename: { commits.append(($0, $1)) }
        )
        let coordinator = view.makeCoordinator()
        let textField = NSTextField(string: item.name)
        let fieldEditor = NSTextView()

        #expect(coordinator.control(textField, textShouldBeginEditing: fieldEditor) == false)

        view = FileTableView(
            items: [item],
            selection: selection.binding,
            renameRequestID: UUID(),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onInlineEditingEvent: { editingEvents.append($0) },
            onDiscardRename: { discardedRenames += 1 },
            onCommitRename: { commits.append(($0, $1)) }
        )
        coordinator.parent = view
        let tableView = RenameRecordingTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        coordinator.apply(items: [item], selection: [item.url], to: tableView)
        #expect(coordinator.control(textField, textShouldBeginEditing: fieldEditor))

        coordinator.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: textField
        ))
        textField.stringValue = "Renamed.pdf"
        coordinator.controlTextDidEndEditing(textEditingNotification(textField, movement: .return))

        #expect(editingEvents.count == 2)
        if case let .began(beginToken) = editingEvents[0],
           case let .ended(endToken) = editingEvents[1] {
            #expect(beginToken == endToken)
        } else {
            Issue.record("Expected matching begin/end inline editing events")
        }
        #expect(commits.count == 1)
        #expect(commits.first?.0 == item.url)
        #expect(commits.first?.1 == "Renamed.pdf")

        view = FileTableView(
            items: [item],
            selection: selection.binding,
            renameRequestID: UUID(),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onInlineEditingEvent: { editingEvents.append($0) },
            onDiscardRename: { discardedRenames += 1 },
            onCommitRename: { commits.append(($0, $1)) }
        )
        coordinator.parent = view
        coordinator.apply(items: [item], selection: [item.url], to: tableView)
        coordinator.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: textField
        ))
        textField.stringValue = "Ghost.pdf"
        coordinator.controlTextDidEndEditing(textEditingNotification(textField, movement: .cancel))

        #expect(textField.stringValue == item.name)
        #expect(commits.count == 1)
        #expect(discardedRenames == 1)
        #expect(editingEvents.count == 4)
        if case let .began(beginToken) = editingEvents[2],
           case let .ended(endToken) = editingEvents[3] {
            #expect(beginToken == endToken)
        } else {
            Issue.record("Expected matching begin/end inline editing events after Escape")
        }
    }

    @Test func runningOperationStillAllowsDragSubmissionToTheQueue() {
        let item = makeTableItem(named: "item", in: URL(filePath: "/tmp/table-test"))
        let selection = SelectionRecorder(value: [item.url])
        let view = FileTableView(
            items: [item],
            selection: selection.binding,
            isOperationRunning: true,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let tableView = NSTableView()

        #expect(coordinator.tableView(tableView, pasteboardWriterForRow: 0) != nil)
        #expect(coordinator.dragSourceOperationMask == [.copy, .move])
    }

    @Test func acceptedBlankPaneDropRoutesURLsDestinationAndCommandMoveIntent() {
        let directory = URL(filePath: "/destination", directoryHint: .isDirectory)
        let sources = [URL(filePath: "/source/a"), URL(filePath: "/source/b")]
        let selection = SelectionRecorder(value: [])
        var received: ([URL], URL, DropIntent)?
        let view = FileTableView(
            items: [],
            selection: selection.binding,
            directory: directory,
            dropModifierFlags: { [.command] },
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onDrop: { received = ($0, $1, $2) }
        )
        let coordinator = view.makeCoordinator()
        let tableView = NSTableView()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BloomDrop-\(UUID())"))
        FileURLPasteboard.write(sources, to: pasteboard)
        let info = DraggingInfoStub(pasteboard: pasteboard)

        #expect(coordinator.tableView(
            tableView,
            validateDrop: info,
            proposedRow: -1,
            proposedDropOperation: .on
        ) == .move)
        #expect(coordinator.tableView(tableView, acceptDrop: info, row: -1, dropOperation: .on))
        #expect(received?.0 == sources)
        #expect(received?.1 == directory)
        #expect(received?.2 == .move)
    }

    @Test func invalidPasteboardAndFileOrPackageRowsRejectDropCallbacks() {
        let directory = URL(filePath: "/destination", directoryHint: .isDirectory)
        let file = makeTableItem(named: "file", in: directory)
        let package = FileItem(
            url: directory.appending(path: "App.app", directoryHint: .isDirectory),
            name: "App.app",
            isDirectory: true,
            isPackage: true,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Application"
        )
        let selection = SelectionRecorder(value: [])
        var callbackCount = 0
        let view = FileTableView(
            items: [file, package],
            selection: selection.binding,
            directory: directory,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onDrop: { _, _, _ in callbackCount += 1 }
        )
        let coordinator = view.makeCoordinator()
        let tableView = NSTableView()
        let invalidPasteboard = NSPasteboard(name: NSPasteboard.Name("BloomInvalidDrop-\(UUID())"))
        invalidPasteboard.setString("invalid", forType: .string)
        let invalidInfo = DraggingInfoStub(pasteboard: invalidPasteboard)

        #expect(coordinator.tableView(
            tableView,
            validateDrop: invalidInfo,
            proposedRow: -1,
            proposedDropOperation: .on
        ).isEmpty)

        let validPasteboard = NSPasteboard(name: NSPasteboard.Name("BloomValidDrop-\(UUID())"))
        FileURLPasteboard.write([URL(filePath: "/source/a")], to: validPasteboard)
        let validInfo = DraggingInfoStub(pasteboard: validPasteboard)
        #expect(coordinator.tableView(tableView, acceptDrop: validInfo, row: 0, dropOperation: .on) == false)
        #expect(coordinator.tableView(tableView, acceptDrop: validInfo, row: 1, dropOperation: .on) == false)
        #expect(callbackCount == 0)
    }

    @Test func doubleClickStillOpensTheClickedRowWithoutStartingDirectEditing() {
        let item = makeTableItem(named: "item", in: URL(filePath: "/tmp/table-test"))
        let selection = SelectionRecorder(value: [item.url])
        var opened: FileItem?
        let view = FileTableView(
            items: [item],
            selection: selection.binding,
            onActivatePane: {},
            onOpen: { opened = $0 },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let tableView = ClickedRowTableView(clickedRow: 0)

        coordinator.openClickedRow(tableView)

        #expect(opened == item)
        #expect(coordinator.control(NSTextField(string: item.name), textShouldBeginEditing: NSTextView()) == false)
    }

    @Test func plainSpaceRoutesToTheQuickLookMenuEquivalentBeforeTheTableConsumesIt() throws {
        let application = NSApplication.shared
        let originalMainMenu = application.mainMenu
        defer { application.mainMenu = originalMainMenu }

        let recorder = MenuActionRecorder()
        let menu = NSMenu()
        let quickLookItem = NSMenuItem(
            title: "Quick Look",
            action: #selector(MenuActionRecorder.performQuickLook),
            keyEquivalent: " "
        )
        quickLookItem.keyEquivalentModifierMask = []
        quickLookItem.target = recorder
        menu.addItem(quickLookItem)
        application.mainMenu = menu

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        PaneActivatingTableView().keyDown(with: event)

        #expect(recorder.performCount == 1)
    }

    @Test func escapeFromFocusedFilterResultTableDismissesFilterFirst() async throws {
        let directory = URL(filePath: "/filter", directoryHint: .isDirectory)
        let captured = makeTableItem(named: "captured.txt", in: directory)
        let result = makeTableItem(named: "result.txt", in: directory)
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [
                directory: [captured, result]
            ])
        )
        await pane.navigate(to: directory, recordHistory: false)
        pane.selection = [captured.url]
        pane.beginFiltering()
        pane.updateFilterQuery("result")
        #expect(await waitForTablePaneCondition {
            pane.visibleItems == [result] && pane.selection.isEmpty
        })
        var broaderCancellations = 0
        var focusTask: Task<Void, Never>?
        let selection = Binding<Set<URL>>(
            get: { pane.selection },
            set: { pane.selection = $0 }
        )
        let view = FileTableView(
            items: pane.visibleItems,
            selection: selection,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onCancel: {
                guard pane.isFilterPresented else {
                    broaderCancellations += 1
                    return false
                }
                focusTask = PaneFilterDismissalRouting.handle(
                    clearFieldFocus: {},
                    endEditing: {},
                    dismissFilter: pane.dismissFiltering,
                    requestTableFocus: pane.requestTableFocus
                )
                return true
            }
        )
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let table = try #require(scroll.documentView as? PaneActivatingTableView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        coordinator.apply(items: pane.visibleItems, selection: [], to: table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: table
        ))
        #expect(window.makeFirstResponder(table))
        #expect(pane.selection == [result.url])
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ))

        table.keyDown(with: escape)
        await focusTask?.value
        #expect(await waitForTablePaneCondition {
            pane.visibleItems == [captured, result]
                && pane.selection == [captured.url]
        })

        #expect(!pane.isFilterPresented)
        #expect(pane.filterQuery.isEmpty)
        #expect(pane.selection == [captured.url])
        #expect(pane.focusRequestID != nil)
        #expect(broaderCancellations == 0)
    }

    @Test func tableReportsTheFirstVisibleItemAfterScrolling() throws {
        let directory = URL(filePath: "/scroll", directoryHint: .isDirectory)
        let items = (0..<30).map {
            makeTableItem(named: String(format: "item-%02d", $0), in: directory)
        }
        var reported: URL?
        let view = FileTableView(
            items: items,
            selection: .constant([]),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onFirstVisibleItemChange: { reported = $0 }
        )
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 140)
        let table = try #require(scroll.documentView as? NSTableView)
        table.frame = NSRect(x: 0, y: 0, width: 500, height: 30 * 28)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20 * 28))
        scroll.reflectScrolledClipView(scroll.contentView)

        coordinator.reportFirstVisibleItem(in: table)

        let index = try #require(items.firstIndex { $0.url == reported })
        #expect((19...21).contains(index))
    }

    @Test func scrollRestorationPinsTopAnchorToFirstVisibleRow() throws {
        let fixture = try scrollRestorationFixture(anchorIndex: 0, initialY: 300)

        fixture.coordinator.applyScrollRequest(to: fixture.table)

        #expect(fixture.table.rows(in: fixture.table.visibleRect).location == 0)
    }

    @Test func scrollRestorationPinsMiddleAnchorToFirstVisibleRow() throws {
        let fixture = try scrollRestorationFixture(anchorIndex: 15, initialY: 0)

        fixture.coordinator.applyScrollRequest(to: fixture.table)

        #expect(fixture.table.rows(in: fixture.table.visibleRect).location == 15)
    }

    @Test func scrollRestorationClampsEndAnchorToDocumentBottom() throws {
        let fixture = try scrollRestorationFixture(anchorIndex: 29, initialY: 0)

        fixture.coordinator.applyScrollRequest(to: fixture.table)

        let visibleRows = fixture.table.rows(in: fixture.table.visibleRect)
        #expect(NSMaxRange(visibleRows) == 30)
    }

    @Test func tableConsumesEachAvailableScrollRequestExactlyOnce() throws {
        let directory = URL(filePath: "/scroll", directoryHint: .isDirectory)
        let items = (0..<30).map {
            makeTableItem(named: "item-\($0)", in: directory)
        }
        let request = PaneScrollRequest(id: UUID(), anchor: items[20].url)
        var consumed: [UUID] = []
        var view = FileTableView(
            items: items,
            selection: .constant([]),
            scrollRequest: request,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onConsumeScrollRequest: { consumed.append($0) }
        )
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let table = try #require(scroll.documentView as? NSTableView)
        coordinator.apply(items: items, selection: [], to: table)

        coordinator.applyScrollRequest(to: table)
        coordinator.applyScrollRequest(to: table)

        #expect(consumed == [request.id])

        view = FileTableView(
            items: Array(items.dropLast(10)),
            selection: .constant([]),
            scrollRequest: PaneScrollRequest(id: UUID(), anchor: items[29].url),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onConsumeScrollRequest: { consumed.append($0) }
        )
        coordinator.parent = view
        coordinator.apply(items: view.items, selection: [], to: table)
        coordinator.applyScrollRequest(to: table)

        #expect(consumed == [request.id])
    }

    @Test func dismantledTableStopsReportingBoundsChanges() throws {
        let directory = URL(filePath: "/scroll", directoryHint: .isDirectory)
        let items = (0..<30).map {
            makeTableItem(named: "item-\($0)", in: directory)
        }
        var reportCount = 0
        let view = FileTableView(
            items: items,
            selection: .constant([]),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onFirstVisibleItemChange: { _ in reportCount += 1 }
        )
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        _ = try #require(scroll.documentView as? NSTableView)

        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        #expect(reportCount == 1)

        FileTableView.dismantleNSView(scroll, coordinator: coordinator)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )

        #expect(reportCount == 1)
    }

    private func makeTableView(items: [FileItem], selection: SelectionRecorder) -> FileTableView {
        FileTableView(
            items: items,
            selection: selection.binding,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
    }

    private func scrollRestorationFixture(
        anchorIndex: Int,
        initialY: CGFloat
    ) throws -> (
        coordinator: FileTableView.Coordinator,
        scroll: NSScrollView,
        table: PaneActivatingTableView
    ) {
        let directory = URL(filePath: "/scroll", directoryHint: .isDirectory)
        let items = (0..<30).map {
            makeTableItem(named: String(format: "item-%02d", $0), in: directory)
        }
        let view = FileTableView(
            items: items,
            selection: .constant([]),
            scrollRequest: PaneScrollRequest(id: UUID(), anchor: items[anchorIndex].url),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 140)
        let table = try #require(scroll.documentView as? PaneActivatingTableView)
        table.frame = NSRect(x: 0, y: 0, width: 500, height: 900)
        coordinator.apply(items: items, selection: [], to: table)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: initialY))
        scroll.reflectScrolledClipView(scroll.contentView)
        return (coordinator, scroll, table)
    }
}

@MainActor
private func measureTableUpdateThreshold(
    _ threshold: Int,
    expectsIncrementalBatch: Bool
) {
    let directory = URL(filePath: "/table-threshold", directoryHint: .isDirectory)
    let oldItems = (0..<10_000).map {
        makeTableItem(named: String(format: "item-%05d", $0), in: directory)
    }
    let newItems = oldItems + (10_000..<10_256).map {
        makeTableItem(named: String(format: "item-%05d", $0), in: directory)
    }
    let planner = FileTableUpdatePlanner(maximumIncrementalChanges: threshold)
    let plan = planner.plan(from: oldItems, to: newItems)
    if expectsIncrementalBatch {
        guard case let .insert(indexes) = plan else {
            Issue.record("threshold \(threshold) unexpectedly fell back for a 256-row batch")
            return
        }
        #expect(indexes.count == 256)
    } else {
        #expect(plan == .reloadAll)
    }

    let clock = ContinuousClock()
    let recordedSampleCount = max(
        1,
        Int(ProcessInfo.processInfo.environment["PENGRID_TABLE_THRESHOLD_SAMPLES"] ?? "") ?? 1
    )
    let warmupCount = recordedSampleCount > 1 ? 3 : 0
    var samples: [Duration] = []
    var finalRowCount = 0
    for iteration in 0..<(warmupCount + recordedSampleCount) {
        let elapsed: Duration = autoreleasepool {
            let view = FileTableView(
                items: [],
                selection: .constant([]),
                onActivatePane: {},
                onOpen: { _ in },
                onSortChange: { _ in }
            )
            let coordinator = FileTableView.Coordinator(
                parent: view,
                updatePlanner: planner
            )
            let scrollView = view.makeScrollView(coordinator: coordinator)
            scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
            let tableView = scrollView.documentView as! NSTableView
            tableView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
            coordinator.apply(items: oldItems, selection: [], to: tableView)
            tableView.layoutSubtreeIfNeeded()

            let duration = clock.measure {
                coordinator.apply(items: newItems, selection: [], to: tableView)
                tableView.layoutSubtreeIfNeeded()
            }
            finalRowCount = tableView.numberOfRows
            return duration
        }
        if iteration >= warmupCount {
            samples.append(elapsed)
        }
    }

    let sortedSamples = samples.sorted()
    let p95Index = Int(ceil(Double(sortedSamples.count) * 0.95)) - 1
    let p95 = sortedSamples[p95Index]
    #expect(finalRowCount == newItems.count)
    #expect(p95 < .seconds(5), "threshold \(threshold) exceeded the table-update hang ceiling")
    print(
        "navigation-table-threshold threshold=\(threshold) batch=256 samples=\(samples.count) "
            + "plan=\(plan) p95=\(p95) rows=\(finalRowCount)"
    )
}

@MainActor
private final class MenuActionRecorder: NSObject {
    var performCount = 0

    @objc func performQuickLook() {
        performCount += 1
    }
}

@MainActor
private final class SelectionRecorder {
    var value: Set<URL>
    var writes: [Set<URL>] = []

    init(value: Set<URL>) {
        self.value = value
    }

    var binding: Binding<Set<URL>> {
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
private final class ReloadNotifyingTableView: NSTableView {
    override func reloadData() {
        super.reloadData()
        deselectAll(nil)
        NotificationCenter.default.post(name: NSTableView.selectionDidChangeNotification, object: self)
    }
}

private enum TableUpdateCall: Equatable {
    case begin
    case end
    case insert(IndexSet)
    case remove(IndexSet)
    case move(FileTableRowMove)
    case reload(IndexSet)
    case reloadAll
}

@MainActor
private class UpdateRecordingTableView: NSTableView {
    private var recordedSelection: IndexSet = []
    var updateCalls: [TableUpdateCall] = []
    var selectionRequests: [IndexSet] = []

    override var selectedRowIndexes: IndexSet {
        recordedSelection
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        recordedSelection = extend ? recordedSelection.union(indexes) : indexes
        selectionRequests.append(recordedSelection)
    }

    override func beginUpdates() {
        updateCalls.append(.begin)
    }

    override func endUpdates() {
        updateCalls.append(.end)
    }

    override func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        updateCalls.append(.insert(indexes))
    }

    override func removeRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        updateCalls.append(.remove(indexes))
    }

    override func moveRow(at oldIndex: Int, to newIndex: Int) {
        updateCalls.append(.move(FileTableRowMove(from: oldIndex, to: newIndex)))
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        updateCalls.append(.reload(rowIndexes))
    }

    override func reloadData() {
        updateCalls.append(.reloadAll)
    }
}

@MainActor
private final class FocusDisruptingUpdateTableView: UpdateRecordingTableView {
    override func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        super.insertRows(at: indexes, withAnimation: animationOptions)
        _ = window?.makeFirstResponder(nil)
    }

    override func reloadData() {
        super.reloadData()
        _ = window?.makeFirstResponder(nil)
    }
}

@MainActor
private final class FocusStateRecordingWindow: NSWindow {
    private var recordedFirstResponder: NSResponder?

    override var firstResponder: NSResponder? {
        recordedFirstResponder
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        recordedFirstResponder = responder
        return true
    }
}

@MainActor
private final class RenameRecordingTableView: NSTableView {
    var editRequests: [RenameEditRequest] = []

    override func editColumn(_ column: Int, row: Int, with event: NSEvent?, select: Bool) {
        editRequests.append(RenameEditRequest(column: column, row: row))
    }
}

@MainActor
private final class ClickedRowTableView: NSTableView {
    private let row: Int

    init(clickedRow: Int) {
        row = clickedRow
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var clickedRow: Int { row }
}

private struct RenameEditRequest: Equatable {
    let column: Int
    let row: Int
}

@MainActor
private final class DraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

private func textEditingNotification(_ textField: NSTextField, movement: NSTextMovement) -> Notification {
    Notification(
        name: NSControl.textDidEndEditingNotification,
        object: textField,
        userInfo: ["NSTextMovement": NSNumber(value: movement.rawValue)]
    )
}

@MainActor
private func waitForTablePaneCondition(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func makeTableItem(named name: String, in directory: URL) -> FileItem {
    FileItem(
        url: directory.appending(path: name),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: 1,
        typeDescription: "File"
    )
}
