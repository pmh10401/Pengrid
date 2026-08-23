import Foundation
import Observation

@MainActor @Observable
final class CommandPaletteStore {
    private(set) var isPresented = false
    private(set) var items: [CommandPaletteItem] = []
    private(set) var results: [CommandPaletteItem] = []
    var query = "" {
        didSet { recomputeResults() }
    }
    private(set) var selectedItemID: String?

    private var pendingAction: CommandPaletteAction?

    func present(items: [CommandPaletteItem]) {
        pendingAction = nil
        self.items = items
        query = ""
        isPresented = true
        recomputeResults()
    }

    func requestExecution(itemID: String) {
        guard isPresented,
              let item = results.first(where: { $0.id == itemID })
        else { return }
        pendingAction = item.action
        isPresented = false
    }

    func dismiss() {
        isPresented = false
        pendingAction = nil
    }

    func takePendingAction() -> CommandPaletteAction? {
        defer { pendingAction = nil }
        return pendingAction
    }

    private func recomputeResults() {
        results = CommandPaletteMatcher.ranked(items, query: query)
        selectedItemID = results.first?.id
    }
}
