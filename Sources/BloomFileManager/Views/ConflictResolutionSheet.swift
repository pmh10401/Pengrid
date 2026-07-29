import SwiftUI

struct IdentifiedFileConflict: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let source: URL
        let proposedDestination: URL
    }

    let conflict: FileConflict

    init(_ conflict: FileConflict) {
        self.conflict = conflict
    }

    var id: ID {
        ID(
            source: conflict.source,
            proposedDestination: conflict.proposedDestination
        )
    }
}

struct ConflictResolutionSheet: View {
    let conflict: FileConflict
    let onResolve: (ConflictDecision, Bool) -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("An item with this name already exists", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                Text(conflict.source.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(conflict.proposedDestination.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)

            HStack {
                Button("Cancel", role: .cancel) {
                    resolve(.cancel)
                }
                Spacer()
                Button("Skip") {
                    resolve(.skip)
                }
                Button("Keep Both") {
                    resolve(.keepBoth)
                }
                Button("Replace", role: .destructive) {
                    resolve(.replace)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File conflict for \(conflict.source.lastPathComponent)")
        .accessibilityIdentifier(AccessibilityIdentifiers.conflictSheet)
    }

    private func resolve(_ decision: ConflictDecision) {
        onResolve(decision, applyToAll)
    }
}
