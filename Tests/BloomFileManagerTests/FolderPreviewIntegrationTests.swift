import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FolderPreviewIntegrationTests {
    @Test func workspaceObserverReferencesOnlyCoordinator() throws {
        let implementation = try source(named: "Views/WorkspaceView.swift")

        #expect(implementation.contains("previewCoordinator.selectionDidChange"))
        #expect(!implementation.contains("quickLookController.updateIfPresented"))
        #expect(!implementation.contains("WorkspaceQuickLookSelectionRouting.begin"))
    }

    @Test func workspaceSpaceCommandRoutesThroughSharedContextActionRouterToCoordinator() throws {
        let commands = try source(named: "Support/WorkspaceCommands.swift")
        let router = try source(named: "Support/FileContextActionRouter.swift")

        #expect(commands.contains("Button(\"Quick Look\") {\n                dispatchContextAction(.quickLook)\n            }"))
        #expect(commands.contains("let snapshot = await contextActionRouter.capture(draft)"))
        #expect(commands.contains(
            "_ = await contextActionRouter.quickLook(snapshot, previewCoordinator: previewCoordinator)"
        ))
        #expect(!commands.contains("await previewCoordinator.toggle(selection:"))
        #expect(!commands.contains("await WorkspaceQuickLookCommandRouting.prepareAndPresent("))
        #expect(router.contains("previewCoordinator: WorkspacePreviewCoordinator"))
        #expect(router.contains("await previewCoordinator.toggle(\n            selection: WorkspacePreviewSelection("))
        #expect(!router.contains("QuickLookController"))
    }

    @Test func appComposesOneCoordinatorAndInjectsItIntoWorkspaceAndCommands() throws {
        let implementation = try source(named: "App/BloomFileManagerApp.swift")

        #expect(implementation.contains("WorkspacePreviewCoordinator("))
        #expect(implementation.contains("previewCoordinator: previewCoordinator"))
        #expect(implementation.contains("restoreFocus: { workspace.activePane.requestTableFocus() }"))
    }

    @Test func textEditingKeepsSpaceAndEscapePriority() {
        let folder = previewItem("folder", isDirectory: true)
        let policy = WorkspaceCommandPolicy(
            selectionCount: 1,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: [folder],
            isTextEditing: true
        )

        #expect(!policy.canQuickLook)
        #expect(!policy.canClosePreview)
    }

    @Test func closedEscapeDoesNotRestoreFocus() {
        let focus = FocusRecorder()
        let coordinator = makeCoordinator(restoreFocus: focus.restore)
        let policy = WorkspaceCommandPolicy(
            selectionCount: 0,
            isOperationRunning: false,
            pasteboardHasFileURLs: false
        )

        WorkspacePreviewCommandActions.closeIfPresented(
            policy: policy,
            previewCoordinator: coordinator
        )

        #expect(coordinator.mode == .closed)
        #expect(focus.count == 0)
    }

    @Test func closingPreviewRestoresOnlyTheActivePaneTable() async {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left", directoryHint: .isDirectory),
            rightURL: URL(filePath: "/right", directoryHint: .isDirectory),
            listingService: StubDirectoryListingService(values: [:])
        )
        workspace.activate(.right)
        let item = previewItem("file.txt", isDirectory: false)
        let identity = FileIdentity(entryIdentifier: "file", resolvedIdentifier: "file")
        let coordinator = WorkspacePreviewCoordinator(
            fileSystem: RecordingFileSystem(identities: [item.url: identity]),
            quickLookController: QuickLookController(onPresent: { _ in }),
            folderPresenter: PreviewPresenter(),
            materializer: InMemoryCloudMaterializer(),
            restoreFocus: { workspace.activePane.requestTableFocus() }
        )
        let policy = WorkspaceCommandPolicy(
            selectionCount: 1,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: [item]
        )

        await coordinator.toggle(selection: .init(paneID: .right, items: [item]))
        WorkspacePreviewCommandActions.closeIfPresented(
            policy: policy,
            previewCoordinator: coordinator
        )

        #expect(workspace.right.focusRequestID != nil)
        #expect(workspace.left.focusRequestID == nil)
    }

    @Test func escapeCommandGatesClosedModeAndUsesTheTableFocusBridge() throws {
        let commands = try source(named: "Support/WorkspaceCommands.swift")
        let table = try source(named: "Views/AppKit/FileTableView.swift")

        #expect(commands.contains("policy.canClosePreview"))
        #expect(commands.contains("previewCoordinator.mode != .closed"))
        #expect(table.contains("window.makeFirstResponder(tableView)"))
    }
}

@MainActor
private final class FocusRecorder {
    private(set) var count = 0

    func restore() {
        count += 1
    }
}

@MainActor
private final class PreviewPresenter: FolderPreviewPresenting {
    func present(request: FolderPreviewRequest) {}
    func close() {}
}

@MainActor
private func makeCoordinator(
    restoreFocus: @escaping @MainActor () -> Void
) -> WorkspacePreviewCoordinator {
    WorkspacePreviewCoordinator(
        fileSystem: RecordingFileSystem(),
        quickLookController: QuickLookController(onPresent: { _ in }),
        folderPresenter: PreviewPresenter(),
        materializer: InMemoryCloudMaterializer(),
        restoreFocus: restoreFocus
    )
}

private func previewItem(_ name: String, isDirectory: Bool) -> FileItem {
    FileItem(
        url: URL(
            filePath: "/preview/\(name)",
            directoryHint: isDirectory ? .isDirectory : .notDirectory
        ),
        name: name,
        isDirectory: isDirectory,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: isDirectory ? "Folder" : "Document"
    )
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}
