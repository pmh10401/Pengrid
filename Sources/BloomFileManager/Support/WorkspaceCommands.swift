import AppKit
import SwiftUI

enum DropIntent: Equatable, Sendable {
    case copy
    case move

    static func resolve(modifiers: NSEvent.ModifierFlags) -> DropIntent {
        modifiers.contains(.command) ? .move : .copy
    }

    var transferMode: TransferMode {
        switch self {
        case .copy: .copy
        case .move: .move
        }
    }
}

struct WorkspaceCommandPolicy: Equatable {
    let selectionCount: Int
    let isOperationRunning: Bool
    let pasteboardHasFileURLs: Bool
    var selectedItems: [FileItem] = []
    var isTextEditing = false

    var canCreateFolder: Bool { !isTextEditing }
    var canRename: Bool { !isOperationRunning && !isTextEditing && selectionCount == 1 }
    var canBatchRename: Bool {
        !isOperationRunning
            && !isTextEditing
            && selectionCount >= 2
            && selectedItems.count == selectionCount
    }
    var canCopy: Bool { !isTextEditing && selectionCount > 0 }
    var canPaste: Bool { !isTextEditing && pasteboardHasFileURLs }
    var canTrash: Bool { !isTextEditing && selectionCount > 0 }
    var canOpen: Bool { !isTextEditing && selectionCount > 0 }
    var canQuickLook: Bool { !isTextEditing && selectionCount > 0 }
    var canClosePreview: Bool { !isTextEditing }
    var canNavigate: Bool { !isTextEditing }
    var canCompress: Bool {
        canRunArchiveOperation && ArchiveSelectionEligibility.canCompress(selectedItems)
    }

    /// Password-protected ZIP uses the same selection and editing policy as
    /// ordinary compression. Keep this as a named projection so every menu
    /// route can express that relationship without duplicating policy logic.
    var canCompressProtectedZIP: Bool { canCompress }

    var canExtract: Bool {
        canRunArchiveOperation && ArchiveSelectionEligibility.canExtract(selectedItems)
    }

    private var canRunArchiveOperation: Bool {
        !isTextEditing
            && selectionCount > 0
            && selectedItems.count == selectionCount
    }

    var copyRoute: PasteboardCommandRoute {
        if isTextEditing { return .textResponder }
        return canCopy ? .fileSelection : .unavailable
    }

    var pasteRoute: PasteboardCommandRoute {
        if isTextEditing { return .textResponder }
        return canPaste ? .fileSelection : .unavailable
    }
}

enum PasteboardCommandRoute: Equatable {
    case textResponder
    case fileSelection
    case unavailable
}

/// Shared, privacy-safe VoiceOver wording for context actions. The action
/// snapshot owns paths, so command presentation deliberately describes only
/// the selection count, pane role, and policy state.
enum ContextActionAccessibilityPresentation {
    static func value(
        action: ContextActionKind,
        itemCount: Int,
        destinationPaneID: PaneID,
        availability: ContextActionAvailability
    ) -> String {
        var parts = [itemCount == 1 ? "1 selected item" : "\(itemCount) selected items"]
        if usesOtherPane(action) {
            parts.append("Destination: \(paneName(destinationPaneID)) pane")
        }
        if !availability.isEnabled, let reason = availability.disabledReason {
            parts.append("Unavailable: \(reason)")
        }
        return parts.joined(separator: ". ")
    }

    private static func usesOtherPane(_ action: ContextActionKind) -> Bool {
        switch action {
        case .openInOtherPane, .transferToOtherPane: true
        default: false
        }
    }

    private static func paneName(_ paneID: PaneID) -> String {
        paneID == .left ? "left" : "right"
    }
}

@MainActor
enum WorkspaceContextActionRouting {
    static func policy(
        items: [FileItem],
        capturedSelectionCount: Int,
        sourcePaneID: PaneID,
        workspace: WorkspaceState,
        operationController: FileOperationController,
        cloudLocations: CloudLocationsStore?
    ) -> FileContextMenuPolicy {
        let sourcePane = sourcePaneID == .left ? workspace.left : workspace.right
        let oppositePane = sourcePaneID == .left ? workspace.right : workspace.left
        return FileContextMenuPolicy(.init(
            workspaceCommandPolicy: WorkspaceCommandPolicy(
                selectionCount: capturedSelectionCount,
                isOperationRunning: operationController.isRunning,
                pasteboardHasFileURLs: FileURLPasteboard.containsFileURLs(in: .general),
                selectedItems: items,
                isTextEditing: workspace.activeTextEditingSession != nil
            ),
            selectedItems: items,
            sourceDirectory: sourcePane.currentDirectory,
            oppositeDirectory: oppositePane.currentDirectory,
            sourceCapability: cloudLocations?.localFileOperationCapability(
                for: sourcePane.currentDirectory
            ) ?? .unknown,
            oppositeCapability: cloudLocations?.localFileOperationCapability(
                for: oppositePane.currentDirectory
            ) ?? .unknown,
            isExclusiveOperationActive: false
        ))
    }

    static func draft(
        items: [FileItem],
        capturedSelectionCount: Int,
        sourcePaneID: PaneID,
        workspace: WorkspaceState,
        cloudLocations: CloudLocationsStore?
    ) -> ContextActionDraft? {
        guard items.count == capturedSelectionCount else { return nil }
        let sourcePane = sourcePaneID == .left ? workspace.left : workspace.right
        let oppositePaneID: PaneID = sourcePaneID == .left ? .right : .left
        let oppositePane = oppositePaneID == .left ? workspace.left : workspace.right
        return ContextActionDraft(
            sources: items,
            sourcePaneID: sourcePaneID,
            oppositePaneID: oppositePaneID,
            sourceDirectory: sourcePane.currentDirectory,
            oppositeDirectory: oppositePane.currentDirectory,
            sourceCapability: cloudLocations?.localFileOperationCapability(
                for: sourcePane.currentDirectory
            ) ?? .unknown,
            oppositeCapability: cloudLocations?.localFileOperationCapability(
                for: oppositePane.currentDirectory
            ) ?? .unknown
        )
    }
}

extension ContextActionKind {
    func availability(in policy: FileContextMenuPolicy) -> ContextActionAvailability {
        switch self {
        case .quickLook: policy.quickLook
        case .openWith: policy.openWith
        case .openInOtherPane: policy.openInOtherPane
        case .transferToOtherPane(.copy): policy.copyToOtherPane
        case .transferToOtherPane(.move): policy.moveToOtherPane
        case .showInFinder: policy.showInFinder
        case .copyPath: policy.copyPath
        case .duplicate: policy.duplicate
        case .encloseSelection: policy.encloseSelection
        }
    }
}

@MainActor
enum WorkspaceCommandActions {
    @discardableResult
    static func createFolder(
        in pane: FilePaneState,
        workspace: WorkspaceState,
        operationController: FileOperationController
    ) async -> Bool {
        let existing = Set(pane.items.map(\.name))
        let name = KeepBothNamer.availableName(for: "New Folder", existing: existing)
        return await operationController.createFolder(
            in: pane.currentDirectory,
            named: name,
            workspace: workspace,
            beginInlineRenameIn: pane
        )
    }
}

@MainActor
enum WorkspaceArchiveCommandActions {
    @discardableResult
    static func compressProtectedZIP(
        _ workspace: WorkspaceState,
        operationController: FileOperationController
    ) async -> Bool {
        await operationController.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        )
    }
}

@MainActor
enum WorkspaceFilterCommandActions {
    static func showFilter(in workspace: WorkspaceState, canNavigate: Bool) {
        guard canNavigate else { return }
        workspace.activePane.requestFilterFocus()
    }
}

@MainActor
enum WorkspaceSearchCommandActions {
    static func showSmartSearch(in workspace: WorkspaceState, store: SmartSearchStore) {
        store.present(initialRoot: workspace.activePane.currentDirectory)
    }
}

@MainActor
enum WorkspaceBatchRenameCommandActions {
    static func showBatchRename(
        in workspace: WorkspaceState,
        model: BatchRenameModel,
        capability: BatchRenameLocationCapability
    ) async {
        let pane = workspace.activePane
        let selected = pane.selection
        let items = pane.visibleItems.filter { selected.contains($0.url) }
        guard items.count == selected.count, items.count >= 2 else { return }
        await model.present(
            items: items,
            in: pane.currentDirectory,
            capability: capability
        )
    }
}

@MainActor
protocol WorkspaceOpening {
    func open(_ url: URL)
}

@MainActor
struct LiveWorkspaceOpener: WorkspaceOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum WorkspaceOpenActions {
    static func open(
        _ items: [FileItem],
        in pane: FilePaneState,
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        materializer: any CloudMaterializing = LiveCloudMaterializationService(),
        opener: any WorkspaceOpening = LiveWorkspaceOpener(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) async {
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: items.map(\.url))
        } catch {
            return
        }
        defer { accessLeases.forEach { $0.finish() } }
        if let directory = items.first(where: { $0.isDirectory && !$0.isPackage }) {
            await pane.navigate(to: directory.url)
        }

        let externalItems = items.filter { !$0.isDirectory || $0.isPackage }
        guard !externalItems.isEmpty else { return }
        var requests: [IdentifiedFileRequest] = []
        for item in externalItems {
            guard !Task.isCancelled,
                  let identity = try? await fileSystem.identity(of: item.url)
            else { return }
            requests.append(IdentifiedFileRequest(url: item.url, identity: identity))
        }

        let result = await materializer.materialize(
            requests,
            purpose: .open,
            progress: { _ in }
        )
        guard !Task.isCancelled,
              !result.wasCancelled,
              result.failures.isEmpty,
              let prepared = CloudOperationRequestGate.identityPreservingPreparedRequests(
                  original: requests,
                  prepared: result.preparedRequests
              )
        else { return }
        prepared.forEach { opener.open($0.url) }
    }

    static func identifiedRequests(
        for urls: [URL],
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) async -> [IdentifiedFileRequest]? {
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: urls)
        } catch {
            return nil
        }
        defer { accessLeases.forEach { $0.finish() } }
        var requests: [IdentifiedFileRequest] = []
        for url in urls {
            guard !Task.isCancelled,
                  let identity = try? await fileSystem.identity(of: url)
            else { return nil }
            requests.append(IdentifiedFileRequest(url: url, identity: identity))
        }
        return requests
    }
}

struct WorkspaceQuickLookCommandSelection: Equatable, Sendable {
    let paneID: PaneID
    let urls: [URL]
}

@MainActor
enum WorkspaceQuickLookSelectionRouting {
    static func begin(controller: QuickLookController) -> Bool {
        guard !Task.isCancelled else { return false }
        controller.invalidatePendingPreparationForSelectionChange()
        return controller.isPresenting
    }
}

@MainActor
enum WorkspaceQuickLookCommandRouting {
    static func prepareAndPresent(
        capturedSelection: WorkspaceQuickLookCommandSelection,
        currentSelection: @MainActor () -> WorkspaceQuickLookCommandSelection,
        controller: QuickLookController,
        materializer: any CloudMaterializing,
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) async {
        guard let requests = await WorkspaceOpenActions.identifiedRequests(
            for: capturedSelection.urls,
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator
        ),
        !Task.isCancelled,
        currentSelection() == capturedSelection
        else { return }
        await controller.prepareAndPresent(
            requests: requests,
            materializer: materializer
        )
    }
}

@MainActor
enum WorkspacePreviewCommandActions {
    static func closeIfPresented(
        policy: WorkspaceCommandPolicy,
        previewCoordinator: WorkspacePreviewCoordinator
    ) {
        guard policy.canClosePreview, previewCoordinator.mode != .closed else { return }
        previewCoordinator.closeAndRestoreFocus()
    }
}

@MainActor
enum TextResponderCommand {
    @discardableResult
    static func copy(to target: Any? = nil) -> Bool {
        NSApplication.shared.sendAction(#selector(NSText.copy(_:)), to: target, from: nil)
    }

    @discardableResult
    static func paste(to target: Any? = nil) -> Bool {
        NSApplication.shared.sendAction(#selector(NSText.paste(_:)), to: target, from: nil)
    }
}

@MainActor
enum FileURLPasteboard {
    static func write(_ urls: [URL], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    static func read(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? [])
            .compactMap { $0 as URL? }
    }

    static func containsFileURLs(in pasteboard: NSPasteboard) -> Bool {
        !read(from: pasteboard).isEmpty
    }
}

private struct WorkspaceFocusedValueKey: FocusedValueKey {
    typealias Value = WorkspaceState
}

private struct ComparisonFocusedValueKey: FocusedValueKey {
    typealias Value = ComparisonCoordinator
}

private struct StorageAnalysisFocusedValueKey: FocusedValueKey {
    typealias Value = StorageAnalysisStore
}

extension FocusedValues {
    var workspaceState: WorkspaceState? {
        get { self[WorkspaceFocusedValueKey.self] }
        set { self[WorkspaceFocusedValueKey.self] = newValue }
    }

    var comparisonCoordinator: ComparisonCoordinator? {
        get { self[ComparisonFocusedValueKey.self] }
        set { self[ComparisonFocusedValueKey.self] = newValue }
    }

    var storageAnalysisStore: StorageAnalysisStore? {
        get { self[StorageAnalysisFocusedValueKey.self] }
        set { self[StorageAnalysisFocusedValueKey.self] = newValue }
    }
}

struct ComparisonCommandPolicy: Equatable {
    let isActive: Bool
    let canVerifySelected: Bool
    var canCopyLeftToRight = false
    var canCopyRightToLeft = false
    var canMoveLeftToRight = false
    var canMoveRightToLeft = false

    var toggleTitle: String {
        isActive ? "Exit Comparison" : "Compare Folders"
    }

    var canVerifySelectedContents: Bool {
        isActive && canVerifySelected
    }

    var canVerifyAllContents: Bool {
        isActive
    }
}

@MainActor
enum ComparisonCommandActions {
    static func toggle(
        workspace: WorkspaceState,
        comparison: ComparisonCoordinator,
        storage: StorageAnalysisStore? = nil
    ) {
        if comparison.isActive {
            exit(workspace: workspace, comparison: comparison)
        } else {
            if let storage, storage.isActive {
                StorageInspectorCommandActions.exit(
                    workspace: workspace,
                    storage: storage
                )
            }
            comparison.start(workspace: workspace)
        }
    }

    static func exit(workspace: WorkspaceState, comparison: ComparisonCoordinator) {
        let activePane = workspace.activePane
        comparison.stop()
        Task { @MainActor in
            activePane.requestTableFocus()
        }
    }
}

struct StorageInspectorCommandPolicy: Equatable {
    let isActive: Bool
    let phase: StorageAnalysisPhase

    var canStart: Bool {
        guard isActive else { return false }
        switch phase {
        case .idle, .complete, .paused, .cancelled:
            return true
        case .inactive, .scanning, .verifying:
            return false
        }
    }

    var canCancel: Bool {
        isActive && (phase == .scanning || phase == .verifying)
    }

    var toggleTitle: String {
        isActive ? "Exit Storage Inspector" : "Enter Storage Inspector"
    }
}

@MainActor
enum StorageInspectorCommandActions {
    static func toggle(
        workspace: WorkspaceState,
        comparison: ComparisonCoordinator,
        storage: StorageAnalysisStore
    ) {
        if storage.isActive {
            exit(workspace: workspace, storage: storage)
        } else {
            comparison.stop()
            storage.enter()
        }
    }

    static func exit(
        workspace: WorkspaceState,
        storage: StorageAnalysisStore
    ) {
        let activePane = workspace.activePane
        storage.exit()
        Task { @MainActor in
            activePane.requestTableFocus()
        }
    }

    static func chooseLocation(
        storage: StorageAnalysisStore,
        options: StorageScanOptions = .init()
    ) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Storage Location"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let root = panel.url else { return }
        Task { await storage.requestScan(at: root, options: options) }
    }

    static func start(
        storage: StorageAnalysisStore,
        options: StorageScanOptions = .init()
    ) {
        if let root = storage.rootURL {
            Task { await storage.requestScan(at: root, options: options) }
        } else {
            chooseLocation(storage: storage, options: options)
        }
    }

}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceState) private var workspace
    @FocusedValue(\.comparisonCoordinator) private var comparison
    @FocusedValue(\.storageAnalysisStore) private var focusedStorage

    let quickLookController: QuickLookController
    var previewCoordinator: WorkspacePreviewCoordinator? = nil
    let operationController: FileOperationController
    var contextActionRouter: FileContextActionRouter? = nil
    var openWithProvider: (any OpenWithApplicationProviding)? = nil
    var selectionFolder: SelectionFolderModel? = nil
    var smartSearch: SmartSearchStore?
    let storage: StorageAnalysisStore
    let storageCleanupController: StorageCleanupController
    var materializer: any CloudMaterializing = LiveCloudMaterializationService()
    var fileSystem: any FileSystemAccess
    var workspaceOpener: any WorkspaceOpening = LiveWorkspaceOpener()
    var accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    var batchRename: BatchRenameModel? = nil
    var cloudLocations: CloudLocationsStore? = nil

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") {
                createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(workspace == nil || !policy.canCreateFolder)
        }

        CommandGroup(after: .newItem) {
            Button("Open") {
                openSelection()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!policy.canOpen)

            Button("Quick Look") {
                dispatchContextAction(.quickLook)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!contextPolicy.quickLook.isEnabled || previewCoordinator == nil)

            Button("Close Preview") {
                guard let previewCoordinator else { return }
                WorkspacePreviewCommandActions.closeIfPresented(
                    policy: policy,
                    previewCoordinator: previewCoordinator
                )
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(
                !policy.canClosePreview
                    || previewCoordinator == nil
                    || previewCoordinator?.mode == .closed
            )

            Divider()

            Button("Rename") {
                requestRename()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!policy.canRename)

            Button("Rename with F2") {
                requestRename()
            }
            .keyboardShortcut(KeyEquivalent(Character("\u{F705}")), modifiers: [])
            .disabled(!policy.canRename)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                copy()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(policy.copyRoute == .unavailable)

            Button("Paste") {
                paste()
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(workspace == nil || policy.pasteRoute == .unavailable)
        }

        CommandGroup(after: .pasteboard) {
            Button("Filter Files") {
                guard let workspace, policy.canNavigate else { return }
                WorkspaceFilterCommandActions.showFilter(in: workspace, canNavigate: policy.canNavigate)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(workspace == nil || !policy.canNavigate)

            Button("Smart Search…") {
                guard let workspace, let smartSearch, policy.canNavigate else { return }
                WorkspaceSearchCommandActions.showSmartSearch(
                    in: workspace,
                    store: smartSearch
                )
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(workspace == nil || smartSearch == nil || !policy.canNavigate)
        }

        CommandMenu("File Operations") {
            contextActionCommands

            Divider()

            Button("Batch Rename…") {
                guard let workspace, let batchRename, policy.canBatchRename else { return }
                let capability = cloudLocations?.batchRenameCapability(
                    for: workspace.activePane.currentDirectory
                ) ?? .writable
                Task {
                    await WorkspaceBatchRenameCommandActions.showBatchRename(
                        in: workspace,
                        model: batchRename,
                        capability: capability
                    )
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(!policy.canBatchRename)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceBatchRename)

            Divider()

            Button("Compress to ZIP") {
                guard let workspace, policy.canCompress else { return }
                Task {
                    _ = await operationController.compressSelection(workspace)
                }
            }
            .disabled(!policy.canCompress)

            Button("Compress as Password-Protected ZIP…") {
                guard let workspace, policy.canCompressProtectedZIP else { return }
                Task {
                    _ = await WorkspaceArchiveCommandActions.compressProtectedZIP(
                        workspace,
                        operationController: operationController
                    )
                }
            }
            .disabled(!policy.canCompressProtectedZIP)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceCompressProtectedZIP)

            Menu("Compress as…") {
                ForEach(ArchiveFormat.allCases, id: \.self) { format in
                    Button(format.displayName) {
                        guard let workspace, policy.canCompress else { return }
                        Task {
                            _ = await operationController.compressSelection(workspace, format: format)
                        }
                    }
                }
            }
            .disabled(!policy.canCompress)

            Button("Extract Archive") {
                guard let workspace, policy.canExtract else { return }
                Task {
                    _ = await operationController.extractSelection(workspace)
                }
            }
            .disabled(!policy.canExtract)

            Divider()

            Button("Move to Trash…") {
                guard let workspace, policy.canTrash else { return }
                Task {
                    await operationController.requestTrashConfirmation(
                        for: workspace.selectedURLsForCommands,
                        workspace: workspace
                    )
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!policy.canTrash)

            Button("Move to Trash Immediately") {
                guard let workspace, policy.canTrash else { return }
                let selectedURLs = workspace.selectedURLsForCommands
                Task {
                    _ = await operationController.trashImmediately(
                        selectedURLs,
                        workspace: workspace
                    )
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!policy.canTrash)
        }

        CommandMenu("Go") {
            Button("Back") {
                guard policy.canNavigate, let pane = workspace?.activePane else { return }
                Task { await pane.goBack() }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!policy.canNavigate || workspace?.activePane.canGoBack != true)

            Button("Forward") {
                guard policy.canNavigate, let pane = workspace?.activePane else { return }
                Task { await pane.goForward() }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!policy.canNavigate || workspace?.activePane.canGoForward != true)

            Button("Parent Folder") {
                guard policy.canNavigate, let pane = workspace?.activePane else { return }
                Task { await pane.goToParent() }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!policy.canNavigate || (workspace.map { workspace in
                let directory = workspace.activePane.currentDirectory
                return directory.deletingLastPathComponent() == directory
            } ?? true))

            Divider()

            Button("Edit Location") {
                guard policy.canNavigate else { return }
                workspace?.activePane.isEditingPath.toggle()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(workspace == nil || !policy.canNavigate)
        }

        CommandMenu("Compare") {
            Button(comparisonPolicy.toggleTitle) {
                guard let workspace, let comparison else { return }
                ComparisonCommandActions.toggle(
                    workspace: workspace,
                    comparison: comparison,
                    storage: activeStorage
                )
            }
            .disabled(workspace == nil || comparison == nil)

            Divider()

            Button("Verify Selected Contents") {
                comparison?.verifySelected()
            }
            .disabled(!comparisonPolicy.canVerifySelectedContents)

            Button("Verify All Contents") {
                comparison?.verifyAll()
            }
            .disabled(!comparisonPolicy.canVerifyAllContents)

            Divider()

            Button("Copy Left to Right") {
                copyComparedItems(.leftToRight)
            }
            .disabled(!comparisonPolicy.canCopyLeftToRight)

            Button("Move Left to Right…") {
                comparison?.requestMove(direction: .leftToRight)
            }
            .disabled(!comparisonPolicy.canMoveLeftToRight)

            Button("Copy Right to Left") {
                copyComparedItems(.rightToLeft)
            }
            .disabled(!comparisonPolicy.canCopyRightToLeft)

            Button("Move Right to Left…") {
                comparison?.requestMove(direction: .rightToLeft)
            }
            .disabled(!comparisonPolicy.canMoveRightToLeft)
        }

        CommandMenu("Storage") {
            Button(storagePolicy.toggleTitle) {
                guard let workspace, let comparison, let activeStorage else { return }
                StorageInspectorCommandActions.toggle(
                    workspace: workspace,
                    comparison: comparison,
                    storage: activeStorage
                )
            }
            .disabled(workspace == nil || comparison == nil || activeStorage == nil)

            Divider()

            Button("Choose Location…") {
                guard let activeStorage else { return }
                StorageInspectorCommandActions.chooseLocation(storage: activeStorage)
            }
            .disabled(!storagePolicy.canStart)

            Button("Start Scan") {
                guard let activeStorage else { return }
                StorageInspectorCommandActions.start(storage: activeStorage)
            }
            .disabled(!storagePolicy.canStart)

            Button("Cancel Scan") {
                activeStorage?.cancel()
            }
            .disabled(!storagePolicy.canCancel)

            Button("Scan Again") {
                guard let activeStorage else { return }
                Task { await activeStorage.scanAgain() }
            }
            .disabled(!canScanAgain)
        }
    }

    private func openSelection() {
        guard let workspace, policy.canOpen else { return }

        let pane = workspace.activePane
        let itemsByURL = Dictionary(uniqueKeysWithValues: pane.visibleItems.map { ($0.url, $0) })
        let items = workspace.selectedURLsForCommands.compactMap { itemsByURL[$0] }
        Task {
            await WorkspaceOpenActions.open(
                items,
                in: pane,
                fileSystem: fileSystem,
                materializer: materializer,
                opener: workspaceOpener,
                accessCoordinator: accessCoordinator
            )
        }
    }

    @ViewBuilder
    private var contextActionCommands: some View {
        if contextPresentation.openWithAvailability?.isVisible == true
            || contextPresentation.policy.openWith.isVisible {
            Menu("Open With") {
                ForEach(contextPresentation.openWithApplications) { application in
                    Button(application.displayName) {
                        dispatchContextAction(.openWith(applicationURL: application.applicationURL))
                    }
                }
            }
            .disabled(!(contextPresentation.openWithAvailability?.isEnabled
                ?? contextPresentation.policy.openWith.isEnabled)
                || contextPresentation.openWithApplications.isEmpty)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceOpenWith)
            .accessibilityValue(contextAccessibilityValue(for: .openWith(applicationURL: URL(fileURLWithPath: "/"))))
        }

        if contextPolicy.openInOtherPane.isVisible {
            Button("Open in Other Pane") {
                dispatchContextAction(.openInOtherPane)
            }
            .disabled(!contextPolicy.openInOtherPane.isEnabled)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceOpenInOtherPane)
            .accessibilityValue(contextAccessibilityValue(for: .openInOtherPane))
        }

        if contextPolicy.copyToOtherPane.isVisible {
            Button("Copy to Other Pane") {
                dispatchContextAction(.transferToOtherPane(.copy))
            }
            .disabled(!contextPolicy.copyToOtherPane.isEnabled)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceCopyToOtherPane)
            .accessibilityValue(contextAccessibilityValue(for: .transferToOtherPane(.copy)))
        }

        if contextPolicy.moveToOtherPane.isVisible {
            Button("Move to Other Pane") {
                dispatchContextAction(.transferToOtherPane(.move))
            }
            .disabled(!contextPolicy.moveToOtherPane.isEnabled)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceMoveToOtherPane)
            .accessibilityValue(contextAccessibilityValue(for: .transferToOtherPane(.move)))
        }

        if contextPolicy.showInFinder.isVisible {
            Button("Show in Finder") {
                dispatchContextAction(.showInFinder)
            }
            .disabled(!contextPolicy.showInFinder.isEnabled)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceShowInFinder)
            .accessibilityValue(contextAccessibilityValue(for: .showInFinder))
        }

        if contextPolicy.copyPath.isVisible {
            Menu("Copy Path") {
                Button("Copy Full Path") { dispatchContextAction(.copyPath(.fullPath)) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .accessibilityIdentifier(AccessibilityIdentifiers.workspaceCopyFullPath)
                Button("Copy Name") { dispatchContextAction(.copyPath(.name)) }
                    .accessibilityIdentifier(AccessibilityIdentifiers.workspaceCopyName)
                Button("Copy Parent Path") { dispatchContextAction(.copyPath(.parentPath)) }
                    .accessibilityIdentifier(AccessibilityIdentifiers.workspaceCopyParentPath)
                Button("Copy File URL") { dispatchContextAction(.copyPath(.fileURL)) }
                    .accessibilityIdentifier(AccessibilityIdentifiers.workspaceCopyFileURL)
            }
            .disabled(!contextPolicy.copyPath.isEnabled)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceCopyPath)
            .accessibilityValue(contextAccessibilityValue(for: .copyPath(.fullPath)))
        }

        if contextPolicy.encloseSelection.isVisible {
            Button("New Folder with Selection (\(selectedItemsForCommands.count) Items)…") {
                dispatchContextAction(.encloseSelection)
            }
            .disabled(!contextPolicy.encloseSelection.isEnabled)
            .accessibilityIdentifier(AccessibilityIdentifiers.workspaceEncloseSelection)
            .accessibilityValue(contextAccessibilityValue(for: .encloseSelection))
        }

        if contextPolicy.duplicate.isVisible {
            Button("Duplicate") { dispatchContextAction(.duplicate) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!contextPolicy.duplicate.isEnabled)
                .accessibilityIdentifier(AccessibilityIdentifiers.workspaceDuplicate)
                .accessibilityValue(contextAccessibilityValue(for: .duplicate))
        }
    }

    private var contextPresentation: FileContextMenuPresentation {
        guard let openWithProvider else {
            return FileContextMenuPresentation(policy: contextPolicy)
        }
        return OpenWithMenuPresentation.make(
            policy: contextPolicy,
            selectedItems: selectedItemsForCommands,
            provider: openWithProvider
        )
    }

    private var contextPolicy: FileContextMenuPolicy {
        guard let workspace else {
            return FileContextMenuPolicy(.init(
                workspaceCommandPolicy: WorkspaceCommandPolicy(
                    selectionCount: 0,
                    isOperationRunning: operationController.isRunning,
                    pasteboardHasFileURLs: false
                ),
                selectedItems: [],
                sourceDirectory: URL(fileURLWithPath: "/"),
                oppositeDirectory: nil,
                sourceCapability: .unknown,
                oppositeCapability: .unknown,
                isExclusiveOperationActive: false
            ))
        }
        return WorkspaceContextActionRouting.policy(
            items: selectedItemsForCommands,
            capturedSelectionCount: workspace.selectedURLsForCommands.count,
            sourcePaneID: workspace.activePaneID,
            workspace: workspace,
            operationController: operationController,
            cloudLocations: cloudLocations
        )
    }

    private func contextAccessibilityValue(for action: ContextActionKind) -> String {
        ContextActionAccessibilityPresentation.value(
            action: action,
            itemCount: selectedItemsForCommands.count,
            destinationPaneID: workspace?.activePaneID == .left ? .right : .left,
            availability: action.availability(in: contextPolicy)
        )
    }

    private func dispatchContextAction(_ action: ContextActionKind) {
        guard let workspace,
              let contextActionRouter,
              action.availability(in: contextPolicy).isEnabled,
              let draft = WorkspaceContextActionRouting.draft(
                  items: selectedItemsForCommands,
                  capturedSelectionCount: workspace.selectedURLsForCommands.count,
                  sourcePaneID: workspace.activePaneID,
                  workspace: workspace,
                  cloudLocations: cloudLocations
              )
        else { return }
        let targetPane = draft.oppositePaneID == .left ? workspace.left : workspace.right
        let capturedAction = action
        Task { @MainActor in
            guard let snapshot = await contextActionRouter.capture(draft) else { return }
            switch capturedAction {
            case .quickLook:
                guard let previewCoordinator else { return }
                _ = await contextActionRouter.quickLook(snapshot, previewCoordinator: previewCoordinator)
            case .openWith(let applicationURL):
                _ = await contextActionRouter.openWith(snapshot, applicationURL: applicationURL)
            case .openInOtherPane:
                _ = await contextActionRouter.openInOtherPane(snapshot, targetPane: targetPane)
            case .transferToOtherPane(let mode):
                guard let requests = await contextActionRouter.identifiedTransferRequests(from: snapshot) else {
                    return
                }
                _ = operationController.transferToCapturedDirectory(requests, mode: mode, workspace: workspace)
            case .showInFinder:
                _ = await contextActionRouter.showInFinder(snapshot)
            case .copyPath(let kind):
                _ = contextActionRouter.copyPath(kind, from: snapshot)
            case .duplicate:
                _ = operationController.duplicate(snapshot, in: draft.sourcePaneID == .left ? workspace.left : workspace.right, workspace: workspace)
            case .encloseSelection:
                await selectionFolder?.present(snapshot)
            }
        }
    }

    private var policy: WorkspaceCommandPolicy {
        WorkspaceCommandPolicy(
            selectionCount: workspace?.selectedURLsForCommands.count ?? 0,
            isOperationRunning: operationController.isRunning,
            pasteboardHasFileURLs: FileURLPasteboard.containsFileURLs(in: .general),
            selectedItems: selectedItemsForCommands,
            isTextEditing: workspace?.activeTextEditingSession != nil
        )
    }

    private var selectedItemsForCommands: [FileItem] {
        guard let workspace else { return [] }
        let selectedURLs = Set(workspace.selectedURLsForCommands)
        return workspace.activePane.visibleItems.filter { selectedURLs.contains($0.url) }
    }

    private var comparisonPolicy: ComparisonCommandPolicy {
        ComparisonCommandPolicy(
            isActive: comparison?.isActive == true,
            canVerifySelected: comparison?.canVerifySelected == true,
            canCopyLeftToRight: comparison?.canCopy(.leftToRight) == true,
            canCopyRightToLeft: comparison?.canCopy(.rightToLeft) == true,
            canMoveLeftToRight: comparison?.canMove(.leftToRight) == true,
            canMoveRightToLeft: comparison?.canMove(.rightToLeft) == true
        )
    }

    private var activeStorage: StorageAnalysisStore? {
        focusedStorage ?? storage
    }

    private var storagePolicy: StorageInspectorCommandPolicy {
        StorageInspectorCommandPolicy(
            isActive: activeStorage?.isActive == true,
            phase: activeStorage?.phase ?? .inactive
        )
    }

    private var canScanAgain: Bool {
        storagePolicy.canStart && activeStorage?.rootURL != nil
    }

    private func copyComparedItems(_ direction: ComparisonDirection) {
        guard let workspace, let comparison else { return }
        comparison.copy(
            direction: direction,
            operationController: operationController,
            workspace: workspace
        )
    }

    private func createFolder() {
        guard let workspace, policy.canCreateFolder else { return }
        let pane = workspace.activePane
        Task {
            _ = await WorkspaceCommandActions.createFolder(
                in: pane,
                workspace: workspace,
                operationController: operationController
            )
        }
    }

    private func requestRename() {
        guard policy.canRename else { return }
        guard let workspace else { return }
        Task { _ = await operationController.requestRename(in: workspace) }
    }

    private func copy() {
        switch policy.copyRoute {
        case .textResponder:
            TextResponderCommand.copy()
        case .fileSelection:
            guard let workspace else { return }
            FileURLPasteboard.write(workspace.selectedURLsForCommands, to: .general)
        case .unavailable:
            return
        }
    }

    private func paste() {
        switch policy.pasteRoute {
        case .textResponder:
            TextResponderCommand.paste()
        case .fileSelection:
            guard let workspace else { return }
            let sources = FileURLPasteboard.read(from: .general)
            guard !sources.isEmpty else { return }
            Task {
                _ = await operationController.runTransfer(
                    sources,
                    to: workspace.activePane.currentDirectory,
                    mode: .copy,
                    workspace: workspace
                )
            }
        case .unavailable:
            return
        }
    }
}
