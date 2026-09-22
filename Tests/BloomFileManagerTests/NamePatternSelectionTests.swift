import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct NamePatternSelectionTests {
    private let left = URL(filePath: "/pattern-left", directoryHint: .isDirectory)
    private let right = URL(filePath: "/pattern-right", directoryHint: .isDirectory)

    private func workspace() async -> WorkspaceState {
        let workspace = WorkspaceState(
            leftURL: left,
            rightURL: right,
            listingService: StubDirectoryListingService(values: [
                left: [item("report.pdf", in: left), item("notes.txt", in: left)],
                right: [item("other.pdf", in: right)]
            ])
        )
        await workspace.loadInitialDirectories()
        return workspace
    }

    @Test func previewAndApplyUseOnlyCapturedVisibleItemsInTheOriginPane() async {
        let workspace = await workspace()
        let tab = WorkspaceTabID()
        let request = NamePatternSelectionRequest(workspace: workspace, tabID: tab)
        workspace.beginTextEditing(request.editingSession)
        #expect(request.itemCount == 2)
        workspace.left.selection = [left.appendingPathComponent("notes.txt")]
        workspace.right.selection = [right.appendingPathComponent("other.pdf")]

        #expect(request.matchingURLs("*.PDF") == [left.appendingPathComponent("report.pdf")])
        #expect(request.apply("*.PDF", in: workspace, tabID: tab))
        #expect(workspace.left.selection == [left.appendingPathComponent("report.pdf")])
        #expect(workspace.right.selection == [right.appendingPathComponent("other.pdf")])
        #expect(workspace.left.focusRequestID == nil)
        request.finish(in: workspace, tabID: tab)
        #expect(workspace.left.focusRequestID != nil)
        #expect(workspace.activeTextEditingSession == nil)
    }

    @Test func emptyInputAndCancellationPreserveSelectionWhileNoMatchCanClearIt() async {
        let workspace = await workspace()
        let tab = WorkspaceTabID()
        let selected = left.appendingPathComponent("notes.txt")
        workspace.left.selection = [selected]
        let request = NamePatternSelectionRequest(workspace: workspace, tabID: tab)
        workspace.beginTextEditing(request.editingSession)

        #expect(request.matchingURLs("") == nil)
        #expect(!request.apply("", in: workspace, tabID: tab))
        request.finish(in: workspace, tabID: tab)
        #expect(workspace.left.selection == [selected])
        #expect(workspace.activeTextEditingSession == nil)
        #expect(workspace.left.focusRequestID != nil)

        let second = NamePatternSelectionRequest(workspace: workspace, tabID: tab)
        workspace.beginTextEditing(second.editingSession)
        #expect(second.apply("*.absent", in: workspace, tabID: tab))
        #expect(workspace.left.selection.isEmpty)
        second.finish(in: workspace, tabID: tab)
    }

    @Test func changedPaneTabLoadingOrProjectionRejectsStaleSelection() async {
        let workspace = await workspace()
        let tab = WorkspaceTabID()
        let request = NamePatternSelectionRequest(workspace: workspace, tabID: tab)
        workspace.beginTextEditing(request.editingSession)
        #expect(request.isCurrent(in: workspace, tabID: tab))
        #expect(!request.apply("*", in: workspace, tabID: WorkspaceTabID()))
        workspace.activate(.right)
        #expect(!request.apply("*", in: workspace, tabID: tab))
        request.finish(in: workspace, tabID: tab)
        #expect(workspace.left.focusRequestID == nil)
        #expect(workspace.right.focusRequestID == nil)
        workspace.activate(.left)
        workspace.beginTextEditing(request.editingSession)
        workspace.left.isLoading = true
        #expect(!request.apply("*", in: workspace, tabID: tab))
        workspace.left.isLoading = false
        await workspace.left.navigate(to: right)
        #expect(!request.apply("*", in: workspace, tabID: tab))
        await workspace.left.navigate(to: left)
        #expect(!request.apply("*", in: workspace, tabID: tab))
        #expect(workspace.left.selection.isEmpty)
        request.finish(in: workspace, tabID: tab)
    }

    @Test func dismissalDoesNotEndANewerTextEditingSession() async {
        let workspace = await workspace()
        let tab = WorkspaceTabID()
        let request = NamePatternSelectionRequest(workspace: workspace, tabID: tab)
        let newer = WorkspaceTextEditingSession(paneID: .left, kind: .path)
        workspace.beginTextEditing(newer)
        #expect(!request.apply("*", in: workspace, tabID: tab))
        request.finish(in: workspace, tabID: tab)
        #expect(workspace.activeTextEditingSession == newer)
        #expect(workspace.left.focusRequestID == nil)
    }

    @Test func patternSheetDefersCompetingSheetsUntilDismissal() {
        var state = WorkspaceModalPresentationState()
        let started = state.beginNamePatternPresentation()
        let repeated = state.beginNamePatternPresentation()
        let paletteDuringPattern = state.beginCommandPalettePresentation()
        #expect(started)
        #expect(!repeated)
        #expect(!paletteDuringPattern)
        #expect(!state.allowsOtherModalPresentation)
        #expect(!state.allowsSelectionFolderPresentation(
            conflictPresented: false, searchPresented: false,
            batchRenamePresented: false, passwordPresented: false
        ))
        #expect(!state.allowsSynchronizationReviewPresentation(
            conflictPresented: false, searchPresented: false,
            batchRenamePresented: false, passwordPresented: false,
            selectionFolderPresented: false
        ))
        #expect(state.passwordRequestToPresent(
            pending: ArchivePasswordRequest(id: UUID(), purpose: .createAES256,
                archiveBasename: "file.zip", previousAttemptFailed: false),
            conflictPresented: false, searchPresented: false
        ) == nil)
        state.endNamePatternPresentation()
        #expect(state.allowsOtherModalPresentation)
        let paletteAfterPattern = state.beginCommandPalettePresentation()
        let patternDuringPalette = state.beginNamePatternPresentation()
        #expect(paletteAfterPattern)
        #expect(!patternDuringPalette)
    }

    @Test func patternCommandRequiresVisibleReadyPaneWithoutOtherModalOwners() {
        let policy = WorkspaceSelectionCommandPolicy(
            hasWorkspace: true, isFiltering: false, isTextEditing: false,
            selectionCount: 0, hasValidSameExtensionSelection: false
        )
        #expect(policy.canSelectByName(isLoading: false, isModalPresented: false, isOverlayActive: false))
        #expect(!policy.canSelectByName(isLoading: true, isModalPresented: false, isOverlayActive: false))
        #expect(!policy.canSelectByName(isLoading: false, isModalPresented: true, isOverlayActive: false))
        #expect(!policy.canSelectByName(isLoading: false, isModalPresented: false, isOverlayActive: true))
        for (hasWorkspace, isFiltering, isTextEditing) in [(false, false, false), (true, true, false), (true, false, true)] {
            let blocked = WorkspaceSelectionCommandPolicy(
                hasWorkspace: hasWorkspace, isFiltering: isFiltering, isTextEditing: isTextEditing,
                selectionCount: 0, hasValidSameExtensionSelection: false
            )
            #expect(!blocked.canSelectByName(isLoading: false, isModalPresented: false, isOverlayActive: false))
        }
        #expect(WorkspaceTabModalPolicy(namePatternPresented: true).isPresented)
    }

    private func item(_ name: String, in directory: URL) -> FileItem {
        FileItem(url: directory.appendingPathComponent(name), name: name,
                 isDirectory: false, isPackage: false, modifiedAt: nil,
                 byteSize: nil, typeDescription: "File")
    }
}
