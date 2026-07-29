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
        #expect(WorkspaceCommandActions.createFolder(
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

    @Test func runningOperationDisablesDragSourceWritingAndOperationMask() {
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

        #expect(coordinator.tableView(tableView, pasteboardWriterForRow: 0) == nil)
        #expect(coordinator.dragSourceOperationMask.isEmpty)
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

    private func makeTableView(items: [FileItem], selection: SelectionRecorder) -> FileTableView {
        FileTableView(
            items: items,
            selection: selection.binding,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
    }
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
