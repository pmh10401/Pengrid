import AppKit
import SwiftUI

struct FileTableView: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<URL>
    let projectionToken: PaneProjectionToken?
    let sort: FileSort
    let directory: URL
    let focusRequestID: UUID?
    let renameRequestID: UUID?
    let scrollRequest: PaneScrollRequest?
    let isOperationRunning: Bool
    let isTextEditing: Bool
    let dropModifierFlags: () -> NSEvent.ModifierFlags
    let onActivatePane: () -> Void
    let onOpen: (FileItem) -> Void
    let onSortChange: (FileSort) -> Void
    let onProjectionApplied: (PaneProjectionToken) -> Void
    let onCancel: () -> Bool
    let onFirstVisibleItemChange: (URL?) -> Void
    let onConsumeScrollRequest: (UUID) -> Void
    let onConsumeRenameRequest: (UUID) -> Void
    let onInlineEditingEvent: (InlineTextEditingEvent) -> Void
    let onDiscardRename: () -> Void
    let onCommitRename: (URL, String) -> Void
    let onDrop: ([URL], URL, DropIntent) -> Void
    let canAddToFavorites: (FileItem) -> Bool
    let onAddToFavorites: (URL) -> Void
    let onCreateFolder: () -> Void
    let onRequestRename: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onCompress: (ArchiveFormat) -> Void
    let onCompressProtected: () -> Void
    let onExtract: () -> Void
    let onRequestTrashConfirmation: () -> Void

    init(
        items: [FileItem],
        selection: Binding<Set<URL>>,
        projectionToken: PaneProjectionToken? = nil,
        sort: FileSort = FileSort(),
        directory: URL = URL(filePath: "/", directoryHint: .isDirectory),
        focusRequestID: UUID? = nil,
        renameRequestID: UUID? = nil,
        scrollRequest: PaneScrollRequest? = nil,
        isOperationRunning: Bool = false,
        isTextEditing: Bool = false,
        dropModifierFlags: @escaping () -> NSEvent.ModifierFlags = {
            NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        },
        onActivatePane: @escaping () -> Void,
        onOpen: @escaping (FileItem) -> Void,
        onSortChange: @escaping (FileSort) -> Void,
        onProjectionApplied: @escaping (PaneProjectionToken) -> Void = { _ in },
        onCancel: @escaping () -> Bool = { false },
        onFirstVisibleItemChange: @escaping (URL?) -> Void = { _ in },
        onConsumeScrollRequest: @escaping (UUID) -> Void = { _ in },
        onConsumeRenameRequest: @escaping (UUID) -> Void = { _ in },
        onInlineEditingEvent: @escaping (InlineTextEditingEvent) -> Void = { _ in },
        onDiscardRename: @escaping () -> Void = {},
        onCommitRename: @escaping (URL, String) -> Void = { _, _ in },
        onDrop: @escaping ([URL], URL, DropIntent) -> Void = { _, _, _ in },
        canAddToFavorites: @escaping (FileItem) -> Bool = { _ in false },
        onAddToFavorites: @escaping (URL) -> Void = { _ in },
        onCreateFolder: @escaping () -> Void = {},
        onRequestRename: @escaping () -> Void = {},
        onCopy: @escaping () -> Void = {},
        onPaste: @escaping () -> Void = {},
        onCompress: @escaping (ArchiveFormat) -> Void = { _ in },
        onCompressProtected: @escaping () -> Void = {},
        onExtract: @escaping () -> Void = {},
        onRequestTrashConfirmation: @escaping () -> Void = {}
    ) {
        self.items = items
        _selection = selection
        self.projectionToken = projectionToken
        self.sort = sort
        self.directory = directory
        self.focusRequestID = focusRequestID
        self.renameRequestID = renameRequestID
        self.scrollRequest = scrollRequest
        self.isOperationRunning = isOperationRunning
        self.isTextEditing = isTextEditing
        self.dropModifierFlags = dropModifierFlags
        self.onActivatePane = onActivatePane
        self.onOpen = onOpen
        self.onSortChange = onSortChange
        self.onProjectionApplied = onProjectionApplied
        self.onCancel = onCancel
        self.onFirstVisibleItemChange = onFirstVisibleItemChange
        self.onConsumeScrollRequest = onConsumeScrollRequest
        self.onConsumeRenameRequest = onConsumeRenameRequest
        self.onInlineEditingEvent = onInlineEditingEvent
        self.onDiscardRename = onDiscardRename
        self.onCommitRename = onCommitRename
        self.onDrop = onDrop
        self.canAddToFavorites = canAddToFavorites
        self.onAddToFavorites = onAddToFavorites
        self.onCreateFolder = onCreateFolder
        self.onRequestRename = onRequestRename
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.onCompress = onCompress
        self.onCompressProtected = onCompressProtected
        self.onExtract = onExtract
        self.onRequestTrashConfirmation = onRequestTrashConfirmation
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let tableView = PaneActivatingTableView()
        tableView.onBecomeFirstResponder = { [weak coordinator] in
            coordinator?.activatePaneFromFocus()
        }
        tableView.onCancel = { [weak coordinator] in
            coordinator?.cancelFromTable() ?? false
        }
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.action = #selector(Coordinator.activatePane(_:))
        tableView.doubleAction = #selector(Coordinator.openClickedRow(_:))
        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = coordinator
        tableView.menu = menu
        coordinator.tableView = tableView

        Column.allCases.forEach { column in
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.minWidth = column.minimumWidth
            tableColumn.width = column.defaultWidth
            tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.identifier.rawValue,
                ascending: true
            )
            tableView.addTableColumn(tableColumn)
        }
        coordinator.apply(sort: sort, to: tableView)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        updateNSView(scrollView, coordinator: context.coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        coordinator.parent = self
        coordinator.apply(sort: sort, to: tableView)
        coordinator.apply(items: items, selection: selection, to: tableView)
        coordinator.applyScrollRequest(to: tableView)
        coordinator.reportFirstVisibleItem(in: tableView)
        coordinator.applyFocusRequest(to: tableView)
        coordinator.notifyProjectionAppliedIfNeeded(projectionToken)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = false
        guard let tableView = scrollView.documentView as? PaneActivatingTableView else { return }
        tableView.onBecomeFirstResponder = nil
        tableView.onCancel = nil
        tableView.dataSource = nil
        tableView.delegate = nil
        tableView.target = nil
        tableView.menu?.delegate = nil
        coordinator.tableView = nil
    }
}

private enum Column: String, CaseIterable {
    case name
    case modifiedAt
    case kind
    case size

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }

    var title: String {
        switch self {
        case .name: "Name"
        case .modifiedAt: "Date Modified"
        case .kind: "Kind"
        case .size: "Size"
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: 180
        case .modifiedAt: 130
        case .kind: 100
        case .size: 72
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: 300
        case .modifiedAt: 150
        case .kind: 130
        case .size: 90
        }
    }

    var sortKey: FileSortKey {
        switch self {
        case .name: .name
        case .modifiedAt: .modifiedAt
        case .kind: .kind
        case .size: .size
        }
    }
}

extension FileTableView {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: FileTableView
        var items: [FileItem]
        var isApplyingSelection = false
        private let updatePlanner: FileTableUpdatePlanner
        private var isApplyingSort = false
        private var isApplyingScrollRequest = false
        private var itemIndexByIdentity: [URL: Int]
        private var hasCompleteItemIndexByIdentity: Bool
        weak var tableView: NSTableView?

        private var lastHandledRenameRequestID: UUID?
        private var lastHandledFocusRequestID: UUID?
        private var lastHandledScrollRequestID: UUID?
        private var editingURL: URL?
        private var isInlineEditingActive = false
        private var inlineEditingToken: UUID?
        private var isPreservingInlineEditing = false
        private var lastAppliedProjectionToken: PaneProjectionToken?

        private struct InlineEditingSnapshot {
            let identity: URL
            let draft: String
            let selectedRange: NSRange
            let wasFirstResponder: Bool
        }

        private static let modifiedDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(
            parent: FileTableView,
            updatePlanner: FileTableUpdatePlanner = FileTableUpdatePlanner()
        ) {
            self.parent = parent
            items = parent.items
            self.updatePlanner = updatePlanner
            itemIndexByIdentity = [:]
            hasCompleteItemIndexByIdentity = parent.items.isEmpty
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func apply(items newItems: [FileItem], selection desiredSelection: Set<URL>, to tableView: NSTableView) {
            let updatePlan = updatePlanner.plan(from: items, to: newItems)
            let inlineEditingSnapshot = updatePlan == .none
                ? nil
                : captureInlineEditing(in: tableView)
            let newItemIndexByIdentity = desiredSelection.isEmpty
                ? nil
                : Self.makeItemIndexByIdentity(for: newItems)
            let desiredIndexes = IndexSet(desiredSelection.compactMap {
                newItemIndexByIdentity?[$0.standardizedFileURL]
            })
            guard updatePlan != .none || tableView.selectedRowIndexes != desiredIndexes else {
                beginRequestedRenameIfPossible(in: tableView)
                return
            }

            let requiresStableStateRestoration = switch updatePlan {
            case .insert, .remove, .move, .reloadAll: true
            case .none, .reload: false
            }
            let firstVisibleIdentity = requiresStableStateRestoration
                ? firstVisibleIdentity(in: tableView)
                : nil
            let tableHadFocus = requiresStableStateRestoration
                && tableView.window?.firstResponder === tableView
            isApplyingSelection = true
            isPreservingInlineEditing = inlineEditingSnapshot != nil
            defer {
                isPreservingInlineEditing = false
                isApplyingSelection = false
            }
            items = newItems
            itemIndexByIdentity = newItemIndexByIdentity ?? [:]
            hasCompleteItemIndexByIdentity = newItemIndexByIdentity != nil || newItems.isEmpty
            apply(updatePlan, to: tableView)
            if tableView.selectedRowIndexes != desiredIndexes {
                tableView.selectRowIndexes(desiredIndexes, byExtendingSelection: false)
            }
            if let inlineEditingSnapshot {
                restoreInlineEditing(inlineEditingSnapshot, in: tableView)
            }
            restoreFirstVisibleIdentity(firstVisibleIdentity, in: tableView)
            if tableHadFocus,
               tableView.window?.firstResponder !== tableView {
                _ = tableView.window?.makeFirstResponder(tableView)
            }
            beginRequestedRenameIfPossible(in: tableView)
        }

        func apply(sort: FileSort, to tableView: NSTableView) {
            let descriptor = tableView.sortDescriptors.first
            let isAlreadyApplied = tableView.sortDescriptors.count == 1
                && descriptor?.key == sort.key.rawValue
                && descriptor?.ascending == (sort.direction == .ascending)
            guard !isAlreadyApplied else { return }

            isApplyingSort = true
            defer { isApplyingSort = false }
            tableView.sortDescriptors = [NSSortDescriptor(
                key: sort.key.rawValue,
                ascending: sort.direction == .ascending
            )]
        }

        func applyFocusRequest(to tableView: NSTableView) {
            guard let requestID = parent.focusRequestID,
                  requestID != lastHandledFocusRequestID,
                  let window = tableView.window,
                  window.makeFirstResponder(tableView)
            else { return }
            lastHandledFocusRequestID = requestID
        }

        func notifyProjectionAppliedIfNeeded(_ token: PaneProjectionToken?) {
            guard let token else { return }
            guard lastAppliedProjectionToken != token else { return }
            if let lastAppliedProjectionToken,
               !token.isNewer(than: lastAppliedProjectionToken) {
                return
            }
            lastAppliedProjectionToken = token
            parent.onProjectionApplied(token)
        }

        func reportFirstVisibleItem(in tableView: NSTableView) {
            guard !isApplyingScrollRequest else { return }
            let row = tableView.rows(in: tableView.visibleRect).location
            let url = items.indices.contains(row) ? items[row].url : nil
            parent.onFirstVisibleItemChange(url)
        }

        func applyScrollRequest(to tableView: NSTableView) {
            guard let request = parent.scrollRequest,
                  request.id != lastHandledScrollRequestID,
                  let row = itemIndex(for: request.anchor)
            else { return }

            isApplyingScrollRequest = true
            scroll(row: row, toTopIn: tableView)
            lastHandledScrollRequestID = request.id
            parent.onConsumeScrollRequest(request.id)
            isApplyingScrollRequest = false
        }

        @objc func scrollViewBoundsDidChange(_ notification: Notification) {
            guard let tableView,
                  notification.object as AnyObject? === tableView.enclosingScrollView?.contentView
            else { return }
            reportFirstVisibleItem(in: tableView)
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard items.indices.contains(row),
                  let identifier = tableColumn?.identifier,
                  let column = Column(rawValue: identifier.rawValue)
            else { return nil }

            let item = items[row]
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? makeCell(for: column, identifier: identifier)
            configure(cell, for: column, item: item)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection,
                  let tableView = notification.object as? NSTableView
            else { return }

            let urls = FileTableSelection.urls(
                for: tableView.selectedRowIndexes,
                items: items.map(\.url)
            )
            if parent.selection != urls {
                parent.selection = urls
            }
            parent.onActivatePane()
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !isApplyingSort,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = Column(rawValue: key)
            else { return }

            let updatedSort = FileSort(
                key: column.sortKey,
                direction: descriptor.ascending ? .ascending : .descending
            )
            guard updatedSort != parent.sort else { return }
            parent.onSortChange(updatedSort)
        }

        @objc func activatePane(_ sender: NSTableView) {
            parent.onActivatePane()
        }

        func activatePaneFromFocus() {
            parent.onActivatePane()
        }

        func cancelFromTable() -> Bool {
            parent.onCancel()
        }

        @objc func openClickedRow(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard items.indices.contains(row) else { return }
            parent.onActivatePane()
            parent.onOpen(items[row])
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard items.indices.contains(row) else { return nil }
            return items[row].url as NSURL
        }

        var dragSourceOperationMask: NSDragOperation {
            [.copy, .move]
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            dragSourceOperationMask
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard !FileURLPasteboard.read(from: info.draggingPasteboard).isEmpty,
                  dropDestination(for: row) != nil
            else { return [] }

            if items.indices.contains(row) {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            return dragOperation(for: currentModifiers())
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let destination = dropDestination(for: row)
            else { return false }
            let urls = FileURLPasteboard.read(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }

            parent.onActivatePane()
            parent.onDrop(urls, destination, DropIntent.resolve(modifiers: currentModifiers()))
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isPreservingInlineEditing else { return }
            guard let textField = notification.object as? NSTextField,
                  let source = editingURL
            else { return }
            defer {
                editingURL = nil
                if isInlineEditingActive {
                    isInlineEditingActive = false
                    if let inlineEditingToken {
                        parent.onInlineEditingEvent(.ended(inlineEditingToken))
                    }
                    inlineEditingToken = nil
                }
            }

            let movement = (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
            if movement == NSTextMovement.cancel.rawValue {
                if let row = itemIndex(for: source), items.indices.contains(row) {
                    let item = items[row]
                    textField.stringValue = item.name
                }
                parent.onDiscardRename()
                return
            }
            let newName = textField.stringValue
            guard let row = itemIndex(for: source), items.indices.contains(row) else {
                parent.onDiscardRename()
                return
            }
            let item = items[row]
            guard newName != item.name else {
                parent.onDiscardRename()
                return
            }
            parent.onCommitRename(source, newName)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard editingURL != nil, !isInlineEditingActive else { return }
            isInlineEditingActive = true
            let token = UUID()
            inlineEditingToken = token
            parent.onInlineEditingEvent(.began(token))
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            editingURL != nil
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            prepareSelectionForContextMenu()
            let selectedItems = items.filter { parent.selection.contains($0.url) }
            let policy = WorkspaceCommandPolicy(
                selectionCount: parent.selection.count,
                isOperationRunning: parent.isOperationRunning,
                pasteboardHasFileURLs: FileURLPasteboard.containsFileURLs(in: .general),
                selectedItems: selectedItems,
                isTextEditing: parent.isTextEditing
            )
            menu.removeAllItems()
            addMenuItem("New Folder", action: #selector(createFolderFromMenu), enabled: policy.canCreateFolder, to: menu)
            addMenuItem(
                "Add to Favorites",
                action: #selector(addFavoriteFromMenu),
                enabled: favoriteForContextMenu != nil,
                to: menu
            )
            addMenuItem("Rename", action: #selector(renameFromMenu), enabled: policy.canRename, to: menu)
            menu.addItem(.separator())
            addMenuItem("Copy", action: #selector(copyFromMenu), enabled: policy.canCopy, to: menu)
            addMenuItem("Paste", action: #selector(pasteFromMenu), enabled: policy.canPaste, to: menu)
            menu.addItem(.separator())
            addMenuItem(
                "Compress to ZIP",
                action: #selector(compressFromMenu),
                enabled: policy.canCompress,
                to: menu
            )
            addMenuItem(
                "Compress as Password-Protected ZIP…",
                action: #selector(compressProtectedFromMenu),
                enabled: policy.canCompressProtectedZIP,
                to: menu,
                identifier: AccessibilityIdentifiers.fileTableCompressProtectedZIP
            )
            addCompressSubmenu(enabled: policy.canCompress, to: menu)
            addMenuItem(
                "Extract Archive",
                action: #selector(extractFromMenu),
                enabled: policy.canExtract,
                to: menu
            )
            menu.addItem(.separator())
            addMenuItem("Move to Trash…", action: #selector(trashFromMenu), enabled: policy.canTrash, to: menu)
        }

        @objc private func createFolderFromMenu() { parent.onCreateFolder() }
        @objc private func addFavoriteFromMenu() {
            guard let favoriteForContextMenu else { return }
            parent.onAddToFavorites(favoriteForContextMenu.url)
        }
        @objc private func renameFromMenu() { parent.onRequestRename() }
        @objc private func copyFromMenu() { parent.onCopy() }
        @objc private func pasteFromMenu() { parent.onPaste() }
        @objc private func compressFromMenu() { parent.onCompress(.zip) }
        @objc func compressProtectedFromMenu() { parent.onCompressProtected() }
        @objc private func compressAsFromMenu(_ sender: NSMenuItem) {
            guard ArchiveFormat.allCases.indices.contains(sender.tag) else { return }
            parent.onCompress(ArchiveFormat.allCases[sender.tag])
        }
        @objc private func extractFromMenu() { parent.onExtract() }
        @objc private func trashFromMenu() { parent.onRequestTrashConfirmation() }

        private func makeCell(
            for column: Column,
            identifier: NSUserInterfaceItemIdentifier
        ) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.textColor = column == .name ? .labelColor : .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = textField
            cell.addSubview(textField)

            if column == .name {
                textField.isEditable = true
                textField.isSelectable = true
                textField.delegate = self
                let imageView = NSImageView()
                imageView.imageScaling = .scaleProportionallyDown
                imageView.translatesAutoresizingMaskIntoConstraints = false
                cell.imageView = imageView
                cell.addSubview(imageView)
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6)
                ])
            } else {
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6).isActive = true
            }

            NSLayoutConstraint.activate([
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func configure(_ cell: NSTableCellView, for column: Column, item: FileItem) {
            switch column {
            case .name:
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
                cell.textField?.stringValue = item.name
                cell.textField?.toolTip = item.url.path
            case .modifiedAt:
                cell.textField?.stringValue = item.modifiedAt.map(Self.modifiedDateFormatter.string) ?? "—"
            case .kind:
                cell.textField?.stringValue = item.typeDescription
            case .size:
                cell.textField?.stringValue = item.byteSize.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "—"
            }
        }

        private func beginRequestedRenameIfPossible(in tableView: NSTableView) {
            guard let requestID = parent.renameRequestID,
                  requestID != lastHandledRenameRequestID,
                  parent.selection.count == 1,
                  let selectedURL = parent.selection.first,
                  let row = itemIndex(for: selectedURL),
                  let nameColumn = tableView.tableColumns.firstIndex(where: { $0.identifier == Column.name.identifier })
            else { return }

            lastHandledRenameRequestID = requestID
            editingURL = items[row].url
            tableView.editColumn(nameColumn, row: row, with: nil, select: true)
            let consumeRequest = parent.onConsumeRenameRequest
            Task { @MainActor in
                consumeRequest(requestID)
            }
            Task { @MainActor [weak self, weak tableView] in
                await Task.yield()
                guard let self, !self.isInlineEditingActive, tableView?.currentEditor() == nil else { return }
                self.editingURL = nil
            }
            if let editor = tableView.currentEditor() as? NSTextView {
                editor.setSelectedRange(InlineRenameSelection.range(
                    for: items[row].name,
                    isDirectory: items[row].isDirectory
                ))
            }
        }

        private func captureInlineEditing(in tableView: NSTableView) -> InlineEditingSnapshot? {
            guard isInlineEditingActive,
                  let identity = editingURL?.standardizedFileURL,
                  let editor = tableView.window?.firstResponder as? NSTextView
            else { return nil }
            return InlineEditingSnapshot(
                identity: identity,
                draft: editor.string,
                selectedRange: editor.selectedRange(),
                wasFirstResponder: tableView.window?.firstResponder === editor
            )
        }

        private func restoreInlineEditing(
            _ snapshot: InlineEditingSnapshot,
            in tableView: NSTableView
        ) {
            guard let row = itemIndex(for: snapshot.identity),
                  let nameColumn = tableView.tableColumns.firstIndex(where: {
                      $0.identifier == Column.name.identifier
                  })
            else {
                discardUnrestorableInlineEditing(in: tableView)
                return
            }

            editingURL = items[row].url
            tableView.editColumn(nameColumn, row: row, with: nil, select: false)
            guard let cell = tableView.view(
                atColumn: nameColumn,
                row: row,
                makeIfNecessary: true
            ) as? NSTableCellView,
                  let textField = cell.textField
            else {
                discardUnrestorableInlineEditing(in: tableView)
                return
            }

            textField.stringValue = snapshot.draft
            var editor = tableView.currentEditor() as? NSTextView
            if editor == nil {
                textField.selectText(nil)
                editor = textField.currentEditor() as? NSTextView
            }
            guard let editor else {
                discardUnrestorableInlineEditing(in: tableView)
                return
            }

            editor.string = snapshot.draft
            editor.setSelectedRange(Self.clamped(snapshot.selectedRange, in: snapshot.draft))
            if snapshot.wasFirstResponder,
               tableView.window?.firstResponder !== editor {
                _ = tableView.window?.makeFirstResponder(editor)
            }
        }

        private func discardUnrestorableInlineEditing(in tableView: NSTableView) {
            _ = tableView.window?.makeFirstResponder(nil)
            editingURL = nil
            if isInlineEditingActive {
                isInlineEditingActive = false
                if let inlineEditingToken {
                    parent.onInlineEditingEvent(.ended(inlineEditingToken))
                }
                inlineEditingToken = nil
            }
            parent.onDiscardRename()
        }

        private static func clamped(_ range: NSRange, in text: String) -> NSRange {
            let length = (text as NSString).length
            let location = min(max(0, range.location), length)
            let remaining = length - location
            return NSRange(location: location, length: min(max(0, range.length), remaining))
        }

        private func apply(_ plan: FileTableUpdatePlan, to tableView: NSTableView) {
            switch plan {
            case .none:
                return
            case let .insert(indexes):
                applyBoundedChanges(to: tableView) {
                    tableView.insertRows(at: indexes, withAnimation: [])
                }
            case let .remove(indexes):
                applyBoundedChanges(to: tableView) {
                    tableView.removeRows(at: indexes, withAnimation: [])
                }
            case let .reload(indexes):
                tableView.reloadData(
                    forRowIndexes: indexes,
                    columnIndexes: IndexSet(integersIn: tableView.tableColumns.indices)
                )
            case let .move(moves):
                applyBoundedChanges(to: tableView) {
                    for move in moves {
                        tableView.moveRow(at: move.from, to: move.to)
                    }
                }
            case .reloadAll:
                tableView.reloadData()
            }
        }

        private func applyBoundedChanges(to tableView: NSTableView, changes: () -> Void) {
            tableView.beginUpdates()
            changes()
            tableView.endUpdates()
        }

        private func firstVisibleIdentity(in tableView: NSTableView) -> URL? {
            guard tableView.enclosingScrollView != nil else { return nil }
            let row = tableView.rows(in: tableView.visibleRect).location
            return items.indices.contains(row) ? items[row].url.standardizedFileURL : nil
        }

        private func restoreFirstVisibleIdentity(_ identity: URL?, in tableView: NSTableView) {
            guard let identity,
                  let row = itemIndex(for: identity)
            else { return }
            scroll(row: row, toTopIn: tableView)
        }

        private func scroll(row: Int, toTopIn tableView: NSTableView) {
            if let scrollView = tableView.enclosingScrollView {
                let clipView = scrollView.contentView
                let requestedBounds = NSRect(
                    x: clipView.bounds.minX,
                    y: tableView.rect(ofRow: row).minY,
                    width: clipView.bounds.width,
                    height: clipView.bounds.height
                )
                let targetBounds = clipView.constrainBoundsRect(requestedBounds)
                clipView.scroll(to: targetBounds.origin)
                scrollView.reflectScrolledClipView(clipView)
            } else {
                tableView.scrollRowToVisible(row)
            }
        }

        private static func makeItemIndexByIdentity(for items: [FileItem]) -> [URL: Int] {
            var result: [URL: Int] = [:]
            result.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                let identity = item.url.standardizedFileURL
                result[identity] = index
            }
            return result
        }

        private func itemIndex(for url: URL) -> Int? {
            if !hasCompleteItemIndexByIdentity {
                itemIndexByIdentity = Self.makeItemIndexByIdentity(for: items)
                hasCompleteItemIndexByIdentity = true
            }
            return itemIndexByIdentity[url.standardizedFileURL]
        }

        private func dropDestination(for row: Int) -> URL? {
            FileTableDropRouting.destination(
                for: row,
                items: items,
                paneDirectory: parent.directory
            )
        }

        private func currentModifiers() -> NSEvent.ModifierFlags {
            parent.dropModifierFlags()
        }

        private func dragOperation(for modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
            switch DropIntent.resolve(modifiers: modifiers) {
            case .copy: .copy
            case .move: .move
            }
        }

        private func prepareSelectionForContextMenu() {
            guard let tableView,
                  items.indices.contains(tableView.clickedRow),
                  !tableView.selectedRowIndexes.contains(tableView.clickedRow)
            else {
                parent.onActivatePane()
                return
            }
            tableView.selectRowIndexes(IndexSet(integer: tableView.clickedRow), byExtendingSelection: false)
            parent.onActivatePane()
        }

        private var favoriteForContextMenu: FileItem? {
            guard let tableView,
                  items.indices.contains(tableView.clickedRow)
            else { return nil }
            let item = items[tableView.clickedRow]
            return parent.canAddToFavorites(item) ? item : nil
        }

        private func addMenuItem(
            _ title: String,
            action: Selector,
            enabled: Bool,
            to menu: NSMenu,
            identifier: String? = nil
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            if let identifier {
                item.identifier = NSUserInterfaceItemIdentifier(identifier)
            }
            menu.addItem(item)
        }

        private func addCompressSubmenu(enabled: Bool, to menu: NSMenu) {
            let submenu = NSMenu(title: "Compress as…")
            for (index, format) in ArchiveFormat.allCases.enumerated() {
                let item = NSMenuItem(
                    title: format.displayName,
                    action: #selector(compressAsFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.isEnabled = enabled
                submenu.addItem(item)
            }
            let parentItem = NSMenuItem(title: "Compress as…", action: nil, keyEquivalent: "")
            parentItem.submenu = submenu
            parentItem.isEnabled = enabled
            menu.addItem(parentItem)
        }
    }
}
