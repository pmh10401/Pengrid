import AppKit
import SwiftUI

enum ComparisonColumn: String, CaseIterable {
    case left
    case status
    case right

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }

    var index: Int {
        switch self {
        case .left: 0
        case .status: 1
        case .right: 2
        }
    }

    var title: String {
        switch self {
        case .left: "Left"
        case .status: "Status"
        case .right: "Right"
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .left, .right: 180
        case .status: 170
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .left, .right: 360
        case .status: 210
        }
    }
}

struct ComparisonTableView: NSViewRepresentable {
    let rows: [ComparisonRow]
    @Binding var selection: Set<ComparisonRelativePath>
    let focusRequestID: UUID?

    init(
        rows: [ComparisonRow],
        selection: Binding<Set<ComparisonRelativePath>>,
        focusRequestID: UUID? = nil
    ) {
        self.rows = rows
        _selection = selection
        self.focusRequestID = focusRequestID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let tableView = NSTableView()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.rowHeight = 38
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityIdentifier(AccessibilityIdentifiers.comparisonTable)

        for column in ComparisonColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.minWidth = column.minimumWidth
            tableColumn.width = column.defaultWidth
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableView.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        coordinator.tableView = tableView
        coordinator.apply(rows: rows, selection: selection, to: tableView)
        coordinator.applyFocusRequest(to: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.parent = self
        context.coordinator.apply(rows: rows, selection: selection, to: tableView)
        context.coordinator.applyFocusRequest(to: tableView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        tableView.dataSource = nil
        tableView.delegate = nil
        coordinator.tableView = nil
    }
}

extension ComparisonTableView {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ComparisonTableView
        private(set) var rows: [ComparisonRow]
        private var isApplyingSelection = false
        private var lastHandledFocusRequestID: UUID?
        weak var tableView: NSTableView?

        init(parent: ComparisonTableView) {
            self.parent = parent
            rows = parent.rows
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func apply(
            rows newRows: [ComparisonRow],
            selection desiredSelection: Set<ComparisonRelativePath>,
            to tableView: NSTableView
        ) {
            let update = tableUpdate(from: rows, to: newRows)
            let desiredIndexes = IndexSet(newRows.indices.filter {
                desiredSelection.contains(newRows[$0].id)
            })
            guard update != .none || tableView.selectedRowIndexes != desiredIndexes else { return }

            isApplyingSelection = true
            defer { isApplyingSelection = false }
            switch update {
            case .none:
                break
            case .structural:
                rows = newRows
                tableView.reloadData()
            case let .cells(reloads):
                rows = newRows
                for reload in reloads {
                    tableView.reloadData(
                        forRowIndexes: reload.rows,
                        columnIndexes: reload.columns
                    )
                    for rowIndex in reload.rows {
                        guard rows.indices.contains(rowIndex),
                              let rowView = tableView.rowView(
                                atRow: rowIndex,
                                makeIfNecessary: false
                              )
                        else { continue }
                        configureRowView(rowView, row: rows[rowIndex])
                    }
                }
            }
            if tableView.selectedRowIndexes != desiredIndexes {
                tableView.selectRowIndexes(desiredIndexes, byExtendingSelection: false)
            }
        }

        private func tableUpdate(
            from oldRows: [ComparisonRow],
            to newRows: [ComparisonRow]
        ) -> ComparisonTableUpdate {
            guard oldRows.map(\.id) == newRows.map(\.id) else { return .structural }

            var groupedRows: [IndexSet: IndexSet] = [:]
            for index in newRows.indices {
                let old = oldRows[index]
                let new = newRows[index]
                var columns = IndexSet()
                if old.left != new.left {
                    columns.insert(ComparisonColumn.left.index)
                    columns.insert(ComparisonColumn.status.index)
                }
                if old.right != new.right {
                    columns.insert(ComparisonColumn.right.index)
                    columns.insert(ComparisonColumn.status.index)
                }
                if old.status != new.status
                    || old.descendantDifferenceCount != new.descendantDifferenceCount {
                    columns.insert(ComparisonColumn.status.index)
                }
                if !columns.isEmpty {
                    groupedRows[columns, default: []].insert(index)
                }
            }

            let reloads = groupedRows.map { columns, rows in
                ComparisonCellReload(rows: rows, columns: columns)
            }.sorted { lhs, rhs in
                let leftColumn = lhs.columns.first ?? 0
                let rightColumn = rhs.columns.first ?? 0
                if leftColumn != rightColumn { return leftColumn < rightColumn }
                return (lhs.rows.first ?? 0) < (rhs.rows.first ?? 0)
            }
            return reloads.isEmpty ? .none : .cells(reloads)
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row),
                  let identifier = tableColumn?.identifier,
                  let column = ComparisonColumn(rawValue: identifier.rawValue)
            else { return nil }

            let comparisonRow = rows[row]
            switch column {
            case .left, .right:
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                    ?? makeSideCell(identifier: identifier)
                configureSideCell(
                    cell,
                    entry: column == .left ? comparisonRow.left : comparisonRow.right,
                    row: comparisonRow,
                    side: column
                )
                return cell
            case .status:
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                    ?? makeStatusCell(identifier: identifier)
                configureStatusCell(cell, row: comparisonRow)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard rows.indices.contains(row) else { return nil }
            let rowView = NSTableRowView()
            configureRowView(rowView, row: rows[row])
            return rowView
        }

        private func configureRowView(_ rowView: NSTableRowView, row: ComparisonRow) {
            let presentation = ComparisonAccessibility.status(row)
            rowView.setAccessibilityElement(true)
            rowView.setAccessibilityIdentifier("comparison.row.\(row.id.string)")
            rowView.setAccessibilityLabel(ComparisonAccessibility.row(row))
            rowView.setAccessibilityValue(presentation.value)
        }

        func applyFocusRequest(to tableView: NSTableView) {
            guard let requestID = parent.focusRequestID,
                  requestID != lastHandledFocusRequestID,
                  let window = tableView.window,
                  window.makeFirstResponder(tableView)
            else { return }
            lastHandledFocusRequestID = requestID
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection,
                  let tableView = notification.object as? NSTableView
            else { return }

            let selectedPaths = Set(tableView.selectedRowIndexes.compactMap { index in
                rows.indices.contains(index) ? rows[index].id : nil
            })
            if parent.selection != selectedPaths {
                parent.selection = selectedPaths
            }
        }

        private func makeSideCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let name = NSTextField(labelWithString: "")
            name.tag = 1
            name.lineBreakMode = .byTruncatingMiddle
            name.font = .systemFont(ofSize: NSFont.systemFontSize)

            let parent = NSTextField(labelWithString: "")
            parent.tag = 2
            parent.lineBreakMode = .byTruncatingMiddle
            parent.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            parent.textColor = .secondaryLabelColor

            let stack = NSStackView(views: [name, parent])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func configureSideCell(
            _ cell: NSView,
            entry: ComparisonEntry?,
            row: ComparisonRow,
            side: ComparisonColumn
        ) {
            let name = cell.viewWithTag(1) as? NSTextField
            let parent = cell.viewWithTag(2) as? NSTextField
            name?.stringValue = entry?.url.lastPathComponent
                ?? (side == .left ? "Missing on left" : "Missing on right")
            parent?.stringValue = row.relativePath.parentComponents.isEmpty
                ? "Top level"
                : row.relativePath.parentComponents.joined(separator: "/")
            name?.textColor = entry == nil ? .tertiaryLabelColor : .labelColor
            cell.setAccessibilityElement(true)
            cell.setAccessibilityIdentifier(
                "comparison.\(side.rawValue).\(row.id.string)"
            )
            cell.setAccessibilityLabel(side == .left ? "Left item" : "Right item")
            cell.setAccessibilityValue(
                entry.map { "\($0.url.lastPathComponent), \(row.relativePath.string)" }
                    ?? (side == .left ? "Missing on left" : "Missing on right")
            )
        }

        private func makeStatusCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.tag = 3
            imageView.imageScaling = .scaleProportionallyDown
            imageView.contentTintColor = .secondaryLabelColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16)
            ])

            let label = NSTextField(labelWithString: "")
            label.tag = 4
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .labelColor

            let stack = NSStackView(views: [imageView, label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                stack.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func configureStatusCell(_ cell: NSView, row: ComparisonRow) {
            let presentation = ComparisonAccessibility.status(row)
            let imageView = cell.viewWithTag(3) as? NSImageView
            let label = cell.viewWithTag(4) as? NSTextField
            imageView?.image = NSImage(
                systemSymbolName: presentation.symbolName,
                accessibilityDescription: presentation.label
            )
            label?.stringValue = presentation.label
            cell.setAccessibilityElement(true)
            cell.setAccessibilityIdentifier("comparison.status.\(row.id.string)")
            cell.setAccessibilityLabel(presentation.label)
            cell.setAccessibilityValue(presentation.value)
        }
    }
}

private enum ComparisonTableUpdate: Equatable {
    case none
    case structural
    case cells([ComparisonCellReload])
}

private struct ComparisonCellReload: Equatable {
    let rows: IndexSet
    let columns: IndexSet
}
