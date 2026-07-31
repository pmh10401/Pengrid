import Foundation
import Observation

enum FileOperationStage: Equatable {
    case preparing(CloudMaterializationProgress)
    case operating(FileOperationProgress)
    case archiving(ArchiveOperationProgress)
}

enum CloudOperationRequestGate {
    static func identityPreservingPreparedRequests(
        original: [IdentifiedFileRequest],
        prepared: [IdentifiedFileRequest]
    ) -> [IdentifiedFileRequest]? {
        guard original.count == prepared.count else { return nil }
        var remaining = prepared
        var ordered: [IdentifiedFileRequest] = []
        for request in original {
            guard let index = remaining.firstIndex(where: {
                $0.url.standardizedFileURL == request.url.standardizedFileURL
                    && $0.identity.refersToSameItem(as: request.identity)
            }) else {
                return nil
            }
            ordered.append(remaining.remove(at: index))
        }
        return remaining.isEmpty ? ordered : nil
    }
}

@MainActor @Observable
final class FileOperationController {
    private let service: FileOperationService
    private let materializer: any CloudMaterializing
    private let archiveService: any ArchiveOperating

    private(set) var stage: FileOperationStage?
    private(set) var pendingConflict: FileConflict?
    private(set) var lastResult: FileOperationResult?
    private(set) var lastPreparationFailures: [CloudMaterializationFailure] = []
    private(set) var isRunning = false

    var progress: FileOperationProgress? {
        guard case let .operating(progress) = stage else { return nil }
        return progress
    }

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?
    @ObservationIgnored private var conflictRequestID: UUID?
    @ObservationIgnored private var applyToAllDecision: ConflictDecision?

    init(
        service: FileOperationService,
        materializer: any CloudMaterializing,
        archiveService: any ArchiveOperating = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess()
        )
    ) {
        self.service = service
        self.materializer = materializer
        self.archiveService = archiveService
    }

    func requestDecision(for conflict: FileConflict) async -> ConflictDecision {
        guard !Task.isCancelled else { return .cancel }
        if let applyToAllDecision {
            return applyToAllDecision
        }
        guard conflictContinuation == nil else { return .cancel }

        let requestID = UUID()
        pendingConflict = conflict
        conflictRequestID = requestID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    pendingConflict = nil
                    conflictRequestID = nil
                    continuation.resume(returning: .cancel)
                } else {
                    conflictContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingDecision(requestID: requestID)
            }
        }
    }

    func resolvePendingConflict(_ decision: ConflictDecision, applyToAll: Bool) {
        guard let continuation = conflictContinuation else { return }
        if applyToAll, decision != .cancel {
            applyToAllDecision = decision
        }
        pendingConflict = nil
        conflictContinuation = nil
        conflictRequestID = nil
        continuation.resume(returning: decision)
    }

    func cancel() {
        operationTask?.cancel()
        resolvePendingConflict(.cancel, applyToAll: false)
    }

    private func cancelPendingDecision(requestID: UUID) {
        guard conflictRequestID == requestID else { return }
        resolvePendingConflict(.cancel, applyToAll: false)
    }

    @discardableResult
    func compressSelection(_ workspace: WorkspaceState) async -> Bool {
        guard let capture = archiveSelectionCapture(in: workspace),
              let plan = ArchiveDestinationPlanner.compression(
                selectedItems: capture.selectedItems,
                in: capture.directory,
                occupiedNames: capture.occupiedNames
              )
        else { return false }
        let identityCapture = await captureArchiveIdentities(for: plan.selectedSources)
        return runArchive(plan, identityCapture: identityCapture, in: workspace)
    }

    @discardableResult
    func extractSelection(_ workspace: WorkspaceState) async -> Bool {
        guard let capture = archiveSelectionCapture(in: workspace),
              let plan = ArchiveDestinationPlanner.extraction(
                selectedItems: capture.selectedItems,
                in: capture.directory,
                occupiedNames: capture.occupiedNames
              )
        else { return false }
        let identityCapture = await captureArchiveIdentities(for: plan.selectedSources)
        return runArchive(plan, identityCapture: identityCapture, in: workspace)
    }

    private func archiveSelectionCapture(
        in workspace: WorkspaceState
    ) -> ArchiveSelectionCapture? {
        let pane = workspace.activePane
        let selectedURLs = pane.selection.sorted { $0.path < $1.path }
        guard !selectedURLs.isEmpty else { return nil }
        let itemsByURL = Dictionary(uniqueKeysWithValues: pane.items.map { ($0.url, $0) })
        let selectedItems = selectedURLs.compactMap { itemsByURL[$0] }
        guard selectedItems.count == selectedURLs.count else { return nil }
        return ArchiveSelectionCapture(
            selectedItems: selectedItems,
            directory: pane.currentDirectory,
            occupiedNames: Set(pane.items.map(\.name))
        )
    }

    private func captureArchiveIdentities(
        for sources: [URL]
    ) async -> ArchiveIdentityCapture {
        do {
            var requests: [IdentifiedFileRequest] = []
            for source in sources {
                try Task.checkCancellation()
                requests.append(IdentifiedFileRequest(
                    url: source,
                    identity: try await service.identity(of: source)
                ))
            }
            return .ready(requests)
        } catch is CancellationError {
            return .rejected(FileOperationResult(outcomes: sources.map {
                .cancelled(source: $0)
            }))
        } catch {
            return .rejected(FileOperationResult(outcomes: sources.map {
                .failed(source: $0, message: error.localizedDescription)
            }))
        }
    }

    private func runArchive(
        _ plan: ArchiveDestinationPlan,
        identityCapture: ArchiveIdentityCapture,
        in workspace: WorkspaceState
    ) -> Bool {
        let sources = plan.selectedSources
        let initialName = plan.destinations.first?.lastPathComponent ?? ""
        return beginOperation(
            totalCount: plan.destinations.count,
            initialName: initialName,
            initialStage: .preparing(CloudMaterializationProgress(
                completedCount: 0,
                totalCount: sources.count,
                currentName: Self.sanitizedBasename(sources.first)
            )),
            touchedDirectories: Set(plan.destinations.map { $0.deletingLastPathComponent() }),
            workspace: workspace
        ) { [weak self, service, materializer, archiveService] in
            guard let self else {
                return FileOperationResult(outcomes: sources.map {
                    .cancelled(source: $0)
                })
            }

            let captured: [IdentifiedFileRequest]
            switch identityCapture {
            case let .ready(requests):
                captured = requests
            case let .rejected(result):
                return result
            }

            let materialization = await materializer.materialize(
                captured,
                purpose: .archive
            ) { [weak self] progress in
                await MainActor.run {
                    self?.stage = .preparing(Self.sanitizedPreparationProgress(
                        progress,
                        requests: captured
                    ))
                }
            }
            self.lastPreparationFailures = materialization.failures

            guard !Task.isCancelled, !materialization.wasCancelled else {
                return FileOperationResult(outcomes: sources.map {
                    .cancelled(source: $0)
                })
            }
            guard materialization.failures.isEmpty,
                  let prepared = CloudOperationRequestGate
                    .identityPreservingPreparedRequests(
                        original: captured,
                        prepared: materialization.preparedRequests
                    )
            else {
                if materialization.failures.isEmpty {
                    self.lastPreparationFailures = sources.map {
                        CloudMaterializationFailure(
                            name: Self.sanitizedBasename($0),
                            reason: .itemChanged
                        )
                    }
                }
                return FileOperationResult(outcomes: sources.map { source in
                    let name = Self.sanitizedBasename(source)
                    let reason = materialization.failures.first {
                        $0.name == name
                    }?.reason ?? materialization.failures.first?.reason ?? .itemChanged
                    return .failed(
                        source: source,
                        message: Self.preparationFailureMessage(reason)
                    )
                })
            }

            do {
                for request in prepared {
                    try Task.checkCancellation()
                    let currentIdentity = try await service.identity(of: request.url)
                    guard currentIdentity.refersToSameItem(as: request.identity) else {
                        return self.archiveIdentityChangedResult(for: sources)
                    }
                }
            } catch is CancellationError {
                return FileOperationResult(outcomes: sources.map {
                    .cancelled(source: $0)
                })
            } catch {
                return self.archiveIdentityChangedResult(for: sources)
            }

            guard let archiveRequests = plan.requests(
                for: prepared.map(\.url)
            ),
            let firstRequest = archiveRequests.first
            else {
                return self.archiveIdentityChangedResult(for: sources)
            }
            self.stage = .archiving(ArchiveOperationProgress(
                kind: firstRequest.kind,
                currentDisplayName: firstRequest.progressDisplayName
            ))
            return await archiveService.perform(archiveRequests) { [weak self] progress in
                await MainActor.run {
                    self?.stage = .archiving(progress)
                }
            }
        }
    }

    private func archiveIdentityChangedResult(
        for sources: [URL]
    ) -> FileOperationResult {
        lastPreparationFailures = sources.map {
            CloudMaterializationFailure(
                name: Self.sanitizedBasename($0),
                reason: .itemChanged
            )
        }
        return FileOperationResult(outcomes: sources.map {
            .failed(
                source: $0,
                message: Self.preparationFailureMessage(.itemChanged)
            )
        })
    }

    @discardableResult
    func runTransfer(
        _ sources: [URL],
        to directory: URL,
        mode: TransferMode,
        workspace: WorkspaceState
    ) -> Bool {
        let touchedDirectories = Set(
            sources.map { $0.deletingLastPathComponent() } + [directory]
        )
        return beginOperation(
            totalCount: sources.count,
            initialName: sources.first?.lastPathComponent ?? "",
            initialStage: .preparing(CloudMaterializationProgress(
                completedCount: 0,
                totalCount: sources.count,
                currentName: Self.sanitizedBasename(sources.first)
            )),
            touchedDirectories: touchedDirectories,
            workspace: workspace
        ) { [weak self, service, materializer] in
            guard let self else {
                return FileOperationResult(outcomes: sources.map { .cancelled(source: $0) })
            }
            let destinationIdentity: FileIdentity
            do {
                destinationIdentity = try await service.identity(of: directory)
            } catch is CancellationError {
                return FileOperationResult(outcomes: sources.map { .cancelled(source: $0) })
            } catch {
                return FileOperationResult(outcomes: sources.map {
                    .failed(
                        source: $0,
                        message: "transfer-preparation:destination-identity-unavailable"
                    )
                })
            }
            let requests: [IdentifiedTransferRequest]
            do {
                var captured: [IdentifiedTransferRequest] = []
                for source in sources {
                    try Task.checkCancellation()
                    captured.append(IdentifiedTransferRequest(
                        source: source,
                        sourceIdentity: try await service.identity(of: source),
                        destinationRoot: directory,
                        destinationRootIdentity: destinationIdentity,
                        relativeParentComponents: []
                    ))
                }
                requests = captured
            } catch is CancellationError {
                return FileOperationResult(outcomes: sources.map { .cancelled(source: $0) })
            } catch {
                return FileOperationResult(outcomes: sources.map {
                    .failed(source: $0, message: error.localizedDescription)
                })
            }

            switch await self.prepareTransferRequests(requests, materializer: materializer) {
            case let .rejected(result):
                return result
            case let .ready(prepared):
                return await service.transfer(
                    prepared,
                    mode: mode,
                    resolveConflict: { [weak self] conflict in
                        guard let self else { return .cancel }
                        return await self.requestDecision(for: conflict)
                    },
                    progress: { [weak self] progress in
                        await MainActor.run {
                            self?.stage = .operating(progress)
                        }
                    }
                )
            }
        }
    }

    @discardableResult
    func runIdentifiedTransfer(
        _ requests: [IdentifiedTransferRequest],
        mode: TransferMode,
        workspace: WorkspaceState,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil
    ) -> Bool {
        let sources = requests.map(\.source)
        let safeRelativePaths = safeRelativePaths(for: requests)
        let touchedDirectories = Set(
            sources.map { $0.deletingLastPathComponent() }
                + requests.map(\.destinationRoot)
        )
        return beginOperation(
            totalCount: requests.count,
            initialName: sources.first?.lastPathComponent ?? "",
            initialStage: .preparing(CloudMaterializationProgress(
                completedCount: 0,
                totalCount: requests.count,
                currentName: Self.sanitizedBasename(sources.first)
            )),
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            onCompletion: onCompletion
        ) { [weak self, service, materializer] in
            guard let self else {
                return FileOperationResult(outcomes: sources.map { .cancelled(source: $0) })
            }
            let preparedRequests: [IdentifiedTransferRequest]
            switch await self.prepareTransferRequests(requests, materializer: materializer) {
            case let .rejected(result):
                return FileOperationResult(
                    outcomes: result.outcomes,
                    safeRelativePathsBySource: safeRelativePaths
                )
            case let .ready(prepared):
                preparedRequests = prepared
            }
            let result = await service.transfer(
                preparedRequests,
                mode: mode,
                resolveConflict: { [weak self] conflict in
                    guard let self else { return .cancel }
                    return await self.requestDecision(for: conflict)
                },
                progress: { [weak self] progress in
                    await MainActor.run {
                        self?.stage = .operating(progress)
                    }
                }
            )
            return FileOperationResult(
                outcomes: result.outcomes,
                safeRelativePathsBySource: safeRelativePaths
            )
        }
    }

    private enum PreparedTransferRequests {
        case ready([IdentifiedTransferRequest])
        case rejected(FileOperationResult)
    }

    private func prepareTransferRequests(
        _ requests: [IdentifiedTransferRequest],
        materializer: any CloudMaterializing
    ) async -> PreparedTransferRequests {
        let sourceRequests = requests.map {
            IdentifiedFileRequest(url: $0.source, identity: $0.sourceIdentity)
        }
        let result = await materializer.materialize(
            sourceRequests,
            purpose: .transfer
        ) { [weak self] progress in
            await MainActor.run {
                self?.stage = .preparing(Self.sanitizedPreparationProgress(
                    progress,
                    requests: sourceRequests
                ))
            }
        }
        lastPreparationFailures = result.failures

        guard !Task.isCancelled, !result.wasCancelled else {
            return .rejected(FileOperationResult(outcomes: requests.map {
                .cancelled(source: $0.source)
            }))
        }
        guard result.failures.isEmpty else {
            return .rejected(FileOperationResult(outcomes: requests.map {
                let name = Self.sanitizedBasename($0.source)
                let reason = result.failures.first(where: { $0.name == name })?.reason
                    ?? result.failures.first?.reason
                    ?? .providerFailure
                return .failed(
                    source: $0.source,
                    message: Self.preparationFailureMessage(reason)
                )
            }))
        }
        guard let preparedSources = CloudOperationRequestGate.identityPreservingPreparedRequests(
            original: sourceRequests,
            prepared: result.preparedRequests
        ) else {
            lastPreparationFailures = requests.map {
                CloudMaterializationFailure(
                    name: Self.sanitizedBasename($0.source),
                    reason: .itemChanged
                )
            }
            return .rejected(FileOperationResult(outcomes: requests.map {
                .failed(
                    source: $0.source,
                    message: Self.preparationFailureMessage(.itemChanged)
                )
            }))
        }

        stage = .operating(FileOperationProgress(
            completedCount: 0,
            totalCount: requests.count,
            currentName: Self.sanitizedBasename(requests.first?.source)
        ))
        return .ready(zip(requests, preparedSources).map { request, prepared in
            IdentifiedTransferRequest(
                source: request.source,
                sourceIdentity: prepared.identity,
                destinationRoot: request.destinationRoot,
                destinationRootIdentity: request.destinationRootIdentity,
                relativeParentComponents: request.relativeParentComponents
            )
        })
    }

    static func sanitizedPreparationProgress(
        _ progress: CloudMaterializationProgress,
        requests: [IdentifiedFileRequest]
    ) -> CloudMaterializationProgress {
        let total = requests.count
        let completed = min(max(progress.completedCount, 0), total)
        let index = min(max(completed - 1, 0), max(total - 1, 0))
        return CloudMaterializationProgress(
            completedCount: completed,
            totalCount: total,
            currentName: total > 0 ? sanitizedBasename(requests[index].url) : "Item"
        )
    }

    static func preparationFailureMessage(_ reason: CloudAvailabilityFailure) -> String {
        switch reason {
        case .offline:
            "cloud-preparation:offline"
        case .insufficientLocalStorage:
            "cloud-preparation:insufficient-storage"
        case .permissionDenied:
            "cloud-preparation:permission-denied"
        case .itemChanged:
            "cloud-preparation:item-changed"
        case .providerFailure:
            "cloud-preparation:provider-failure"
        }
    }

    static func sanitizedBasename(_ url: URL?) -> String {
        guard let name = url?.lastPathComponent, !name.isEmpty else { return "Item" }
        return name
    }

    private func safeRelativePaths(
        for requests: [IdentifiedTransferRequest]
    ) -> [URL: ComparisonRelativePath] {
        var result: [URL: ComparisonRelativePath] = [:]
        var ambiguous: Set<URL> = []
        for request in requests {
            let name = request.source.lastPathComponent
            guard (try? FilenameValidator.validate(name)) != nil,
                  let path = try? ComparisonRelativePath(
                      components: request.relativeParentComponents + [name]
                  )
            else { continue }
            let source = request.source.standardizedFileURL
            guard !ambiguous.contains(source) else { continue }
            if let existing = result[source], existing != path {
                result.removeValue(forKey: source)
                ambiguous.insert(source)
            } else {
                result[source] = path
            }
        }
        return result
    }

    @discardableResult
    func createFolder(
        in directory: URL,
        named name: String,
        workspace: WorkspaceState,
        beginInlineRenameIn renamePane: FilePaneState? = nil,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil
    ) -> Bool {
        let proposedURL = directory.appending(path: name, directoryHint: .isDirectory)
        let renameCapture = IdentifiedRequestCapture()
        return beginOperation(
            totalCount: 1,
            initialName: name,
            touchedDirectories: [directory],
            workspace: workspace,
            onCompletion: { result in
                if let renamePane, let target = renameCapture.take() {
                    _ = renamePane.selectForInlineRename(target)
                }
                onCompletion?(result)
            }
        ) { [service] in
            do {
                let createdURL = try await service.createFolder(in: directory, named: name)
                if renamePane != nil {
                    renameCapture.store(IdentifiedFileRequest(
                        url: createdURL,
                        identity: try await service.identity(of: createdURL)
                    ))
                }
                return FileOperationResult(outcomes: [
                    .succeeded(source: createdURL, destination: createdURL)
                ])
            } catch {
                return FileOperationResult(outcomes: [
                    .failed(source: proposedURL, message: error.localizedDescription)
                ])
            }
        }
    }

    @discardableResult
    func rename(
        _ source: URL,
        to name: String,
        workspace: WorkspaceState
    ) -> Bool {
        return beginOperation(
            totalCount: 1,
            initialName: source.lastPathComponent,
            touchedDirectories: [source.deletingLastPathComponent()],
            workspace: workspace
        ) { [service] in
            do {
                let destination = try await service.rename(source, to: name)
                return FileOperationResult(outcomes: [
                    .succeeded(source: source, destination: destination)
                ])
            } catch {
                return FileOperationResult(outcomes: [
                    .failed(source: source, message: error.localizedDescription)
                ])
            }
        }
    }

    func requestRename(in workspace: WorkspaceState) async -> Bool {
        let pane = workspace.activePane
        guard pane.selection.count == 1, let source = pane.selection.first else { return false }
        do {
            let target = IdentifiedFileRequest(url: source, identity: try await service.identity(of: source))
            guard pane.selection == [source] else { return false }
            return pane.requestInlineRename(target)
        } catch {
            return false
        }
    }

    @discardableResult
    func commitPendingRename(
        in pane: FilePaneState,
        to name: String,
        workspace: WorkspaceState
    ) -> Bool {
        guard let target = pane.takePendingRenameTarget() else { return false }
        return rename(target, to: name, workspace: workspace)
    }

    @discardableResult
    func rename(
        _ target: IdentifiedFileRequest,
        to name: String,
        workspace: WorkspaceState
    ) -> Bool {
        let source = target.url
        return beginOperation(
            totalCount: 1,
            initialName: source.lastPathComponent,
            touchedDirectories: [source.deletingLastPathComponent()],
            workspace: workspace
        ) { [service] in
            do {
                let destination = try await service.rename(
                    source,
                    identifiedBy: target.identity,
                    to: name
                )
                return FileOperationResult(outcomes: [
                    .succeeded(source: source, destination: destination)
                ])
            } catch {
                return FileOperationResult(outcomes: [
                    .failed(source: source, message: error.localizedDescription)
                ])
            }
        }
    }

    func requestTrashConfirmation(for urls: [URL], workspace: WorkspaceState) async {
        var requests: [IdentifiedFileRequest] = []
        for url in urls {
            let identity = (try? await service.identity(of: url)) ?? FileIdentity(
                entryIdentifier: "missing:\(UUID().uuidString)",
                resolvedIdentifier: "missing:\(UUID().uuidString)"
            )
            requests.append(IdentifiedFileRequest(url: url, identity: identity))
        }
        workspace.requestTrashConfirmation(for: requests)
    }

    @discardableResult
    func trash(_ sources: [URL], workspace: WorkspaceState) -> Bool {
        let touchedDirectories = Set(sources.map { $0.deletingLastPathComponent() })
        return beginOperation(
            totalCount: sources.count,
            initialName: sources.first?.lastPathComponent ?? "",
            touchedDirectories: touchedDirectories,
            workspace: workspace
        ) { [weak self, service] in
            var requests: [IdentifiedFileRequest] = []
            var captureFailures: [FileOperationItemOutcome] = []
            for source in sources {
                do {
                    requests.append(IdentifiedFileRequest(
                        url: source,
                        identity: try await service.identity(of: source)
                    ))
                } catch {
                    captureFailures.append(.failed(source: source, message: error.localizedDescription))
                }
            }
            let result = await service.trash(requests) { [weak self] progress in
                await MainActor.run { self?.stage = .operating(progress) }
            }
            return FileOperationResult(outcomes: captureFailures + result.outcomes)
        }
    }

    @discardableResult
    func trash(
        _ requests: [IdentifiedFileRequest],
        workspace: WorkspaceState,
        privacySafeProgress: Bool = false,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil
    ) -> Bool {
        let sources = requests.map(\.url)
        let touchedDirectories = Set(sources.map { $0.deletingLastPathComponent() })
        return beginOperation(
            totalCount: sources.count,
            initialName: privacySafeProgress
                ? "Item"
                : sources.first?.lastPathComponent ?? "",
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            onCompletion: onCompletion
        ) { [weak self, service] in
            await service.trash(requests) { [weak self] progress in
                await MainActor.run {
                    self?.stage = .operating(FileOperationProgress(
                        completedCount: progress.completedCount,
                        totalCount: progress.totalCount,
                        currentName: privacySafeProgress ? "Item" : progress.currentName
                    ))
                }
            }
        }
    }

    @discardableResult
    func trashStorageCleanup(
        _ groups: [StorageCleanupMutationGroup],
        workspace: WorkspaceState,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil
    ) -> Bool {
        let entries = groups.flatMap(\.trash)
        let touchedDirectories = Set(entries.map { $0.url.deletingLastPathComponent() })
        return beginOperation(
            totalCount: entries.count,
            initialName: "Item",
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            onCompletion: onCompletion
        ) { [weak self, service] in
            await service.trashStorageCleanup(groups) { [weak self] progress in
                await MainActor.run {
                    self?.stage = .operating(FileOperationProgress(
                        completedCount: progress.completedCount,
                        totalCount: progress.totalCount,
                        currentName: "Item"
                    ))
                }
            }
        }
    }

    private func beginOperation(
        totalCount: Int,
        initialName: String,
        initialStage: FileOperationStage? = nil,
        touchedDirectories: Set<URL>,
        workspace: WorkspaceState,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil,
        operation: @escaping @MainActor () async -> FileOperationResult
    ) -> Bool {
        guard !isRunning else { return false }

        isRunning = true
        stage = initialStage ?? .operating(FileOperationProgress(
            completedCount: 0,
            totalCount: totalCount,
            currentName: initialName
        ))
        lastResult = nil
        lastPreparationFailures = []
        applyToAllDecision = nil

        operationTask = Task { [weak self, workspace] in
            guard let self else { return }
            let result = await operation()
            let completionTask = Task { @MainActor [weak self, workspace] in
                await self?.completeOperation(
                    with: result,
                    touching: touchedDirectories,
                    in: workspace
                )
                onCompletion?(result)
            }
            await completionTask.value
        }
        return true
    }

    private func completeOperation(
        with result: FileOperationResult,
        touching directories: Set<URL>,
        in workspace: WorkspaceState
    ) async {
        lastResult = result
        if let progress {
            stage = .operating(FileOperationProgress(
                completedCount: result.outcomes.count,
                totalCount: progress.totalCount,
                currentName: progress.currentName
            ))
        }
        await refreshVisiblePanes(in: workspace, touching: directories)
        isRunning = false
        operationTask = nil
        applyToAllDecision = nil
    }

    private func refreshVisiblePanes(
        in workspace: WorkspaceState,
        touching directories: Set<URL>
    ) async {
        let standardizedDirectories = Set(directories.map(directoryKey))
        for pane in [workspace.left, workspace.right]
        where standardizedDirectories.contains(directoryKey(pane.currentDirectory)) {
            await pane.navigate(to: pane.currentDirectory, recordHistory: false)
        }
    }

    private func directoryKey(_ directory: URL) -> String {
        var path = directory.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

private struct ArchiveSelectionCapture {
    let selectedItems: [FileItem]
    let directory: URL
    let occupiedNames: Set<String>
}

private enum ArchiveIdentityCapture {
    case ready([IdentifiedFileRequest])
    case rejected(FileOperationResult)
}

private final class IdentifiedRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: IdentifiedFileRequest?

    func store(_ request: IdentifiedFileRequest) {
        lock.withLock { self.request = request }
    }

    func take() -> IdentifiedFileRequest? {
        lock.withLock {
            defer { request = nil }
            return request
        }
    }
}
