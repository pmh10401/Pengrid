import Foundation

enum WorkspacePreviewMode: Equatable, Sendable {
    case closed
    case systemQuickLook
    case folder(FolderPreviewRequest)
}

struct WorkspacePreviewSelection: Equatable, Sendable {
    let paneID: PaneID
    let items: [FileItem]
}

@MainActor
protocol FolderPreviewPresenting: AnyObject {
    func present(request: FolderPreviewRequest)
    func close()
}

/// The one authority for workspace Space-preview transitions. It keeps the
/// concrete system and folder presenters mutually exclusive and rejects every
/// async result whose captured selection or generation is no longer current.
@MainActor
final class WorkspacePreviewCoordinator {
    private(set) var mode: WorkspacePreviewMode = .closed

    private let fileSystem: any FileSystemAccess
    private let quickLookController: QuickLookController
    private let folderPresenter: any FolderPreviewPresenting
    private let materializer: any CloudMaterializing
    private let restoreFocus: @MainActor () -> Void

    private var generation: UInt = 0
    private var activeSelection: WorkspacePreviewSelection?

    init(
        fileSystem: any FileSystemAccess,
        quickLookController: QuickLookController,
        folderPresenter: any FolderPreviewPresenting,
        materializer: any CloudMaterializing,
        restoreFocus: @escaping @MainActor () -> Void
    ) {
        self.fileSystem = fileSystem
        self.quickLookController = quickLookController
        self.folderPresenter = folderPresenter
        self.materializer = materializer
        self.restoreFocus = restoreFocus
    }

    func toggle(selection: WorkspacePreviewSelection) async {
        guard !Task.isCancelled else { return }
        if activeSelection != nil || mode != .closed {
            closeAndRestoreFocus()
            return
        }
        await route(selection: selection, cancellingExistingPresenters: false)
    }

    func selectionDidChange(to selection: WorkspacePreviewSelection) async {
        guard !Task.isCancelled, (activeSelection != nil || mode != .closed) else { return }
        await route(selection: selection, cancellingExistingPresenters: true)
    }

    func closeAndRestoreFocus() {
        generation &+= 1
        activeSelection = nil
        mode = .closed
        cancelConcretePresenters()
        restoreFocus()
    }

    private func route(
        selection: WorkspacePreviewSelection,
        cancellingExistingPresenters: Bool
    ) async {
        generation &+= 1
        let routeGeneration = generation
        activeSelection = selection.items.isEmpty ? nil : selection
        mode = .closed

        if cancellingExistingPresenters {
            cancelConcretePresenters()
        }
        guard !selection.items.isEmpty,
              isCurrent(selection, generation: routeGeneration)
        else { return }

        if let item = ordinaryFolder(in: selection) {
            await routeFolder(item, selection: selection, generation: routeGeneration)
        } else {
            await routeSystemQuickLook(selection: selection, generation: routeGeneration)
        }
    }

    private func routeFolder(
        _ item: FileItem,
        selection: WorkspacePreviewSelection,
        generation routeGeneration: UInt
    ) async {
        guard isCurrent(selection, generation: routeGeneration) else { return }
        let request: FolderPreviewRequest?
        do {
            request = try await fileSystem.captureFolderPreviewRequest(
                paneID: selection.paneID,
                url: item.url
            )
        } catch {
            // Provider or access failure is not a reason to materialize a
            // folder. A successfully captured `nil` (for example, a symlink)
            // remains the explicit system Quick Look fallback below.
            closeIfCurrent(selection, generation: routeGeneration)
            return
        }
        guard isCurrent(selection, generation: routeGeneration) else { return }

        guard let request else {
            await routeSystemQuickLook(selection: selection, generation: routeGeneration)
            return
        }
        guard request.paneID == selection.paneID,
              request.url.standardizedFileURL == item.url.standardizedFileURL,
              request.kind == .ordinaryDirectory,
              isCurrent(selection, generation: routeGeneration)
        else {
            closeIfCurrent(selection, generation: routeGeneration)
            return
        }

        // Capturing and presenting a folder request is metadata-only. In
        // particular, this path never invokes the cloud materializer.
        quickLookController.cancelAndClose()
        guard isCurrent(selection, generation: routeGeneration) else { return }
        mode = .folder(request)
        folderPresenter.present(request: request)
    }

    private func routeSystemQuickLook(
        selection: WorkspacePreviewSelection,
        generation routeGeneration: UInt
    ) async {
        guard isCurrent(selection, generation: routeGeneration) else { return }
        var requests: [IdentifiedFileRequest] = []
        for item in selection.items {
            guard isCurrent(selection, generation: routeGeneration),
                  let identity = try? await fileSystem.identity(of: item.url)
            else {
                closeIfCurrent(selection, generation: routeGeneration)
                return
            }
            requests.append(IdentifiedFileRequest(url: item.url, identity: identity))
        }
        guard isCurrent(selection, generation: routeGeneration) else { return }

        mode = .systemQuickLook
        await quickLookController.prepareAndPresent(
            requests: requests,
            materializer: materializer
        )
        guard isCurrent(selection, generation: routeGeneration) else { return }
        if !quickLookController.isPresenting {
            closeIfCurrent(selection, generation: routeGeneration)
        }
    }

    private func ordinaryFolder(in selection: WorkspacePreviewSelection) -> FileItem? {
        guard selection.items.count == 1,
              let item = selection.items.first,
              item.isDirectory,
              !item.isPackage
        else { return nil }
        return item
    }

    private func isCurrent(
        _ selection: WorkspacePreviewSelection,
        generation expectedGeneration: UInt
    ) -> Bool {
        !Task.isCancelled
            && generation == expectedGeneration
            && activeSelection == selection
    }

    private func closeIfCurrent(
        _ selection: WorkspacePreviewSelection,
        generation expectedGeneration: UInt
    ) {
        guard isCurrent(selection, generation: expectedGeneration) else { return }
        activeSelection = nil
        mode = .closed
        cancelConcretePresenters()
    }

    private func cancelConcretePresenters() {
        quickLookController.cancelAndClose()
        folderPresenter.close()
    }
}
