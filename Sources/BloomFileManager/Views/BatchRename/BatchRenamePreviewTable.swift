import SwiftUI

struct BatchRenameRowPresentation: Equatable, Sendable {
    let originalName: String
    let proposedName: String
    let statusLabel: String
    let statusHint: String
    let accessibilityLabel: String

    init(entry: BatchRenamePreviewEntry) {
        originalName = Self.safeName(entry.source.name)
        proposedName = Self.safeName(entry.proposedName)
        (statusLabel, statusHint) = switch entry.status {
        case .ready:
            ("Ready", "This item will be renamed.")
        case .unchanged:
            ("Unchanged", "The rule does not change this item.")
        case .duplicate:
            ("Duplicate new name", "Choose a rule that gives every item a unique name.")
        case .occupied:
            ("Name already in use", "Another item in this folder already uses this name.")
        case .invalidName:
            ("Invalid filename", "Remove invalid characters or choose another rule.")
        }
        accessibilityLabel = "\(originalName), new name \(proposedName), \(statusLabel). \(statusHint)"
    }

    private static func safeName(_ value: String) -> String {
        let value = value.components(separatedBy: .newlines).joined(separator: " ")
        return value.isEmpty ? "Item" : value
    }
}

extension BatchRenamePreviewEntry: Identifiable {
    var id: URL { source.url }
}

struct BatchRenamePreviewTable: View {
    let entries: [BatchRenamePreviewEntry]

    var body: some View {
        Table(entries) {
            TableColumn("Original Name") { entry in
                let row = BatchRenameRowPresentation(entry: entry)
                Text(row.originalName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(row.accessibilityLabel)
            }
            .width(min: 140, ideal: 220)

            TableColumn("New Name") { entry in
                Text(BatchRenameRowPresentation(entry: entry).proposedName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Status") { entry in
                let row = BatchRenameRowPresentation(entry: entry)
                Text(row.statusLabel)
                    .foregroundStyle(entry.status == .ready ? .secondary : .primary)
                    .help(row.statusHint)
                    .accessibilityHint(row.statusHint)
            }
            .width(min: 130, ideal: 170)
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.batchRenamePreview)
        .accessibilityLabel("Rename preview, \(entries.count) items")
    }
}
