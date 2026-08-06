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

struct ArchiveProgressPublicationGate {
    private var lastPublishedAt: ContinuousClock.Instant?
    private var lastPublishedProgress: (completedCount: Int, totalCount: Int)?
    private let minimumInterval: Duration

    init(minimumInterval: Duration = .milliseconds(100)) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldPublish(
        completedCount: Int,
        totalCount: Int,
        at now: ContinuousClock.Instant
    ) -> Bool {
        if let lastPublishedProgress,
           lastPublishedProgress.completedCount == completedCount,
           lastPublishedProgress.totalCount == totalCount {
            return false
        }
        let isBoundary = completedCount <= 0 || completedCount >= totalCount
        if !isBoundary,
           let lastPublishedAt,
           now - lastPublishedAt < minimumInterval {
            return false
        }
        lastPublishedAt = now
        lastPublishedProgress = (completedCount, totalCount)
        return true
    }

    mutating func reset() {
        lastPublishedAt = nil
        lastPublishedProgress = nil
    }
}

@MainActor @Observable
final class FileOperationController {
    private let service: FileOperationService
    private let materializer: any CloudMaterializing
    private let archiveService: any ArchiveOperating
    private let undoService: FileOperationUndoService

    private(set) var stage: FileOperationStage?
    private(set) var pendingConflict: FileConflict?
    private(set) var lastResult: FileOperationResult?
    private(set) var lastPreparationFailures: [CloudMaterializationFailure] = []
    private(set) var isRunning = false
    private(set) var activeJob: FileOperationJobSnapshot?
    private(set) var queuedJobs: [FileOperationJobSnapshot] = []
    private(set) var operationHistory: [FileOperationJobSnapshot] = []
    private(set) var isPaused = false
    private(set) var isQueueBlockedByRecovery = false

    var progress: FileOperationProgress? {
        guard case let .operating(progress) = stage else { return nil }
        return progress
    }

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?
    @ObservationIgnored private var conflictRequestID: UUID?
    @ObservationIgnored private var applyToAllDecision: ConflictDecision?
    @ObservationIgnored private var pendingOperations: [PendingFileOperation] = []
    @ObservationIgnored private var activeOperation: PendingFileOperation?
    @ObservationIgnored private var activeControl: FileOperationControl?
    @ObservationIgnored private var retryOperations: [UUID: PendingFileOperation] = [:]
    @ObservationIgnored private var undoRecipes: [UUID: FileOperationUndoRecipe] = [:]
    @ObservationIgnored private var undoDirectoryKeys: [UUID: Set<String>] = [:]
    @ObservationIgnored private var activeOperationDidReplace = false
    @ObservationIgnored private var archiveProgressGate = ArchiveProgressPublicationGate()
    @ObservationIgnored private let historyLimit: Int

    init(
        service: FileOperationService,
        materializer: any CloudMaterializing,
        archiveService: (any ArchiveOperating)? = nil,
        historyLimit: Int = 100
    ) {
        self.service = service
        self.materializer = materializer
        self.archiveService = archiveService
            ?? service.makeArchiveOperationService()
        self.undoService = service.makeUndoService()
        self.historyLimit = max(historyLimit, 1)
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
        if decision == .replace {
            activeOperationDidReplace = true
        }
        if applyToAll, decision != .cancel {
            applyToAllDecision = decision
        }
        pendingConflict = nil
        conflictContinuation = nil
        conflictRequestID = nil
        continuation.resume(returning: decision)
    }

    func cancel() {
        cancelActiveJob()
    }

    func cancelActiveJob() {
        operationTask?.cancel()
        if let activeControl {
            Task { await activeControl.cancel() }
        }
        resolvePendingConflict(.cancel, applyToAll: false)
    }

    @discardableResult
    func continueAfterRecovery() -> Bool {
        guard isQueueBlockedByRecovery else { return false }
        isQueueBlockedByRecovery = false
        startNextOperationIfNeeded()
        return true
    }

    func pauseActiveJob() async {
        guard let activeControl, let activeJob else { return }
        await activeControl.pause()
        isPaused = false
        self.activeJob = snapshot(
            for: activeJob,
            state: .pauseRequested,
            progress: activeJob.progress,
            canUndo: false
        )
    }

    func resumeActiveJob() async {
        guard let activeControl, let activeJob else { return }
        await activeControl.resume()
        isPaused = false
        self.activeJob = snapshot(
            for: activeJob,
            state: .running,
            progress: activeJob.progress,
            canUndo: false
        )
    }

    @discardableResult
    func cancelQueuedJob(_ id: UUID) -> Bool {
        guard let index = pendingOperations.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let pending = pendingOperations.remove(at: index)
        queuedJobs.removeAll { $0.id == id }
        retryOperations[id] = pending
        let cancellationResult = pending.cancellationResult
        recordHistory(pending.snapshot(
            state: .cancelled,
            canRetry: pending.allowsRetry
        ))
        pending.onCompletion?(cancellationResult)
        return true
    }

    @discardableResult
    func moveQueuedJob(_ id: UUID, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
              let currentIndex = pendingOperations.firstIndex(where: { $0.id == id })
        else { return false }
        let destinationIndex = currentIndex + offset
        guard pendingOperations.indices.contains(destinationIndex) else { return false }
        pendingOperations.swapAt(currentIndex, destinationIndex)
        guard let snapshotIndex = queuedJobs.firstIndex(where: { $0.id == id }) else {
            pendingOperations.swapAt(currentIndex, destinationIndex)
            return false
        }
        let snapshotDestination = snapshotIndex + offset
        guard queuedJobs.indices.contains(snapshotDestination) else {
            pendingOperations.swapAt(currentIndex, destinationIndex)
            return false
        }
        queuedJobs.swapAt(snapshotIndex, snapshotDestination)
        return true
    }

    @discardableResult
    func retryJob(_ id: UUID) -> Bool {
        guard operationHistory.first(where: { $0.id == id })?.canRetry == true,
              let original = retryOperations[id]
        else { return false }
        return enqueue(original.retryAttempt())
    }

    @discardableResult
    func undoJob(_ id: UUID) -> Bool {
        guard activeOperation == nil,
              pendingOperations.isEmpty,
              operationHistory.first(where: { $0.id == id })?.canUndo == true,
              let recipe = undoRecipes.removeValue(forKey: id),
              let original = retryOperations[id]
        else { return false }

        undoDirectoryKeys.removeValue(forKey: id)
        setUndoEligibility(for: id, canUndo: false)
        return beginOperation(
            kind: .undo,
            totalCount: recipe.itemCount,
            initialName: recipe.displayName,
            touchedDirectories: recipe.touchedDirectories,
            workspace: original.workspace,
            cancellationSources: Array(recipe.touchedDirectories),
            allowsRetry: false,
            requiresExclusiveQueue: true
        ) { [weak self] in
            guard let self else {
                return FileOperationResult(outcomes: [])
            }
            return await self.undoService.perform(recipe) { [weak self] progress in
                guard let self else { return }
                await self.publish(stage: .operating(progress))
            }
        }
    }

    private func cancelPendingDecision(requestID: UUID) {
        guard conflictRequestID == requestID else { return }
        resolvePendingConflict(.cancel, applyToAll: false)
    }

    @discardableResult
    func compressSelection(
        _ workspace: WorkspaceState,
        format: ArchiveFormat = .zip
    ) async -> Bool {
        guard let capture = archiveSelectionCapture(in: workspace),
              let plan = ArchiveDestinationPlanner.compression(
                selectedItems: capture.selectedItems,
                in: capture.directory,
                occupiedNames: capture.occupiedNames,
                format: format
              )
        else { return false }
        let identityCapture = await captureArchiveIdentities(for: plan)
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
        let identityCapture = await captureArchiveIdentities(for: plan)
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
        for plan: ArchiveDestinationPlan
    ) async -> ArchiveIdentityCapture {
        let sources = plan.selectedSources
        do {
            var requests: [IdentifiedFileRequest] = []
            for source in sources {
                try Task.checkCancellation()
                requests.append(IdentifiedFileRequest(
                    url: source,
                    identity: try await service.identity(of: source)
                ))
            }
            guard let destinationParent = plan.destinations.first?
                .deletingLastPathComponent() else {
                throw ArchiveOperationError.invalidRequest
            }
            return .ready(
                requests,
                destinationParentIdentity: try await service.identity(of: destinationParent)
            )
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
        let jobKind: FileOperationJobKind = switch plan.kind {
        case .compress:
            .compress(plan.formats.first ?? .zip)
        case .extract:
            .extract(plan.formats.first ?? .zip)
        }
        return beginOperation(
            kind: jobKind,
            totalCount: plan.destinations.count,
            initialName: initialName,
            initialStage: .preparing(CloudMaterializationProgress(
                completedCount: 0,
                totalCount: sources.count,
                currentName: Self.sanitizedBasename(sources.first)
            )),
            touchedDirectories: Set(plan.destinations.map { $0.deletingLastPathComponent() }),
            workspace: workspace,
            cancellationSources: sources
        ) { [weak self, service, materializer, archiveService] in
            guard let self else {
                return FileOperationResult(outcomes: sources.map {
                    .cancelled(source: $0)
                })
            }

            let captured: [IdentifiedFileRequest]
            let destinationParentIdentity: FileIdentity
            switch identityCapture {
            case let .ready(requests, parentIdentity):
                captured = requests
                destinationParentIdentity = parentIdentity
            case let .rejected(result):
                return result
            }

            let materialization = await materializer.materialize(
                captured,
                purpose: .archive
            ) { [weak self] progress in
                guard let self else { return }
                await self.publish(stage: .preparing(Self.sanitizedPreparationProgress(
                    progress,
                    requests: captured
                )))
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
                for: prepared,
                destinationParentIdentity: destinationParentIdentity
            ),
            let firstRequest = archiveRequests.first
            else {
                return self.archiveIdentityChangedResult(for: sources)
            }
            await self.publish(stage: .archiving(ArchiveOperationProgress(
                kind: firstRequest.kind,
                currentDisplayName: firstRequest.progressDisplayName,
                format: firstRequest.format
            )))
            return await archiveService.perform(archiveRequests) { [weak self] progress in
                guard let self else { return }
                await self.publish(stage: .archiving(progress))
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
    ) async -> Bool {
        guard !sources.isEmpty else { return false }
        let touchedDirectories = Set(
            sources.map { $0.deletingLastPathComponent() } + [directory]
        )
        let destinationIdentity: FileIdentity
        do {
            try Task.checkCancellation()
            destinationIdentity = try await service.identity(of: directory)
        } catch is CancellationError {
            return false
        } catch {
            let result = FileOperationResult(outcomes: sources.map {
                .failed(
                    source: $0,
                    message: "transfer-preparation:destination-identity-unavailable"
                )
            })
            return beginOperation(
                kind: mode == .copy ? .copy : .move,
                totalCount: sources.count,
                initialName: sources.first?.lastPathComponent ?? "",
                touchedDirectories: touchedDirectories,
                workspace: workspace
            ) { result }
        }

        do {
            var requests: [IdentifiedTransferRequest] = []
            for source in sources {
                try Task.checkCancellation()
                requests.append(IdentifiedTransferRequest(
                    source: source,
                    sourceIdentity: try await service.identity(of: source),
                    destinationRoot: directory,
                    destinationRootIdentity: destinationIdentity,
                    relativeParentComponents: []
                ))
            }
            return runIdentifiedTransfer(
                requests,
                mode: mode,
                workspace: workspace,
                includeSafeRelativePaths: false
            )
        } catch is CancellationError {
            return false
        } catch {
            let result = FileOperationResult(outcomes: sources.map {
                .failed(source: $0, message: error.localizedDescription)
            })
            return beginOperation(
                kind: mode == .copy ? .copy : .move,
                totalCount: sources.count,
                initialName: sources.first?.lastPathComponent ?? "",
                touchedDirectories: touchedDirectories,
                workspace: workspace
            ) { result }
        }
    }

    @discardableResult
    func runIdentifiedTransfer(
        _ requests: [IdentifiedTransferRequest],
        mode: TransferMode,
        workspace: WorkspaceState,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil,
        includeSafeRelativePaths: Bool = true
    ) -> Bool {
        let sources = requests.map(\.source)
        let safeRelativePaths = safeRelativePaths(for: requests)
        let touchedDirectories = Set(
            sources.map { $0.deletingLastPathComponent() }
                + requests.map(\.destinationRoot)
        )
        return beginOperation(
            kind: mode == .copy ? .copy : .move,
            totalCount: requests.count,
            initialName: sources.first?.lastPathComponent ?? "",
            initialStage: .preparing(CloudMaterializationProgress(
                completedCount: 0,
                totalCount: requests.count,
                currentName: Self.sanitizedBasename(sources.first)
            )),
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            cancellationSources: sources,
            onCompletion: onCompletion
        ) { [weak self, service, materializer] in
            guard let self else {
                return FileOperationResult(outcomes: sources.map { .cancelled(source: $0) })
            }
            let preparedRequests: [IdentifiedTransferRequest]
            switch await self.prepareTransferRequests(requests, materializer: materializer) {
            case let .rejected(result):
                return includeSafeRelativePaths
                    ? FileOperationResult(
                        outcomes: result.outcomes,
                        safeRelativePathsBySource: safeRelativePaths
                    )
                    : result
            case let .ready(prepared):
                preparedRequests = prepared
            }
            let result = await service.transfer(
                preparedRequests,
                mode: mode,
                resolveConflict: { [weak self] conflict in
                    guard let self else { return .cancel }
                    let decision = await self.requestDecision(for: conflict)
                    await self.waitIfPaused()
                    return decision
                },
                progress: { [weak self] progress in
                    guard let self else { return }
                    await self.publish(stage: .operating(progress))
                }
            )
            return includeSafeRelativePaths
                ? result.addingSafeRelativePaths(safeRelativePaths)
                : result
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
            guard let self else { return }
            await self.publish(stage: .preparing(Self.sanitizedPreparationProgress(
                progress,
                requests: sourceRequests
            )))
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
    ) async -> Bool {
        let proposedURL = directory.appending(path: name, directoryHint: .isDirectory)
        let renameCapture = IdentifiedRequestCapture()
        let directoryIdentity: FileIdentity
        do {
            directoryIdentity = try await service.identity(of: directory)
        } catch {
            return beginOperation(
                kind: .createFolder,
                totalCount: 1,
                initialName: name,
                touchedDirectories: [directory],
                workspace: workspace,
                cancellationSources: [proposedURL],
                onCompletion: onCompletion
            ) {
                FileOperationResult(outcomes: [
                    .failed(
                        source: proposedURL,
                        message: "folder-preparation:directory-identity-unavailable"
                    )
                ])
            }
        }
        return beginOperation(
            kind: .createFolder,
            totalCount: 1,
            initialName: name,
            touchedDirectories: [directory],
            workspace: workspace,
            cancellationSources: [proposedURL],
            onCompletion: { result in
                if let renamePane, let target = renameCapture.take() {
                    _ = renamePane.selectForInlineRename(target)
                }
                onCompletion?(result)
            }
        ) { [service] in
            do {
                let created = try await service.createFolder(
                    in: directory,
                    identifiedBy: directoryIdentity,
                    named: name
                )
                if renamePane != nil {
                    renameCapture.store(IdentifiedFileRequest(
                        url: created.url,
                        identity: created.identity
                    ))
                }
                return FileOperationResult(outcomes: [
                    .succeeded(source: created.url, destination: created.url)
                ], undoDestinationIdentities: [created.url: created.identity],
                undoDestinationFingerprints: created.fingerprint.map {
                    [created.url: $0]
                } ?? [:])
            } catch is CancellationError {
                return FileOperationResult(outcomes: [
                    .cancelled(source: proposedURL)
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
            kind: .rename,
            totalCount: 1,
            initialName: source.lastPathComponent,
            touchedDirectories: [source.deletingLastPathComponent()],
            workspace: workspace,
            cancellationSources: [source]
        ) { [service] in
            do {
                let destination = try await service.rename(source, to: name)
                return FileOperationResult(outcomes: [
                    .succeeded(source: source, destination: destination)
                ])
            } catch is CancellationError {
                return FileOperationResult(outcomes: [
                    .cancelled(source: source)
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
            kind: .rename,
            totalCount: 1,
            initialName: source.lastPathComponent,
            touchedDirectories: [source.deletingLastPathComponent()],
            workspace: workspace,
            cancellationSources: [source]
        ) { [service] in
            do {
                let destination = try await service.rename(
                    source,
                    identifiedBy: target.identity,
                    to: name
                )
                return FileOperationResult(outcomes: [
                    .succeeded(source: source, destination: destination)
                ], undoDestinationIdentities: [destination: target.identity])
            } catch is CancellationError {
                return FileOperationResult(outcomes: [
                    .cancelled(source: source)
                ])
            } catch {
                return FileOperationResult(outcomes: [
                    .failed(source: source, message: error.localizedDescription)
                ])
            }
        }
    }

    func requestTrashConfirmation(for urls: [URL], workspace: WorkspaceState) async {
        let paneID = workspace.activePaneID
        let requestedSelection = Set(urls)
        guard !requestedSelection.isEmpty,
              workspace.activePane.selection == requestedSelection
        else { return }
        var requests: [IdentifiedFileRequest] = []
        for url in urls {
            let identity = (try? await service.identity(of: url)) ?? FileIdentity(
                entryIdentifier: "missing:\(UUID().uuidString)",
                resolvedIdentifier: "missing:\(UUID().uuidString)"
            )
            requests.append(IdentifiedFileRequest(url: url, identity: identity))
        }
        guard workspace.activePaneID == paneID,
              workspace.activePane.selection == requestedSelection
        else { return }
        workspace.requestTrashConfirmation(for: requests)
    }

    @discardableResult
    func trashImmediately(
        _ sources: [URL],
        workspace: WorkspaceState
    ) async -> Bool {
        guard !sources.isEmpty else { return false }
        do {
            var requests: [IdentifiedFileRequest] = []
            for source in sources {
                try Task.checkCancellation()
                requests.append(IdentifiedFileRequest(
                    url: source,
                    identity: try await service.identity(of: source)
                ))
            }
            return trash(requests, workspace: workspace)
        } catch is CancellationError {
            return false
        } catch {
            let result = FileOperationResult(outcomes: sources.map {
                .failed(source: $0, message: error.localizedDescription)
            })
            return beginOperation(
                kind: .trash,
                totalCount: sources.count,
                initialName: sources.first?.lastPathComponent ?? "",
                touchedDirectories: Set(sources.map { $0.deletingLastPathComponent() }),
                workspace: workspace,
                cancellationSources: sources
            ) { result }
        }
    }

    @discardableResult
    func trash(_ sources: [URL], workspace: WorkspaceState) -> Bool {
        let touchedDirectories = Set(sources.map { $0.deletingLastPathComponent() })
        return beginOperation(
            kind: .trash,
            totalCount: sources.count,
            initialName: sources.first?.lastPathComponent ?? "",
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            cancellationSources: sources
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
                guard let self else { return }
                await self.publish(stage: .operating(progress))
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
            kind: .trash,
            totalCount: sources.count,
            initialName: privacySafeProgress
                ? "Item"
                : sources.first?.lastPathComponent ?? "",
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            cancellationSources: sources,
            onCompletion: onCompletion
        ) { [weak self, service] in
            await service.trash(requests) { [weak self] progress in
                guard let self else { return }
                await self.publish(stage: .operating(FileOperationProgress(
                    completedCount: progress.completedCount,
                    totalCount: progress.totalCount,
                    currentName: privacySafeProgress ? "Item" : progress.currentName
                )))
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
            kind: .trash,
            totalCount: entries.count,
            initialName: "Item",
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            cancellationSources: entries.map(\.url),
            allowsRetry: false,
            requiresExclusiveQueue: true,
            onCompletion: onCompletion
        ) { [weak self, service] in
            await service.trashStorageCleanup(groups) { [weak self] progress in
                guard let self else { return }
                await self.publish(stage: .operating(FileOperationProgress(
                    completedCount: progress.completedCount,
                    totalCount: progress.totalCount,
                    currentName: "Item"
                )))
            }
        }
    }

    private func beginOperation(
        kind: FileOperationJobKind,
        totalCount: Int,
        initialName: String,
        initialStage: FileOperationStage? = nil,
        touchedDirectories: Set<URL>,
        workspace: WorkspaceState,
        cancellationSources: [URL] = [],
        allowsRetry: Bool = true,
        requiresExclusiveQueue: Bool = false,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil,
        operation: @escaping @MainActor () async -> FileOperationResult
    ) -> Bool {
        enqueue(PendingFileOperation(
            kind: kind,
            itemDisplayName: initialName,
            itemCount: totalCount,
            initialStage: initialStage,
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            cancellationSources: cancellationSources,
            allowsRetry: allowsRetry,
            requiresExclusiveQueue: requiresExclusiveQueue,
            onCompletion: onCompletion,
            operation: operation
        ))
    }

    @discardableResult
    private func enqueue(_ pending: PendingFileOperation) -> Bool {
        if pending.requiresExclusiveQueue {
            guard activeOperation == nil, pendingOperations.isEmpty else { return false }
        } else if activeOperation?.requiresExclusiveQueue == true
            || pendingOperations.contains(where: \.requiresExclusiveQueue) {
            return false
        }
        pendingOperations.append(pending)
        queuedJobs.append(pending.snapshot(state: .queued))
        startNextOperationIfNeeded()
        return true
    }

    private func startNextOperationIfNeeded() {
        guard activeOperation == nil,
              !isQueueBlockedByRecovery,
              !pendingOperations.isEmpty
        else { return }
        let pending = pendingOperations.removeFirst()
        queuedJobs.removeAll { $0.id == pending.id }
        invalidateUndoRecipes(touching: pending.touchedDirectories)

        let control = FileOperationControl()
        activeOperation = pending
        activeControl = control
        activeJob = pending.snapshot(state: .running)
        isPaused = false
        isRunning = true
        stage = pending.initialStage ?? .operating(FileOperationProgress(
            completedCount: 0,
            totalCount: pending.itemCount,
            currentName: pending.itemDisplayName
        ))
        lastResult = nil
        lastPreparationFailures = []
        applyToAllDecision = nil
        activeOperationDidReplace = false
        archiveProgressGate.reset()

        operationTask = Task { [weak self] in
            guard let self else { return }
            let execution: (result: FileOperationResult, cancelledBeforeStart: Bool)
            do {
                await self.acknowledgePauseIfRequested(using: control)
                try await control.checkpoint()
                execution = (await pending.operation(), false)
            } catch {
                execution = (pending.cancellationResult, true)
            }
            let completionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.completeOperation(
                    with: execution.result,
                    pending: pending,
                    cancelledBeforeStart: execution.cancelledBeforeStart
                )
                pending.onCompletion?(execution.result)
                self.startNextOperationIfNeeded()
            }
            await completionTask.value
        }
    }

    private func waitIfPaused() async {
        guard let activeControl else { return }
        await acknowledgePauseIfRequested(using: activeControl)
        try? await activeControl.checkpoint()
    }

    private func acknowledgePauseIfRequested(
        using control: FileOperationControl
    ) async {
        guard await control.isPaused,
              activeControl === control,
              let activeJob,
              activeJob.state == .pauseRequested
        else { return }
        isPaused = true
        self.activeJob = snapshot(
            for: activeJob,
            state: .paused,
            progress: activeJob.progress,
            canUndo: false
        )
    }

    private func publish(stage newStage: FileOperationStage) async {
        await waitIfPaused()
        guard !Task.isCancelled else { return }
        if case let .archiving(progress) = newStage,
           case let .preparingSources(completedCount, totalCount) = progress.phase,
           !archiveProgressGate.shouldPublish(
               completedCount: completedCount,
               totalCount: totalCount,
               at: ContinuousClock.now
           ) {
            return
        }
        stage = newStage
        guard let activeJob else { return }
        self.activeJob = snapshot(
            for: activeJob,
            state: activeJob.state,
            progress: jobProgress(for: newStage),
            canUndo: false
        )
    }

    private func jobProgress(for stage: FileOperationStage) -> FileOperationJobProgress? {
        switch stage {
        case let .preparing(progress):
            FileOperationJobProgress(
                completedCount: progress.completedCount,
                totalCount: progress.totalCount,
                detail: "Preparing download"
            )
        case let .operating(progress):
            FileOperationJobProgress(
                completedCount: progress.completedCount,
                totalCount: progress.totalCount,
                detail: "Processing files"
            )
        case let .archiving(progress):
            switch progress.phase {
            case let .preparingSources(completedCount, totalCount):
                FileOperationJobProgress(
                    completedCount: completedCount,
                    totalCount: totalCount,
                    detail: "Preparing files"
                )
            case let .processingBytes(completedByteCount, totalByteCount):
                FileOperationJobProgress(
                    completedCount: Int(clamping: completedByteCount),
                    totalCount: totalByteCount.map(Int.init(clamping:)) ?? 0,
                    detail: "Processing archive"
                )
            case .encoding:
                FileOperationJobProgress(
                    completedCount: 0,
                    totalCount: 0,
                    detail: "Encoding archive"
                )
            case .publishing:
                FileOperationJobProgress(
                    completedCount: 0,
                    totalCount: 0,
                    detail: "Finishing archive"
                )
            }
        }
    }

    private func completeOperation(
        with result: FileOperationResult,
        pending: PendingFileOperation,
        cancelledBeforeStart: Bool = false
    ) async {
        lastResult = result
        if let progress {
            stage = .operating(FileOperationProgress(
                completedCount: result.outcomes.count,
                totalCount: progress.totalCount,
                currentName: progress.currentName
            ))
        }
        await refreshVisiblePanes(
            in: pending.workspace,
            touching: pending.touchedDirectories
        )
        let completedState: FileOperationJobState = cancelledBeforeStart
            ? .cancelled
            : terminalState(for: result)
        let canRetry = pending.allowsRetry && (cancelledBeforeStart || (!result.outcomes.isEmpty && result.outcomes.allSatisfy {
            switch $0 {
            case .failed, .cancelled:
                true
            case .succeeded, .recoveryNeeded, .skipped:
                false
            }
        }))
        let recipe: FileOperationUndoRecipe?
        if completedState == .succeeded {
            recipe = await undoService.makeRecipe(
                kind: pending.kind,
                result: result,
                allowsUndo: !activeOperationDidReplace
            )
        } else {
            recipe = nil
        }
        if let recipe {
            undoRecipes[pending.id] = recipe
            undoDirectoryKeys[pending.id] = Set(
                recipe.touchedDirectories.flatMap(directoryKeys)
            )
        }
        retryOperations[pending.id] = pending
        recordHistory(pending.snapshot(
            state: completedState,
            canUndo: recipe != nil,
            canRetry: canRetry
        ))
        if result.outcomes.contains(where: {
            if case .recoveryNeeded = $0 { return true }
            return false
        }) {
            isQueueBlockedByRecovery = true
        }
        activeJob = nil
        activeOperation = nil
        activeControl = nil
        isPaused = false
        isRunning = false
        operationTask = nil
        applyToAllDecision = nil
        activeOperationDidReplace = false
        archiveProgressGate.reset()
    }

    private func terminalState(for result: FileOperationResult) -> FileOperationJobState {
        var sawFailure = false
        var sawCancellation = false
        for outcome in result.outcomes {
            switch outcome {
            case .failed, .recoveryNeeded:
                sawFailure = true
            case .cancelled:
                sawCancellation = true
            case .succeeded, .skipped:
                break
            }
        }
        if sawFailure { return .failed }
        if sawCancellation { return .cancelled }
        return .succeeded
    }

    private func recordHistory(_ snapshot: FileOperationJobSnapshot) {
        operationHistory.insert(snapshot, at: 0)
        guard operationHistory.count > historyLimit else { return }
        let removed = Array(operationHistory.suffix(from: historyLimit))
        operationHistory.removeSubrange(historyLimit...)
        for item in removed {
            retryOperations.removeValue(forKey: item.id)
            undoRecipes.removeValue(forKey: item.id)
            undoDirectoryKeys.removeValue(forKey: item.id)
        }
    }

    private func setUndoEligibility(for id: UUID, canUndo: Bool) {
        guard let index = operationHistory.firstIndex(where: { $0.id == id }) else { return }
        let current = operationHistory[index]
        operationHistory[index] = snapshot(
            for: current,
            state: current.state,
            progress: current.progress,
            canUndo: canUndo
        )
    }

    private func invalidateUndoRecipes(touching directories: Set<URL>) {
        let currentKeys = Set(directories.flatMap(directoryKeys))
        guard !currentKeys.isEmpty else { return }
        let invalidated = undoRecipes.compactMap { id, recipe -> UUID? in
            let recipeKeys = undoDirectoryKeys[id]
                ?? Set(recipe.touchedDirectories.flatMap(directoryKeys))
            return recipeKeys.contains(where: { recipeKey in
                currentKeys.contains(where: { pathsOverlap(recipeKey, $0) })
            }) ? id : nil
        }
        for id in invalidated {
            undoRecipes.removeValue(forKey: id)
            undoDirectoryKeys.removeValue(forKey: id)
            setUndoEligibility(for: id, canUndo: false)
        }
    }

    private func snapshot(
        for original: FileOperationJobSnapshot,
        state: FileOperationJobState,
        progress: FileOperationJobProgress?,
        canUndo: Bool
    ) -> FileOperationJobSnapshot {
        FileOperationJobSnapshot(
            id: original.id,
            kind: original.kind,
            itemDisplayName: original.itemDisplayName,
            itemCount: original.itemCount,
            state: state,
            progress: progress,
            canUndo: canUndo,
            canRetry: original.isRetryEligible
        )
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

    private func directoryKeys(_ directory: URL) -> [String] {
        let lexical = directoryKey(directory)
        let resolved = directoryKey(directory.resolvingSymlinksInPath())
        return lexical == resolved ? [lexical] : [lexical, resolved]
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
            || lhs.hasPrefix(rhs == "/" ? "/" : rhs + "/")
            || rhs.hasPrefix(lhs == "/" ? "/" : lhs + "/")
    }
}

@MainActor
private struct PendingFileOperation {
    let id: UUID
    let kind: FileOperationJobKind
    let itemDisplayName: String
    let itemCount: Int
    let initialStage: FileOperationStage?
    let touchedDirectories: Set<URL>
    let workspace: WorkspaceState
    let cancellationSources: [URL]
    let allowsRetry: Bool
    let requiresExclusiveQueue: Bool
    let onCompletion: (@MainActor (FileOperationResult) -> Void)?
    let operation: @MainActor () async -> FileOperationResult

    init(
        id: UUID = UUID(),
        kind: FileOperationJobKind,
        itemDisplayName: String,
        itemCount: Int,
        initialStage: FileOperationStage?,
        touchedDirectories: Set<URL>,
        workspace: WorkspaceState,
        cancellationSources: [URL],
        allowsRetry: Bool,
        requiresExclusiveQueue: Bool,
        onCompletion: (@MainActor (FileOperationResult) -> Void)?,
        operation: @escaping @MainActor () async -> FileOperationResult
    ) {
        self.id = id
        self.kind = kind
        self.itemCount = max(itemCount, 0)
        self.initialStage = initialStage
        self.touchedDirectories = touchedDirectories
        self.workspace = workspace
        self.cancellationSources = cancellationSources
        self.allowsRetry = allowsRetry
        self.requiresExclusiveQueue = requiresExclusiveQueue
        self.onCompletion = onCompletion
        self.operation = operation
        self.itemDisplayName = FileOperationJobSnapshot(
            id: id,
            kind: kind,
            itemDisplayName: itemDisplayName,
            itemCount: itemCount,
            state: .queued,
            progress: nil,
            canUndo: false
        ).itemDisplayName
    }

    func snapshot(
        state: FileOperationJobState,
        canUndo: Bool = false,
        canRetry: Bool = true
    ) -> FileOperationJobSnapshot {
        FileOperationJobSnapshot(
            id: id,
            kind: kind,
            itemDisplayName: itemDisplayName,
            itemCount: itemCount,
            state: state,
            progress: nil,
            canUndo: canUndo,
            canRetry: canRetry && allowsRetry
        )
    }

    var cancellationResult: FileOperationResult {
        FileOperationResult(outcomes: cancellationSources.map {
            .cancelled(source: $0)
        })
    }

    func retryAttempt() -> PendingFileOperation {
        PendingFileOperation(
            kind: kind,
            itemDisplayName: itemDisplayName,
            itemCount: itemCount,
            initialStage: initialStage,
            touchedDirectories: touchedDirectories,
            workspace: workspace,
            cancellationSources: cancellationSources,
            allowsRetry: allowsRetry,
            requiresExclusiveQueue: requiresExclusiveQueue,
            onCompletion: onCompletion,
            operation: operation
        )
    }
}

private struct ArchiveSelectionCapture {
    let selectedItems: [FileItem]
    let directory: URL
    let occupiedNames: Set<String>
}

private enum ArchiveIdentityCapture {
    case ready(
        [IdentifiedFileRequest],
        destinationParentIdentity: FileIdentity
    )
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
