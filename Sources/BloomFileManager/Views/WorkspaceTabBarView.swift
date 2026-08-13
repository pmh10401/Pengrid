import SwiftUI

enum WorkspaceTabPresentation {
    static func basename(for directory: URL) -> String {
        let basename = directory.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? "Workspace" : basename
    }

    static func title(left: URL, right: URL) -> String {
        "\(basename(for: left)) ⇄ \(basename(for: right))"
    }

    static func accessibilityLabel(
        index: Int,
        leftDirectory: URL,
        rightDirectory: URL,
        isActive: Bool
    ) -> String {
        let selection = isActive ? ", selected" : ""
        return "Workspace tab \(index), \(basename(for: leftDirectory)) and \(basename(for: rightDirectory))\(selection)"
    }
}

final class WorkspaceTabInitialLoadState: @unchecked Sendable {
    private var completed = Set<WorkspaceTabID>()
    private var loading = [WorkspaceTabID: UUID]()
    private let lock = NSLock()

    func load(
        tabID: WorkspaceTabID,
        operation: @escaping @MainActor () async -> Void
    ) async {
        let loadID = UUID()
        guard lock.withLock({
            guard !completed.contains(tabID), loading[tabID] == nil else { return false }
            loading[tabID] = loadID
            return true
        }) else { return }
        await operation()
        lock.withLock {
            guard loading[tabID] == loadID else { return }
            loading[tabID] = nil
            guard !Task.isCancelled else { return }
            completed.insert(tabID)
        }
    }

    func cancel(tabID: WorkspaceTabID) {
        lock.withLock { loading[tabID] = nil }
    }

    func isCompleted(tabID: WorkspaceTabID) -> Bool {
        lock.withLock { completed.contains(tabID) }
    }
}

struct WorkspaceTabModalPolicy: Equatable {
    var profilesPresented = false
    var passwordPresented = false
    var selectionFolderPresented = false
    var conflictPresented = false
    var smartSearchPresented = false
    var batchRenamePresented = false
    var pendingTrashPresented = false

    var isPresented: Bool {
        profilesPresented
            || passwordPresented
            || selectionFolderPresented
            || conflictPresented
            || smartSearchPresented
            || batchRenamePresented
            || pendingTrashPresented
    }
}

struct WorkspaceTabInteractionPolicy: Equatable {
    let isModalPresented: Bool
    let isTextEditing: Bool

    var permitsTabChange: Bool {
        !isModalPresented && !isTextEditing
    }

    func permitsTabChange(allowsCurrentModalOwner: Bool) -> Bool {
        !isTextEditing && (!isModalPresented || allowsCurrentModalOwner)
    }
}

enum WorkspaceTabTeardownActions {
    static func perform(
        stopComparison: () -> Void,
        exitStorage: () -> Void,
        closePreview: () -> Void,
        dismissSmartSearch: () -> Void,
        dismissBatchRename: () -> Void,
        dismissSelectionFolder: () -> Void,
        dismissSynchronizationReview: () -> Void,
        dismissPendingTrash: () -> Void,
        endTextEditing: () -> Void,
        cancelPassword: () -> Void
    ) {
        stopComparison()
        exitStorage()
        closePreview()
        dismissSmartSearch()
        dismissBatchRename()
        dismissSelectionFolder()
        dismissSynchronizationReview()
        dismissPendingTrash()
        endTextEditing()
        cancelPassword()
    }
}

@MainActor
enum WorkspaceTabCommandActions {
    @discardableResult
    static func newTab(
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        teardown: () -> Void
    ) -> Bool {
        guard WorkspaceTabInteractionPolicy(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing
        ).permitsTabChange else { return false }
        teardown()
        _ = session.newTab()
        return true
    }

    @discardableResult
    static func select(
        _ id: WorkspaceTabID,
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        teardown: () -> Void
    ) -> Bool {
        guard WorkspaceTabInteractionPolicy(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing
        ).permitsTabChange else { return false }
        guard id != session.activeTabID else { return true }
        guard session.tabs.contains(where: { $0.id == id }) else { return false }
        teardown()
        return session.selectTab(id)
    }

    @discardableResult
    static func selectNext(
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        teardown: () -> Void
    ) -> Bool {
        selectAdjacent(
            in: session,
            offset: 1,
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing,
            teardown: teardown
        )
    }

    @discardableResult
    static func selectPrevious(
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        teardown: () -> Void
    ) -> Bool {
        selectAdjacent(
            in: session,
            offset: -1,
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing,
            teardown: teardown
        )
    }

    @discardableResult
    static func openProfile(
        _ id: WorkspaceProfileID,
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        allowsCurrentModalOwner: Bool,
        teardown: () -> Void
    ) -> Bool {
        guard WorkspaceTabInteractionPolicy(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing
        ).permitsTabChange(allowsCurrentModalOwner: allowsCurrentModalOwner) else { return false }
        guard session.profiles.contains(where: { $0.id == id }) else { return false }
        teardown()
        return session.openProfile(id) != nil
    }

    static func saveActiveProfile(
        named name: String,
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        allowsCurrentModalOwner: Bool
    ) throws -> WorkspaceProfileID? {
        guard permitsProfileManagement(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing,
            allowsCurrentModalOwner: allowsCurrentModalOwner
        ) else { return nil }
        return try session.saveActiveProfile(named: name)
    }

    @discardableResult
    static func renameProfile(
        _ id: WorkspaceProfileID,
        to name: String,
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        allowsCurrentModalOwner: Bool
    ) throws -> Bool {
        guard permitsProfileManagement(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing,
            allowsCurrentModalOwner: allowsCurrentModalOwner
        ) else { return false }
        try session.renameProfile(id, to: name)
        return true
    }

    @discardableResult
    static func deleteProfile(
        _ id: WorkspaceProfileID,
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        allowsCurrentModalOwner: Bool
    ) -> Bool {
        guard permitsProfileManagement(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing,
            allowsCurrentModalOwner: allowsCurrentModalOwner
        ) else { return false }
        return session.deleteProfile(id)
    }

    @discardableResult
    static func closeActiveTab(
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        canClose: (WorkspaceTabID) -> Bool,
        beforeClose: (WorkspaceState) -> Void = { _ in },
        teardown: () -> Void
    ) -> Bool {
        guard !isModalPresented,
              !isTextEditing,
              session.tabs.count > 1,
              canClose(session.activeTabID)
        else { return false }
        beforeClose(session.activeWorkspace)
        teardown()
        return session.closeTab(session.activeTabID, canClose: canClose)
    }

    @discardableResult
    static func close(
        _ id: WorkspaceTabID,
        in session: WorkspaceSessionState,
        isModalPresented: Bool,
        isTextEditing: Bool,
        canClose: (WorkspaceTabID) -> Bool,
        beforeClose: (WorkspaceState) -> Void = { _ in },
        teardown: () -> Void
    ) -> Bool {
        guard WorkspaceTabInteractionPolicy(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing
        ).permitsTabChange,
              session.tabs.count > 1,
              canClose(id),
              let tab = session.tabs.first(where: { $0.id == id })
        else { return false }
        beforeClose(tab.workspace)
        if id == session.activeTabID {
            teardown()
        }
        return session.closeTab(id, canClose: canClose)
    }

    private static func selectAdjacent(
        in session: WorkspaceSessionState,
        offset: Int,
        isModalPresented: Bool,
        isTextEditing: Bool,
        teardown: () -> Void
    ) -> Bool {
        guard session.tabs.count > 1,
              let currentIndex = session.tabs.firstIndex(where: { $0.id == session.activeTabID })
        else { return false }
        let destinationIndex = (currentIndex + offset + session.tabs.count) % session.tabs.count
        return select(
            session.tabs[destinationIndex].id,
            in: session,
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing,
            teardown: teardown
        )
    }

    private static func permitsProfileManagement(
        isModalPresented: Bool,
        isTextEditing: Bool,
        allowsCurrentModalOwner: Bool
    ) -> Bool {
        WorkspaceTabInteractionPolicy(
            isModalPresented: isModalPresented,
            isTextEditing: isTextEditing
        ).permitsTabChange(allowsCurrentModalOwner: allowsCurrentModalOwner)
    }
}

struct WorkspaceTabBarView: View {
    let session: WorkspaceSessionState
    let canClose: (WorkspaceTabID) -> Bool
    let invalidateReversalHistory: (WorkspaceState) -> Void
    let teardown: () -> Void
    let isModalPresented: Bool
    let isTextEditing: Bool
    @Binding var profilesPresented: Bool

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(tab, index: index + 1)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            Button {
                _ = WorkspaceTabCommandActions.newTab(
                    in: session,
                    isModalPresented: isModalPresented,
                    isTextEditing: isTextEditing,
                    teardown: teardown
                )
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.newTab)
            .accessibilityLabel("New workspace tab")
            .disabled(isModalPresented || isTextEditing)

            Button {
                guard WorkspaceTabInteractionPolicy(
                    isModalPresented: isModalPresented,
                    isTextEditing: isTextEditing
                ).permitsTabChange else { return }
                profilesPresented = true
            } label: {
                Image(systemName: "bookmark")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.profiles)
            .accessibilityLabel("Workspace profiles")
            .disabled(isModalPresented || isTextEditing)
        }
        .padding(.vertical, 5)
        .background(.bar)
        .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.tabBar)
        .accessibilityLabel("Workspace tabs")
    }

    @ViewBuilder
    private func tabButton(_ tab: WorkspaceTabRuntime, index: Int) -> some View {
        let isActive = tab.id == session.activeTabID
        let leftDirectory = tab.workspace.left.currentDirectory
        let rightDirectory = tab.workspace.right.currentDirectory
        HStack(spacing: 4) {
            Button(WorkspaceTabPresentation.title(left: leftDirectory, right: rightDirectory)) {
                _ = WorkspaceTabCommandActions.select(
                    tab.id,
                    in: session,
                    isModalPresented: isModalPresented,
                    isTextEditing: isTextEditing,
                    teardown: teardown
                )
            }
            .buttonStyle(.bordered)
            .tint(isActive ? .accentColor : .gray)
            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.tab(tab.id))
            .accessibilityLabel(WorkspaceTabPresentation.accessibilityLabel(
                index: index,
                leftDirectory: leftDirectory,
                rightDirectory: rightDirectory,
                isActive: isActive
            ))
            .accessibilityValue(isActive ? "Selected" : "Not selected")
            .disabled(isModalPresented || isTextEditing)

            Button {
                guard !isModalPresented, !isTextEditing else { return }
                _ = WorkspaceTabCommandActions.close(
                    tab.id,
                    in: session,
                    isModalPresented: isModalPresented,
                    isTextEditing: isTextEditing,
                    canClose: canClose,
                    beforeClose: invalidateReversalHistory,
                    teardown: teardown
                )
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(
                session.tabs.count == 1
                    || !canClose(tab.id)
                    || isModalPresented
                    || isTextEditing
            )
            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.closeTab(tab.id))
            .accessibilityLabel("Close \(WorkspaceTabPresentation.title(left: leftDirectory, right: rightDirectory)) workspace tab")
        }
    }
}
