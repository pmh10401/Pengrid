import SwiftUI

private struct PreviewSelectionKey: Hashable {
    let paneID: String
    let items: [FileItem]
}

struct WorkspaceView: View {
    let workspace: WorkspaceState
    let operationController: FileOperationController
    let smartSearch: SmartSearchStore
    let smartSearchRouter: SmartSearchActionRouter
    let favorites: FavoritesStore
    let cloudLocations: CloudLocationsStore
    let comparison: ComparisonCoordinator
    let storage: StorageAnalysisStore
    let storageCleanupController: StorageCleanupController
    let quickLookController: QuickLookController
    let previewCoordinator: WorkspacePreviewCoordinator
    let materializer: any CloudMaterializing
    let fileSystem: any FileSystemAccess
    let cloudWorkspaceActions: any CloudLocationWorkspaceActions
    let cloudAccessCoordinator: CloudLocationScopedAccessCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hasOverlay = comparison.isActive || storage.isActive

        VStack(spacing: 0) {
            ZStack {
                ordinaryWorkspace
                    .opacity(hasOverlay ? 0 : 1)
                    .allowsHitTesting(!hasOverlay)
                    .accessibilityHidden(hasOverlay)

                if comparison.isActive {
                    ComparisonWorkspaceView(
                        workspace: workspace,
                        comparison: comparison,
                        operationController: operationController
                    )
                } else if storage.isActive {
                    StorageInspectorView(
                        workspace: workspace,
                        storage: storage,
                        cleanupController: storageCleanupController,
                        quickLookController: quickLookController,
                        materializer: materializer,
                        fileSystem: fileSystem,
                        workspaceActions: cloudWorkspaceActions,
                        operationController: operationController,
                        accessCoordinator: cloudAccessCoordinator
                    )
                }
            }

            HStack(spacing: 0) {
                OperationStatusView(controller: operationController)
                FileOperationCenterView(controller: operationController)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            HStack {
                Text(workspace.activePaneID == .left ? "Left panel active" : "Right panel active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityLabel("Active file pane")
            .accessibilityValue(workspace.activePaneID == .left ? "Left" : "Right")
        }
        .task {
            await workspace.loadInitialDirectories()
        }
        .onDisappear {
            workspace.flushPendingPersistence()
        }
        .sheet(item: pendingConflict) { item in
            ConflictResolutionSheet(conflict: item.conflict) { decision, applyToAll in
                operationController.resolvePendingConflict(
                    decision,
                    applyToAll: applyToAll
                )
            }
        }
        .sheet(isPresented: smartSearchPresentation) {
            SmartSearchView(
                store: smartSearch,
                router: smartSearchRouter,
                workspace: workspace,
                operationController: operationController,
                quickLookController: quickLookController,
                materializer: materializer
            )
        }
        .alert("Move to Trash?", isPresented: trashConfirmationIsPresented) {
            Button("Cancel", role: .cancel) {
                workspace.dismissTrashConfirmation()
            }
            Button("Move to Trash", role: .destructive) {
                guard let request = workspace.pendingTrashRequest else { return }
                workspace.dismissTrashConfirmation()
                _ = operationController.trash(request.items, workspace: workspace)
            }
        } message: {
            Text(trashConfirmationMessage)
        }
        .focusedSceneValue(\.workspaceState, workspace)
        .focusedSceneValue(\.comparisonCoordinator, comparison)
        .focusedSceneValue(\.storageAnalysisStore, storage)
    }

    private var ordinaryWorkspace: some View {
        @Bindable var workspace = workspace

        return HStack(spacing: 0) {
            PlacesRailView(
                favorites: favorites,
                cloudLocations: cloudLocations,
                activePane: workspace.activePane,
                cloudWorkspaceActions: cloudWorkspaceActions,
                cloudAccessCoordinator: cloudAccessCoordinator
            )

            WorkspaceSplitView(ratio: $workspace.splitRatio) {
                FilePaneView(
                    paneID: .left,
                    state: workspace.left,
                    workspace: workspace,
                    operationController: operationController,
                    favorites: favorites,
                    materializer: materializer,
                    accessCoordinator: cloudAccessCoordinator,
                    isActive: workspace.activePaneID == .left,
                    onActivate: { workspace.activate(.left) },
                    onRequestTrashConfirmation: workspace.requestTrashConfirmation
                )
            } right: {
                FilePaneView(
                    paneID: .right,
                    state: workspace.right,
                    workspace: workspace,
                    operationController: operationController,
                    favorites: favorites,
                    materializer: materializer,
                    accessCoordinator: cloudAccessCoordinator,
                    isActive: workspace.activePaneID == .right,
                    onActivate: { workspace.activate(.right) },
                    onRequestTrashConfirmation: workspace.requestTrashConfirmation
                )
            }
            .transaction { transaction in
                if !AccessibilityMotionPresentation.allowsNonessentialAnimation(
                    reduceMotion: reduceMotion
                ) {
                    transaction.animation = nil
                }
            }
        }
        .task(id: previewSelectionKey) {
            await previewCoordinator.selectionDidChange(
                to: WorkspacePreviewSelection(
                    paneID: workspace.activePaneID,
                    items: selectedItemsForPreview
                )
            )
        }
    }

    private var previewSelectionKey: PreviewSelectionKey {
        PreviewSelectionKey(
            paneID: workspace.activePaneID.rawValue,
            items: selectedItemsForPreview
        )
    }

    private var selectedItemsForPreview: [FileItem] {
        let selectedURLs = Set(workspace.selectedURLsForCommands)
        return workspace.activePane.items.filter { selectedURLs.contains($0.url) }
    }

    private var pendingConflict: Binding<IdentifiedFileConflict?> {
        Binding {
            operationController.pendingConflict.map(IdentifiedFileConflict.init)
        } set: { item in
            if item == nil, operationController.pendingConflict != nil {
                operationController.resolvePendingConflict(.cancel, applyToAll: false)
            }
        }
    }

    private var smartSearchPresentation: Binding<Bool> {
        Binding {
            smartSearch.isPresented
        } set: { isPresented in
            if !isPresented {
                smartSearch.dismiss()
            }
        }
    }

    private var trashConfirmationIsPresented: Binding<Bool> {
        Binding {
            workspace.pendingTrashRequest != nil
        } set: { isPresented in
            if !isPresented {
                workspace.dismissTrashConfirmation()
            }
        }
    }

    private var trashConfirmationMessage: String {
        let count = workspace.pendingTrashRequest?.urls.count ?? 0
        return count == 1
            ? "The selected item will be moved to the Trash."
            : "The \(count) selected items will be moved to the Trash."
    }
}
