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
    var isTextEditing = false

    var canCreateFolder: Bool { !isOperationRunning && !isTextEditing }
    var canRename: Bool { !isOperationRunning && !isTextEditing && selectionCount == 1 }
    var canCopy: Bool { !isTextEditing && selectionCount > 0 }
    var canPaste: Bool { !isOperationRunning && !isTextEditing && pasteboardHasFileURLs }
    var canTrash: Bool { !isOperationRunning && !isTextEditing && selectionCount > 0 }
    var canOpen: Bool { !isTextEditing && selectionCount > 0 }
    var canQuickLook: Bool { !isTextEditing && selectionCount > 0 }
    var canNavigate: Bool { !isTextEditing }

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

@MainActor
enum WorkspaceCommandActions {
    @discardableResult
    static func createFolder(
        in pane: FilePaneState,
        workspace: WorkspaceState,
        operationController: FileOperationController
    ) -> Bool {
        guard !operationController.isRunning else { return false }
        let existing = Set(pane.visibleItems.map(\.name))
        let name = KeepBothNamer.availableName(for: "New Folder", existing: existing)
        return operationController.createFolder(
            in: pane.currentDirectory,
            named: name,
            workspace: workspace,
            beginInlineRenameIn: pane
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
    let operationController: FileOperationController
    let storage: StorageAnalysisStore
    let storageCleanupController: StorageCleanupController
    var materializer: any CloudMaterializing = LiveCloudMaterializationService()
    var fileSystem: any FileSystemAccess
    var workspaceOpener: any WorkspaceOpening = LiveWorkspaceOpener()
    var accessCoordinator: CloudLocationScopedAccessCoordinator = .init()

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
                guard policy.canQuickLook else { return }
                let urls = workspace?.selectedURLsForCommands ?? []
                Task {
                    guard let requests = await WorkspaceOpenActions.identifiedRequests(
                        for: urls,
                        fileSystem: fileSystem,
                        accessCoordinator: accessCoordinator
                    ) else { return }
                    await quickLookController.prepareAndPresent(
                        requests: requests,
                        materializer: materializer
                    )
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!policy.canQuickLook)

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

        CommandMenu("File Operations") {
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
                _ = operationController.trash(
                    workspace.selectedURLsForCommands,
                    workspace: workspace
                )
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

    private var policy: WorkspaceCommandPolicy {
        WorkspaceCommandPolicy(
            selectionCount: workspace?.selectedURLsForCommands.count ?? 0,
            isOperationRunning: operationController.isRunning,
            pasteboardHasFileURLs: FileURLPasteboard.containsFileURLs(in: .general),
            isTextEditing: workspace?.activeTextEditingSession != nil
        )
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
        _ = WorkspaceCommandActions.createFolder(
            in: pane,
            workspace: workspace,
            operationController: operationController
        )
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
            _ = operationController.runTransfer(
                sources,
                to: workspace.activePane.currentDirectory,
                mode: .copy,
                workspace: workspace
            )
        case .unavailable:
            return
        }
    }
}
