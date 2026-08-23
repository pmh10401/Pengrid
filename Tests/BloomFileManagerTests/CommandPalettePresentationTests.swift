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

    @Test func workspaceOwnsPresentationAndDefersExecutionUntilOnDismiss() throws {
        let workspace = try commandPaletteSource(named: "Views/WorkspaceView.swift")
        let app = try commandPaletteSource(named: "App/BloomFileManagerApp.swift")
        let commands = try commandPaletteSource(named: "Support/WorkspaceCommands.swift")

        #expect(workspace.contains(".sheet(isPresented: commandPalettePresentation, onDismiss: executeCommandPaletteAction)"))
        #expect(workspace.contains("commandPalette.takePendingAction()"))
        #expect(workspace.contains("workspace.activePane.requestTableFocus()"))
        #expect(commands.contains("CommandPaletteBuilder.build("))
        #expect(app.contains("@State private var commandPalette"))
        #expect(app.contains("commandPalette: commandPalette"))
        #expect(app.contains("favorites: favorites"))
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
