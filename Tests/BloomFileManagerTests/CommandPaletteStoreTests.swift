import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct CommandPaletteStoreTests {
    @Test func presentationResetsQueryAndPendingActionAndSelectsFirstResult() {
        let store = CommandPaletteStore()
        let old = CommandPaletteItem(title: "Old", action: .createFolder)
        let first = CommandPaletteItem(title: "First", action: .createFile)
        let second = CommandPaletteItem(title: "Second", action: .showFilter)

        store.present(items: [old])
        store.query = "old"
        store.requestExecution(itemID: old.id)
        store.present(items: [first, second])

        #expect(store.isPresented)
        #expect(store.query.isEmpty)
        #expect(store.results == [first, second])
        #expect(store.selectedItemID == first.id)
        #expect(store.takePendingAction() == nil)
    }

    @Test func queryUpdatesPrecomputedResultsAndSelection() {
        let store = CommandPaletteStore()
        let folder = CommandPaletteItem(title: "Create Folder", action: .createFolder)
        let file = CommandPaletteItem(title: "Create File", action: .createFile)

        store.present(items: [folder, file])
        store.query = "file"

        #expect(store.results == [file])
        #expect(store.selectedItemID == file.id)
    }

    @Test func explicitDismissalClearsPendingAction() {
        let store = CommandPaletteStore()
        let item = CommandPaletteItem(title: "Create Folder", action: .createFolder)

        store.present(items: [item])
        store.dismiss()

        #expect(!store.isPresented)
        #expect(store.takePendingAction() == nil)
    }

    @Test func requestExecutionStoresOneShotActionAcrossDismissal() {
        let store = CommandPaletteStore()
        let item = CommandPaletteItem(title: "Create Folder", action: .createFolder)

        store.present(items: [item])
        store.requestExecution(itemID: item.id)
        store.dismiss()

        #expect(!store.isPresented)
        #expect(store.takePendingAction() == .createFolder)
        #expect(store.takePendingAction() == nil)
    }

    @Test func staleItemIDsAreRejected() {
        let store = CommandPaletteStore()
        let first = CommandPaletteItem(title: "First", action: .createFolder)
        let replacement = CommandPaletteItem(title: "Replacement", action: .createFile)

        store.present(items: [first])
        store.present(items: [replacement])
        store.requestExecution(itemID: first.id)

        #expect(store.isPresented)
        #expect(store.takePendingAction() == nil)
    }
}
