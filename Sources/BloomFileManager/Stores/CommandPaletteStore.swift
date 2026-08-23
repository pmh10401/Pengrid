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
    private var preservesPendingActionThroughDismissal = false

    func present(items: [CommandPaletteItem]) {
        pendingAction = nil
        preservesPendingActionThroughDismissal = false
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
        preservesPendingActionThroughDismissal = true
        isPresented = false
    }

    func dismiss() {
        isPresented = false
        if preservesPendingActionThroughDismissal {
            preservesPendingActionThroughDismissal = false
        } else {
            pendingAction = nil
        }
    }

    func takePendingAction() -> CommandPaletteAction? {
        defer {
            pendingAction = nil
            preservesPendingActionThroughDismissal = false
        }
        return pendingAction
    }

    private func recomputeResults() {
        results = CommandPaletteMatcher.ranked(items, query: query)
        selectedItemID = results.first?.id
    }
}
