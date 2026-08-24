import Foundation

private struct TransactionScopedAccess: FolderSynchronizationScopedAccessing {
    let coordinator: CloudLocationScopedAccessCoordinator

    func acquireAccess(for roots: [URL]) throws -> [any FolderSynchronizationScopedAccessLease] {
        try coordinator.acquireAccess(for: roots).map(TransactionScopedAccessLease.init)
    }
}

private final class TransactionScopedAccessLease: FolderSynchronizationScopedAccessLease, @unchecked Sendable {
    private let lease: CloudLocationScopedAccessLease

    init(_ lease: CloudLocationScopedAccessLease) { self.lease = lease }

    func finish() { lease.finish() }
}

enum FolderSynchronizationTransactionPhase: Sendable, Equatable {
    case preflighting
    case staging
    case verifyingStaging
    case quarantining
    case publishing
    case verifyingPublished
    case movingToTrash
    case rollingBack
}

struct FolderSynchronizationProgress: Sendable, Equatable {
    let phase: FolderSynchronizationTransactionPhase
    let completedCount: Int
    let totalCount: Int
    let currentRelativePath: ComparisonRelativePath?

    init(
        phase: FolderSynchronizationTransactionPhase,
        completedCount: Int,
        totalCount: Int,
        currentRelativePath: ComparisonRelativePath? = nil
    ) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.currentRelativePath = currentRelativePath
    }
}

enum FolderSynchronizationTransactionFailure: LocalizedError, Sendable {
    case preflightFailed
    case unavailable
    case rootAuthorityUnavailable
    case rootChanged
    case unsafeRootRelationship
    case filenamePolicyChanged
    case insufficientCapacity
    case sourceChanged(ComparisonRelativePath)
    case destinationChanged(ComparisonRelativePath)
    case destinationOccupied(ComparisonRelativePath)
    case stagedItemChanged(ComparisonRelativePath)
    case publishedItemChanged(ComparisonRelativePath)

    var errorDescription: String? {
        switch self {
        case .preflightFailed: "The synchronization review is no longer valid."
        case .unavailable: "An item is not immediately available."
        case .rootAuthorityUnavailable: "Folder relationship safety could not be verified."
        case .rootChanged: "A synchronization folder changed before the operation began."
        case .unsafeRootRelationship: "The synchronization folders overlap unsafely."
        case .filenamePolicyChanged: "Destination filename comparison behavior changed."
        case .insufficientCapacity: "Destination capacity is no longer sufficient."
        case let .sourceChanged(path): "\(path.string) changed before synchronization."
        case let .destinationChanged(path): "\(path.string) changed before synchronization."
        case let .destinationOccupied(path): "\(path.string) is already occupied."
        case let .stagedItemChanged(path): "\(path.string) changed while it was staged."
        case let .publishedItemChanged(path): "\(path.string) changed while it was being published."
        }
    }
}

/// Executes a prepared synchronization as a single recoverable transaction.  The
/// only permanent-data operation it requests is the existing Trash API, and that is
/// deliberately deferred until every new publication has been verified.
protocol FolderSynchronizationExecuting: Sendable {
    func execute(
        _ plan: PreparedFolderSynchronizationPlan,
        verificationPolicy: TransferVerificationPolicy,
        progress: @escaping @Sendable (FolderSynchronizationProgress) async -> Void,
        verificationProgress: @escaping TransferVerificationProgressHandler
    ) async -> FileOperationResult
}

extension FolderSynchronizationExecuting {
    func execute(
        _ plan: PreparedFolderSynchronizationPlan,
        progress: @escaping @Sendable (FolderSynchronizationProgress) async -> Void = { _ in }
    ) async -> FileOperationResult {
        await execute(
            plan,
            verificationPolicy: .disabled,
            progress: progress,
            verificationProgress: { _ in }
        )
    }
}

actor FolderSynchronizationTransactionService: FolderSynchronizationExecuting {
    typealias ProgressHandler = @Sendable (FolderSynchronizationProgress) async -> Void

    private enum StagedVerificationState: @unchecked Sendable {
        case disabled
        case sourceManifest(TransferVerificationManifest)
        case verifying
        case receipt(TransferVerificationCompletion)
    }

    private struct StagedItem: @unchecked Sendable {
        let action: FolderSynchronizationAction
        let reservation: StagingReservation
        let identity: FileIdentity
        let stagedFingerprint: SourceFingerprint
        var verificationState: StagedVerificationState

        func closeVerificationResources() {
            switch verificationState {
            case .disabled, .verifying:
                break
            case let .sourceManifest(manifest):
                manifest.close()
            case let .receipt(completion):
                completion.receipt.source.close()
                completion.receipt.staged.close()
            }
        }
    }

    private struct PublishedItem: Sendable {
        let action: FolderSynchronizationAction
        let url: URL
        let identity: FileIdentity
        let fingerprint: SourceFingerprint
    }

    private struct QuarantinedItem: Sendable {
        let action: FolderSynchronizationAction
        let quarantine: StorageTrashQuarantine
        let destinationParentIdentity: FileIdentity
    }

    private final class StagedVerificationClaim: @unchecked Sendable {
        let index: Int
        let action: FolderSynchronizationAction
        let reservation: StagingReservation
        let identity: FileIdentity

        private let lock = NSLock()
        private var sourceManifest: TransferVerificationManifest?

        init(
            index: Int,
            item: StagedItem,
            sourceManifest: TransferVerificationManifest
        ) {
            self.index = index
            action = item.action
            reservation = item.reservation
            identity = item.identity
            self.sourceManifest = sourceManifest
        }

        func takeSourceManifest() -> TransferVerificationManifest? {
            lock.withLock {
                defer { sourceManifest = nil }
                return sourceManifest
            }
        }

        deinit {
            lock.withLock { sourceManifest?.close() }
        }
    }

    private actor StagedVerificationQueue {
        private var staged: [StagedItem]
        private var nextIndex = 0
        private var completedCount = 0

        init(staged: [StagedItem]) {
            self.staged = staged
        }

        func claimNext() throws -> StagedVerificationClaim? {
            guard nextIndex < staged.count else { return nil }
            let index = nextIndex
            nextIndex += 1
            guard case let .sourceManifest(sourceManifest) = staged[index].verificationState else {
                throw TransferVerificationFailure(category: .identityUnavailable)
            }
            staged[index].verificationState = .verifying
            return StagedVerificationClaim(
                index: index,
                item: staged[index],
                sourceManifest: sourceManifest
            )
        }

        func install(
            _ completion: TransferVerificationCompletion,
            at index: Int
        ) throws -> Int {
            guard staged.indices.contains(index),
                  case .verifying = staged[index].verificationState else {
                completion.receipt.source.close()
                completion.receipt.staged.close()
                throw TransferVerificationFailure(category: .identityUnavailable)
            }
            staged[index].verificationState = .receipt(completion)
            completedCount += 1
            return completedCount
        }

        func takeAll() -> [StagedItem] {
            defer { staged.removeAll(keepingCapacity: false) }
            return staged
        }
    }

    private struct StagedVerificationBatchFailure: Error, @unchecked Sendable {
        let staged: [StagedItem]
        let underlying: any Error
    }

    private struct VerificationWorkerResult: @unchecked Sendable {
        let error: (any Error)?
    }

    private actor VerificationProgressDelivery {
        private let handler: TransferVerificationProgressHandler
        private var isDelivering = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(handler: @escaping TransferVerificationProgressHandler) {
            self.handler = handler
        }

        func publish(_ value: TransferVerificationProgress) async {
            if isDelivering {
                await withCheckedContinuation { waiters.append($0) }
            } else {
                isDelivering = true
            }
            await handler(value)
            if waiters.isEmpty {
                isDelivering = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private actor VerificationProgressAggregator {
        private struct RootState: Sendable {
            var phaseRank = 0
            var phaseFractions = [0.0, 0.0, 0.0]
            var completedFileCount = 0
            var completedLogicalByteCount: Int64 = 0
            var totalFileCount: Int
            var totalLogicalByteCount: Int64
        }

        private var roots: [RootState]
        private let delivery: VerificationProgressDelivery
        private var lastFractionByPhase = [0.0, 0.0, 0.0]

        init(
            staged: [StagedItem],
            handler: @escaping TransferVerificationProgressHandler
        ) {
            roots = staged.map { item in
                guard case let .sourceManifest(manifest) = item.verificationState else {
                    return RootState(totalFileCount: 0, totalLogicalByteCount: 0)
                }
                return RootState(
                    totalFileCount: manifest.regularFileCount,
                    totalLogicalByteCount: manifest.logicalByteCount
                )
            }
            delivery = VerificationProgressDelivery(handler: handler)
        }

        func update(root index: Int, with value: TransferVerificationProgress) async {
            guard roots.indices.contains(index) else { return }
            let rank = Self.rank(value.phase)
            for completedRank in 0..<rank {
                roots[index].phaseFractions[completedRank] = 1
            }
            roots[index].phaseRank = max(roots[index].phaseRank, rank)
            roots[index].phaseFractions[rank] = max(
                roots[index].phaseFractions[rank],
                value.fractionCompleted
            )
            roots[index].completedFileCount = max(
                roots[index].completedFileCount,
                value.completedFileCount
            )
            roots[index].completedLogicalByteCount = max(
                roots[index].completedLogicalByteCount,
                value.completedLogicalByteCount
            )
            roots[index].totalFileCount = max(
                roots[index].totalFileCount,
                value.totalFileCount
            )
            roots[index].totalLogicalByteCount = max(
                roots[index].totalLogicalByteCount,
                value.totalLogicalByteCount
            )
            await delivery.publish(aggregate(currentName: value.currentName))
        }

        func complete(root index: Int, currentName: String) async {
            guard roots.indices.contains(index) else { return }
            roots[index].phaseRank = 2
            roots[index].phaseFractions = [1, 1, 1]
            roots[index].completedFileCount = roots[index].totalFileCount
            roots[index].completedLogicalByteCount = roots[index].totalLogicalByteCount
            await delivery.publish(aggregate(currentName: currentName))
        }

        private func aggregate(currentName: String) -> TransferVerificationProgress {
            let allFinal = !roots.isEmpty && roots.allSatisfy {
                $0.phaseRank == 2 && $0.phaseFractions[2] == 1
            }
            let phaseRank: Int
            if allFinal {
                phaseRank = 2
            } else if roots.contains(where: { $0.phaseRank >= 1 }) {
                phaseRank = 1
            } else {
                phaseRank = 0
            }
            let totalFiles = roots.reduce(0) { Self.saturatedAdd($0, $1.totalFileCount) }
            let totalBytes = roots.reduce(Int64(0)) {
                Self.saturatedAdd($0, $1.totalLogicalByteCount)
            }
            let completedFiles = min(
                totalFiles,
                roots.reduce(0) { Self.saturatedAdd($0, $1.completedFileCount) }
            )
            let completedBytes = min(
                totalBytes,
                roots.reduce(Int64(0)) {
                    Self.saturatedAdd($0, $1.completedLogicalByteCount)
                }
            )
            let rawFraction: Double
            if totalBytes > 0 {
                let weighted = roots.reduce(0.0) { partial, root in
                    partial + root.phaseFractions[phaseRank]
                        * Double(root.totalLogicalByteCount)
                }
                rawFraction = weighted / Double(totalBytes)
            } else if totalFiles > 0 {
                let weighted = roots.reduce(0.0) { partial, root in
                    partial + root.phaseFractions[phaseRank]
                        * Double(root.totalFileCount)
                }
                rawFraction = weighted / Double(totalFiles)
            } else if roots.isEmpty {
                rawFraction = 1
            } else {
                rawFraction = roots.reduce(0.0) {
                    $0 + $1.phaseFractions[phaseRank]
                } / Double(roots.count)
            }
            let fraction = max(lastFractionByPhase[phaseRank], rawFraction)
            lastFractionByPhase[phaseRank] = fraction
            return TransferVerificationProgress(
                phase: Self.phase(phaseRank),
                fractionCompleted: fraction,
                completedFileCount: completedFiles,
                totalFileCount: totalFiles,
                completedLogicalByteCount: completedBytes,
                totalLogicalByteCount: totalBytes,
                currentName: currentName
            )
        }

        private nonisolated static func rank(_ phase: TransferVerificationPhase) -> Int {
            switch phase {
            case .preparingManifest: 0
            case .hashing: 1
            case .finalValidation: 2
            }
        }

        private nonisolated static func phase(_ rank: Int) -> TransferVerificationPhase {
            switch rank {
            case 0: .preparingManifest
            case 1: .hashing
            default: .finalValidation
            }
        }

        private nonisolated static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : value
        }

        private nonisolated static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : value
        }
    }

    private let fileSystem: any FileSystemAccess
    private let scopedAccess: any FolderSynchronizationScopedAccessing
    private let availabilityReader: any CloudItemAvailabilityReading
    private let verificationSessionFactory: any TransferVerificationSessionFactory
    private let logger: any OperationLogging

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        scopedAccess: any FolderSynchronizationScopedAccessing = TransactionScopedAccess(
            coordinator: .init()
        ),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        verificationSessionFactory: any TransferVerificationSessionFactory =
            LiveTransferVerificationSessionFactory(),
        logger: any OperationLogging = LiveOperationLogger()
    ) {
        self.fileSystem = fileSystem
        self.scopedAccess = scopedAccess
        self.availabilityReader = availabilityReader
        self.verificationSessionFactory = verificationSessionFactory
        self.logger = logger
    }

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        verificationSessionFactory: any TransferVerificationSessionFactory =
            LiveTransferVerificationSessionFactory(),
        logger: any OperationLogging = LiveOperationLogger()
    ) {
        self.init(
            fileSystem: fileSystem,
            scopedAccess: TransactionScopedAccess(coordinator: accessCoordinator),
            availabilityReader: availabilityReader,
            verificationSessionFactory: verificationSessionFactory,
            logger: logger
        )
    }

    func execute(
        _ plan: PreparedFolderSynchronizationPlan,
        verificationPolicy: TransferVerificationPolicy,
        progress: @escaping ProgressHandler,
        verificationProgress: @escaping TransferVerificationProgressHandler
    ) async -> FileOperationResult {
        let verificationEnabled = verificationPolicy.effectivePairLimit != nil
        let leases: [any FolderSynchronizationScopedAccessLease]
        do {
            leases = try scopedAccess.acquireAccess(for: [
                plan.draft.sourceRoot, plan.draft.destinationRoot
            ])
        } catch {
            let report = verificationEnabled ? emptyVerificationReport : nil
            let result = failure(plan, error: error, verificationReport: report)
            if let report {
                await recordTransferVerification(report: report, failureCategory: nil)
            }
            return result
        }
        defer { leases.forEach { $0.finish() } }

        let verificationSession: (any TransferVerificationSession)?
        if verificationEnabled {
            guard let session = verificationSessionFactory.makeSession(policy: verificationPolicy) else {
                let error = TransferVerificationFailure(category: .identityUnavailable)
                let report = verificationReport(
                    for: [],
                    failureCategory: .identityUnavailable
                )
                let result = failure(plan, error: error, verificationReport: report)
                await recordTransferVerification(
                    report: report,
                    failureCategory: .identityUnavailable
                )
                return result
            }
            verificationSession = session
        } else {
            verificationSession = nil
        }

        var staged: [StagedItem] = []
        defer { staged.forEach { $0.closeVerificationResources() } }
        var unfinalizedReservations: [(FolderSynchronizationAction, StagingReservation)] = []
        var quarantines: [QuarantinedItem] = []
        var published: [PublishedItem] = []
        var committedTrash = Set<ComparisonRelativePath>()
        var restoredTrash = Set<ComparisonRelativePath>()
        do {
            try Task.checkCancellation()
            await report(.preflighting, 0, plan.draft.actions.count, nil, progress)
            try Task.checkCancellation()
            try await preflight(plan)
            try Task.checkCancellation()

            let copyActions = plan.draft.actions.filter { $0.kind == .copy || $0.kind == .replace }
            for (index, action) in copyActions.enumerated() {
                try Task.checkCancellation()
                await report(.staging, index, copyActions.count, action.relativePath, progress)
                try Task.checkCancellation()
                guard let source = action.source,
                      let fingerprint = plan.sourceFingerprints[action.relativePath] else {
                    throw FolderSynchronizationTransactionFailure.preflightFailed
                }
                let destination = destinationURL(for: action, in: plan)
                let parent = destination.deletingLastPathComponent().standardizedFileURL
                guard let expectedParentIdentity = expectedDestinationParentIdentity(
                    for: action, destinationParent: parent, plan: plan
                ), try await fileSystem.identity(of: parent) == expectedParentIdentity else {
                    throw FolderSynchronizationTransactionFailure.destinationChanged(action.relativePath)
                }
                let sourceManifest: TransferVerificationManifest?
                if let verificationSession {
                    sourceManifest = try await verificationSession.captureSource(
                        at: source.url,
                        identifiedBy: source.fingerprint.identity,
                        comparisonPolicy: plan.destinationFilenameComparisonPolicy
                    )
                } else {
                    sourceManifest = nil
                }
                var transferredSourceManifest = false
                defer {
                    if !transferredSourceManifest {
                        sourceManifest?.close()
                    }
                }
                let reservation = try await fileSystem.reserveStagingDirectory(
                    beside: destination,
                    parentIdentifiedBy: expectedParentIdentity
                )
                do {
                    let identity = try await fileSystem.copyAndCaptureIdentity(
                        source.url,
                        identifiedBy: source.fingerprint.identity,
                        to: reservation.item
                    )
                    // Copy returns a newly allocated item.  Capture its fingerprint
                    // precisely once, bracketed by no-follow identity checks, and
                    // bind every later publish/rollback decision to that value.
                    guard try await fileSystem.identity(of: reservation.item) == identity else {
                        throw FolderSynchronizationTransactionFailure.stagedItemChanged(action.relativePath)
                    }
                    let stagedFingerprint = try await fileSystem.fingerprint(of: reservation.item)
                    guard try await fileSystem.identity(of: reservation.item) == identity,
                          matchesStagedCopy(stagedFingerprint, source: fingerprint) else {
                        throw FolderSynchronizationTransactionFailure.stagedItemChanged(action.relativePath)
                    }
                    staged.append(.init(action: action, reservation: reservation, identity: identity,
                        stagedFingerprint: stagedFingerprint,
                        verificationState: sourceManifest.map(StagedVerificationState.sourceManifest)
                            ?? .disabled))
                    transferredSourceManifest = true
                } catch {
                    // A failed copy has no returned payload identity.  Its implementation
                    // owns any partial payload cleanup; we may only remove the directory
                    // if the reservation's original directory identity still proves it is
                    // ours.  A failed removal is carried through rollback as Recovery.
                    unfinalizedReservations.append((action, reservation))
                    throw error
                }
                try Task.checkCancellation()
            }

            if let verificationSession {
                // Complete every metadata/identity staging check before any content
                // worker can report a root complete. No preexisting destination is
                // quarantined until the entire verified batch has succeeded.
                for item in staged {
                    try Task.checkCancellation()
                    guard try await fileSystem.identity(of: item.reservation.item) == item.identity,
                          try await fileSystem.fingerprint(of: item.reservation.item)
                            .matchesAfterRelocation(item.stagedFingerprint),
                          try await fileSystem.identity(of: item.reservation.item) == item.identity else {
                        throw FolderSynchronizationTransactionFailure.stagedItemChanged(
                            item.action.relativePath
                        )
                    }
                }
                let verificationQueue = StagedVerificationQueue(staged: staged)
                let verificationAggregator = VerificationProgressAggregator(
                    staged: staged,
                    handler: verificationProgress
                )
                let stagedCount = staged.count
                // Transfer the array's manifest ownership into the queue. Keeping a
                // second immutable snapshot here would retain every manifest backing
                // store until the whole batch completed.
                staged.removeAll(keepingCapacity: false)
                do {
                    staged = try await verifyStagedItems(
                        queue: verificationQueue,
                        aggregator: verificationAggregator,
                        total: stagedCount,
                        session: verificationSession,
                        progress: progress
                    )
                } catch let failure as StagedVerificationBatchFailure {
                    staged = failure.staged
                    throw failure.underlying
                }
            } else {
                // Preserve the original disabled event sequence exactly.
                for (index, item) in staged.enumerated() {
                    try Task.checkCancellation()
                    await report(.verifyingStaging, index, staged.count, item.action.relativePath, progress)
                    try Task.checkCancellation()
                    guard try await fileSystem.identity(of: item.reservation.item) == item.identity,
                          try await fileSystem.fingerprint(of: item.reservation.item)
                            .matchesAfterRelocation(item.stagedFingerprint),
                          try await fileSystem.identity(of: item.reservation.item) == item.identity else {
                        throw FolderSynchronizationTransactionFailure.stagedItemChanged(
                            item.action.relativePath
                        )
                    }
                }
            }

            let quarantinedActions = plan.draft.actions.filter {
                $0.kind == .replace || $0.kind == .moveDestinationToTrash
            }
            for (index, action) in quarantinedActions.enumerated() {
                try Task.checkCancellation()
                await report(.quarantining, index, quarantinedActions.count, action.relativePath, progress)
                try Task.checkCancellation()
                guard let destination = action.destination,
                      let fingerprint = plan.destinationFingerprints[action.relativePath],
                      let expectedParentIdentity = expectedDestinationParentIdentity(
                        for: action,
                        destinationParent: destination.url.deletingLastPathComponent().standardizedFileURL,
                        plan: plan
                      ),
                      try await fileSystem.identity(of: destination.url.deletingLastPathComponent())
                        == expectedParentIdentity,
                      try await fileSystem.identity(of: destination.url) == destination.fingerprint.identity,
                      try await fileSystem.fingerprint(of: destination.url) == fingerprint,
                      try await fileSystem.identity(of: destination.url) == destination.fingerprint.identity else {
                    throw FolderSynchronizationTransactionFailure.destinationChanged(action.relativePath)
                }
                let quarantine: StorageTrashQuarantine
                do {
                    quarantine = try await fileSystem.quarantineForTrash(
                        destination.url, identifiedBy: destination.fingerprint.identity,
                        parentIdentifiedBy: expectedParentIdentity
                    )
                } catch let recoverable as StorageTrashRecoverableFailure {
                    // The low-level primitive has moved the old payload but retained
                    // descriptor-backed authority for it.  Record that authority before
                    // propagating the failure so detached rollback can restore it.
                    guard recoverable.quarantine.originalURL == destination.url,
                          recoverable.quarantine.identity == destination.fingerprint.identity else {
                        throw StorageTrashAccessError.recoveryRequired
                    }
                    quarantines.append(.init(action: action, quarantine: recoverable.quarantine,
                        destinationParentIdentity: expectedParentIdentity))
                    throw recoverable
                }
                // Quarantine has already moved user data.  Record it before every
                // verification await so a mismatch/cancellation restores it.
                quarantines.append(.init(action: action, quarantine: quarantine,
                    destinationParentIdentity: expectedParentIdentity))
                guard quarantine.identity == destination.fingerprint.identity,
                      try await fileSystem.fingerprint(of: quarantine).matchesAfterRelocation(fingerprint) else {
                    throw FolderSynchronizationTransactionFailure.destinationChanged(action.relativePath)
                }
            }

            for (index, item) in staged.enumerated() {
                try Task.checkCancellation()
                await report(.publishing, index, staged.count, item.action.relativePath, progress)
                try Task.checkCancellation()
                let destination = destinationURL(for: item.action, in: plan)
                let parent = destination.deletingLastPathComponent().standardizedFileURL
                guard await !fileSystem.exists(destination),
                      let expectedParentIdentity = expectedDestinationParentIdentity(
                          for: item.action, destinationParent: parent, plan: plan
                      ), try await fileSystem.identity(of: parent) == expectedParentIdentity else {
                    throw FolderSynchronizationTransactionFailure.destinationOccupied(item.action.relativePath)
                }
                if let verificationSession {
                    guard case let .receipt(completion) = item.verificationState else {
                        throw TransferVerificationFailure(category: .identityUnavailable)
                    }
                    // Receipt revalidation is deliberately the final awaited safety
                    // step before the identity-bound publication primitive.
                    try await verificationSession.revalidate(completion.receipt)
                }
                try await fileSystem.moveExclusively(
                    item.reservation.item,
                    identifiedBy: item.identity,
                    to: destination,
                    destinationParentIdentifiedBy: expectedParentIdentity
                )
                // Publication is externally visible before verification.  Record it first
                // so a cancellation at either following await is recovered.
                published.append(.init(action: item.action, url: destination, identity: item.identity,
                    fingerprint: item.stagedFingerprint))
                // Validate the exact staged authority after relocation before applying
                // deferred immutable flags.  Capturing only after finalization would
                // accept a mutation raced into the publication window.
                guard try await fileSystem.identity(of: destination) == item.identity,
                      try await fileSystem.fingerprint(of: destination)
                        .matchesAfterRelocation(item.stagedFingerprint),
                      try await fileSystem.identity(of: destination) == item.identity else {
                    throw FolderSynchronizationTransactionFailure.publishedItemChanged(item.action.relativePath)
                }
                // This may apply deferred immutable metadata and fail. The publication
                // was recorded first, so detached rollback still owns the destination.
                try await fileSystem.finalizePendingCopyAfterExclusiveRelocation(identity: item.identity)
                guard try await fileSystem.identity(of: destination) == item.identity else {
                    throw FolderSynchronizationTransactionFailure.publishedItemChanged(item.action.relativePath)
                }
                let finalizedFingerprint = try await fileSystem.fingerprint(of: destination)
                guard try await fileSystem.identity(of: destination) == item.identity else {
                    throw FolderSynchronizationTransactionFailure.publishedItemChanged(item.action.relativePath)
                }
                published[published.count - 1] = .init(action: item.action, url: destination,
                    identity: item.identity, fingerprint: finalizedFingerprint)
            }

            for (index, item) in published.enumerated() {
                try Task.checkCancellation()
                await report(.verifyingPublished, index, published.count, item.action.relativePath, progress)
                try Task.checkCancellation()
                guard try await fileSystem.identity(of: item.url) == item.identity,
                      try await fileSystem.fingerprint(of: item.url)
                        .matchesAfterRelocation(item.fingerprint),
                      try await fileSystem.identity(of: item.url) == item.identity else {
                    throw FolderSynchronizationTransactionFailure.publishedItemChanged(item.action.relativePath)
                }
            }

            for (index, item) in quarantines.enumerated() {
                try Task.checkCancellation()
                await report(.movingToTrash, index, quarantines.count, item.action.relativePath, progress)
                try Task.checkCancellation()
                do {
                    _ = try await fileSystem.moveTrashQuarantineAtomically(item.quarantine)
                    committedTrash.insert(item.action.relativePath)
                } catch let recoverable as StorageTrashRecoverableFailure {
                    guard recoverable.quarantine.id == item.quarantine.id,
                          recoverable.quarantine.identity == item.quarantine.identity else {
                        throw StorageTrashAccessError.recoveryRequired
                    }
                    throw recoverable
                } catch StorageTrashAccessError.failedButRestored {
                    // The primitive proves it put this item back at its original
                    // identity. Do not retry rollback against an already-restored
                    // quarantine or turn a clean failure into Recovery Needed.
                    restoredTrash.insert(item.action.relativePath)
                    throw StorageTrashAccessError.failedButRestored
                }
            }
            for item in staged {
                try await fileSystem.removeStagingDirectory(item.reservation)
            }
            // Only successful completion releases descriptor-backed publication
            // authority. Any failure above retains it for detached rollback.
            for item in published {
                try await fileSystem.commitFinalizedOwnedCopy(identity: item.identity)
            }
            let verificationReport = verificationEnabled
                ? verificationReport(for: staged, failureCategory: nil)
                : nil
            let result = success(plan, verificationReport: verificationReport)
            if let verificationReport {
                await recordTransferVerification(
                    report: verificationReport,
                    failureCategory: nil
                )
            }
            return result
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let fileSystem = self.fileSystem
            let total = plan.draft.actions.count
            let finalizedTrash = committedTrash
            let rollbackQuarantines = quarantines.filter {
                !finalizedTrash.contains($0.action.relativePath)
                    && !restoredTrash.contains($0.action.relativePath)
            }
            let failureCategory = verificationEnabled
                ? transferVerificationFailureCategory(in: error, cancelled: cancelled)
                : nil
            let verificationReport = verificationEnabled
                ? verificationReport(for: staged, failureCategory: failureCategory)
                : nil
            let rollbackStaged = staged
            let recoveryNeeded = await Task.detached {
                await Self.rollback(
                    staged: rollbackStaged,
                    unfinalizedReservations: unfinalizedReservations,
                    quarantines: rollbackQuarantines,
                    published: published,
                    committedTrash: finalizedTrash,
                    fileSystem: fileSystem,
                    total: total,
                    progress: progress
                )
            }.value
            let result = result(
                plan,
                error: error,
                cancelled: cancelled,
                recoveryNeeded: recoveryNeeded,
                committedTrash: finalizedTrash,
                verificationReport: verificationReport
            )
            if let verificationReport {
                await recordTransferVerification(
                    report: verificationReport,
                    failureCategory: failureCategory
                )
            }
            return result
        }
    }

    private func verifyStagedItems(
        queue: StagedVerificationQueue,
        aggregator: VerificationProgressAggregator,
        total: Int,
        session: any TransferVerificationSession,
        progress: @escaping ProgressHandler
    ) async throws -> [StagedItem] {
        guard total > 0 else { return await queue.takeAll() }
        do {
            try Task.checkCancellation()
            var selectedError: (any Error)?
            await withTaskGroup(of: VerificationWorkerResult.self) { group in
                for _ in 0..<min(2, total) {
                    group.addTask {
                        do {
                            while let claim = try await queue.claimNext() {
                                try Task.checkCancellation()
                                var sourceManifest = claim.takeSourceManifest()
                                defer { sourceManifest?.close() }
                                let rootIndex = claim.index
                                var pendingCompletion: TransferVerificationCompletion?
                                defer {
                                    pendingCompletion?.receipt.source.close()
                                    pendingCompletion?.receipt.staged.close()
                                }
                                do {
                                    guard let manifest = sourceManifest else {
                                        throw TransferVerificationFailure(
                                            category: .identityUnavailable
                                        )
                                    }
                                    pendingCompletion = try await session.verify(
                                        source: manifest,
                                        stagedURL: claim.reservation.item,
                                        stagedIdentity: claim.identity,
                                        progress: { value in
                                            await aggregator.update(root: rootIndex, with: value)
                                        }
                                    )
                                }
                                try Task.checkCancellation()

                                // Drop the earlier manifest before the receipt becomes the
                                // staged item's sole verification authority.
                                sourceManifest?.close()
                                sourceManifest = nil
                                guard let completion = pendingCompletion else {
                                    throw TransferVerificationFailure(
                                        category: .identityUnavailable
                                    )
                                }
                                let completed = try await queue.install(
                                    completion,
                                    at: rootIndex
                                )
                                pendingCompletion = nil
                                await aggregator.complete(
                                    root: rootIndex,
                                    currentName: claim.action.relativePath.components.last ?? "Item"
                                )
                                try Task.checkCancellation()
                                await progress(.init(
                                    phase: .verifyingStaging,
                                    completedCount: completed,
                                    totalCount: total,
                                    currentRelativePath: claim.action.relativePath
                                ))
                                try Task.checkCancellation()
                            }
                            return VerificationWorkerResult(error: nil)
                        } catch {
                            return VerificationWorkerResult(error: error)
                        }
                    }
                }
                for await result in group {
                    guard let candidate = result.error else { continue }
                    selectedError = Self.preferredVerificationError(
                        selectedError,
                        candidate
                    )
                    group.cancelAll()
                }
            }
            if let selectedError { throw selectedError }
            try Task.checkCancellation()
            return await queue.takeAll()
        } catch {
            let recovered = await queue.takeAll()
            throw StagedVerificationBatchFailure(staged: recovered, underlying: error)
        }
    }

    private nonisolated static func preferredVerificationError(
        _ current: (any Error)?,
        _ candidate: any Error
    ) -> any Error {
        guard let current else { return candidate }
        if isVerificationCancellation(current),
           !isVerificationCancellation(candidate) {
            return candidate
        }
        return current
    }

    private nonisolated static func isVerificationCancellation(
        _ error: any Error
    ) -> Bool {
        if error is CancellationError { return true }
        return (error as? TransferVerificationFailure)?.category == .cancelled
    }

    private func preflight(_ plan: PreparedFolderSynchronizationPlan) async throws {
        try requireNonOverlappingActions(plan.draft.actions)
        guard try await fileSystem.identity(of: plan.draft.sourceRoot) == plan.draft.sourceRootIdentity,
              try await fileSystem.identity(of: plan.draft.destinationRoot) == plan.draft.destinationRootIdentity else {
            throw FolderSynchronizationTransactionFailure.rootChanged
        }
        guard let authorityProvider = fileSystem as? any FolderSynchronizationRootAuthorityProviding else {
            throw FolderSynchronizationTransactionFailure.rootAuthorityUnavailable
        }
        let sourceAuthority = try await authorityProvider.captureFolderSynchronizationRootAuthority(
            at: plan.draft.sourceRoot, expectedIdentity: plan.draft.sourceRootIdentity
        )
        let destinationAuthority = try await authorityProvider.captureFolderSynchronizationRootAuthority(
            at: plan.draft.destinationRoot, expectedIdentity: plan.draft.destinationRootIdentity
        )
        guard FolderSynchronizationRootAuthority(source: sourceAuthority, destination: destinationAuthority)
            == plan.rootAuthority else { throw FolderSynchronizationTransactionFailure.rootChanged }
        try requireDisjoint(sourceAuthority, destinationAuthority)
        guard try await fileSystem.filenameComparisonPolicy(in: plan.draft.destinationRoot)
            == plan.destinationFilenameComparisonPolicy else {
            throw FolderSynchronizationTransactionFailure.filenamePolicyChanged
        }
        for action in plan.draft.actions {
            try Task.checkCancellation()
            switch action.kind {
            case .copy:
                guard let source = action.source,
                      let expected = plan.sourceFingerprints[action.relativePath],
                      try await fileSystem.identity(of: source.url) == source.fingerprint.identity,
                      try await fileSystem.fingerprint(of: source.url) == expected,
                      try await fileSystem.identity(of: source.url) == source.fingerprint.identity else {
                    throw FolderSynchronizationTransactionFailure.sourceChanged(action.relativePath)
                }
                try await requireAvailableEntries(expected, root: source.url)
                guard await !fileSystem.exists(destinationURL(for: action, in: plan)) else {
                    throw FolderSynchronizationTransactionFailure.destinationOccupied(action.relativePath)
                }
            case .replace:
                guard let source = action.source,
                      let destination = action.destination,
                      let sourceFingerprint = plan.sourceFingerprints[action.relativePath],
                      let destinationFingerprint = plan.destinationFingerprints[action.relativePath],
                      try await fileSystem.identity(of: source.url) == source.fingerprint.identity,
                      try await fileSystem.fingerprint(of: source.url) == sourceFingerprint,
                      try await fileSystem.identity(of: source.url) == source.fingerprint.identity,
                      try await fileSystem.identity(of: destination.url) == destination.fingerprint.identity,
                      try await fileSystem.fingerprint(of: destination.url) == destinationFingerprint,
                      try await fileSystem.identity(of: destination.url) == destination.fingerprint.identity else {
                    throw FolderSynchronizationTransactionFailure.preflightFailed
                }
                try await requireAvailableEntries(sourceFingerprint, root: source.url)
            case .moveDestinationToTrash:
                guard let destination = action.destination,
                      let expected = plan.destinationFingerprints[action.relativePath],
                      try await fileSystem.identity(of: destination.url) == destination.fingerprint.identity,
                      try await fileSystem.fingerprint(of: destination.url) == expected,
                      try await fileSystem.identity(of: destination.url) == destination.fingerprint.identity else {
                    throw FolderSynchronizationTransactionFailure.destinationChanged(action.relativePath)
                }
            }
        }
        for absent in plan.expectedAbsentDestinations {
            guard await !fileSystem.exists(plan.draft.destinationRoot.appending(path: absent.string)) else {
                throw FolderSynchronizationTransactionFailure.destinationOccupied(absent)
            }
        }
        guard let finalCapacity = try await fileSystem.availableCapacity(at: plan.draft.destinationRoot),
              finalCapacity >= plan.requiredCapacityBytes else {
            throw FolderSynchronizationTransactionFailure.insufficientCapacity
        }
        // This is the final filesystem authority capture immediately before the
        // first staging mutation, closing preflight-time root replacement races.
        guard try await fileSystem.identity(of: plan.draft.sourceRoot) == plan.draft.sourceRootIdentity,
              try await fileSystem.identity(of: plan.draft.destinationRoot) == plan.draft.destinationRootIdentity else {
            throw FolderSynchronizationTransactionFailure.rootChanged
        }
        let finalSourceAuthority = try await authorityProvider.captureFolderSynchronizationRootAuthority(
            at: plan.draft.sourceRoot, expectedIdentity: plan.draft.sourceRootIdentity
        )
        let finalDestinationAuthority = try await authorityProvider.captureFolderSynchronizationRootAuthority(
            at: plan.draft.destinationRoot, expectedIdentity: plan.draft.destinationRootIdentity
        )
        guard FolderSynchronizationRootAuthority(source: finalSourceAuthority,
                                                  destination: finalDestinationAuthority)
                == plan.rootAuthority else { throw FolderSynchronizationTransactionFailure.rootChanged }
        try requireDisjoint(finalSourceAuthority, finalDestinationAuthority)
    }

    private func requireNonOverlappingActions(_ actions: [FolderSynchronizationAction]) throws {
        guard Set(actions.map(\.relativePath)).count == actions.count else {
            throw FolderSynchronizationTransactionFailure.preflightFailed
        }
        for action in actions {
            for other in actions where action.relativePath != other.relativePath {
                if action.relativePath.components.count < other.relativePath.components.count,
                   zip(action.relativePath.components, other.relativePath.components).allSatisfy(==) {
                    throw FolderSynchronizationTransactionFailure.preflightFailed
                }
            }
        }
    }

    private func requireAvailableEntries(_ fingerprint: SourceFingerprint, root: URL) async throws {
        for entry in fingerprint.entries {
            let url = try entryURL(entry.relativePath, under: root)
            guard await availabilityReader.availability(of: url) == .availableLocally else {
                throw FolderSynchronizationTransactionFailure.unavailable
            }
        }
    }

    private func entryURL(_ relativePath: String, under root: URL) throws -> URL {
        if relativePath == "." { return root }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            throw FolderSynchronizationTransactionFailure.unavailable
        }
        let relative = try ComparisonRelativePath(components: components)
        let candidate = root.appending(path: relative.string).standardizedFileURL
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidate.pathComponents.count > rootComponents.count,
              candidate.pathComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            throw FolderSynchronizationTransactionFailure.unavailable
        }
        return candidate
    }

    private func destinationURL(for action: FolderSynchronizationAction, in plan: PreparedFolderSynchronizationPlan) -> URL {
        plan.draft.destinationRoot.appending(path: action.relativePath.string).standardizedFileURL
    }

    private func expectedDestinationParentIdentity(
        for action: FolderSynchronizationAction,
        destinationParent: URL,
        plan: PreparedFolderSynchronizationPlan
    ) -> FileIdentity? {
        guard Self.isContained(destinationParent, in: plan.draft.destinationRoot),
              let identity = plan.destinationParentIdentities[action.relativePath] else {
            return nil
        }
        return identity
    }

    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }

    /// Copying creates new directory entries, so inode identity must *not* match the
    /// source.  The staged verification instead compares the content/metadata shape;
    /// subsequent publication and rollback use relocation-safe identity fingerprints.
    private func matchesStagedCopy(_ staged: SourceFingerprint, source: SourceFingerprint) -> Bool {
        guard staged.entries.count == source.entries.count else { return false }
        return zip(staged.entries, source.entries).allSatisfy { left, right in
            left.relativePath == right.relativePath
                && left.mode == right.mode
                && left.size == right.size
                && left.modificationSeconds == right.modificationSeconds
                && left.modificationNanoseconds == right.modificationNanoseconds
        }
    }

    private func requireDisjoint(
        _ source: FolderSynchronizationRootEvidence,
        _ destination: FolderSynchronizationRootEvidence
    ) throws {
        let sourceComponents = source.canonicalURL.standardizedFileURL.pathComponents
        let destinationComponents = destination.canonicalURL.standardizedFileURL.pathComponents
        let nested = sourceComponents == destinationComponents
            || (sourceComponents.count < destinationComponents.count
                && zip(sourceComponents, destinationComponents).allSatisfy(==))
            || (destinationComponents.count < sourceComponents.count
                && zip(destinationComponents, sourceComponents).allSatisfy(==))
        guard source.identity != destination.identity,
              !source.identity.refersToSameItem(as: destination.identity),
              !nested else { throw FolderSynchronizationTransactionFailure.unsafeRootRelationship }
        if source.volumeIdentifier == destination.volumeIdentifier,
           source.mountIdentifier != destination.mountIdentifier {
            throw FolderSynchronizationTransactionFailure.unsafeRootRelationship
        }
    }

    private nonisolated static func rollback(
        staged: [StagedItem],
        unfinalizedReservations: [(FolderSynchronizationAction, StagingReservation)],
        quarantines: [QuarantinedItem],
        published: [PublishedItem],
        committedTrash: Set<ComparisonRelativePath>,
        fileSystem: any FileSystemAccess,
        total: Int,
        progress: @escaping ProgressHandler
    ) async -> Set<ComparisonRelativePath> {
        var recovery = Set<ComparisonRelativePath>()
        var completed = 0
        for item in published.reversed() {
            // Once a replacement's old payload is committed to Trash, its new
            // publication is the durable successful result.  A later action must not
            // erase it merely because that later action needs rollback.
            if item.action.kind == .replace,
               committedTrash.contains(item.action.relativePath) {
                continue
            }
            do {
                guard try await fileSystem.identity(of: item.url) == item.identity,
                      try await fileSystem.fingerprint(of: item.url).matchesAfterRelocation(item.fingerprint) else {
                    throw FolderSynchronizationTransactionFailure.publishedItemChanged(item.action.relativePath)
                }
                try await fileSystem.removeFinalizedOwnedCopy(item.url, identifiedBy: item.identity)
            } catch { recovery.insert(item.action.relativePath) }
            completed += 1
            await progress(.init(phase: .rollingBack, completedCount: completed, totalCount: total,
                currentRelativePath: item.action.relativePath))
        }
        for item in quarantines.reversed() {
            do {
                guard try await fileSystem.identity(of: item.quarantine.originalURL.deletingLastPathComponent())
                    == item.destinationParentIdentity else {
                    throw FileSystemAccessError.identityMismatch(item.quarantine.originalURL.deletingLastPathComponent())
                }
                try await fileSystem.rollbackTrashQuarantine(item.quarantine)
            }
            catch { recovery.insert(item.action.relativePath) }
        }
        for item in staged {
            do { try await cleanupOwnedReservation(item.reservation, payloadIdentity: item.identity, fileSystem: fileSystem) }
            catch { recovery.insert(item.action.relativePath) }
        }
        for (action, reservation) in unfinalizedReservations {
            do { try await cleanupEmptyOwnedReservation(reservation, fileSystem: fileSystem) }
            catch { recovery.insert(action.relativePath) }
        }
        return recovery
    }

    private nonisolated static func cleanupOwnedReservation(
        _ reservation: StagingReservation,
        payloadIdentity: FileIdentity,
        fileSystem: any FileSystemAccess
    ) async throws {
        let directoryIdentity = try await fileSystem.identity(of: reservation.directory)
        guard directoryIdentity == reservation.directoryIdentity || directoryIdentity == nil else {
            throw FileSystemAccessError.identityMismatch(reservation.directory)
        }
        // An earlier owned cleanup/publication may have already removed this
        // reservation.  Absence of both entries is an idempotent success, not a
        // spurious Recovery Needed outcome.
        if directoryIdentity == nil {
            guard try await fileSystem.identity(of: reservation.item) == nil else {
                throw FileSystemAccessError.identityMismatch(reservation.item)
            }
            return
        }
        if let itemIdentity = try await fileSystem.identity(of: reservation.item) {
            guard itemIdentity == payloadIdentity else {
                throw FileSystemAccessError.identityMismatch(reservation.item)
            }
            try await fileSystem.remove(reservation.item, identifiedBy: payloadIdentity)
        }
        try await fileSystem.removeStagingDirectory(reservation)
    }

    private nonisolated static func cleanupEmptyOwnedReservation(
        _ reservation: StagingReservation,
        fileSystem: any FileSystemAccess
    ) async throws {
        guard try await fileSystem.identity(of: reservation.directory) == reservation.directoryIdentity,
              try await fileSystem.identity(of: reservation.item) == nil else {
            throw FileSystemAccessError.identityMismatch(reservation.directory)
        }
        try await fileSystem.removeStagingDirectory(reservation)
    }

    private func report(
        _ phase: FolderSynchronizationTransactionPhase,
        _ completed: Int,
        _ total: Int,
        _ path: ComparisonRelativePath?,
        _ progress: @escaping ProgressHandler
    ) async {
        await progress(.init(phase: phase, completedCount: completed, totalCount: total, currentRelativePath: path))
    }

    private func success(
        _ plan: PreparedFolderSynchronizationPlan,
        verificationReport: TransferVerificationReport?
    ) -> FileOperationResult {
        FileOperationResult(
            outcomes: plan.draft.actions.map { action in
                .succeeded(
                    source: action.source?.url ?? action.destination!.url,
                    destination: action.kind == .moveDestinationToTrash
                        ? nil
                        : destinationURL(for: action, in: plan)
                )
            },
            verificationReport: verificationReport
        )
    }

    private func failure(
        _ plan: PreparedFolderSynchronizationPlan,
        error: any Error,
        verificationReport: TransferVerificationReport?
    ) -> FileOperationResult {
        result(
            plan,
            error: error,
            cancelled: error is CancellationError,
            recoveryNeeded: [],
            committedTrash: [],
            verificationReport: verificationReport
        )
    }

    private func result(
        _ plan: PreparedFolderSynchronizationPlan,
        error: any Error,
        cancelled: Bool,
        recoveryNeeded: Set<ComparisonRelativePath>,
        committedTrash: Set<ComparisonRelativePath>,
        verificationReport: TransferVerificationReport?
    ) -> FileOperationResult {
        FileOperationResult(
            outcomes: plan.draft.actions.map { action in
                let source = action.source?.url ?? action.destination!.url
                if recoveryNeeded.contains(action.relativePath) {
                    return .recoveryNeeded(source: source)
                }
                if committedTrash.contains(action.relativePath), action.kind == .replace {
                    return .succeeded(
                        source: source,
                        destination: destinationURL(for: action, in: plan)
                    )
                }
                if committedTrash.contains(action.relativePath) {
                    return .succeeded(source: source, destination: nil)
                }
                if cancelled { return .cancelled(source: source) }
                return .failed(source: source, message: error.localizedDescription)
            },
            verificationReport: verificationReport
        )
    }

    private var emptyVerificationReport: TransferVerificationReport {
        TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        )
    }

    private func verificationReport(
        for staged: [StagedItem],
        failureCategory: TransferVerificationFailureCategory?
    ) -> TransferVerificationReport {
        var report = emptyVerificationReport
        for item in staged {
            guard case let .receipt(completion) = item.verificationState else { continue }
            report = report.merging(TransferVerificationReport(
                verifiedFileCount: completion.summary.verifiedFileCount,
                verifiedLogicalByteCount: completion.summary.verifiedLogicalByteCount,
                noByteTransferItemCount: completion.summary.noByteTransferItemCount,
                failedVerificationItemCount: 0
            ))
        }
        if failureCategory != nil {
            report = report.merging(TransferVerificationReport(
                verifiedFileCount: 0,
                verifiedLogicalByteCount: 0,
                noByteTransferItemCount: 0,
                failedVerificationItemCount: 1
            ))
        }
        return report
    }

    private func transferVerificationFailureCategory(
        in error: any Error,
        cancelled: Bool
    ) -> TransferVerificationFailureCategory? {
        if let failure = error as? TransferVerificationFailure {
            return failure.category
        }
        if cancelled {
            return .cancelled
        }
        return nil
    }

    private func recordTransferVerification(
        report: TransferVerificationReport,
        failureCategory: TransferVerificationFailureCategory?
    ) async {
        await logger.recordTransferVerification(TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: report.verifiedFileCount,
            verifiedLogicalByteCount: report.verifiedLogicalByteCount,
            noByteTransferItemCount: report.noByteTransferItemCount,
            failedVerificationItemCount: report.failedVerificationItemCount,
            failureCategory: failureCategory
        ))
    }
}
