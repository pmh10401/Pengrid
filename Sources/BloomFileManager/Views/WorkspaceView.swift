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
    private(set) var isSynchronizationReviewPresented = false
    private(set) var isCommandPalettePresented = false

    private(set) var isNamePatternPresented = false

    mutating func beginNamePatternPresentation() -> Bool {
        guard allowsOtherModalPresentation else { return false }
        isNamePatternPresented = true
        return true
    }

    mutating func endNamePatternPresentation() {
        isNamePatternPresented = false
    }

    var allowsOtherModalPresentation: Bool {
        presentedPasswordRequestID == nil
            && !isSelectionFolderPresented
            && !isSynchronizationReviewPresented
            && !isCommandPalettePresented
            && !isNamePatternPresented
    }

    mutating func beginCommandPalettePresentation() -> Bool {
        guard allowsOtherModalPresentation else { return false }
        isCommandPalettePresented = true
        return true
    }

    mutating func endCommandPalettePresentation() {
        isCommandPalettePresented = false
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
        passwordPresented: Bool,
        synchronizationReviewPresented: Bool = false
    ) -> Bool {
        !isSelectionFolderPresented
            && !conflictPresented
            && !searchPresented
            && !isCommandPalettePresented
            && !isNamePatternPresented
            && !batchRenamePresented
            && !passwordPresented
            && !synchronizationReviewPresented
            && !isSynchronizationReviewPresented
    }

    mutating func synchronizationReviewSheetDidAppear() {
        guard presentedPasswordRequestID == nil else { return }
        isSynchronizationReviewPresented = true
    }

    mutating func synchronizationReviewSheetDidDisappear() {
        isSynchronizationReviewPresented = false
    }

    func allowsSynchronizationReviewPresentation(
        conflictPresented: Bool,
        searchPresented: Bool,
        batchRenamePresented: Bool,
        passwordPresented: Bool,
        selectionFolderPresented: Bool
    ) -> Bool {
        !isSynchronizationReviewPresented
            && presentedPasswordRequestID == nil
            && !conflictPresented
            && !searchPresented
            && !isCommandPalettePresented
            && !isNamePatternPresented
            && !batchRenamePresented
            && !passwordPresented
            && !selectionFolderPresented
            && !isSelectionFolderPresented
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
        selectionFolderPresented: Bool = false,
        synchronizationReviewPresented: Bool = false
    ) -> ArchivePasswordRequest? {
        guard let pending else { return nil }
        if let presentedPasswordRequestID {
            return pending.id == presentedPasswordRequestID ? pending : nil
        }
        guard !conflictPresented,
              !searchPresented,
              !isCommandPalettePresented,
              !isNamePatternPresented,
              !batchRenamePresented,
              !selectionFolderPresented,
              !synchronizationReviewPresented
        else { return nil }
        return pending
    }
}

struct CommandPaletteOrigin: Equatable {
    let tabID: WorkspaceTabID
    let paneID: PaneID
}

enum CommandPaletteActionRouting {
    static func originIsCurrent(
        _ origin: CommandPaletteOrigin,
        activeTabID: WorkspaceTabID,
        activePaneID: PaneID
    ) -> Bool {
        origin.tabID == activeTabID && origin.paneID == activePaneID
    }

    static func route(
        _ action: CommandPaletteAction,
        profiles: [WorkspaceProfileID],
        savedSearchIDs: [UUID]
    ) -> CommandPaletteAction? {
        switch action {
        case let .navigate(url):
            return .navigate(url.standardizedFileURL)
        case .createFolder, .createFile, .showFilter, .showSmartSearch:
            return action
        case let .openProfile(id):
            return profiles.contains(id) ? action : nil
        case let .openSavedSearch(id):
            return savedSearchIDs.contains(id) ? action : nil
        }
    }
}

struct WorkspaceView: View {
    let workspaceSession: WorkspaceSessionState
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
    let getInfoInspector: GetInfoInspectorController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var modalPresentationState = WorkspaceModalPresentationState()
    @State private var initialLoadState = WorkspaceTabInitialLoadState()
    @State private var profilesPresented = false
    @State private var commandPalette = CommandPaletteStore()
    @State private var commandPaletteOrigin: CommandPaletteOrigin?
    @State private var namePatternRequest: NamePatternSelectionRequest?
    @State private var namePatternPresented = false
    @State private var smartSearchOwner = UUID()

    private var workspace: WorkspaceState {
        workspaceSession.activeWorkspace
    }

    var body: some View {
        workspaceModals
        .alert("Move to Trash?", isPresented: trashConfirmationIsPresented) {
            Button("Cancel", role: .cancel) { workspace.dismissTrashConfirmation() }
            Button("Move to Trash", role: .destructive) {
                guard let request = workspace.pendingTrashRequest else { return }
                workspace.dismissTrashConfirmation()
                _ = operationController.trash(request.items, workspace: workspace)
            }
        } message: { Text(trashConfirmationMessage) }
        .focusedSceneValue(\.workspaceState, workspace)
        .focusedSceneValue(\.workspaceSessionState, workspaceSession)
        .focusedSceneValue(\.workspaceTabModalPresented, workspaceModalIsPresented)
        .focusedSceneValue(\.workspaceTabTeardown, teardownActiveWorkspace)
        .focusedSceneValue(\.workspaceProfilesPresentation, { profilesPresented = true })
        .focusedSceneValue(\.workspaceCommandPalettePresentation, presentCommandPalette)
        .focusedSceneValue(\.workspaceNamePatternPresentation, presentNamePattern)
        .focusedSceneValue(\.workspaceSmartSearchPresentation, presentSmartSearch)
        .focusedSceneValue(\.comparisonCoordinator, comparison)
        .focusedSceneValue(\.storageAnalysisStore, storage)
    }

    private var workspaceLifecycle: some View {
        workspaceCore
        .task(id: workspaceSession.activeTabID) {
            let tabID = workspaceSession.activeTabID
            let loadState = initialLoadState
            await withTaskCancellationHandler {
                await loadState.load(tabID: tabID) {
                    await workspaceSession.activeWorkspace.loadInitialDirectories()
                }
            } onCancel: {
                loadState.cancel(tabID: tabID)
            }
        }
        .onDisappear {
            workspaceSession.flushPersistence()
            smartSearch.dismiss(owner: smartSearchOwner)
            namePatternDidDismiss()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            workspaceSession.flushPersistence()
        }
    }

    private var workspaceModals: some View {
        workspaceLifecycle
        .sheet(isPresented: profilesPresentation) {
            WorkspaceProfilesView(
                session: workspaceSession,
                teardown: teardownActiveWorkspace
            )
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
                materializer: materializer,
                presentationOwner: smartSearchOwner
            )
        }
        .sheet(isPresented: commandPalettePresentation, onDismiss: commandPaletteDidDismiss) {
            CommandPaletteView(store: commandPalette)
        }
        .sheet(isPresented: $namePatternPresented, onDismiss: namePatternDidDismiss) {
            if let request = namePatternRequest {
                NamePatternSelectionView(
                    request: request,
                    workspace: workspace,
                    tabID: workspaceSession.activeTabID
                )
            }
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
    }

    private var workspaceCore: some View {
        let hasOverlay = comparison.isActive || storage.isActive

        return VStack(spacing: 0) {
            WorkspaceTabBarView(
                session: workspaceSession,
                canClose: { id in
                    guard let tab = workspaceSession.tabs.first(where: { $0.id == id }) else {
                        return false
                    }
                    return !operationController.hasActiveOrQueuedWork(boundTo: tab.workspace)
                },
                invalidateReversalHistory: operationController.invalidateReversalHistory(for:),
                teardown: teardownActiveWorkspace,
                isModalPresented: workspaceModalIsPresented,
                isTextEditing: workspace.activeTextEditingSession != nil,
                profilesPresented: $profilesPresented
            )

            ZStack {
                ordinaryWorkspace
                    .opacity(hasOverlay ? 0 : 1)
                    .allowsHitTesting(!hasOverlay)
                    .accessibilityHidden(hasOverlay)

                if comparison.isActive {
                    ComparisonWorkspaceView(
                        workspace: workspace,
                        comparison: comparison,
                        operationController: operationController,
                        searchPresented: smartSearchIsPresented,
                        batchRenamePresented: batchRename.isPresented,
                        trashPresented: workspace.pendingTrashRequest != nil,
                        profilesPresented: profilesPresented,
                        modalPresentationState: $modalPresentationState
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

            workspaceStatusBar
        }
    }

    private var workspaceStatusBar: some View {
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
        .overlay(Divider(), alignment: .top)
        .accessibilityLabel("Active file pane")
        .accessibilityValue(workspace.activePaneID == .left ? "Left" : "Right")
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
                    getInfoInspector: getInfoInspector,
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
                    getInfoInspector: getInfoInspector,
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

    private var workspaceModalIsPresented: Bool {
        WorkspaceTabModalPolicy(
            profilesPresented: profilesPresented,
            passwordPresented: modalPresentationState.presentedPasswordRequestID != nil,
            selectionFolderPresented: modalPresentationState.isSelectionFolderPresented,
            conflictPresented: operationController.pendingConflict != nil,
            smartSearchPresented: smartSearchIsPresented,
            batchRenamePresented: batchRename.isPresented,
            pendingTrashPresented: workspace.pendingTrashRequest != nil,
            synchronizationReviewPresented: comparison.folderSynchronizationReview != .idle,
            commandPalettePresented: modalPresentationState.isCommandPalettePresented,
            namePatternPresented: modalPresentationState.isNamePatternPresented
        ).isPresented
    }

    private func teardownActiveWorkspace() {
        namePatternDidDismiss()
        WorkspaceTabTeardownActions.perform(
            stopComparison: comparison.stop,
            exitStorage: storage.exit,
            closePreview: previewCoordinator.closeAndRestoreFocus,
            dismissCommandPalette: cancelCommandPalettePresentation,
            dismissSmartSearch: { smartSearch.dismiss(owner: smartSearchOwner) },
            dismissBatchRename: batchRename.dismiss,
            dismissSelectionFolder: selectionFolder.dismiss,
            dismissSynchronizationReview: comparison.cancelFolderSynchronizationReview,
            dismissPendingTrash: workspace.dismissTrashConfirmation,
            endTextEditing: {
                guard let editing = workspace.activeTextEditingSession else { return }
                workspace.endTextEditing(editing)
            },
            cancelPassword: {
                guard let request = passwordCoordinator.pendingRequest else { return }
                passwordCoordinator.cancel(requestID: request.id)
            }
        )
    }

    private var pendingConflict: Binding<IdentifiedFileConflict?> {
        Binding {
            guard modalPresentationState.allowsOtherModalPresentation,
                  !smartSearchIsPresented,
                  !batchRename.isPresented,
                  !selectionFolder.isPresented,
                  comparison.folderSynchronizationReview == .idle
            else { return nil }
            return operationController.pendingConflict.map(IdentifiedFileConflict.init)
        } set: { item in
            if item == nil,
               modalPresentationState.allowsOtherModalPresentation,
               !smartSearchIsPresented,
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
                && smartSearchIsPresented
        } set: { isPresented in
            if !isPresented,
               modalPresentationState.allowsOtherModalPresentation,
               operationController.pendingConflict == nil,
               !batchRename.isPresented,
               !selectionFolder.isPresented {
                smartSearch.dismiss(owner: smartSearchOwner)
            }
        }
    }

    private var batchRenamePresentation: Binding<Bool> {
        Binding {
            modalPresentationState.allowsOtherModalPresentation
                && operationController.pendingConflict == nil
                && !smartSearchIsPresented
                && !selectionFolder.isPresented
                && batchRename.isPresented
        } set: { isPresented in
            if !isPresented,
               modalPresentationState.allowsOtherModalPresentation,
               operationController.pendingConflict == nil,
               !smartSearchIsPresented,
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
                searchPresented: smartSearchIsPresented,
                batchRenamePresented: batchRename.isPresented,
                selectionFolderPresented: selectionFolder.isPresented,
                synchronizationReviewPresented: comparison.folderSynchronizationReview != .idle
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
                    searchPresented: smartSearchIsPresented,
                    batchRenamePresented: batchRename.isPresented,
                    passwordPresented: passwordCoordinator.pendingRequest != nil,
                    synchronizationReviewPresented: comparison.folderSynchronizationReview != .idle
                )
        } set: { isPresented in
            if !isPresented {
                selectionFolder.dismiss()
            }
        }
    }

    private var trashConfirmationIsPresented: Binding<Bool> {
        Binding {
            !modalPresentationState.isCommandPalettePresented
                && !modalPresentationState.isNamePatternPresented
                && workspace.pendingTrashRequest != nil
        } set: { isPresented in
            if !isPresented, !modalPresentationState.isNamePatternPresented {
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

    private var profilesPresentation: Binding<Bool> {
        Binding {
            !modalPresentationState.isCommandPalettePresented
                && !modalPresentationState.isNamePatternPresented && profilesPresented
        } set: { isPresented in
            if isPresented {
                guard !modalPresentationState.isCommandPalettePresented,
                      !modalPresentationState.isNamePatternPresented else { return }
                profilesPresented = true
            } else {
                profilesPresented = false
            }
        }
    }

    private var commandPalettePresentation: Binding<Bool> {
        Binding {
            modalPresentationState.isCommandPalettePresented && commandPalette.isPresented
        } set: { isPresented in
            if !isPresented, commandPalette.isPresented {
                commandPalette.dismiss()
            }
        }
    }

    private func presentNamePattern() {
        guard workspace.activeTextEditingSession == nil,
              !comparison.isActive,
              !storage.isActive,
              !workspace.activePane.isFilterPresented,
              !workspace.activePane.isLoading,
              !workspaceModalIsPresented,
              !selectionFolder.isPresented,
              passwordCoordinator.pendingRequest == nil,
              modalPresentationState.beginNamePatternPresentation()
        else { return }
        let request = NamePatternSelectionRequest(workspace: workspace, tabID: workspaceSession.activeTabID)
        workspace.beginTextEditing(request.editingSession)
        namePatternRequest = request
        namePatternPresented = true
    }

    private func namePatternDidDismiss() {
        guard let request = namePatternRequest else { return }
        namePatternRequest = nil
        namePatternPresented = false
        modalPresentationState.endNamePatternPresentation()
        request.finish(in: workspace, tabID: workspaceSession.activeTabID)
    }

    private func presentCommandPalette() {
        guard workspace.activeTextEditingSession == nil,
              !workspaceModalIsPresented,
              !selectionFolder.isPresented,
              passwordCoordinator.pendingRequest == nil,
              modalPresentationState.beginCommandPalettePresentation()
        else { return }
        let pane = workspace.activePane
        commandPaletteOrigin = CommandPaletteOrigin(
            tabID: workspaceSession.activeTabID,
            paneID: workspace.activePaneID
        )
        let favoriteCandidates = favorites.records.compactMap { record -> CommandPaletteFavoriteCandidate? in
            let resolution = favorites.resolution(for: record)
            guard case .available = resolution else { return nil }
            return CommandPaletteFavoriteCandidate(record: record, resolution: resolution)
        }
        commandPalette.present(items: CommandPaletteBuilder.build(
            currentDirectory: pane.currentDirectory,
            backHistory: pane.backHistory,
            forwardHistory: pane.forwardHistory,
            favorites: favoriteCandidates,
            profiles: workspaceSession.profiles,
            savedSearches: smartSearch.savedSearches
        ))
    }

    private func cancelCommandPalettePresentation() {
        commandPalette.dismiss()
        commandPaletteOrigin = nil
        modalPresentationState.endCommandPalettePresentation()
    }

    private func commandPaletteDidDismiss() {
        let action = commandPalette.takePendingAction()
        let origin = commandPaletteOrigin
        commandPaletteOrigin = nil
        modalPresentationState.endCommandPalettePresentation()
        guard let origin,
              CommandPaletteActionRouting.originIsCurrent(
                  origin,
                  activeTabID: workspaceSession.activeTabID,
                  activePaneID: workspace.activePaneID
              )
        else { return }
        let originPane = origin.paneID == .left ? workspace.left : workspace.right
        guard let action else {
            originPane.requestTableFocus()
            return
        }
        guard let route = CommandPaletteActionRouting.route(
            action,
            profiles: workspaceSession.profiles.map(\.id),
            savedSearchIDs: smartSearch.savedSearches.map(\.id)
        ) else {
            originPane.requestTableFocus()
            return
        }
        switch route {
        case let .navigate(url):
            Task { await originPane.navigate(to: url) }
        case .createFolder:
            Task {
                _ = await WorkspaceCommandActions.createFolder(
                    in: originPane,
                    workspace: workspace,
                    operationController: operationController
                )
            }
        case .createFile:
            Task {
                _ = await WorkspaceCommandActions.createFile(
                    in: originPane,
                    workspace: workspace,
                    operationController: operationController
                )
            }
        case .showFilter:
            WorkspaceFilterCommandActions.showFilter(in: workspace, canNavigate: true)
        case .showSmartSearch:
            presentSmartSearch()
        case let .openProfile(id):
            _ = WorkspaceTabCommandActions.openProfile(
                id,
                in: workspaceSession,
                isModalPresented: false,
                isTextEditing: false,
                allowsCurrentModalOwner: false,
                teardown: teardownActiveWorkspace
            )
        case let .openSavedSearch(id):
            guard let record = smartSearch.savedSearches.first(where: { $0.id == id }) else { return }
            _ = smartSearch.openSavedSearch(record, owner: smartSearchOwner)
        }
    }

    private var smartSearchIsPresented: Bool {
        smartSearch.isPresented(for: smartSearchOwner)
    }

    private func presentSmartSearch() {
        guard workspace.activeTextEditingSession == nil, !workspaceModalIsPresented else { return }
        _ = smartSearch.present(initialRoot: workspace.activePane.currentDirectory, owner: smartSearchOwner)
    }
}
