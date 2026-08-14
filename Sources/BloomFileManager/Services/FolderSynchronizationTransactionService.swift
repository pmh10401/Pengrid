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
        progress: @escaping @Sendable (FolderSynchronizationProgress) async -> Void
    ) async -> FileOperationResult
}

actor FolderSynchronizationTransactionService: FolderSynchronizationExecuting {
    typealias ProgressHandler = @Sendable (FolderSynchronizationProgress) async -> Void

    private struct StagedItem: Sendable {
        let action: FolderSynchronizationAction
        let reservation: StagingReservation
        let identity: FileIdentity
        let stagedFingerprint: SourceFingerprint
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

    private let fileSystem: any FileSystemAccess
    private let scopedAccess: any FolderSynchronizationScopedAccessing
    private let availabilityReader: any CloudItemAvailabilityReading

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        scopedAccess: any FolderSynchronizationScopedAccessing = TransactionScopedAccess(
            coordinator: .init()
        ),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService()
    ) {
        self.fileSystem = fileSystem
        self.scopedAccess = scopedAccess
        self.availabilityReader = availabilityReader
    }

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService()
    ) {
        self.init(
            fileSystem: fileSystem,
            scopedAccess: TransactionScopedAccess(coordinator: accessCoordinator),
            availabilityReader: availabilityReader
        )
    }

    func execute(
        _ plan: PreparedFolderSynchronizationPlan,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> FileOperationResult {
        let leases: [any FolderSynchronizationScopedAccessLease]
        do {
            leases = try scopedAccess.acquireAccess(for: [
                plan.draft.sourceRoot, plan.draft.destinationRoot
            ])
        } catch {
            return failure(plan, error: error)
        }
        defer { leases.forEach { $0.finish() } }

        var staged: [StagedItem] = []
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
                        stagedFingerprint: stagedFingerprint))
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

            for (index, item) in staged.enumerated() {
                try Task.checkCancellation()
                await report(.verifyingStaging, index, staged.count, item.action.relativePath, progress)
                try Task.checkCancellation()
                guard try await fileSystem.identity(of: item.reservation.item) == item.identity,
                      try await fileSystem.fingerprint(of: item.reservation.item)
                        .matchesAfterRelocation(item.stagedFingerprint),
                      try await fileSystem.identity(of: item.reservation.item) == item.identity else {
                    throw FolderSynchronizationTransactionFailure.stagedItemChanged(item.action.relativePath)
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
            return success(plan)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let fileSystem = self.fileSystem
            let total = plan.draft.actions.count
            let finalizedTrash = committedTrash
            let rollbackQuarantines = quarantines.filter {
                !finalizedTrash.contains($0.action.relativePath)
                    && !restoredTrash.contains($0.action.relativePath)
            }
            let recoveryNeeded = await Task.detached {
                await Self.rollback(
                    staged: staged,
                    unfinalizedReservations: unfinalizedReservations,
                    quarantines: rollbackQuarantines,
                    published: published,
                    committedTrash: finalizedTrash,
                    fileSystem: fileSystem,
                    total: total,
                    progress: progress
                )
            }.value
            return result(plan, error: error, cancelled: cancelled, recoveryNeeded: recoveryNeeded,
                committedTrash: finalizedTrash)
        }
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

    private func success(_ plan: PreparedFolderSynchronizationPlan) -> FileOperationResult {
        FileOperationResult(outcomes: plan.draft.actions.map { action in
            .succeeded(source: action.source?.url ?? action.destination!.url,
                       destination: action.kind == .moveDestinationToTrash ? nil : destinationURL(for: action, in: plan))
        })
    }

    private func failure(_ plan: PreparedFolderSynchronizationPlan, error: any Error) -> FileOperationResult {
        result(plan, error: error, cancelled: error is CancellationError, recoveryNeeded: [], committedTrash: [])
    }

    private func result(
        _ plan: PreparedFolderSynchronizationPlan,
        error: any Error,
        cancelled: Bool,
        recoveryNeeded: Set<ComparisonRelativePath>,
        committedTrash: Set<ComparisonRelativePath>
    ) -> FileOperationResult {
        FileOperationResult(outcomes: plan.draft.actions.map { action in
            let source = action.source?.url ?? action.destination!.url
            if recoveryNeeded.contains(action.relativePath) { return .recoveryNeeded(source: source) }
            if committedTrash.contains(action.relativePath), action.kind == .replace {
                return .succeeded(source: source, destination: destinationURL(for: action, in: plan))
            }
            if committedTrash.contains(action.relativePath) {
                return .succeeded(source: source, destination: nil)
            }
            if cancelled { return .cancelled(source: source) }
            return .failed(source: source, message: error.localizedDescription)
        })
    }
}
