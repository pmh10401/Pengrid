import Foundation
import Testing
@testable import BloomFileManager

@Suite struct BatchRenamePresentationTests {
    @Test func rowStatusesUseActionableVoiceOverLabelsWithoutPaths() {
        let source = BatchRenameSource(
            url: URL(filePath: "/private/work/A.txt"),
            identity: FileIdentity(entryIdentifier: "A", resolvedIdentifier: "A"),
            name: "A.txt",
            isDirectory: false,
            isPackage: false
        )
        let cases: [(BatchRenamePreviewStatus, String)] = [
            (.ready, "Ready"),
            (.unchanged, "Unchanged"),
            (.duplicate, "Duplicate new name"),
            (.occupied, "Name already in use"),
            (.invalidName(.containsPathSeparator), "Invalid filename")
        ]

        for (status, expected) in cases {
            let presentation = BatchRenameRowPresentation(entry: BatchRenamePreviewEntry(
                source: source,
                proposedName: "New A.txt",
                status: status
            ))
            #expect(presentation.originalName == "A.txt")
            #expect(presentation.proposedName == "New A.txt")
            #expect(presentation.statusLabel == expected)
            #expect(presentation.accessibilityLabel.contains(presentation.statusHint))
            #expect(!presentation.accessibilityLabel.contains("/private"))
        }
    }

    @Test func sheetSummaryAndSubmitTitlePluralizeSelectedItems() {
        let ready = BatchRenameSheetPresentation(
            itemCount: 3,
            summary: .ready(changedCount: 2, totalCount: 3),
            phase: .ready
        )
        let single = BatchRenameSheetPresentation(
            itemCount: 1,
            summary: .noChanges,
            phase: .ready
        )

        #expect(ready.submitTitle == "Rename 3 Items")
        #expect(ready.summaryLabel == "2 of 3 items will be renamed.")
        #expect(single.submitTitle == "Rename 1 Item")
    }

    @Test func invalidRulesRouteFocusToTheirActionableField() {
        #expect(BatchRenameFocusRouting.target(
            for: .findReplace(find: "", replacement: "", caseSensitive: true),
            summary: .invalid(count: 2, message: "Enter text to find.")
        ) == .findText)
        #expect(BatchRenameFocusRouting.target(
            for: .sequence(baseName: "", start: -1, digits: 0),
            summary: .invalid(count: 2, message: "Enter a valid sequence name and number.")
        ) == .sequenceBase)
        #expect(BatchRenameFocusRouting.target(
            for: .prefix("bad/"),
            summary: .invalid(count: 2, message: "2 names are invalid.")
        ) == .prefix)
    }

    @Test func accessibilityIdentifiersAndKeyboardMotionContractsAreStable() throws {
        #expect(AccessibilityIdentifiers.batchRenameSheet == "batchRename.sheet")
        #expect(AccessibilityIdentifiers.batchRenameRule == "batchRename.rule")
        #expect(AccessibilityIdentifiers.batchRenamePreview == "batchRename.preview")
        #expect(AccessibilityIdentifiers.batchRenameValidation == "batchRename.validation")
        #expect(AccessibilityIdentifiers.batchRenameSubmit == "batchRename.submit")
        #expect(AccessibilityIdentifiers.batchRenameCancel == "batchRename.cancel")
        #expect(AccessibilityIdentifiers.fileTableBatchRename == "fileTable.batchRename")

        let implementation = try source(named: "Views/BatchRename/BatchRenameSheet.swift")
        #expect(implementation.contains(".keyboardShortcut(.defaultAction)"))
        #expect(implementation.contains(".keyboardShortcut(.cancelAction)"))
        #expect(implementation.contains("accessibilityReduceMotion"))
        #expect(implementation.contains("transaction.animation = nil"))
    }

    @Test func pendingPasswordWaitsWhileBatchRenameIsPresented() {
        let request = makeBatchRenamePasswordRequest()
        let state = WorkspaceModalPresentationState()

        #expect(state.passwordRequestToPresent(
            pending: request,
            conflictPresented: false,
            searchPresented: false,
            batchRenamePresented: true
        ) == nil)
        #expect(state.passwordRequestToPresent(
            pending: request,
            conflictPresented: false,
            searchPresented: false,
            batchRenamePresented: false
        ) == request)
    }

    @Test @MainActor func localAndUnregisteredCloudStorageCapabilitiesFailAppropriately() {
        let store = CloudLocationsStore(
            storageURL: URL(filePath: "/tmp/pengrid-batch-rename-\(UUID().uuidString).json"),
            localFileOperationsSupported: { !$0.path.contains("ReadOnly") }
        )
        let local = URL(filePath: "/Users/example/Documents")
        let readOnly = URL(filePath: "/Users/example/ReadOnly")
        let unknownCloud = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage/UnknownProvider/Documents")

        #expect(store.batchRenameCapability(for: local) == .writable)
        #expect(store.batchRenameCapability(for: readOnly) == .readOnly)
        #expect(store.batchRenameCapability(for: unknownCloud) == .unknown)
    }

    @Test func appWiresOneSharedBatchRenameModelIntoWorkspaceAndCommands() throws {
        let implementation = try source(named: "App/BloomFileManagerApp.swift")

        #expect(implementation.components(separatedBy: "BatchRenameModel(").count - 1 == 1)
        #expect(implementation.contains("_batchRename = State(initialValue:"))
        #expect(implementation.components(separatedBy: "batchRename: batchRename").count - 1 == 2)
    }

    private func source(named relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root
                .appending(path: "Sources/BloomFileManager", directoryHint: .isDirectory)
                .appending(path: relativePath),
            encoding: .utf8
        )
    }
}

private func makeBatchRenamePasswordRequest() -> ArchivePasswordRequest {
    ArchivePasswordRequest(
        id: UUID(),
        purpose: .createAES256,
        archiveBasename: "Archive.zip",
        previousAttemptFailed: false
    )
}
