import Foundation
import Testing
@testable import BloomFileManager

@Test func compressionRequiresACompleteSelectionAndNoActiveMutationOrTextEdit() {
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
    ).canCompress == false)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [item],
        isTextEditing: true
    ).canCompress == false)
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
    ).canExtract == false)
    #expect(WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [firstZIP, secondZIP],
        isTextEditing: true
    ).canExtract == false)
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
