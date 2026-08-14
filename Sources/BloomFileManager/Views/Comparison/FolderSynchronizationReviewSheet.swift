import SwiftUI

struct FolderSynchronizationReviewSheetPresentation: Equatable, Sendable {
    let title: String
    let statusText: String
    let sourceBasename: String
    let destinationBasename: String
    let copyCountLabel: String
    let replaceCountLabel: String
    let trashCountLabel: String
    let skipCountLabel: String
    let estimatedSizeLabel: String?
    let representativePaths: [String]
    let destructiveWarning: String
    let isConfirmEnabled: Bool
    let accessibilityLabel: String

    init(
        state: FolderSynchronizationReviewPresentation,
        canAdmit: Bool,
        currentGeneration: UUID?
    ) {
        switch state {
        case .idle:
            title = "Synchronize Folders"
            statusText = ""
            sourceBasename = ""
            destinationBasename = ""
            copyCountLabel = "Copy 0"
            replaceCountLabel = "Replace 0"
            trashCountLabel = "Move to Trash 0"
            skipCountLabel = "Skip 0"
            estimatedSizeLabel = nil
            representativePaths = []
            destructiveWarning = ""
            isConfirmEnabled = false
            accessibilityLabel = "Synchronize folders"
        case let .plannerBlocked(blockers):
            title = "Synchronize Folders"
            statusText = blockers.map(\.presentation).joined(separator: "\n")
            sourceBasename = ""
            destinationBasename = ""
            copyCountLabel = "Copy 0"
            replaceCountLabel = "Replace 0"
            trashCountLabel = "Move to Trash 0"
            skipCountLabel = "Skip 0"
            estimatedSizeLabel = nil
            representativePaths = []
            destructiveWarning = ""
            isConfirmEnabled = false
            accessibilityLabel = "Synchronization blocked"
        case let .alreadySynchronized(summary):
            title = Self.title(for: summary.direction)
            statusText = "Already Synchronized"
            sourceBasename = summary.sourceRoot.lastPathComponent
            destinationBasename = summary.destinationRoot.lastPathComponent
            copyCountLabel = "Copy 0"
            replaceCountLabel = "Replace 0"
            trashCountLabel = "Move to Trash 0"
            skipCountLabel = "Skip \(summary.skipCount)"
            estimatedSizeLabel = nil
            representativePaths = []
            destructiveWarning = ""
            isConfirmEnabled = false
            accessibilityLabel = "Already synchronized"
        case let .preparing(direction, _):
            title = Self.title(for: direction)
            statusText = "Preparing the synchronization review…"
            sourceBasename = ""
            destinationBasename = ""
            copyCountLabel = "Copy 0"
            replaceCountLabel = "Replace 0"
            trashCountLabel = "Move to Trash 0"
            skipCountLabel = "Skip 0"
            estimatedSizeLabel = nil
            representativePaths = []
            destructiveWarning = ""
            isConfirmEnabled = false
            accessibilityLabel = "Preparing synchronization review"
        case let .preparationBlocked(blocker):
            title = "Synchronize Folders"
            statusText = blocker.presentation
            sourceBasename = ""
            destinationBasename = ""
            copyCountLabel = "Copy 0"
            replaceCountLabel = "Replace 0"
            trashCountLabel = "Move to Trash 0"
            skipCountLabel = "Skip 0"
            estimatedSizeLabel = nil
            representativePaths = []
            destructiveWarning = ""
            isConfirmEnabled = false
            accessibilityLabel = "Synchronization preparation blocked"
        case let .ready(review):
            let stale = currentGeneration != review.comparisonGeneration
            title = Self.title(for: review.direction)
            statusText = "Review this one-way synchronization before it runs."
            sourceBasename = review.preparedPlan.draft.sourceRoot.lastPathComponent
            destinationBasename = review.preparedPlan.draft.destinationRoot.lastPathComponent
            copyCountLabel = "Copy \(review.summary.copyCount)"
            replaceCountLabel = "Replace \(review.summary.replaceCount)"
            trashCountLabel = "Move to Trash \(review.summary.moveToTrashCount)"
            skipCountLabel = "Skip \(review.summary.skipCount)"
            estimatedSizeLabel = ByteCountFormatter.string(
                fromByteCount: review.summary.estimatedCopyBytes,
                countStyle: .file
            )
            representativePaths = review.representativeRelativePaths.prefix(8).map(\.string)
            destructiveWarning = review.summary.moveToTrashCount == 0
                ? ""
                : "Destination-only items will be moved to Trash. This cannot be undone after it finishes."
            isConfirmEnabled = canAdmit && !stale
            let directionSpoken = review.direction == .leftToRight ? "left to right" : "right to left"
            accessibilityLabel = "Synchronize \(directionSpoken), \(review.summary.copyCount) copies, "
                + "\(review.summary.replaceCount) replacements, "
                + "\(review.summary.moveToTrashCount) move to Trash, "
                + "\(review.summary.skipCount) skipped"
        }
    }

    var visibleStrings: [String] {
        [title, statusText, sourceBasename, destinationBasename, copyCountLabel, replaceCountLabel,
         trashCountLabel, skipCountLabel, estimatedSizeLabel ?? "", destructiveWarning, accessibilityLabel]
            + representativePaths
    }

    private static func title(for direction: ComparisonDirection) -> String {
        switch direction {
        case .leftToRight: "Synchronize Left to Right"
        case .rightToLeft: "Synchronize Right to Left"
        }
    }
}

struct FolderSynchronizationReviewSheet: View {
    let comparison: ComparisonCoordinator
    let operationController: FileOperationController
    let workspace: WorkspaceState
    let onCancel: () -> Void
    let onConfirm: () -> Bool

    var body: some View {
        let presentation = FolderSynchronizationReviewSheetPresentation(
            state: comparison.folderSynchronizationReview,
            canAdmit: operationController.canAdmitFolderSynchronization,
            currentGeneration: comparison.session?.generation
        )
        VStack(alignment: .leading, spacing: 16) {
            Text(presentation.title)
                .font(.title2.weight(.semibold))

            if !presentation.statusText.isEmpty {
                Text(presentation.statusText)
                    .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewStatus)
            }

            if !presentation.sourceBasename.isEmpty {
                Text("\(presentation.sourceBasename) → \(presentation.destinationBasename)")
            }

            HStack(spacing: 12) {
                Text(presentation.copyCountLabel)
                    .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewCopyCount)
                Text(presentation.replaceCountLabel)
                    .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewReplaceCount)
                Text(presentation.trashCountLabel)
                    .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewTrashCount)
                Text(presentation.skipCountLabel)
                    .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewSkipCount)
            }

            if let estimatedSizeLabel = presentation.estimatedSizeLabel {
                Text(estimatedSizeLabel)
            }

            if !presentation.destructiveWarning.isEmpty {
                Text(presentation.destructiveWarning)
                    .foregroundStyle(.red)
            }

            if !presentation.representativePaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Items")
                        .font(.headline)
                    ForEach(presentation.representativePaths, id: \.self) { path in
                        Text(path)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewPaths)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewCancel)
                Button("Synchronize") {
                    _ = onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!presentation.isConfirmEnabled)
                .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier(AccessibilityIdentifiers.folderSynchronizationReviewSheet)
    }
}
