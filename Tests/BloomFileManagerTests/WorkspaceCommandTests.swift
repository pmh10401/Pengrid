import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct WorkspaceCommandTests {
    @Test func newFolderCommandCapturesCreatedIdentityInItsOriginalPaneThroughReturn() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let leftDirectory = root.url.appending(path: "left", directoryHint: .isDirectory)
        let rightDirectory = root.url.appending(path: "right", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: leftDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: rightDirectory, withIntermediateDirectories: false)
        let listing = LiveDirectoryListingService(batchSize: 64)
        let workspace = WorkspaceState(
            leftURL: leftDirectory,
            rightURL: rightDirectory,
            listingService: listing
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess())
        )
        await workspace.loadInitialDirectories()

        #expect(WorkspaceCommandActions.createFolder(
            in: workspace.left,
            workspace: workspace,
            operationController: controller
        ))
        workspace.activate(.right)
        while controller.isRunning { await Task.yield() }

        let created = leftDirectory.appending(path: "New Folder", directoryHint: .isDirectory)
        #expect(workspace.left.selection.contains { $0.standardizedFileURL.path == created.standardizedFileURL.path })
        let request = try #require(workspace.left.pendingRenameTarget)
        #expect(request.identity.entryIdentifier != "uncaptured")
        #expect(workspace.right.renameRequestID == nil)
        let requestID = try #require(workspace.left.renameRequestID)
        workspace.left.consumeInlineRenameRequest(requestID)
        #expect(controller.commitPendingRename(
            in: workspace.left,
            to: "Renamed Folder",
            workspace: workspace
        ))
        while controller.isRunning { await Task.yield() }

        #expect(controller.lastResult?.hasFailures == false)
        #expect(FileManager.default.fileExists(
            atPath: leftDirectory.appending(path: "Renamed Folder").path
        ))
    }

    @Test func newFolderAvoidsNamesHiddenByTheActiveFilter() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let directory = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "New Folder", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let listing = LiveDirectoryListingService(batchSize: 64)
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: directory,
            listingService: listing
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess())
        )
        await workspace.loadInitialDirectories()
        workspace.left.beginFiltering()
        workspace.left.updateFilterQuery("does-not-match")
        #expect(workspace.left.visibleItems.isEmpty)

        #expect(WorkspaceCommandActions.createFolder(
            in: workspace.left,
            workspace: workspace,
            operationController: controller
        ))
        while controller.isRunning { await Task.yield() }

        #expect(controller.lastResult?.hasFailures == false)
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "New Folder 2", directoryHint: .isDirectory).path
        ))
    }

    @Test func commandSelectionUsesOnlyTheActivePane() {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left"),
            rightURL: URL(filePath: "/right"),
            listingService: StubDirectoryListingService(values: [:])
        )
        workspace.left.selection = [URL(filePath: "/left/a")]
        workspace.right.selection = [URL(filePath: "/right/b")]
        workspace.activate(.right)

        #expect(workspace.selectedURLsForCommands == [URL(filePath: "/right/b")])
    }

    @Test func inlineRenameRequestRequiresExactlyOneSelectedItem() {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left"),
            rightURL: URL(filePath: "/right"),
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(workspace.left.requestInlineRename() == false)
        #expect(workspace.left.renameRequestID == nil)

        workspace.left.selection = [URL(filePath: "/left/one")]
        #expect(workspace.left.requestInlineRename())
        let firstRequest = workspace.left.renameRequestID
        #expect(firstRequest != nil)
        #expect(workspace.left.requestInlineRename())
        #expect(workspace.left.renameRequestID != firstRequest)

        workspace.left.selection = [URL(filePath: "/left/one"), URL(filePath: "/left/two")]
        #expect(workspace.left.requestInlineRename() == false)
        #expect(workspace.left.renameRequestID == nil)
        #expect(workspace.left.pendingRenameTarget == nil)
    }

    @Test func trashConfirmationCapturesTheRequestedURLs() {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left"),
            rightURL: URL(filePath: "/right"),
            listingService: StubDirectoryListingService(values: [:])
        )
        let urls = [URL(filePath: "/left/a"), URL(filePath: "/left/b")]

        workspace.requestTrashConfirmation(for: urls)

        #expect(workspace.pendingTrashRequest?.urls == urls)
        workspace.dismissTrashConfirmation()
        #expect(workspace.pendingTrashRequest == nil)
    }

    @Test func createdDirectoryCanBeSelectedForRenameAcrossDirectoryHintDifferences() async {
        let directory = URL(filePath: "/left", directoryHint: .isDirectory)
        let listedURL = URL(filePath: "/left/New Folder")
        let createdURL = URL(filePath: "/left/New Folder", directoryHint: .isDirectory)
        let item = FileItem(
            url: listedURL,
            name: "New Folder",
            isDirectory: true,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Folder"
        )
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: [item]])
        )
        await pane.navigate(to: directory, recordHistory: false)

        #expect(pane.selectForInlineRename(createdURL))
        #expect(pane.selection == [listedURL])
        #expect(pane.renameRequestID != nil)
    }

    @Test func onlyTheMatchingRenameRequestCanBeConsumed() {
        let pane = FilePaneState(
            directory: URL(filePath: "/left"),
            listingService: StubDirectoryListingService(values: [:])
        )
        pane.selection = [URL(filePath: "/left/item")]
        #expect(pane.requestInlineRename())
        let request = try! #require(pane.renameRequestID)

        pane.consumeInlineRenameRequest(UUID())
        #expect(pane.renameRequestID == request)
        pane.consumeInlineRenameRequest(request)
        #expect(pane.renameRequestID == nil)
    }

    @Test func onlyTheMatchingTextEditingSessionCanEnd() {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left"),
            rightURL: URL(filePath: "/right"),
            listingService: StubDirectoryListingService(values: [:])
        )
        let pathSession = WorkspaceTextEditingSession(paneID: .left, kind: .path)
        let inlineSession = WorkspaceTextEditingSession(paneID: .left, kind: .inlineName)

        workspace.beginTextEditing(pathSession)
        #expect(workspace.activeTextEditingSession == pathSession)
        workspace.endTextEditing(inlineSession)
        #expect(workspace.activeTextEditingSession == pathSession)
        workspace.endTextEditing(pathSession)
        #expect(workspace.activeTextEditingSession == nil)
    }

    @Test func pathInlineAndFilterEditorsSuppressReturnDeleteAndImmediateTrashFileActions() {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left"),
            rightURL: URL(filePath: "/right"),
            listingService: StubDirectoryListingService(values: [:])
        )

        for kind in [WorkspaceTextEditingSession.Kind.path, .inlineName, .filter] {
            let session = WorkspaceTextEditingSession(paneID: .left, kind: kind)
            workspace.beginTextEditing(session)
            let policy = WorkspaceCommandPolicy(
                selectionCount: 1,
                isOperationRunning: false,
                pasteboardHasFileURLs: true,
                isTextEditing: workspace.activeTextEditingSession != nil
            )

            #expect(policy.canRename == false) // Return/F2 remain with the editor.
            #expect(policy.canTrash == false) // Delete/Command-Delete remain with the editor.
            #expect(policy.copyRoute == .textResponder)
            #expect(policy.pasteRoute == .textResponder)
            #expect(policy.canQuickLook == false) // Bare Space remains text input.
            #expect(policy.canNavigate == false) // Command-Up/Back/Forward stay with text.
            #expect(policy.canOpen == false)
            workspace.endTextEditing(session)
        }
    }

    @Test func filterEditingIsATextSessionAndCommandFTargetsOnlyTheActivePane() {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left"),
            rightURL: URL(filePath: "/right"),
            listingService: StubDirectoryListingService(values: [:])
        )
        let session = WorkspaceTextEditingSession(paneID: .right, kind: .filter)
        workspace.beginTextEditing(session)
        #expect(workspace.activeTextEditingSession == session)
        workspace.endTextEditing(session)

        workspace.activate(.right)
        WorkspaceFilterCommandActions.showFilter(in: workspace, canNavigate: false)
        #expect(!workspace.left.isFilterPresented)
        #expect(!workspace.right.isFilterPresented)

        WorkspaceFilterCommandActions.showFilter(in: workspace, canNavigate: true)
        #expect(!workspace.left.isFilterPresented)
        #expect(workspace.right.isFilterPresented)
        #expect(workspace.right.filterFocusRequestID != nil)
    }

    @Test func oldSamePaneAndKindSessionCannotEndANewerGeneration() {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left"),
            rightURL: URL(filePath: "/right"),
            listingService: StubDirectoryListingService(values: [:])
        )
        let oldSession = WorkspaceTextEditingSession(paneID: .left, kind: .inlineName)
        let newSession = WorkspaceTextEditingSession(paneID: .left, kind: .inlineName)

        #expect(oldSession != newSession)
        workspace.beginTextEditing(oldSession)
        workspace.beginTextEditing(newSession)
        workspace.endTextEditing(oldSession)

        #expect(workspace.activeTextEditingSession == newSession)
        workspace.endTextEditing(newSession)
        #expect(workspace.activeTextEditingSession == nil)
    }

    @Test func storageInspectorCommandPolicyTracksModeAndPhase() {
        let inactive = StorageInspectorCommandPolicy(isActive: false, phase: .inactive)
        #expect(inactive.toggleTitle == "Enter Storage Inspector")
        #expect(!inactive.canStart)
        #expect(!inactive.canCancel)

        for phase in [
            StorageAnalysisPhase.idle,
            .complete,
            .paused,
            .cancelled
        ] {
            let policy = StorageInspectorCommandPolicy(isActive: true, phase: phase)
            #expect(policy.toggleTitle == "Exit Storage Inspector")
            #expect(policy.canStart)
            #expect(!policy.canCancel)
        }

        for phase in [StorageAnalysisPhase.scanning, .verifying] {
            let policy = StorageInspectorCommandPolicy(isActive: true, phase: phase)
            #expect(!policy.canStart)
            #expect(policy.canCancel)
        }
    }
}
