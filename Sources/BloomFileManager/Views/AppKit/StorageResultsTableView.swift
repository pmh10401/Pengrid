import AppKit
import SwiftUI

enum StorageResultColumn: String, CaseIterable {
    case name
    case relativeParent
    case size
    case modified
    case category
    case verification

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("storageInspector.result.\(rawValue)")
    }

    var title: String {
        switch self {
        case .name: "Name"
        case .relativeParent: "Location"
        case .size: "Size"
        case .modified: "Modified"
        case .category: "Category"
        case .verification: "Verification"
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: 150
        case .relativeParent: 160
        case .size: 72
        case .modified: 145
        case .category: 90
        case .verification: 130
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: 220
        case .relativeParent: 240
        case .size: 82
        case .modified: 170
        case .category: 100
        case .verification: 160
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

struct StorageResultCellReload: Equatable {
    let rows: IndexSet
    let columns: IndexSet
}

struct StorageResultsTableUpdatePlan: Equatable {
    let removals: IndexSet
    let insertions: IndexSet
    let cellReloads: [StorageResultCellReload]

    static func make(
        from oldRows: [StorageResultRow],
        to newRows: [StorageResultRow]
    ) -> Self {
        let difference = newRows.map(\.id).difference(from: oldRows.map(\.id))
        let removals = IndexSet(difference.compactMap { change in
            if case let .remove(offset, _, _) = change { offset } else { nil }
        })
        let insertions = IndexSet(difference.compactMap { change in
            if case let .insert(offset, _, _) = change { offset } else { nil }
        })
        let oldRowsByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
        var groupedRows: [IndexSet: IndexSet] = [:]
        for (index, newRow) in newRows.enumerated() {
            guard let oldRow = oldRowsByID[newRow.id] else { continue }
            let columns = changedColumns(from: oldRow, to: newRow)
            if !columns.isEmpty {
                groupedRows[columns, default: []].insert(index)
            }
        }
        let cellReloads = groupedRows.map { columns, rows in
            StorageResultCellReload(rows: rows, columns: columns)
        }.sorted { lhs, rhs in
            let leftColumn = lhs.columns.first ?? 0
            let rightColumn = rhs.columns.first ?? 0
            if leftColumn != rightColumn { return leftColumn < rightColumn }
            return (lhs.rows.first ?? 0) < (rhs.rows.first ?? 0)
        }
        return Self(
            removals: removals,
            insertions: insertions,
            cellReloads: cellReloads
        )
    }

    private static func changedColumns(
        from old: StorageResultRow,
        to new: StorageResultRow
    ) -> IndexSet {
        var columns = IndexSet()
        if old.name != new.name { columns.insert(StorageResultColumn.name.index) }
        if old.relativeParent != new.relativeParent {
            columns.insert(StorageResultColumn.relativeParent.index)
        }
        if old.sizeText != new.sizeText {
            columns.insert(StorageResultColumn.size.index)
        }
        if old.modifiedText != new.modifiedText {
            columns.insert(StorageResultColumn.modified.index)
        }
        if old.categoryText != new.categoryText {
            columns.insert(StorageResultColumn.category.index)
        }
        if old.verificationText != new.verificationText {
            columns.insert(StorageResultColumn.verification.index)
        }
        return columns
    }
}

final class StorageResultsNSTableView: NSTableView {
    var onQuickLook: (() -> Void)?
    var onWindowAttachment: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onWindowAttachment?()
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let characters = event.charactersIgnoringModifiers
        if (characters == " " || characters == "\r" || characters == "\n"),
           event.modifierFlags.intersection(modifiers).isEmpty {
            onQuickLook?()
            return
        }
        super.keyDown(with: event)
    }
}

struct StorageResultsTableView: NSViewRepresentable {
    let rows: [StorageResultRow]
    let section: StorageAnalysisSection
    @Binding var selection: Set<StorageRelativePath>
    let focusRequestID: UUID?
    let reduceMotion: Bool
    let onQuickLook: (StorageRelativePath) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = StorageResultsNSTableView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityIdentifier(
            StorageResultsAccessibilityPresentation.identifier(section: section)
        )
        tableView.setAccessibilityLabel(
            StorageResultsAccessibilityPresentation.label(section: section)
        )
        tableView.onQuickLook = { [weak coordinator = context.coordinator] in
            coordinator?.quickLookSelection()
        }
        tableView.onWindowAttachment = {
            [weak tableView, weak coordinator = context.coordinator] in
            guard let tableView else { return }
            coordinator?.applyFocusRequest(to: tableView)
        }

        for column in StorageResultColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.minWidth = column.minimumWidth
            tableColumn.width = column.defaultWidth
            tableColumn.resizingMask = column == .name
                ? [.autoresizingMask, .userResizingMask]
                : .userResizingMask
            tableView.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.apply(
            rows: rows,
            selection: selection,
            reduceMotion: reduceMotion,
            to: tableView
        )
        context.coordinator.applyFocusRequest(to: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? StorageResultsNSTableView else {
            return
        }
        context.coordinator.parent = self
        context.coordinator.apply(
            rows: rows,
            selection: selection,
            reduceMotion: reduceMotion,
            to: tableView
        )
        context.coordinator.applyFocusRequest(to: tableView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let tableView = scrollView.documentView as? StorageResultsNSTableView else {
            return
        }
        tableView.onQuickLook = nil
        tableView.onWindowAttachment = nil
        tableView.dataSource = nil
        tableView.delegate = nil
        coordinator.tableView = nil
    }
}

enum StorageResultsAccessibilityPresentation {
    static func identifier(section: StorageAnalysisSection) -> String {
        section == .duplicates
            ? AccessibilityIdentifiers.storageInspectorGroupMembers
            : "\(AccessibilityIdentifiers.storageInspectorResults).table"
    }

    static func label(section: StorageAnalysisSection) -> String {
        section == .duplicates
            ? "Duplicate group members"
            : "\(StorageInspectorPresentation.sectionTitle(section)) results"
    }
}

extension StorageResultsTableView {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: StorageResultsTableView
        private(set) var rows: [StorageResultRow]
        private var isApplyingSelection = false
        private var lastHandledFocusRequestID: UUID?
        weak var tableView: NSTableView?

        init(parent: StorageResultsTableView) {
            self.parent = parent
            rows = parent.rows
        }

        func numberOfRows(in _: NSTableView) -> Int {
            rows.count
        }

        func apply(
            rows newRows: [StorageResultRow],
            selection desiredSelection: Set<StorageRelativePath>,
            reduceMotion: Bool,
            to tableView: NSTableView
        ) {
            isApplyingSelection = true
            defer { isApplyingSelection = false }

            let plan = StorageResultsTableUpdatePlan.make(from: rows, to: newRows)
            rows = newRows
            if !plan.removals.isEmpty || !plan.insertions.isEmpty {
                applyStructuralChanges(
                    plan: plan,
                    reduceMotion: reduceMotion,
                    in: tableView
                )
            }
            applyCellReloads(plan.cellReloads, in: tableView)

            let desiredIndexes = IndexSet(newRows.indices.filter {
                desiredSelection.contains(newRows[$0].id)
            })
            if tableView.selectedRowIndexes != desiredIndexes {
                tableView.selectRowIndexes(desiredIndexes, byExtendingSelection: false)
            }
        }

        func applyFocusRequest(to tableView: NSTableView) {
            guard let requestID = parent.focusRequestID,
                  requestID != lastHandledFocusRequestID,
                  let window = tableView.window,
                  window.makeFirstResponder(tableView)
            else {
                return
            }
            lastHandledFocusRequestID = requestID
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row),
                  let identifier = tableColumn?.identifier,
                  let column = StorageResultColumn.allCases.first(where: {
                      $0.identifier == identifier
                  })
            else {
                return nil
            }

            let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? NSTableCellView ?? makeCell(identifier: identifier)
            configure(cell, column: column, row: rows[row])
            return cell
        }

        func tableView(_: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard rows.indices.contains(row) else { return nil }
            let rowView = NSTableRowView()
            configure(rowView, row: rows[row])
            return rowView
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection,
                  let tableView = notification.object as? NSTableView
            else {
                return
            }
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { index in
                rows.indices.contains(index) ? rows[index].id : nil
            })
            if parent.selection != selectedIDs {
                parent.selection = selectedIDs
            }
        }

        func quickLookSelection() {
            guard let tableView,
                  rows.indices.contains(tableView.selectedRow)
            else {
                return
            }
            parent.onQuickLook(rows[tableView.selectedRow].id)
        }

        private func applyStructuralChanges(
            plan: StorageResultsTableUpdatePlan,
            reduceMotion: Bool,
            in tableView: NSTableView
        ) {
            tableView.beginUpdates()
            if !plan.removals.isEmpty {
                tableView.removeRows(
                    at: plan.removals,
                    withAnimation: reduceMotion ? [] : .effectFade
                )
            }
            if !plan.insertions.isEmpty {
                tableView.insertRows(
                    at: plan.insertions,
                    withAnimation: reduceMotion ? [] : .effectFade
                )
            }
            tableView.endUpdates()
        }

        private func applyCellReloads(
            _ reloads: [StorageResultCellReload],
            in tableView: NSTableView
        ) {
            for reload in reloads {
                tableView.reloadData(
                    forRowIndexes: reload.rows,
                    columnIndexes: reload.columns
                )
                for index in reload.rows {
                    if rows.indices.contains(index),
                       let rowView = tableView.rowView(
                           atRow: index,
                           makeIfNecessary: false
                       ) {
                        configure(rowView, row: rows[index])
                    }
                }
            }
        }

        private func makeCell(
            identifier: NSUserInterfaceItemIdentifier
        ) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func configure(
            _ cell: NSTableCellView,
            column: StorageResultColumn,
            row: StorageResultRow
        ) {
            let value: String
            switch column {
            case .name: value = row.name
            case .relativeParent: value = row.relativeParent
            case .size: value = row.sizeText
            case .modified: value = row.modifiedText
            case .category: value = row.categoryText
            case .verification: value = row.verificationText
            }
            cell.textField?.stringValue = value
            cell.textField?.textColor = column == .name ? .labelColor : .secondaryLabelColor
            cell.setAccessibilityElement(true)
            cell.setAccessibilityIdentifier(
                "storageInspector.result.\(column.rawValue).\(row.id.string)"
            )
            cell.setAccessibilityLabel(column.title)
            cell.setAccessibilityValue(value)
        }

        private func configure(_ rowView: NSTableRowView, row: StorageResultRow) {
            rowView.setAccessibilityElement(true)
            rowView.setAccessibilityIdentifier("storageInspector.result.row.\(row.id.string)")
            rowView.setAccessibilityLabel(row.accessibilityLabel)
        }
    }
}
