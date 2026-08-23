import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite("CommandPalettePresentationTests")
struct CommandPalettePresentationTests {
    @Test func paletteViewUsesAccessibleNativeControlsAndKeyboardPresentation() throws {
        let source = try commandPaletteSource(named: "Views/CommandPaletteView.swift")

        for requiredSnippet in [
            "@FocusState private var queryFieldIsFocused",
            "TextField(\"Search commands and locations\"",
            "List(selection: $selection)",
            "Button {",
            ".focused($queryFieldIsFocused)",
            ".defaultFocus($queryFieldIsFocused, true)",
            ".onSubmit",
            ".onExitCommand",
            "ContentUnavailableView.search",
            "AccessibilityIdentifiers.commandPaletteSheet",
            "AccessibilityIdentifiers.commandPaletteQuery",
            "AccessibilityIdentifiers.commandPaletteResults",
            "AccessibilityIdentifiers.commandPaletteRow(item.id)"
        ] {
            #expect(source.contains(requiredSnippet))
        }
        #expect(!source.contains("accessibilityValue(item.subtitle"))
    }

    @Test func routingMapsLocalActionsAndFailsClosedForDeletedReferences() {
        let profileID = WorkspaceProfileID(rawValue: UUID())
        let searchID = UUID()
        let destination = URL(filePath: "/private/Example", directoryHint: .isDirectory)

        #expect(CommandPaletteActionRouting.route(.navigate(destination), profiles: [], savedSearchIDs: []) == .navigate(destination.standardizedFileURL))
        #expect(CommandPaletteActionRouting.route(.createFolder, profiles: [], savedSearchIDs: []) == .createFolder)
        #expect(CommandPaletteActionRouting.route(.createFile, profiles: [], savedSearchIDs: []) == .createFile)
        #expect(CommandPaletteActionRouting.route(.showFilter, profiles: [], savedSearchIDs: []) == .showFilter)
        #expect(CommandPaletteActionRouting.route(.showSmartSearch, profiles: [], savedSearchIDs: []) == .showSmartSearch)
        #expect(CommandPaletteActionRouting.route(.openProfile(profileID), profiles: [profileID], savedSearchIDs: []) == .openProfile(profileID))
        #expect(CommandPaletteActionRouting.route(.openSavedSearch(searchID), profiles: [], savedSearchIDs: [searchID]) == .openSavedSearch(searchID))
        #expect(CommandPaletteActionRouting.route(.openProfile(profileID), profiles: [], savedSearchIDs: []) == nil)
        #expect(CommandPaletteActionRouting.route(.openSavedSearch(searchID), profiles: [], savedSearchIDs: []) == nil)
    }

    @Test func executionIsConsumedOnlyAfterTheSheetDismisses() {
        let store = CommandPaletteStore()
        let item = CommandPaletteItem(title: "Create Folder", action: .createFolder)

        store.present(items: [item])
        store.requestExecution(itemID: item.id)

        #expect(!store.isPresented)
        #expect(store.takePendingAction() == .createFolder)
        #expect(store.takePendingAction() == nil)
    }

    @Test func modalOwnershipSurvivesExecutionUntilDismissalAndRejectsSecondPresentation() {
        var modal = WorkspaceModalPresentationState()
        let store = CommandPaletteStore()
        let item = CommandPaletteItem(title: "Create Folder", action: .createFolder)

        let didBegin = modal.beginCommandPalettePresentation()
        #expect(didBegin)
        store.present(items: [item])
        store.requestExecution(itemID: item.id)

        #expect(modal.isCommandPalettePresented)
        #expect(!modal.allowsOtherModalPresentation)
        let didRejectSecondPresentation = modal.beginCommandPalettePresentation()
        #expect(!didRejectSecondPresentation)
        #expect(store.takePendingAction() == .createFolder)
        modal.endCommandPalettePresentation()
        #expect(!modal.isCommandPalettePresented)
    }

    @Test func paletteModalOwnershipBlocksEveryOtherPresentationGate() {
        var modal = WorkspaceModalPresentationState()
        let didBegin = modal.beginCommandPalettePresentation()
        #expect(didBegin)

        #expect(!modal.allowsOtherModalPresentation)
        #expect(!modal.allowsSelectionFolderPresentation(
            conflictPresented: false,
            searchPresented: false,
            batchRenamePresented: false,
            passwordPresented: false
        ))
        #expect(!modal.allowsSynchronizationReviewPresentation(
            conflictPresented: false,
            searchPresented: false,
            batchRenamePresented: false,
            passwordPresented: false,
            selectionFolderPresented: false
        ))
        #expect(modal.passwordRequestToPresent(
            pending: ArchivePasswordRequest(
                id: UUID(),
                purpose: .createAES256,
                archiveBasename: "Archive.zip",
                previousAttemptFailed: false
            ),
            conflictPresented: false,
            searchPresented: false
        ) == nil)
    }

    @Test func cancellationClearsActionButKeepsModalOwnershipUntilDismissalCompletes() {
        var modal = WorkspaceModalPresentationState()
        let store = CommandPaletteStore()
        let item = CommandPaletteItem(title: "Create Folder", action: .createFolder)
        let didBegin = modal.beginCommandPalettePresentation()
        #expect(didBegin)
        store.present(items: [item])

        store.dismiss()

        #expect(store.takePendingAction() == nil)
        #expect(modal.isCommandPalettePresented)
        modal.endCommandPalettePresentation()
        #expect(!modal.isCommandPalettePresented)
    }

    @Test func originMustStillOwnTheSameTabAndPaneBeforeRouting() {
        let origin = CommandPaletteOrigin(
            tabID: WorkspaceTabID(rawValue: UUID()),
            paneID: .right
        )

        #expect(CommandPaletteActionRouting.originIsCurrent(
            origin,
            activeTabID: origin.tabID,
            activePaneID: .right
        ))
        #expect(!CommandPaletteActionRouting.originIsCurrent(
            origin,
            activeTabID: WorkspaceTabID(rawValue: UUID()),
            activePaneID: .right
        ))
        #expect(!CommandPaletteActionRouting.originIsCurrent(
            origin,
            activeTabID: origin.tabID,
            activePaneID: .left
        ))
    }

    @Test func workspaceOwnsPresentationAndDefersExecutionUntilOnDismiss() throws {
        let workspace = try commandPaletteSource(named: "Views/WorkspaceView.swift")
        let app = try commandPaletteSource(named: "App/BloomFileManagerApp.swift")
        let commands = try commandPaletteSource(named: "Support/WorkspaceCommands.swift")

        #expect(workspace.contains(".sheet(isPresented: commandPalettePresentation, onDismiss: commandPaletteDidDismiss)"))
        #expect(workspace.contains("commandPalette.takePendingAction()"))
        #expect(workspace.contains("originPane.requestTableFocus()"))
        #expect(workspace.contains("CommandPaletteBuilder.build("))
        #expect(workspace.contains("CommandPaletteOrigin("))
        #expect(workspace.contains("modalPresentationState.beginCommandPalettePresentation()"))
        #expect(commands.contains("@FocusedValue(\\.workspaceCommandPalettePresentation)"))
        #expect(commands.contains("workspaceCommandPalettePresentation?()"))
        #expect(!app.contains("CommandPaletteStore"))
        #expect(!app.contains("commandPalette: commandPalette"))
    }
}

private func commandPaletteSource(named relativePath: String) throws -> String {
    let testsDirectory = URL(filePath: #filePath).deletingLastPathComponent()
    let packageRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot.appending(path: "Sources/BloomFileManager/\(relativePath)"),
        encoding: .utf8
    )
}
