import Foundation

enum BatchRenameTransactionPhase: String, Sendable, Equatable {
    case staging
    case publishing
    case rollingBack
}

struct BatchRenameTransactionProgress: Sendable, Equatable {
    let phase: BatchRenameTransactionPhase
    let completedCount: Int
    let totalCount: Int
    let currentName: String
}

enum BatchRenameTransactionFailure: LocalizedError, Equatable, Sendable {
    case emptyPlan
    case parentChanged
    case sourceChanged(String)
    case destinationOccupied(String)
    case comparisonPolicyChanged
    case temporaryNameUnavailable
    case publishedIdentityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyPlan:
            "There are no names to change."
        case .parentChanged:
            "The containing folder changed before the rename began."
        case let .sourceChanged(name):
            "\(name) changed before the rename began."
        case let .destinationOccupied(name):
            "\(name) is now used by another item."
        case .comparisonPolicyChanged:
            "The folder's filename rules changed before the rename began."
        case .temporaryNameUnavailable:
            "Pengrid could not reserve temporary names for this rename."
        case let .publishedIdentityUnavailable(name):
            "Pengrid could not verify \(name) after renaming it."
        }
    }
}

actor BatchRenameTransactionService {
    typealias ProgressHandler = @Sendable (BatchRenameTransactionProgress) async -> Void

    private enum Location: Sendable {
        case original
        case staged
        case published
    }

    private struct WorkingEntry: Sendable {
        let planEntry: BatchRenamePlanEntry
        let temporaryURL: URL
        var currentURL: URL
        var currentIdentity: FileIdentity
        var location: Location
    }

    private struct RollbackResult: Sendable {
        let unrecoveredSources: Set<URL>
    }

    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let temporaryName: @Sendable (Int) -> String

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        temporaryName: @escaping @Sendable (Int) -> String = {
            ".pengrid-rename-\(UUID().uuidString)-\($0)"
        }
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.temporaryName = temporaryName
    }

    func execute(
        _ plan: BatchRenamePlan,
        expectedSourceFingerprints: [URL: SourceFingerprint] = [:],
        progress: @escaping ProgressHandler
    ) async -> FileOperationResult {
        guard !plan.entries.isEmpty else {
            return failureResult(plan, error: BatchRenameTransactionFailure.emptyPlan)
        }

        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: [plan.parentURL]
                + plan.entries.flatMap { [$0.source.url, $0.destinationURL] })
        } catch {
            return failureResult(plan, error: error)
        }
        defer { accessLeases.forEach { $0.finish() } }

        var workingEntries: [WorkingEntry] = []
        do {
            try Task.checkCancellation()
            try await preflight(plan)
            workingEntries = try await makeWorkingEntries(for: plan)

            for index in workingEntries.indices {
                try Task.checkCancellation()
                let entry = workingEntries[index]
                try await fileSystem.moveExclusively(
                    entry.planEntry.source.url,
                    identifiedBy: entry.planEntry.source.identity,
                    to: entry.temporaryURL,
                    destinationParentIdentifiedBy: plan.parentIdentity
                )
                workingEntries[index].currentURL = entry.temporaryURL
                workingEntries[index].currentIdentity = entry.planEntry.source.identity
                workingEntries[index].location = .staged
                await progress(BatchRenameTransactionProgress(
                    phase: .staging,
                    completedCount: index + 1,
                    totalCount: workingEntries.count,
                    currentName: entry.planEntry.source.name
                ))
                try Task.checkCancellation()
                guard let stagedIdentity = try await fileSystem.identity(of: entry.temporaryURL),
                      stagedIdentity == entry.planEntry.source.identity else {
                    throw BatchRenameTransactionFailure.sourceChanged(
                        entry.planEntry.source.name
                    )
                }
                workingEntries[index].currentIdentity = stagedIdentity
            }

            for entry in workingEntries {
                try Task.checkCancellation()
                guard let expectedFingerprint = expectedSourceFingerprints[
                    entry.planEntry.source.url
                ] else { continue }
                guard try await fileSystem.fingerprint(of: entry.currentURL)
                    == expectedFingerprint else {
                    throw BatchRenameTransactionFailure.sourceChanged(
                        entry.planEntry.source.name
                    )
                }
            }

            var finalIdentities: [URL: FileIdentity] = [:]
            var finalFingerprints: [URL: SourceFingerprint] = [:]
            var undoEntries: [BatchRenameUndoEntry] = []
            for index in workingEntries.indices {
                try Task.checkCancellation()
                let entry = workingEntries[index]
                try await fileSystem.moveExclusively(
                    entry.currentURL,
                    identifiedBy: entry.currentIdentity,
                    to: entry.planEntry.destinationURL,
                    destinationParentIdentifiedBy: plan.parentIdentity
                )
                workingEntries[index].currentURL = entry.planEntry.destinationURL
                workingEntries[index].location = .published
                await progress(BatchRenameTransactionProgress(
                    phase: .publishing,
                    completedCount: index + 1,
                    totalCount: workingEntries.count,
                    currentName: entry.planEntry.proposedName
                ))
                try Task.checkCancellation()
                guard let finalIdentity = try await fileSystem.identity(
                    of: entry.planEntry.destinationURL
                ), finalIdentity == entry.planEntry.source.identity else {
                    throw BatchRenameTransactionFailure.publishedIdentityUnavailable(
                        entry.planEntry.proposedName
                    )
                }
                let fingerprint = try await fileSystem.fingerprint(
                    of: entry.planEntry.destinationURL
                )
                finalIdentities[entry.planEntry.destinationURL] = finalIdentity
                finalFingerprints[entry.planEntry.destinationURL] = fingerprint
                undoEntries.append(BatchRenameUndoEntry(
                    originalSource: entry.planEntry.source,
                    finalURL: entry.planEntry.destinationURL,
                    finalIdentity: finalIdentity,
                    finalFingerprint: fingerprint
                ))
                workingEntries[index].currentIdentity = finalIdentity
            }

            return FileOperationResult(
                outcomes: plan.entries.map {
                    .succeeded(source: $0.source.url, destination: $0.destinationURL)
                },
                undoDestinationIdentities: finalIdentities,
                undoDestinationFingerprints: finalFingerprints,
                batchRenameUndoPlan: BatchRenameUndoPlan(
                    parentURL: plan.parentURL,
                    parentIdentity: plan.parentIdentity,
                    entries: undoEntries,
                    comparisonPolicy: plan.comparisonPolicy
                )
            )
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            guard workingEntries.contains(where: { $0.location != .original }) else {
                return wasCancelled ? cancellationResult(plan) : failureResult(plan, error: error)
            }
            let fileSystem = self.fileSystem
            let parentIdentity = plan.parentIdentity
            let rollback = await Task.detached {
                await Self.rollback(
                    workingEntries,
                    parentIdentity: parentIdentity,
                    fileSystem: fileSystem,
                    progress: progress
                )
            }.value
            return rollbackResult(
                plan,
                primaryError: error,
                wasCancelled: wasCancelled,
                unrecoveredSources: rollback.unrecoveredSources
            )
        }
    }

    private func preflight(_ plan: BatchRenamePlan) async throws {
        guard try await fileSystem.identity(of: plan.parentURL) == plan.parentIdentity else {
            throw BatchRenameTransactionFailure.parentChanged
        }
        guard try await fileSystem.filenameComparisonPolicy(in: plan.parentURL)
            == plan.comparisonPolicy else {
            throw BatchRenameTransactionFailure.comparisonPolicyChanged
        }
        for entry in plan.entries {
            try Task.checkCancellation()
            guard try await fileSystem.identity(of: entry.source.url) == entry.source.identity else {
                throw BatchRenameTransactionFailure.sourceChanged(entry.source.name)
            }
        }

        let currentNames = try await fileSystem.names(in: plan.parentURL)
        let selectedKeys = Set(plan.entries.map {
            plan.comparisonPolicy.key(for: $0.source.name)
        })
        let externallyOccupied = Set(currentNames.map(plan.comparisonPolicy.key(for:)))
            .subtracting(selectedKeys)
        for entry in plan.entries where externallyOccupied.contains(
            plan.comparisonPolicy.key(for: entry.proposedName)
        ) {
            throw BatchRenameTransactionFailure.destinationOccupied(entry.proposedName)
        }
    }

    private func makeWorkingEntries(for plan: BatchRenamePlan) async throws -> [WorkingEntry] {
        let occupiedNames = try await fileSystem.names(in: plan.parentURL)
        var occupiedKeys = Set(occupiedNames.map(plan.comparisonPolicy.key(for:)))
        occupiedKeys.formUnion(plan.entries.map {
            plan.comparisonPolicy.key(for: $0.proposedName)
        })
        var result: [WorkingEntry] = []
        result.reserveCapacity(plan.entries.count)
        for (index, entry) in plan.entries.enumerated() {
            let name = temporaryName(index)
            try FilenameValidator.validate(name)
            let key = plan.comparisonPolicy.key(for: name)
            guard !occupiedKeys.contains(key) else {
                throw BatchRenameTransactionFailure.temporaryNameUnavailable
            }
            occupiedKeys.insert(key)
            let temporaryURL = plan.parentURL.appending(
                path: name,
                directoryHint: entry.source.isDirectory ? .isDirectory : .notDirectory
            )
            result.append(WorkingEntry(
                planEntry: entry,
                temporaryURL: temporaryURL,
                currentURL: entry.source.url,
                currentIdentity: entry.source.identity,
                location: .original
            ))
        }
        return result
    }

    private nonisolated static func rollback(
        _ initialEntries: [WorkingEntry],
        parentIdentity: FileIdentity,
        fileSystem: any FileSystemAccess,
        progress: @escaping ProgressHandler
    ) async -> RollbackResult {
        var entries = initialEntries
        var completed = 0
        let mutatedCount = entries.count(where: { $0.location != .original })

        for index in entries.indices where entries[index].location == .published {
            let holdingURL = entries[index].planEntry.source.url.deletingLastPathComponent()
                .appending(path: ".pengrid-rename-rollback-\(UUID().uuidString)-\(index)")
            do {
                guard await !fileSystem.exists(holdingURL) else { continue }
                try await fileSystem.moveExclusively(
                    entries[index].currentURL,
                    identifiedBy: entries[index].currentIdentity,
                    to: holdingURL,
                    destinationParentIdentifiedBy: parentIdentity
                )
                entries[index].currentURL = holdingURL
                entries[index].location = .staged
            } catch {
                continue
            }
        }

        for index in entries.indices where entries[index].location != .original {
            let originalURL = entries[index].planEntry.source.url
            do {
                guard await !fileSystem.exists(originalURL) else { continue }
                try await fileSystem.moveExclusively(
                    entries[index].currentURL,
                    identifiedBy: entries[index].currentIdentity,
                    to: originalURL,
                    destinationParentIdentifiedBy: parentIdentity
                )
                entries[index].currentURL = originalURL
                entries[index].location = .original
                completed += 1
                await progress(BatchRenameTransactionProgress(
                    phase: .rollingBack,
                    completedCount: completed,
                    totalCount: mutatedCount,
                    currentName: entries[index].planEntry.source.name
                ))
            } catch {
                continue
            }
        }

        var unrecovered: Set<URL> = []
        for entry in entries {
            let restoredIdentity = try? await fileSystem.identity(of: entry.planEntry.source.url)
            if restoredIdentity != entry.planEntry.source.identity {
                unrecovered.insert(entry.planEntry.source.url)
            }
        }
        return RollbackResult(unrecoveredSources: unrecovered)
    }

    private func cancellationResult(_ plan: BatchRenamePlan) -> FileOperationResult {
        FileOperationResult(outcomes: plan.entries.map {
            .cancelled(source: $0.source.url)
        })
    }

    private func failureResult(
        _ plan: BatchRenamePlan,
        error: any Error
    ) -> FileOperationResult {
        let message = safeMessage(for: error)
        return FileOperationResult(outcomes: plan.entries.map {
            .failed(source: $0.source.url, message: message)
        })
    }

    private func rollbackResult(
        _ plan: BatchRenamePlan,
        primaryError: any Error,
        wasCancelled: Bool,
        unrecoveredSources: Set<URL>
    ) -> FileOperationResult {
        let message = safeMessage(for: primaryError)
        return FileOperationResult(outcomes: plan.entries.map { entry in
            if unrecoveredSources.contains(entry.source.url) {
                return .recoveryNeeded(source: entry.source.url)
            }
            if wasCancelled {
                return .cancelled(source: entry.source.url)
            }
            return .failed(source: entry.source.url, message: message)
        })
    }

    private func safeMessage(for error: any Error) -> String {
        if let failure = error as? BatchRenameTransactionFailure {
            return failure.localizedDescription
        }
        return "The batch rename could not be completed safely."
    }
}
