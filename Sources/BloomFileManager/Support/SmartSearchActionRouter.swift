import Foundation

enum SmartSearchActionError: Error, Equatable, Sendable {
    case itemChanged
}

struct SmartSearchTrashConfirmation: Equatable, Sendable {
    let requests: [IdentifiedFileRequest]
    let orderedResultIdentities: [FileIdentity]
}

@MainActor
final class SmartSearchActionRouter {
    private let fileSystem: any FileSystemAccess

    private(set) var error: SmartSearchActionError?

    init(fileSystem: any FileSystemAccess = LiveFileSystemAccess()) {
        self.fileSystem = fileSystem
    }

    func revalidatedRequest(for result: SmartSearchResult) async -> IdentifiedFileRequest? {
        error = nil
        return await revalidatedRequestWithoutReset(for: result)
    }

    func transferRequests(
        for results: [SmartSearchResult],
        destination: URL
    ) async throws -> [IdentifiedTransferRequest] {
        error = nil
        guard !results.isEmpty,
              let destinationIdentity = await currentIdentity(at: destination)
        else {
            error = .itemChanged
            throw SmartSearchActionError.itemChanged
        }

        var requests: [IdentifiedTransferRequest] = []
        requests.reserveCapacity(results.count)
        for result in results {
            guard let source = await revalidatedRequestWithoutReset(for: result) else {
                throw SmartSearchActionError.itemChanged
            }
            requests.append(IdentifiedTransferRequest(
                source: source.url,
                sourceIdentity: source.identity,
                destinationRoot: destination,
                destinationRootIdentity: destinationIdentity,
                relativeParentComponents: []
            ))
        }
        return requests
    }

    func prepareQuickLook(
        for result: SmartSearchResult,
        controller: QuickLookController,
        materializer: any CloudMaterializing
    ) async -> Bool {
        guard let request = await revalidatedRequest(for: result) else { return false }
        await controller.prepareAndPresent(requests: [request], materializer: materializer)
        return true
    }

    func reveal(_ result: SmartSearchResult, in pane: FilePaneState) async -> Bool {
        guard let request = await revalidatedRequest(for: result) else { return false }
        let parent = request.url.deletingLastPathComponent().standardizedFileURL
        await pane.navigate(to: parent)
        guard pane.currentDirectory.standardizedFileURL == parent,
              await revalidatedRequestWithoutReset(for: result) != nil,
              let listedURL = pane.items.first(where: {
                  $0.url.standardizedFileURL == request.url.standardizedFileURL
              })?.url
        else {
            error = .itemChanged
            return false
        }
        pane.selection = [listedURL]
        return true
    }

    func openContainingFolderInOppositePane(
        for result: SmartSearchResult,
        workspace: WorkspaceState
    ) async -> Bool {
        let targetPane = workspace.activePaneID == .left ? workspace.right : workspace.left
        guard let request = await revalidatedRequest(for: result) else { return false }
        let parent = request.url.deletingLastPathComponent().standardizedFileURL
        await targetPane.navigate(to: parent)
        guard targetPane.currentDirectory.standardizedFileURL == parent,
              await revalidatedRequestWithoutReset(for: result) != nil,
              let listedURL = targetPane.items.first(where: {
                  $0.url.standardizedFileURL == request.url.standardizedFileURL
              })?.url
        else {
            error = .itemChanged
            return false
        }
        targetPane.selection = [listedURL]
        return true
    }

    func transferToOppositePane(
        _ results: [SmartSearchResult],
        mode: TransferMode,
        operationController: FileOperationController,
        workspace: WorkspaceState
    ) async -> Bool {
        let destination = (workspace.activePaneID == .left ? workspace.right : workspace.left)
            .currentDirectory
        do {
            let requests = try await transferRequests(for: results, destination: destination)
            return operationController.runIdentifiedTransfer(
                requests,
                mode: mode,
                workspace: workspace,
                includeSafeRelativePaths: false
            )
        } catch {
            return false
        }
    }

    func requestTrashConfirmation(
        for results: [SmartSearchResult],
        workspace: WorkspaceState
    ) async -> SmartSearchTrashConfirmation? {
        error = nil
        guard !results.isEmpty else { return nil }
        var requests: [IdentifiedFileRequest] = []
        requests.reserveCapacity(results.count)
        for result in results {
            guard let request = await revalidatedRequestWithoutReset(for: result) else {
                return nil
            }
            requests.append(request)
        }
        let confirmation = SmartSearchTrashConfirmation(
            requests: requests,
            orderedResultIdentities: results.map(\.identity)
        )
        workspace.requestTrashConfirmation(for: requests)
        return confirmation
    }

    func confirmTrash(
        _ confirmation: SmartSearchTrashConfirmation?,
        currentResults: [SmartSearchResult],
        operationController: FileOperationController,
        workspace: WorkspaceState
    ) async -> Bool {
        guard let confirmation,
              confirmation.orderedResultIdentities == currentResults.map(\.identity),
              workspace.pendingTrashRequest?.items == confirmation.requests
        else { return false }
        error = nil
        var revalidatedRequests: [IdentifiedFileRequest] = []
        revalidatedRequests.reserveCapacity(currentResults.count)
        for result in currentResults {
            guard let request = await revalidatedRequestWithoutReset(for: result)
            else { return false }
            revalidatedRequests.append(request)
        }
        guard revalidatedRequests == confirmation.requests else { return false }
        workspace.dismissTrashConfirmation()
        return operationController.trash(
            confirmation.requests,
            workspace: workspace,
            privacySafeProgress: true
        )
    }

    private func revalidatedRequestWithoutReset(
        for result: SmartSearchResult
    ) async -> IdentifiedFileRequest? {
        guard let identity = await currentIdentity(at: result.item.url),
              identity == result.identity
        else {
            error = .itemChanged
            return nil
        }
        return IdentifiedFileRequest(url: result.item.url, identity: result.identity)
    }

    private func currentIdentity(at url: URL) async -> FileIdentity? {
        guard !Task.isCancelled,
              let identity = try? await fileSystem.identity(of: url),
              !Task.isCancelled
        else {
            error = .itemChanged
            return nil
        }
        return identity
    }
}
