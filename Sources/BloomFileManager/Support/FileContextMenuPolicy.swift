import Foundation

struct FileContextMenuPolicy: Equatable {
    struct Input {
        let workspaceCommandPolicy: WorkspaceCommandPolicy
        let selectedItems: [FileItem]
        let sourceDirectory: URL
        let oppositeDirectory: URL?
        let sourceCapability: LocalFileOperationCapability
        let oppositeCapability: LocalFileOperationCapability
        let isExclusiveOperationActive: Bool

        init(
            workspaceCommandPolicy: WorkspaceCommandPolicy,
            selectedItems: [FileItem],
            sourceDirectory: URL,
            oppositeDirectory: URL?,
            sourceCapability: LocalFileOperationCapability,
            oppositeCapability: LocalFileOperationCapability,
            isExclusiveOperationActive: Bool
        ) {
            self.workspaceCommandPolicy = workspaceCommandPolicy
            self.selectedItems = selectedItems
            self.sourceDirectory = sourceDirectory
            self.oppositeDirectory = oppositeDirectory
            self.sourceCapability = sourceCapability
            self.oppositeCapability = oppositeCapability
            self.isExclusiveOperationActive = isExclusiveOperationActive
        }
    }

    let quickLook: ContextActionAvailability
    let openWith: ContextActionAvailability
    let openInOtherPane: ContextActionAvailability
    let copyToOtherPane: ContextActionAvailability
    let moveToOtherPane: ContextActionAvailability
    let showInFinder: ContextActionAvailability
    let copyPath: ContextActionAvailability
    let duplicate: ContextActionAvailability
    let encloseSelection: ContextActionAvailability

    init(_ input: Input) {
        let selectionCount = input.workspaceCommandPolicy.selectionCount
        let hasSelection = selectionCount > 0
        let completeSelection = input.selectedItems.count == selectionCount
        let sourceDirectory = input.sourceDirectory.standardizedFileURL
        let oppositeDirectory = input.oppositeDirectory?.standardizedFileURL
        let hasOppositeDirectory = oppositeDirectory != nil
        let isTextEditing = input.workspaceCommandPolicy.isTextEditing
        let hasSiblingSelection = completeSelection && input.selectedItems.allSatisfy {
            $0.url.deletingLastPathComponent().standardizedFileURL == sourceDirectory
        }
        let fileURLSelection = completeSelection
            && input.selectedItems.allSatisfy { $0.url.isFileURL }
        let isDifferentDirectory = oppositeDirectory.map { $0 != sourceDirectory } ?? false

        quickLook = Self.availability(
            visible: hasSelection,
            enabled: completeSelection && input.workspaceCommandPolicy.canQuickLook,
            disabledReason: Self.selectionOrEditingReason(
                completeSelection: completeSelection,
                isTextEditing: isTextEditing,
                fallback: "Quick Look is unavailable."
            )
        )

        let isOpenWithItem = completeSelection
            && input.selectedItems.count == 1
            && input.selectedItems[0].isOpenWithEligible
        openWith = Self.availability(
            visible: isOpenWithItem,
            enabled: !isTextEditing,
            disabledReason: "Finish editing first."
        )

        openInOtherPane = Self.availability(
            visible: selectionCount == 1 && hasOppositeDirectory,
            enabled: completeSelection && !isTextEditing,
            disabledReason: Self.selectionOrEditingReason(
                completeSelection: completeSelection,
                isTextEditing: isTextEditing,
                fallback: "Opening in the other pane is unavailable."
            )
        )

        let transferVisible = hasSelection && hasOppositeDirectory
        let commonTransferEnabled = completeSelection
            && !isTextEditing
            && isDifferentDirectory
            && input.oppositeCapability == .writable
            && !input.isExclusiveOperationActive
        let transferReason = Self.transferReason(
            completeSelection: completeSelection,
            isTextEditing: isTextEditing,
            isDifferentDirectory: isDifferentDirectory,
            oppositeCapability: input.oppositeCapability,
            isExclusiveOperationActive: input.isExclusiveOperationActive
        )
        copyToOtherPane = Self.availability(
            visible: transferVisible,
            enabled: commonTransferEnabled,
            disabledReason: transferReason
        )
        moveToOtherPane = Self.availability(
            visible: transferVisible,
            enabled: commonTransferEnabled && input.sourceCapability == .writable,
            disabledReason: commonTransferEnabled && input.sourceCapability != .writable
                ? "The current folder is not writable."
                : transferReason
        )

        let externalVisibility = hasSelection && fileURLSelection
        showInFinder = Self.availability(
            visible: externalVisibility,
            enabled: !isTextEditing,
            disabledReason: "Finish editing first."
        )
        copyPath = Self.availability(
            visible: externalVisibility,
            enabled: !isTextEditing,
            disabledReason: "Finish editing first."
        )

        let siblingMutationEnabled = completeSelection
            && hasSiblingSelection
            && !isTextEditing
            && input.sourceCapability == .writable
            && !input.isExclusiveOperationActive
        let siblingMutationReason = Self.siblingMutationReason(
            completeSelection: completeSelection,
            hasSiblingSelection: hasSiblingSelection,
            isTextEditing: isTextEditing,
            sourceCapability: input.sourceCapability,
            isExclusiveOperationActive: input.isExclusiveOperationActive
        )
        duplicate = Self.availability(
            visible: hasSelection,
            enabled: siblingMutationEnabled,
            disabledReason: siblingMutationReason
        )
        encloseSelection = Self.availability(
            visible: selectionCount >= 2,
            enabled: siblingMutationEnabled,
            disabledReason: siblingMutationReason
        )
    }

    private static func availability(
        visible: Bool,
        enabled: Bool,
        disabledReason: String
    ) -> ContextActionAvailability {
        guard visible else { return .hidden }
        return enabled ? .enabled : .disabled(reason: disabledReason)
    }

    private static func selectionOrEditingReason(
        completeSelection: Bool,
        isTextEditing: Bool,
        fallback: String
    ) -> String {
        if !completeSelection { return "Selection is still loading." }
        if isTextEditing { return "Finish editing first." }
        return fallback
    }

    private static func transferReason(
        completeSelection: Bool,
        isTextEditing: Bool,
        isDifferentDirectory: Bool,
        oppositeCapability: LocalFileOperationCapability,
        isExclusiveOperationActive: Bool
    ) -> String {
        if !completeSelection { return "Selection is still loading." }
        if isTextEditing { return "Finish editing first." }
        if !isDifferentDirectory { return "Choose a different folder." }
        if oppositeCapability != .writable { return "The other folder is not writable." }
        if isExclusiveOperationActive { return "Another exclusive operation is active." }
        return "Transfer is unavailable."
    }

    private static func siblingMutationReason(
        completeSelection: Bool,
        hasSiblingSelection: Bool,
        isTextEditing: Bool,
        sourceCapability: LocalFileOperationCapability,
        isExclusiveOperationActive: Bool
    ) -> String {
        if !completeSelection { return "Selection is still loading." }
        if !hasSiblingSelection { return "Selected items must be in the current folder." }
        if isTextEditing { return "Finish editing first." }
        if sourceCapability != .writable { return "The current folder is not writable." }
        if isExclusiveOperationActive { return "Another exclusive operation is active." }
        return "This action is unavailable."
    }
}

private extension FileItem {
    var isOpenWithEligible: Bool {
        !isDirectory || isPackage || isSymbolicLink
    }
}
