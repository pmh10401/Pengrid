import SwiftUI

struct StorageCleanupReviewSheet: View {
    let review: StorageCleanupReview
    let cleanupController: StorageCleanupController
    let storage: StorageAnalysisStore
    let operationController: FileOperationController
    let workspace: WorkspaceState
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirming = false
    @State private var confirmationFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review Files Marked for Trash")
                    .font(.title2.weight(.semibold))
                Text(StorageInspectorPresentation.cleanupSummary(review))
                    .foregroundStyle(.secondary)
            }

            Label(
                "Only the files explicitly listed under “Move to Trash” will be affected. "
                    + "Every required keep copy remains in place.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(
                "\(AccessibilityIdentifiers.storageInspectorReview).warning"
            )

            List {
                ForEach(review.groups, id: \.groupID) { group in
                    Section {
                        reviewPath(
                            label: "Required keep",
                            path: group.keep.relativePath,
                            symbol: "checkmark.shield",
                            identifier: "keep"
                        )

                        ForEach(group.trash, id: \.id) { entry in
                            reviewPath(
                                label: "Move to Trash",
                                path: entry.relativePath,
                                symbol: "trash",
                                identifier: "trash"
                            )
                        }
                    } header: {
                        Text("Duplicate group")
                    }
                }
            }
            .listStyle(.inset)

            if confirmationFailed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleanup did not start because the review changed or no file remained eligible.")
                    ForEach(cleanupController.excludedIDs.sorted(), id: \.self) { id in
                        Text("Not eligible: \(id.string)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "\(AccessibilityIdentifiers.storageInspectorReview).confirmationWarning"
                )
            }

            if let result = cleanupController.lastResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleanup Result")
                        .font(.headline)
                    Text(StorageInspectorPresentation.cleanupResultSummary(result))
                        .foregroundStyle(.secondary)
                    ForEach(Array(result.outcomes.enumerated()), id: \.offset) { _, outcome in
                        Text(cleanupOutcomeDescription(outcome))
                        .font(.callout)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(
                    "\(AccessibilityIdentifiers.storageInspectorReview).result"
                )
            }

            HStack {
                Spacer()

                Button(cleanupController.lastResult == nil ? "Cancel" : "Close", role: .cancel) {
                    cleanupController.cancelReview()
                    onDismiss()
                }
                .disabled(isConfirming || cleanupController.isRunning)
                .accessibilityIdentifier(
                    "\(AccessibilityIdentifiers.storageInspectorReview).cancel"
                )

                Button("Move Explicitly Marked Files to Trash", role: .destructive) {
                    confirm()
                }
                .disabled(
                    isConfirming
                        || cleanupController.isRunning
                        || cleanupController.lastResult != nil
                )
                .accessibilityIdentifier(
                    "\(AccessibilityIdentifiers.storageInspectorReview).confirm"
                )
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 500)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage cleanup review")
        .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorReview)
    }

    @ViewBuilder
    private func reviewPath(
        label: String,
        path: StorageRelativePath,
        symbol: String,
        identifier: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(path.string)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(path.string)")
        .accessibilityIdentifier(
            "\(AccessibilityIdentifiers.storageInspectorReview).\(identifier).\(path.string)"
        )
    }

    private func confirm() {
        isConfirming = true
        confirmationFailed = false
        Task {
            let started = await cleanupController.confirm(
                currentGeneration: storage.currentGeneration,
                currentAdmission: storage.currentAdmission,
                groups: storage.duplicateGroups,
                operationController: operationController,
                workspace: workspace,
                validateAdmission: { admission in
                    await storage.revalidateCleanupAdmission(admission)
                }
            ) { result in
                storage.applyCleanupResult(result)
            }
            isConfirming = false
            if !started {
                confirmationFailed = true
            }
        }
    }

    private func reviewedPath(for outcome: FileOperationItemOutcome) -> String {
        let source: URL = switch outcome {
        case let .succeeded(source, _),
             let .recoveryNeeded(source),
             let .skipped(source),
             let .cancelled(source),
             let .failed(source, _):
            source
        }
        return review.groups.flatMap(\.trash).first {
            $0.url.standardizedFileURL == source.standardizedFileURL
        }?.relativePath.string ?? "Reviewed item"
    }

    private func cleanupOutcomeDescription(
        _ outcome: FileOperationItemOutcome
    ) -> String {
        let title = StorageInspectorPresentation.cleanupOutcomeTitle(outcome)
        if let guidance = StorageInspectorPresentation.cleanupOutcomeGuidance(outcome) {
            return "\(title): \(guidance)"
        }
        return "\(title): \(reviewedPath(for: outcome))"
    }
}
