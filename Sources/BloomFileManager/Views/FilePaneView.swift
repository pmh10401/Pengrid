import AppKit
import SwiftUI

enum FilePanePath {
    static func expandedPath(for draft: String) -> String? {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NSString(string: draft).expandingTildeInPath
    }
}

@MainActor
enum PaneFilterFocusRouting {
    static func handle(
        isFocused: Bool,
        onActivate: () -> Void,
        onBeginEditing: () -> Void,
        onEndEditing: () -> Void
    ) {
        if isFocused {
            onActivate()
            onBeginEditing()
        } else {
            onEndEditing()
        }
    }
}

@MainActor
enum PaneEscapeRouting {
    @discardableResult
    static func handle(
        isFilterPresented: Bool,
        dismissFilter: () -> Void,
        otherwise: () -> Void = {}
    ) -> Bool {
        guard isFilterPresented else {
            otherwise()
            return false
        }
        dismissFilter()
        return true
    }
}

@MainActor
enum PaneFilterDismissalRouting {
    static func handle(
        clearFieldFocus: () -> Void,
        endEditing: () -> Void,
        dismissFilter: () -> Void,
        requestTableFocus: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        clearFieldFocus()
        endEditing()
        dismissFilter()
        return Task { @MainActor in
            await Task.yield()
            requestTableFocus()
        }
    }
}

@MainActor
enum FileContextActionTargetRouting {
    static func pane(with paneID: PaneID, in workspace: WorkspaceState) -> FilePaneState {
        paneID == .left ? workspace.left : workspace.right
    }
}

@MainActor
enum OpenWithMenuPresentation {
    static func make(
        policy: FileContextMenuPolicy,
        selectedItems: [FileItem],
        provider: any OpenWithApplicationProviding
    ) -> FileContextMenuPresentation {
        guard policy.openWith.isVisible,
              selectedItems.count == 1,
              let item = selectedItems.first
        else {
            return FileContextMenuPresentation(policy: policy)
        }
        guard policy.openWith.isEnabled else {
            return FileContextMenuPresentation(
                policy: policy,
                openWithAvailability: policy.openWith
            )
        }
        guard let applications = provider.cachedApplications(for: item) else {
            provider.requestApplications(for: item)
            return FileContextMenuPresentation(
                policy: policy,
                openWithAvailability: .disabled(reason: "Compatible applications are loading.")
            )
        }
        return FileContextMenuPresentation(
            policy: policy,
            openWithApplications: applications,
            openWithAvailability: applications.isEmpty
                ? .disabled(reason: "No compatible applications found.")
                : .enabled
        )
    }
}

struct FilePaneView: View {
    let paneID: PaneID
    let state: FilePaneState
    let workspace: WorkspaceState
    let operationController: FileOperationController
    let batchRename: BatchRenameModel
    let cloudLocations: CloudLocationsStore
    let favorites: FavoritesStore
    let materializer: any CloudMaterializing
    let fileSystem: any FileSystemAccess
    let accessCoordinator: CloudLocationScopedAccessCoordinator
    let previewCoordinator: WorkspacePreviewCoordinator
    @State private var openWithProvider: any OpenWithApplicationProviding = OpenWithApplicationProvider()
    let applicationOpener: any ApplicationOpening = LiveApplicationOpener()
    let isActive: Bool
    let onActivate: () -> Void
    let onRequestTrashConfirmation: ([URL]) -> Void

    @State private var pathDraft = ""
    @State private var pathError: String?
    @State private var pathEditingSession: WorkspaceTextEditingSession?
    @State private var filterEditingSession: WorkspaceTextEditingSession?
    @State private var inlineEditingSession: WorkspaceTextEditingSession?
    @State private var favoriteError: String?
    @FocusState private var pathFieldIsFocused: Bool
    @FocusState private var filterFieldIsFocused: Bool

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    onActivate()
                    Task { await state.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canGoBack)
                .help("Back")
                .accessibilityLabel("Back")

                Button {
                    onActivate()
                    Task { await state.goForward() }
                } label: {
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")

                if state.isEditingPath {
                    TextField("Path", text: $pathDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($pathFieldIsFocused)
                        .onSubmit { submitPath() }
                        .onExitCommand {
                            handleEscape(otherwise: cancelPathEditing)
                        }
                } else {
                    Button {
                        beginPathEditing()
                    } label: {
                        Text(state.currentDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Edit location (Command-L)")
                    .contextMenu {
                        Button("Add to Favorites") {
                            onActivate()
                            addFavorite(state.currentDirectory)
                        }
                        .disabled(favorites.containsExactURL(state.currentDirectory))
                    }
                }

                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .help("Loading")
                } else if let message = pathError ?? state.errorMessage {
                    HStack(spacing: 6) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.red)
                            .help(message)
                        Button("Go to \(workspace.fallbackDisplayName(for: paneID))") {
                            let fallback = workspace.fallbackURL(for: paneID)
                            Task { await state.navigate(to: fallback, recordHistory: false) }
                        }
                        .controlSize(.small)
                        .accessibilityHint("Opens the safe fallback folder for this pane")
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            if state.isFilterPresented {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .accessibilityHidden(true)
                    TextField(
                        "Filter files",
                        text: Binding(
                            get: { state.filterQuery },
                            set: { state.updateFilterQuery($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFieldIsFocused)
                    .onExitCommand { handleEscape() }
                    .accessibilityIdentifier(
                        paneID == .left
                            ? AccessibilityIdentifiers.leftPaneFilter
                            : AccessibilityIdentifiers.rightPaneFilter
                    )
                    .accessibilityLabel(PaneFilterAccessibilityPresentation.fieldLabel(for: paneID))

                    Text(PaneFilterAccessibilityPresentation.resultCount(state.filterResultCount))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            PaneFilterAccessibilityPresentation.resultCountLabel(for: paneID)
                        )
                        .accessibilityIdentifier(
                            paneID == .left
                                ? AccessibilityIdentifiers.leftPaneFilterResults
                                : AccessibilityIdentifiers.rightPaneFilterResults
                        )

                    Button("Close") { dismissFilter() }
                        .accessibilityLabel(PaneFilterAccessibilityPresentation.closeLabel(for: paneID))
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }

            fileTable
        }
        .overlay {
            Rectangle()
                .stroke(isActive ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onExitCommand { handleEscape() }
        .onChange(of: state.isEditingPath) { _, isEditing in
            if isEditing {
                pathDraft = state.currentDirectory.path
                pathError = nil
                Task { @MainActor in
                    pathFieldIsFocused = true
                }
            } else {
                pathDraft = state.currentDirectory.path
                pathError = nil
                pathFieldIsFocused = false
            }
        }
        .onChange(of: pathFieldIsFocused) { _, isFocused in
            if isFocused {
                beginPathEditingSession()
            } else {
                endPathEditingSession()
            }
        }
        .onChange(of: state.filterFocusRequestID) { _, requestID in
            guard requestID != nil else { return }
            onActivate()
            Task { @MainActor in
                guard state.isFilterPresented else { return }
                filterFieldIsFocused = true
            }
        }
        .onChange(of: filterFieldIsFocused) { _, isFocused in
            PaneFilterFocusRouting.handle(
                isFocused: isFocused,
                onActivate: onActivate,
                onBeginEditing: beginFilterEditingSession,
                onEndEditing: endFilterEditingSession
            )
        }
        .onChange(of: state.isFilterPresented) { _, isPresented in
            guard !isPresented else { return }
            filterFieldIsFocused = false
            endFilterEditingSession()
        }
        .onAppear {
            if pathFieldIsFocused {
                beginPathEditingSession()
            }
            if filterFieldIsFocused {
                beginFilterEditingSession()
            }
        }
        .onDisappear {
            if let pathEditingSession {
                workspace.endTextEditing(pathEditingSession)
                self.pathEditingSession = nil
            }
            if let filterEditingSession {
                workspace.endTextEditing(filterEditingSession)
                self.filterEditingSession = nil
            }
            if let inlineEditingSession {
                workspace.endTextEditing(inlineEditingSession)
                self.inlineEditingSession = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            paneID == .left
                ? AccessibilityIdentifiers.leftPane
                : AccessibilityIdentifiers.rightPane
        )
        .accessibilityLabel(PaneAccessibilityPresentation.label(for: paneID))
        .accessibilityValue(PaneAccessibilityPresentation.value(isActive: isActive))
        .alert("Could Not Add Favorite", isPresented: Binding(
            get: { favoriteError != nil },
            set: { if !$0 { favoriteError = nil } }
        )) {
            Button("OK") { favoriteError = nil }
        } message: {
            Text(favoriteError ?? "The folder could not be added to Favorites.")
        }
    }

    private var fileTable: some View {
        @Bindable var state = state

        return FileTableView(
            items: state.visibleItems,
            selection: $state.selection,
            projectionToken: state.acceptedProjectionToken,
            itemIndexByURL: state.visibleIndexByURL,
            sort: state.sort,
            directory: state.currentDirectory,
            focusRequestID: state.focusRequestID,
            renameRequestID: state.renameRequestID,
            scrollRequest: state.scrollRestoreRequest,
            isOperationRunning: operationController.isRunning,
            isTextEditing: workspace.activeTextEditingSession != nil,
            onActivatePane: onActivate,
            onOpen: open,
            onOpenSelection: open,
            onSortChange: { state.sort = $0 },
            contextMenuPresentation: { contextMenuPresentation(for: $0) },
            onContextAction: { routeContextAction($0, items: $1) },
            onProjectionApplicationAttempt: state.recordTableApplicationAttempt,
            onProjectionApplied: state.recordTableApplicationCompleted,
            onCancel: { handleEscape() },
            onFirstVisibleItemChange: state.recordFirstVisibleItem,
            onConsumeScrollRequest: state.consumeScrollRestoreRequest,
            onConsumeRenameRequest: state.consumeInlineRenameRequest,
            onInlineEditingEvent: handleInlineEditingEvent,
            onDiscardRename: state.cancelPendingRename,
            onCommitRename: commitRename,
            onDrop: performDrop,
            canAddToFavorites: { item in
                FavoriteAddPolicy.canAdd(item, containsExactURL: favorites.containsExactURL)
            },
            onAddToFavorites: addFavorite,
            onCreateFolder: createFolder,
            onRequestRename: {
                Task { _ = await operationController.requestRename(in: workspace) }
            },
            onRequestBatchRename: requestBatchRename,
            onCopy: copySelection,
            onPaste: paste,
            onCompress: compressSelection,
            onCompressProtected: compressProtectedSelection,
            onExtract: extractSelection,
            onRequestTrashConfirmation: requestTrashConfirmation
        )
    }

    private func beginPathEditing() {
        onActivate()
        state.isEditingPath = true
    }

    private func cancelPathEditing() {
        pathDraft = state.currentDirectory.path
        pathError = nil
        state.isEditingPath = false
        pathFieldIsFocused = false
    }

    private func submitPath() {
        guard let expandedPath = FilePanePath.expandedPath(for: pathDraft) else {
            pathError = "The location is not an existing directory."
            return
        }
        let destination = URL(filePath: expandedPath, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            pathError = "The location is not an existing directory."
            return
        }

        pathDraft = destination.path
        pathError = nil
        state.isEditingPath = false
        pathFieldIsFocused = false
        Task { await state.navigate(to: destination) }
    }

    private func open(_ item: FileItem) {
        open([item])
    }

    private func contextMenuPresentation(for items: [FileItem]) -> FileContextMenuPresentation {
        let oppositePane = FileContextActionTargetRouting.pane(
            with: oppositePaneID,
            in: workspace
        )
        let policy = FileContextMenuPolicy(.init(
            workspaceCommandPolicy: WorkspaceCommandPolicy(
                selectionCount: items.count,
                isOperationRunning: operationController.isRunning,
                pasteboardHasFileURLs: FileURLPasteboard.containsFileURLs(in: .general),
                selectedItems: items,
                isTextEditing: workspace.activeTextEditingSession != nil
            ),
            selectedItems: items,
            sourceDirectory: state.currentDirectory,
            oppositeDirectory: oppositePane.currentDirectory,
            sourceCapability: cloudLocations.localFileOperationCapability(for: state.currentDirectory),
            oppositeCapability: cloudLocations.localFileOperationCapability(for: oppositePane.currentDirectory),
            isExclusiveOperationActive: false
        ))
        return OpenWithMenuPresentation.make(
            policy: policy,
            selectedItems: items,
            provider: openWithProvider
        )
    }

    private func routeContextAction(_ action: ContextActionKind, items: [FileItem]) {
        let capturedApplicationURL: URL?
        switch action {
        case let .openWith(applicationURL):
            capturedApplicationURL = applicationURL.standardizedFileURL
        case .quickLook, .openInOtherPane:
            capturedApplicationURL = nil
        default:
            return
        }
        let targetPane = FileContextActionTargetRouting.pane(with: oppositePaneID, in: workspace)
        let sourceDirectory = state.currentDirectory
        let oppositeDirectory = targetPane.currentDirectory
        guard let draft = ContextActionDraft(
            sources: items,
            sourcePaneID: paneID,
            oppositePaneID: oppositePaneID,
            sourceDirectory: sourceDirectory,
            oppositeDirectory: oppositeDirectory,
            sourceCapability: cloudLocations.localFileOperationCapability(for: sourceDirectory),
            oppositeCapability: cloudLocations.localFileOperationCapability(for: oppositeDirectory)
        ) else { return }
        let router = FileContextActionRouter(
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator,
            materializer: materializer,
            applicationOpener: applicationOpener
        )

        Task { @MainActor in
            guard let snapshot = await router.capture(draft) else { return }
            switch action {
            case .quickLook:
                _ = await router.quickLook(snapshot, previewCoordinator: previewCoordinator)
            case .openInOtherPane:
                _ = await router.openInOtherPane(snapshot, targetPane: targetPane)
            case .openWith:
                guard let capturedApplicationURL else { return }
                _ = await router.openWith(snapshot, applicationURL: capturedApplicationURL)
            default:
                return
            }
        }
    }

    private var oppositePaneID: PaneID {
        paneID == .left ? .right : .left
    }

    private func open(_ items: [FileItem]) {
        onActivate()
        Task {
            await WorkspaceOpenActions.open(
                items,
                in: state,
                materializer: materializer,
                accessCoordinator: accessCoordinator
            )
        }
    }

    private func createFolder() {
        onActivate()
        Task {
            _ = await WorkspaceCommandActions.createFolder(
                in: state,
                workspace: workspace,
                operationController: operationController
            )
        }
    }

    private func commitRename(_ source: URL, _ name: String) {
        onActivate()
        _ = operationController.commitPendingRename(
            in: state,
            to: name,
            workspace: workspace
        )
    }

    private func requestBatchRename() {
        onActivate()
        let selected = state.selection
        let items = state.visibleItems.filter { selected.contains($0.url) }
        guard items.count == selected.count, items.count >= 2 else { return }
        let directory = state.currentDirectory
        let capability = cloudLocations.batchRenameCapability(for: directory)
        Task {
            await batchRename.present(
                items: items,
                in: directory,
                capability: capability
            )
        }
    }

    private func copySelection() {
        onActivate()
        FileURLPasteboard.write(
            state.selection.sorted { $0.path < $1.path },
            to: .general
        )
    }

    private func paste() {
        onActivate()
        let urls = FileURLPasteboard.read(from: .general)
        guard !urls.isEmpty else { return }
        Task {
            _ = await operationController.runTransfer(
                urls,
                to: state.currentDirectory,
                mode: .copy,
                workspace: workspace
            )
        }
    }

    private func compressSelection(format: ArchiveFormat = .zip) {
        onActivate()
        Task {
            _ = await operationController.compressSelection(workspace, format: format)
        }
    }

    private func compressProtectedSelection() {
        onActivate()
        Task {
            _ = await WorkspaceArchiveCommandActions.compressProtectedZIP(
                workspace,
                operationController: operationController
            )
        }
    }

    private func extractSelection() {
        onActivate()
        Task {
            _ = await operationController.extractSelection(workspace)
        }
    }

    private func performDrop(_ urls: [URL], _ destination: URL, _ intent: DropIntent) {
        onActivate()
        Task {
            _ = await operationController.runTransfer(
                urls,
                to: destination,
                mode: intent.transferMode,
                workspace: workspace
            )
        }
    }

    private func addFavorite(_ url: URL) {
        do {
            try favorites.add(url)
        } catch {
            favoriteError = error.localizedDescription
        }
    }

    private func requestTrashConfirmation() {
        onActivate()
        let urls = state.selection.sorted { $0.path < $1.path }
        Task {
            await operationController.requestTrashConfirmation(for: urls, workspace: workspace)
        }
    }

    private func handleInlineEditingEvent(_ event: InlineTextEditingEvent) {
        switch event {
        case let .began(token):
            let session = WorkspaceTextEditingSession(
                id: token,
                paneID: paneID,
                kind: .inlineName
            )
            inlineEditingSession = session
            workspace.beginTextEditing(session)
        case let .ended(token):
            let session = WorkspaceTextEditingSession(
                id: token,
                paneID: paneID,
                kind: .inlineName
            )
            workspace.endTextEditing(session)
            if inlineEditingSession == session {
                inlineEditingSession = nil
            }
        }
    }

    private func beginPathEditingSession() {
        guard pathEditingSession == nil else { return }
        let session = WorkspaceTextEditingSession(paneID: paneID, kind: .path)
        pathEditingSession = session
        workspace.beginTextEditing(session)
    }

    private func endPathEditingSession() {
        guard let session = pathEditingSession else { return }
        pathEditingSession = nil
        workspace.endTextEditing(session)
    }

    private func beginFilterEditingSession() {
        guard filterEditingSession == nil else { return }
        let session = WorkspaceTextEditingSession(paneID: paneID, kind: .filter)
        filterEditingSession = session
        workspace.beginTextEditing(session)
    }

    private func endFilterEditingSession() {
        guard let session = filterEditingSession else { return }
        filterEditingSession = nil
        workspace.endTextEditing(session)
    }

    private func dismissFilter() {
        _ = PaneFilterDismissalRouting.handle(
            clearFieldFocus: { filterFieldIsFocused = false },
            endEditing: endFilterEditingSession,
            dismissFilter: state.dismissFiltering,
            requestTableFocus: state.requestTableFocus
        )
    }

    @discardableResult
    private func handleEscape(otherwise: () -> Void = {}) -> Bool {
        PaneEscapeRouting.handle(
            isFilterPresented: state.isFilterPresented,
            dismissFilter: dismissFilter,
            otherwise: otherwise
        )
    }
}
