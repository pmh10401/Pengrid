import SwiftUI

private struct PreviewSelectionKey: Hashable {
    let paneID: String
    let items: [FileItem]
}

/// Retains the identity of the password sheet that SwiftUI actually presented.
/// Other modal requests are deferred while that identity is active, and a
/// dismissal can only release the exact request captured by the sheet.
struct WorkspaceModalPresentationState: Equatable {
    private(set) var presentedPasswordRequestID: UUID?
    private(set) var isSelectionFolderPresented = false

    var allowsOtherModalPresentation: Bool {
        presentedPasswordRequestID == nil && !isSelectionFolderPresented
    }

    mutating func selectionFolderSheetDidAppear() {
        guard presentedPasswordRequestID == nil else { return }
        isSelectionFolderPresented = true
    }

    mutating func selectionFolderSheetDidDisappear() {
        isSelectionFolderPresented = false
    }

    func allowsSelectionFolderPresentation(
        conflictPresented: Bool,
        searchPresented: Bool,
        batchRenamePresented: Bool,
        passwordPresented: Bool
    ) -> Bool {
        !isSelectionFolderPresented
            && !conflictPresented
            && !searchPresented
            && !batchRenamePresented
            && !passwordPresented
    }

    mutating func passwordSheetDidAppear(requestID: UUID) {
        guard presentedPasswordRequestID == nil else { return }
        presentedPasswordRequestID = requestID
    }

    mutating func passwordSheetDidDisappear(requestID: UUID) -> UUID? {
        guard presentedPasswordRequestID == requestID else { return nil }
        presentedPasswordRequestID = nil
        return requestID
    }

    func passwordRequestToPresent(
        pending: ArchivePasswordRequest?,
        conflictPresented: Bool,
        searchPresented: Bool,
        batchRenamePresented: Bool = false,
        selectionFolderPresented: Bool = false
    ) -> ArchivePasswordRequest? {
        guard let pending else { return nil }
        if let presentedPasswordRequestID {
            return pending.id == presentedPasswordRequestID ? pending : nil
        }
        guard !conflictPresented,
              !searchPresented,
              !batchRenamePresented,
              !selectionFolderPresented
        else { return nil }
        return pending
    }
}

struct WorkspaceView: View {
    let workspace: WorkspaceState
    let operationController: FileOperationController
    let batchRename: BatchRenameModel
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
    let passwordCoordinator: ArchivePasswordPromptCoordinator
    let contextActionRouter: FileContextActionRouter
    let openWithProvider: any OpenWithApplicationProviding
    let selectionFolder: SelectionFolderModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modalPresentationState = WorkspaceModalPresentationState()

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
                Text(contextActionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityIdentifiers.workspaceContextActionStatus)
                    .accessibilityLabel("Context action status")
                    .accessibilityValue(contextActionStatus)
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
        .sheet(isPresented: batchRenamePresentation) {
            BatchRenameSheet(model: batchRename) { plan in
                operationController.batchRename(plan, workspace: workspace)
            }
        }
        .sheet(isPresented: selectionFolderPresentation) {
            SelectionFolderSheet(model: selectionFolder) { plan in
                let capturedPane = selectionFolder.snapshot?.sourcePaneID == .right
                    ? workspace.right
                    : workspace.left
                return operationController.encloseSelection(
                    plan,
                    in: capturedPane,
                    workspace: workspace
                )
            }
            .onAppear { modalPresentationState.selectionFolderSheetDidAppear() }
            .onDisappear { modalPresentationState.selectionFolderSheetDidDisappear() }
        }
        .sheet(item: pendingPasswordRequest) { request in
            ArchivePasswordSheet(
                request: request,
                coordinator: passwordCoordinator
            )
            .onAppear {
                modalPresentationState.passwordSheetDidAppear(requestID: request.id)
            }
            .onDisappear {
                guard let requestID = modalPresentationState.passwordSheetDidDisappear(
                    requestID: request.id
                ) else { return }
                passwordCoordinator.cancel(requestID: requestID)
            }
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
                    batchRename: batchRename,
                    cloudLocations: cloudLocations,
                    favorites: favorites,
                    materializer: materializer,
                    fileSystem: fileSystem,
                    accessCoordinator: cloudAccessCoordinator,
                    previewCoordinator: previewCoordinator,
                    contextActionRouter: contextActionRouter,
                    openWithProvider: openWithProvider,
                    selectionFolder: selectionFolder,
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
                    batchRename: batchRename,
                    cloudLocations: cloudLocations,
                    favorites: favorites,
                    materializer: materializer,
                    fileSystem: fileSystem,
                    accessCoordinator: cloudAccessCoordinator,
                    previewCoordinator: previewCoordinator,
                    contextActionRouter: contextActionRouter,
                    openWithProvider: openWithProvider,
                    selectionFolder: selectionFolder,
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

    private var contextActionStatus: String {
        if operationController.isRunning {
            return "File operation in progress."
        }
        if let result = operationController.lastResult {
            return OperationStatusSummary(result: result).accessibilityLabel
        }
        return "No file operation in progress."
    }

    private var pendingConflict: Binding<IdentifiedFileConflict?> {
        Binding {
            guard modalPresentationState.allowsOtherModalPresentation,
                  !smartSearch.isPresented,
                  !batchRename.isPresented,
                  !selectionFolder.isPresented
            else { return nil }
            return operationController.pendingConflict.map(IdentifiedFileConflict.init)
        } set: { item in
            if item == nil,
               modalPresentationState.allowsOtherModalPresentation,
               !smartSearch.isPresented,
               !batchRename.isPresented,
               !selectionFolder.isPresented,
               operationController.pendingConflict != nil {
                operationController.resolvePendingConflict(.cancel, applyToAll: false)
            }
        }
    }

    private var smartSearchPresentation: Binding<Bool> {
        Binding {
            modalPresentationState.allowsOtherModalPresentation
                && operationController.pendingConflict == nil
                && !batchRename.isPresented
                && !selectionFolder.isPresented
                && smartSearch.isPresented
        } set: { isPresented in
            if !isPresented,
               modalPresentationState.allowsOtherModalPresentation,
               operationController.pendingConflict == nil,
               !batchRename.isPresented,
               !selectionFolder.isPresented {
                smartSearch.dismiss()
            }
        }
    }

    private var batchRenamePresentation: Binding<Bool> {
        Binding {
            modalPresentationState.allowsOtherModalPresentation
                && operationController.pendingConflict == nil
                && !smartSearch.isPresented
                && !selectionFolder.isPresented
                && batchRename.isPresented
        } set: { isPresented in
            if !isPresented,
               modalPresentationState.allowsOtherModalPresentation,
               operationController.pendingConflict == nil,
               !smartSearch.isPresented,
               !selectionFolder.isPresented {
                batchRename.dismiss()
            }
        }
    }

    private var pendingPasswordRequest: Binding<ArchivePasswordRequest?> {
        Binding {
            modalPresentationState.passwordRequestToPresent(
                pending: passwordCoordinator.pendingRequest,
                conflictPresented: operationController.pendingConflict != nil,
                searchPresented: smartSearch.isPresented,
                batchRenamePresented: batchRename.isPresented,
                selectionFolderPresented: selectionFolder.isPresented
            )
        } set: { request in
            // The sheet's content captures the request ID and handles its own
            // dismissal. A binding write has no identity and must not cancel a
            // newer coordinator request.
            guard request == nil else { return }
        }
    }

    private var selectionFolderPresentation: Binding<Bool> {
        Binding {
            guard selectionFolder.isPresented else { return false }
            return modalPresentationState.isSelectionFolderPresented
                || modalPresentationState.allowsSelectionFolderPresentation(
                    conflictPresented: operationController.pendingConflict != nil,
                    searchPresented: smartSearch.isPresented,
                    batchRenamePresented: batchRename.isPresented,
                    passwordPresented: passwordCoordinator.pendingRequest != nil
                )
        } set: { isPresented in
            if !isPresented {
                selectionFolder.dismiss()
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
