import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct WorkspacePreviewCoordinatorTests {
    @Test func ordinaryFolderUsesFolderModeWithoutMaterialization() async {
        let folder = previewItem("folder", isDirectory: true)
        let request = folderRequest(for: folder, token: "folder")
        let materializer = InMemoryCloudMaterializer()
        let presenter = RecordingFolderPreviewPresenter()
        let coordinator = WorkspacePreviewCoordinator(
            fileSystem: RecordingFileSystem(
                identities: [folder.url: request.identity],
                folderPreviewRequests: [folder.url: request]
            ),
            quickLookController: QuickLookController(onPresent: { _ in }),
            folderPresenter: presenter,
            materializer: materializer,
            restoreFocus: {}
        )

        await coordinator.toggle(selection: .init(paneID: .left, items: [folder]))

        #expect(coordinator.mode == .folder(request))
        #expect(presenter.presentedRequests == [request])
        #expect(await materializer.recordedCalls().isEmpty)
    }

    @Test func filePackageSymlinkAndMultiSelectionUseSystemQuickLook() async {
        let file = previewItem("file.txt", isDirectory: false)
        let package = previewItem("App.app", isDirectory: true, isPackage: true)
        let symlink = previewItem("linked-folder", isDirectory: true)
        let selections = [[file], [package], [symlink], [file, package]]

        for items in selections {
            let identities = Dictionary(uniqueKeysWithValues: items.map {
                ($0.url, FileIdentity(entryIdentifier: $0.name, resolvedIdentifier: $0.name))
            })
            let presenter = QuickLookPresentationRecorder()
            let coordinator = WorkspacePreviewCoordinator(
                fileSystem: RecordingFileSystem(identities: identities),
                quickLookController: QuickLookController(onPresent: presenter.present),
                folderPresenter: RecordingFolderPreviewPresenter(),
                materializer: InMemoryCloudMaterializer(),
                restoreFocus: {}
            )

            await coordinator.toggle(selection: .init(paneID: .left, items: items))

            #expect(coordinator.mode == .systemQuickLook)
            #expect(presenter.history == [items.map(\.url)])
        }
    }

    @Test func selectionUpdatesRouteOnlyWhilePreviewIsPresented() async {
        let first = previewItem("first", isDirectory: true)
        let second = previewItem("second", isDirectory: true)
        let firstRequest = folderRequest(for: first, token: "first")
        let secondRequest = folderRequest(for: second, token: "second")
        let presenter = RecordingFolderPreviewPresenter()
        let coordinator = WorkspacePreviewCoordinator(
            fileSystem: RecordingFileSystem(
                identities: [first.url: firstRequest.identity, second.url: secondRequest.identity],
                folderPreviewRequests: [first.url: firstRequest, second.url: secondRequest]
            ),
            quickLookController: QuickLookController(onPresent: { _ in }),
            folderPresenter: presenter,
            materializer: InMemoryCloudMaterializer(),
            restoreFocus: {}
        )

        await coordinator.selectionDidChange(to: .init(paneID: .left, items: [first]))
        #expect(coordinator.mode == .closed)
        #expect(presenter.presentedRequests.isEmpty)

        await coordinator.toggle(selection: .init(paneID: .left, items: [first]))
        await coordinator.selectionDidChange(to: .init(paneID: .left, items: [second]))

        #expect(coordinator.mode == .folder(secondRequest))
        #expect(presenter.presentedRequests == [firstRequest, secondRequest])
    }

    @Test func repeatedSpaceClosesBothPreviewControllersAndRestoresFocus() async {
        let file = previewItem("file.txt", isDirectory: false)
        let identity = FileIdentity(entryIdentifier: "file", resolvedIdentifier: "file")
        let folderPresenter = RecordingFolderPreviewPresenter()
        let focus = FocusRecorder()
        let quickLook = QuickLookController(onPresent: { _ in })
        let coordinator = WorkspacePreviewCoordinator(
            fileSystem: RecordingFileSystem(identities: [file.url: identity]),
            quickLookController: quickLook,
            folderPresenter: folderPresenter,
            materializer: InMemoryCloudMaterializer(),
            restoreFocus: focus.restore
        )
        let selection = WorkspacePreviewSelection(paneID: .left, items: [file])

        await coordinator.toggle(selection: selection)
        await coordinator.toggle(selection: selection)

        #expect(coordinator.mode == .closed)
        #expect(!quickLook.isPresenting)
        #expect(folderPresenter.closeCount == 1)
        #expect(focus.count == 1)
    }

    @Test func staleIdentityCaptureCannotPresentAfterSelectionChanges() async {
        let first = previewItem("first", isDirectory: false)
        let second = previewItem("second", isDirectory: false)
        let firstIdentity = FileIdentity(entryIdentifier: "first", resolvedIdentifier: "first")
        let secondIdentity = FileIdentity(entryIdentifier: "second", resolvedIdentifier: "second")
        let fileSystem = RecordingFileSystem(
            identities: [first.url: firstIdentity, second.url: secondIdentity],
            suspendIdentityOf: first.url
        )
        let folderPresenter = RecordingFolderPreviewPresenter()
        let quickLookPresenter = QuickLookPresentationRecorder()
        let coordinator = WorkspacePreviewCoordinator(
            fileSystem: fileSystem,
            quickLookController: QuickLookController(onPresent: quickLookPresenter.present),
            folderPresenter: folderPresenter,
            materializer: InMemoryCloudMaterializer(),
            restoreFocus: {}
        )

        let firstTask = Task { @MainActor in
            await coordinator.toggle(selection: .init(paneID: .left, items: [first]))
        }
        while !(await fileSystem.hasSuspendedIdentity) { await Task.yield() }
        let secondTask = Task { @MainActor in
            await coordinator.selectionDidChange(to: .init(paneID: .left, items: [second]))
        }
        await Task.yield()
        await fileSystem.releaseSuspendedIdentity()
        await firstTask.value
        await secondTask.value

        #expect(coordinator.mode == .systemQuickLook)
        #expect(folderPresenter.presentedRequests.isEmpty)
        #expect(quickLookPresenter.history == [[second.url]])
    }
}

@MainActor
private final class RecordingFolderPreviewPresenter: FolderPreviewPresenting {
    private(set) var presentedRequests: [FolderPreviewRequest] = []
    private(set) var closeCount = 0

    func present(request: FolderPreviewRequest) {
        presentedRequests.append(request)
    }

    func close() {
        closeCount += 1
    }
}

@MainActor
private final class QuickLookPresentationRecorder {
    private(set) var history: [[URL]] = []

    func present(_ urls: [URL]) {
        history.append(urls)
    }
}

@MainActor
private final class FocusRecorder {
    private(set) var count = 0

    func restore() {
        count += 1
    }
}

private func previewItem(_ name: String, isDirectory: Bool, isPackage: Bool = false) -> FileItem {
    FileItem(
        url: URL(filePath: "/preview/\(name)", directoryHint: isDirectory ? .isDirectory : .notDirectory),
        name: name,
        isDirectory: isDirectory,
        isPackage: isPackage,
        modifiedAt: nil,
        byteSize: isDirectory ? nil : 1,
        typeDescription: isDirectory ? "Folder" : "File"
    )
}

private func folderRequest(for item: FileItem, token: String) -> FolderPreviewRequest {
    FolderPreviewRequest(
        paneID: .left,
        url: item.url,
        identity: FileIdentity(entryIdentifier: token, resolvedIdentifier: token),
        kind: .ordinaryDirectory
    )
}
