import Foundation
import Testing
@testable import BloomFileManager

@Suite struct WorkspaceModalPresentationStateTests {
    @Test func selectionFolderIsExclusiveWithEveryOtherWorkspaceSheet() {
        var state = WorkspaceModalPresentationState()
        state.selectionFolderSheetDidAppear()

        #expect(!state.allowsOtherModalPresentation)
        #expect(!state.allowsSelectionFolderPresentation(
            conflictPresented: false,
            searchPresented: false,
            batchRenamePresented: false,
            passwordPresented: true
        ))
        #expect(!state.allowsSelectionFolderPresentation(
            conflictPresented: true,
            searchPresented: false,
            batchRenamePresented: false,
            passwordPresented: false
        ))

        state.selectionFolderSheetDidDisappear()
        #expect(state.allowsSelectionFolderPresentation(
            conflictPresented: false,
            searchPresented: false,
            batchRenamePresented: false,
            passwordPresented: false
        ))
    }

    @Test func passwordWaitsWhileSelectionFolderIsPresented() {
        let request = ArchivePasswordRequest(
            id: UUID(),
            purpose: .createAES256,
            archiveBasename: "Archive.zip",
            previousAttemptFailed: false
        )
        var state = WorkspaceModalPresentationState()
        state.selectionFolderSheetDidAppear()

        #expect(state.passwordRequestToPresent(
            pending: request,
            conflictPresented: false,
            searchPresented: false,
            batchRenamePresented: false,
            selectionFolderPresented: true
        ) == nil)
    }
}
