import Foundation
import Testing
@testable import BloomFileManager

@Test func compressionRequiresACompleteSelectionAndNoTextEdit() {
    let item = commandPolicyItem(named: "Report.pdf")

    #expect(WorkspaceCommandPolicy(
        selectionCount: 0,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: []
    ).canCompress == false)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [item]
    ).canCompress)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: []
    ).canCompress == false)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: true,
        pasteboardHasFileURLs: false,
        selectedItems: [item]
    ).canCompress)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [item],
        isTextEditing: true
    ).canCompress == false)
}

@Test func protectedCompressionUsesExactlyTheOrdinaryCompressionPolicy() {
    let item = commandPolicyItem(named: "Report.pdf")

    for policy in [
        WorkspaceCommandPolicy(
            selectionCount: 0,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: []
        ),
        WorkspaceCommandPolicy(
            selectionCount: 1,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: [item]
        ),
        WorkspaceCommandPolicy(
            selectionCount: 1,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: [item],
            isTextEditing: true
        ),
        WorkspaceCommandPolicy(
            selectionCount: 1,
            isOperationRunning: true,
            pasteboardHasFileURLs: false,
            selectedItems: [item]
        )
    ] {
        #expect(policy.canCompressProtectedZIP == policy.canCompress)
    }
}

@Test func extractionRequiresEverySelectedItemToBeARegularZIPAndNoActiveEdit() {
    let firstZIP = commandPolicyItem(named: "First.zip")
    let secondZIP = commandPolicyItem(named: "SECOND.ZIP")
    let textFile = commandPolicyItem(named: "Notes.txt")
    let zipDirectory = commandPolicyItem(named: "Folder.zip", isDirectory: true)

    #expect(WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [firstZIP, secondZIP]
    ).canExtract)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [firstZIP, textFile]
    ).canExtract == false)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [zipDirectory]
    ).canExtract == false)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [firstZIP]
    ).canExtract == false)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: true,
        pasteboardHasFileURLs: false,
        selectedItems: [firstZIP, secondZIP]
    ).canExtract)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [firstZIP, secondZIP],
        isTextEditing: true
    ).canExtract == false)
}

@Test func queueableMutationsRemainAvailableWhileRenameStaysExclusive() {
    let item = commandPolicyItem(named: "Report.pdf")
    let policy = WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: true,
        pasteboardHasFileURLs: true,
        selectedItems: [item]
    )

    #expect(policy.canCreateFolder)
    #expect(policy.canPaste)
    #expect(policy.canTrash)
    #expect(policy.canCompress)
    #expect(!policy.canRename)
}

@Test func batchRenameRequiresTwoCompleteItemsAndNoOperationOrTextEdit() {
    let first = commandPolicyItem(named: "A.txt")
    let second = commandPolicyItem(named: "B.txt")

    #expect(WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [first, second]
    ).canBatchRename)
    #expect(!WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [first]
    ).canBatchRename)
    #expect(!WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: true,
        pasteboardHasFileURLs: false,
        selectedItems: [first, second]
    ).canBatchRename)
    #expect(!WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [first, second],
        isTextEditing: true
    ).canBatchRename)
    #expect(!WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [first]
    ).canBatchRename)
}

@Test func smartSearchShortcutDoesNotReplacePaneFilterShortcut() throws {
    let commands = try commandSource()
    #expect(commands.contains("Button(\"Filter Files\")"))
    #expect(commands.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
    #expect(commands.contains("Button(\"Smart Search…\")"))
    #expect(commands.contains(".keyboardShortcut(\"f\", modifiers: [.command, .shift])"))
}

@Test func protectedCompressionCommandIsImmediatelyAfterOrdinaryZIPAndNeverInTARChoices() throws {
    let commands = try commandSource()
    let ordinary = try #require(commands.range(of: "Button(\"Compress to ZIP\")"))
    let protected = try #require(commands.range(of: "Button(\"Compress as Password-Protected ZIP…\")"))
    #expect(protected.lowerBound > ordinary.upperBound)

    let protectedProjection = String(commands[protected.lowerBound...])
    #expect(commands.contains("format: .zip"))
    #expect(commands.contains("protection: .aes256"))
    #expect(protectedProjection.contains(
        "AccessibilityIdentifiers.workspaceCompressProtectedZIP"
    ))
    #expect(!protectedProjection.prefix(through: protectedProjection.firstIndex(of: "}") ?? protectedProjection.endIndex).contains("ArchiveFormat.allCases"))
}

@Test func appKitContextMenuUsesTheProtectedControllerRouteAndSharedEnablement() throws {
    let table = try fileTableSource()
    let ordinary = try #require(table.range(of: "\"Compress to ZIP\""))
    let protected = try #require(table.range(of: "\"Compress as Password-Protected ZIP…\""))
    #expect(protected.lowerBound > ordinary.upperBound)
    #expect(table.contains("action: #selector(compressProtectedFromMenu)"))
    #expect(table.contains("onCompressProtected"))
    #expect(table.contains("AccessibilityIdentifiers.fileTableCompressProtectedZIP"))

    let pane = try filePaneSource()
    #expect(pane.contains("onCompressProtected: compressProtectedSelection"))
    #expect(pane.contains("WorkspaceArchiveCommandActions.compressProtectedZIP"))
}

@Test func batchRenameUsesOneMenuAndContextRoute() throws {
    let commands = try commandSource()
    #expect(commands.contains("Button(\"Batch Rename…\")"))
    #expect(commands.contains("WorkspaceBatchRenameCommandActions.showBatchRename"))
    #expect(commands.contains(".disabled(!policy.canBatchRename)"))

    let table = try fileTableSource()
    #expect(table.contains("\"Batch Rename…\""))
    #expect(table.contains("action: #selector(batchRenameFromMenu)"))
    #expect(table.contains("enabled: policy.canBatchRename"))
    #expect(table.contains("onRequestBatchRename"))
}

@Test func extractionAcceptsEverySupportedRegularArchiveSuffix() {
    let suffixes = [
        "zip", "tar", "tar.gz", "tgz", "tar.bz2", "tbz", "tbz2", "tar.xz", "txz"
    ]

    for suffix in suffixes {
        let archive = commandPolicyItem(named: "Backup.\(suffix)")
        #expect(WorkspaceCommandPolicy(
            selectionCount: 1,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: [archive]
        ).canExtract, "Expected .\(suffix) to be extractable")
    }
}

@Test func textEditingKeepsSpaceAndEscapePriority() {
    let folder = commandPolicyItem(named: "folder", isDirectory: true)
    let policy = WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [folder],
        isTextEditing: true
    )

    #expect(!policy.canQuickLook)
    #expect(!policy.canClosePreview)
}

private func commandPolicyItem(
    named name: String,
    isDirectory: Bool = false
) -> FileItem {
    FileItem(
        url: URL(filePath: "/selection").appending(
            path: name,
            directoryHint: isDirectory ? .isDirectory : .notDirectory
        ),
        name: name,
        isDirectory: isDirectory,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: isDirectory ? "Folder" : "Document"
    )
}

private func commandSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot.appending(path: "Sources/BloomFileManager/Support/WorkspaceCommands.swift"),
        encoding: .utf8
    )
}

private func fileTableSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot.appending(path: "Sources/BloomFileManager/Views/AppKit/FileTableView.swift"),
        encoding: .utf8
    )
}

private func filePaneSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot.appending(path: "Sources/BloomFileManager/Views/FilePaneView.swift"),
        encoding: .utf8
    )
}
