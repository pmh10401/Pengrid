import SwiftUI

@MainActor
enum StorageInspectorItemActions {
    static func quickLook(
        entry: StorageEntry,
        controller: QuickLookController,
        materializer: any CloudMaterializing,
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator
    ) async {
        let lease: CloudLocationScopedAccessLease?
        do {
            lease = try accessCoordinator.acquireAccess(for: entry.url)
        } catch {
            return
        }
        defer { lease?.finish() }

        let reviewedIdentity = entry.fingerprint.identity
        guard !Task.isCancelled,
              let currentIdentity = try? await fileSystem.identity(of: entry.url),
              currentIdentity.refersToSameItem(as: reviewedIdentity)
        else {
            return
        }
        let request = IdentifiedFileRequest(
            url: entry.url,
            identity: currentIdentity
        )
        await controller.prepareAndPresent(
            requests: [request],
            materializer: materializer
        )
    }
}

enum StorageInspectorDecisionPolicy {
    static func canMutate(
        phase: StorageAnalysisPhase,
        isOperationRunning: Bool,
        hasPendingReview: Bool,
        cleanupAuthorized: Bool
    ) -> Bool {
        phase == .complete
            && !isOperationRunning
            && !hasPendingReview
            && cleanupAuthorized
    }
}

struct StorageInspectorDetailView: View {
    let entry: StorageEntry
    let row: StorageResultRow
    let storage: StorageAnalysisStore
    let quickLookController: QuickLookController
    let materializer: any CloudMaterializing
    let fileSystem: any FileSystemAccess
    let workspaceActions: any CloudLocationWorkspaceActions
    let cleanupController: StorageCleanupController
    let operationController: FileOperationController
    let accessCoordinator: CloudLocationScopedAccessCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(row.relativeParent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                detailRow("Size", row.sizeText)
                detailRow("Modified", row.modifiedText)
                detailRow("Category", row.categoryText)
                detailRow("Kind", entry.typeDescription)
                detailRow("Verification", row.verificationText)
            }

            HStack {
                Button("Quick Look") {
                    Task {
                        await StorageInspectorItemActions.quickLook(
                            entry: entry,
                            controller: quickLookController,
                            materializer: materializer,
                            fileSystem: fileSystem,
                            accessCoordinator: accessCoordinator
                        )
                    }
                }
                .accessibilityIdentifier(
                    "\(AccessibilityIdentifiers.storageInspectorDetail).quickLook"
                )

                Button("Reveal in Finder") {
                    workspaceActions.revealInFinder(entry.url)
                }
                .accessibilityIdentifier(
                    "\(AccessibilityIdentifiers.storageInspectorDetail).reveal"
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Duplicate Decision")
                    .font(.headline)

                if let group {
                    Text(group.keepID == entry.id ? "This copy is required to stay." : decisionHelp)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Keep This Copy") {
                            storage.setKeep(entry.id, in: group.id)
                        }
                        .disabled(!canKeep)
                        .accessibilityIdentifier(
                            "\(AccessibilityIdentifiers.storageInspectorDetail).keep"
                        )

                        Button(isTrashMarked ? "Unmark Trash" : "Mark for Trash") {
                            storage.setTrashMarked(
                                !isTrashMarked,
                                id: entry.id,
                                in: group.id
                            )
                        }
                        .disabled(!canToggleTrash)
                        .accessibilityIdentifier(
                            "\(AccessibilityIdentifiers.storageInspectorDetail).trash"
                        )
                    }
                } else {
                    Text("Keep and Trash decisions are available for verified duplicate groups.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "\(AccessibilityIdentifiers.storageInspectorDetail).warning"
                        )

                    HStack {
                        Button("Keep This Copy") {}
                            .disabled(true)
                            .accessibilityIdentifier(
                                "\(AccessibilityIdentifiers.storageInspectorDetail).keep"
                            )
                        Button("Mark for Trash") {}
                            .disabled(true)
                            .accessibilityIdentifier(
                                "\(AccessibilityIdentifiers.storageInspectorDetail).trash"
                            )
                    }
                }
            }

            if storage.phase != .complete {
                Label(
                    "Cleanup decisions are disabled until verification completes.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "\(AccessibilityIdentifiers.storageInspectorDetail).phaseWarning"
                )
            } else if let decisionLockMessage {
                Label(decisionLockMessage, systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "\(AccessibilityIdentifiers.storageInspectorDetail).decisionLockWarning"
                    )
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 260, idealWidth: 310, maxWidth: 360, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage result details for \(row.name)")
        .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorDetail)
    }

    private var group: StorageDuplicateGroup? {
        storage.duplicateGroups.first {
            $0.members.contains(where: { $0.id == entry.id })
        }
    }

    private var isTrashMarked: Bool {
        group?.trashIDs.contains(entry.id) == true
    }

    private var canKeep: Bool {
        canMutateDecisions
            && group?.keepID != entry.id
            && group?.members.contains(where: { $0.id == entry.id }) == true
    }

    private var canToggleTrash: Bool {
        guard canMutateDecisions, let group else { return false }
        return isTrashMarked
            || StorageCleanupSelectionPolicy.canMarkForTrash(entry.id, in: group)
    }

    private var canMutateDecisions: Bool {
        StorageInspectorDecisionPolicy.canMutate(
            phase: storage.phase,
            isOperationRunning: operationController.isRunning,
            hasPendingReview: cleanupController.pendingReview != nil,
            cleanupAuthorized: storage.canPerformCleanupActions
        )
    }

    private var decisionHelp: String {
        isTrashMarked
            ? "This copy is explicitly marked for Trash."
            : "Choose which verified copy to keep or mark for Trash."
    }

    private var decisionLockMessage: String? {
        if operationController.isRunning {
            return "Cleanup decisions are locked while a file operation is running."
        }
        if cleanupController.pendingReview != nil {
            return "Cleanup decisions are locked while the review is open."
        }
        if !storage.canPerformCleanupActions {
            return "Confirm the protected-location cleanup warning before changing decisions."
        }
        return nil
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
