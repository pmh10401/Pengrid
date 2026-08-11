import Foundation
import Testing
@testable import BloomFileManager

@Test func transferActionsRemainEnabledWhileAnOrdinaryOperationRuns() {
    let policy = fileContextPolicy(
        selectedItems: [fileContextItem(named: "report.txt")],
        workspacePolicy: fileContextWorkspacePolicy(selectionCount: 1, isOperationRunning: true),
        isExclusiveOperationActive: false
    )

    #expect(policy.copyToOtherPane.isVisible)
    #expect(policy.copyToOtherPane.isEnabled)
    #expect(policy.moveToOtherPane.isEnabled)
}

@Test func exclusiveOperationKeepsQueueableTransferVisibleButDisabledWithoutAPath() {
    let policy = fileContextPolicy(
        selectedItems: [fileContextItem(named: "report.txt")],
        isExclusiveOperationActive: true
    )

    #expect(policy.copyToOtherPane.isVisible)
    #expect(!policy.copyToOtherPane.isEnabled)
    #expect(policy.copyToOtherPane.disabledReason?.isEmpty == false)
    #expect(!policy.copyToOtherPane.disabledReason!.contains("report.txt"))
}

@Test func openWithIsHiddenForAnOrdinaryDirectoryAndVisibleForASymbolicLink() {
    let directory = fileContextItem(named: "Folder", isDirectory: true)
    let symbolicLink = fileContextItem(named: "Folder Link", isDirectory: true, isSymbolicLink: true)

    #expect(!fileContextPolicy(selectedItems: [directory]).openWith.isVisible)
    #expect(fileContextPolicy(selectedItems: [symbolicLink]).openWith.isVisible)
    #expect(fileContextPolicy(selectedItems: [symbolicLink]).openWith.isEnabled)
}

@Test func showInFinderAndCopyPathStayEnabledWhileAnOrdinaryOperationRuns() {
    let policy = fileContextPolicy(
        selectedItems: [fileContextItem(named: "report.txt")],
        workspacePolicy: fileContextWorkspacePolicy(selectionCount: 1, isOperationRunning: true)
    )

    #expect(policy.showInFinder.isEnabled)
    #expect(policy.copyPath.isEnabled)
}

@Test func siblingMutationsRequireACompleteWritableSelection() {
    let sourceDirectory = URL(filePath: "/workspace/source", directoryHint: .isDirectory)
    let otherDirectory = URL(filePath: "/workspace/other", directoryHint: .isDirectory)
    let policy = fileContextPolicy(
        selectedItems: [fileContextItem(named: "one.txt", in: sourceDirectory)],
        sourceDirectory: sourceDirectory,
        workspacePolicy: fileContextWorkspacePolicy(selectionCount: 2),
        sourceCapability: .writable
    )
    let mixedParent = fileContextPolicy(
        selectedItems: [
            fileContextItem(named: "one.txt", in: sourceDirectory),
            fileContextItem(named: "two.txt", in: otherDirectory)
        ],
        sourceDirectory: sourceDirectory
    )

    #expect(policy.duplicate.isVisible)
    #expect(!policy.duplicate.isEnabled)
    #expect(!mixedParent.duplicate.isEnabled)
    #expect(!mixedParent.encloseSelection.isEnabled)
}

@Test func transfersAreDisabledWhenStandardizedDirectoriesMatch() {
    let policy = fileContextPolicy(
        selectedItems: [fileContextItem(named: "report.txt")],
        sourceDirectory: URL(filePath: "/workspace/source/./", directoryHint: .isDirectory),
        oppositeDirectory: URL(filePath: "/workspace/source/../source", directoryHint: .isDirectory)
    )

    #expect(policy.copyToOtherPane.isVisible)
    #expect(!policy.copyToOtherPane.isEnabled)
}

@Test func emptySelectionHidesEveryContextAction() {
    let policy = fileContextPolicy(selectedItems: [])

    #expect([
        policy.quickLook,
        policy.openWith,
        policy.openInOtherPane,
        policy.copyToOtherPane,
        policy.moveToOtherPane,
        policy.showInFinder,
        policy.copyPath,
        policy.duplicate,
        policy.encloseSelection
    ].allSatisfy { !$0.isVisible })
}

@Test func openWithIsEnabledForOnePackage() {
    let package = fileContextItem(named: "Example.app", isDirectory: true, isPackage: true)

    let availability = fileContextPolicy(selectedItems: [package]).openWith

    #expect(availability.isVisible)
    #expect(availability.isEnabled)
}

@Test func textEditingDisablesEveryVisibleContextAction() {
    let policy = fileContextPolicy(
        selectedItems: [fileContextItem(named: "one.txt"), fileContextItem(named: "two.txt")],
        workspacePolicy: fileContextWorkspacePolicy(selectionCount: 2, isTextEditing: true)
    )
    let visibleActions = [
        policy.quickLook,
        policy.copyToOtherPane,
        policy.moveToOtherPane,
        policy.showInFinder,
        policy.copyPath,
        policy.duplicate,
        policy.encloseSelection
    ]

    #expect(visibleActions.allSatisfy { $0.isVisible })
    #expect(visibleActions.allSatisfy { !$0.isEnabled && $0.disabledReason?.isEmpty == false })
}

@Test func nonwritableOppositeDisablesCopyAndMove() {
    for capability in [LocalFileOperationCapability.readOnly, .unknown] {
        let policy = fileContextPolicy(
            selectedItems: [fileContextItem(named: "report.txt")],
            oppositeCapability: capability
        )

        #expect(policy.copyToOtherPane.isVisible)
        #expect(!policy.copyToOtherPane.isEnabled)
        #expect(!policy.moveToOtherPane.isEnabled)
    }
}

@Test func nonwritableSourceDisablesSourceMutationsButNotCopy() {
    for capability in [LocalFileOperationCapability.readOnly, .unknown] {
        let policy = fileContextPolicy(
            selectedItems: [fileContextItem(named: "one.txt"), fileContextItem(named: "two.txt")],
            workspacePolicy: fileContextWorkspacePolicy(selectionCount: 2),
            sourceCapability: capability
        )

        #expect(policy.copyToOtherPane.isEnabled)
        #expect(!policy.moveToOtherPane.isEnabled)
        #expect(!policy.duplicate.isEnabled)
        #expect(!policy.encloseSelection.isEnabled)
    }
}

@Test func encloseSelectionRequiresTwoCompleteSiblings() {
    let oneItem = fileContextPolicy(selectedItems: [fileContextItem(named: "one.txt")])
    let twoItems = fileContextPolicy(
        selectedItems: [fileContextItem(named: "one.txt"), fileContextItem(named: "two.txt")],
        workspacePolicy: fileContextWorkspacePolicy(selectionCount: 2)
    )

    #expect(!oneItem.encloseSelection.isVisible)
    #expect(twoItems.encloseSelection.isVisible)
    #expect(twoItems.encloseSelection.isEnabled)
}

@Test func duplicateRemainsQueueableDuringOrdinaryOperationsButNotExclusiveOperations() {
    let ordinary = fileContextPolicy(
        selectedItems: [fileContextItem(named: "report.txt")],
        workspacePolicy: fileContextWorkspacePolicy(selectionCount: 1, isOperationRunning: true)
    )
    let exclusive = fileContextPolicy(
        selectedItems: [fileContextItem(named: "report.txt")],
        isExclusiveOperationActive: true
    )

    #expect(ordinary.duplicate.isEnabled)
    #expect(exclusive.duplicate.isVisible)
    #expect(!exclusive.duplicate.isEnabled)
}

@Test func openInOtherPaneRequiresOneCompleteSelectionAndAnOppositeDirectory() {
    let noOppositeDirectory = fileContextPolicy(
        selectedItems: [fileContextItem(named: "report.txt")],
        oppositeDirectory: nil
    )
    let incompleteSelection = fileContextPolicy(
        selectedItems: [],
        workspacePolicy: fileContextWorkspacePolicy(selectionCount: 1)
    )
    let completeSelection = fileContextPolicy(selectedItems: [fileContextItem(named: "report.txt")])

    #expect(!noOppositeDirectory.openInOtherPane.isVisible)
    #expect(incompleteSelection.openInOtherPane.isVisible)
    #expect(!incompleteSelection.openInOtherPane.isEnabled)
    #expect(completeSelection.openInOtherPane.isEnabled)
}

private func fileContextPolicy(
    selectedItems: [FileItem],
    sourceDirectory: URL = URL(filePath: "/workspace/source", directoryHint: .isDirectory),
    oppositeDirectory: URL? = URL(filePath: "/workspace/opposite", directoryHint: .isDirectory),
    workspacePolicy: WorkspaceCommandPolicy? = nil,
    sourceCapability: LocalFileOperationCapability = .writable,
    oppositeCapability: LocalFileOperationCapability = .writable,
    isExclusiveOperationActive: Bool = false
) -> FileContextMenuPolicy {
    let policy = workspacePolicy ?? fileContextWorkspacePolicy(selectionCount: selectedItems.count)
    return FileContextMenuPolicy(.init(
        workspaceCommandPolicy: policy,
        selectedItems: selectedItems,
        sourceDirectory: sourceDirectory,
        oppositeDirectory: oppositeDirectory,
        sourceCapability: sourceCapability,
        oppositeCapability: oppositeCapability,
        isExclusiveOperationActive: isExclusiveOperationActive
    ))
}

private func fileContextWorkspacePolicy(
    selectionCount: Int,
    isOperationRunning: Bool = false,
    isTextEditing: Bool = false
) -> WorkspaceCommandPolicy {
    WorkspaceCommandPolicy(
        selectionCount: selectionCount,
        isOperationRunning: isOperationRunning,
        pasteboardHasFileURLs: false,
        selectedItems: [],
        isTextEditing: isTextEditing
    )
}

private func fileContextItem(
    named name: String,
    in directory: URL = URL(filePath: "/workspace/source", directoryHint: .isDirectory),
    isDirectory: Bool = false,
    isPackage: Bool = false,
    isSymbolicLink: Bool = false
) -> FileItem {
    FileItem(
        url: directory.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
        name: name,
        isDirectory: isDirectory,
        isPackage: isPackage,
        isSymbolicLink: isSymbolicLink,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: isDirectory ? "Folder" : "Document"
    )
}
