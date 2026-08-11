import Foundation

struct FileOperationUndoMoveEntry: Sendable, Equatable {
    let currentURL: URL
    let currentIdentity: FileIdentity
    let originalURL: URL
}

struct FileOperationUndoCreatedEntry: Sendable, Equatable {
    let url: URL
    let identity: FileIdentity
    let fingerprint: SourceFingerprint
}

enum FileOperationUndoRecipe: Sendable, Equatable {
    case moveBack([FileOperationUndoMoveEntry])
    case removeCreated([FileOperationUndoCreatedEntry])
    case batchRename(BatchRenameUndoPlan)

    var itemCount: Int {
        switch self {
        case let .moveBack(entries): entries.count
        case let .removeCreated(entries): entries.count
        case let .batchRename(plan): plan.entries.count
        }
    }

    var displayName: String {
        switch self {
        case let .moveBack(entries): entries.first?.currentURL.lastPathComponent ?? "Item"
        case let .removeCreated(entries): entries.first?.url.lastPathComponent ?? "Item"
        case let .batchRename(plan): plan.entries.first?.finalURL.lastPathComponent ?? "Item"
        }
    }

    var touchedDirectories: Set<URL> {
        switch self {
        case let .moveBack(entries):
            Set(entries.flatMap {
                [$0.currentURL.deletingLastPathComponent(), $0.originalURL.deletingLastPathComponent()]
            })
        case let .removeCreated(entries):
            Set(entries.map { $0.url.deletingLastPathComponent() })
        case let .batchRename(plan):
            [plan.parentURL]
        }
    }
}

actor FileOperationUndoService {
    private enum UndoSafetyError: Error {
        case unavailable
    }

    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let batchRenameService: BatchRenameTransactionService

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        batchRenameService: BatchRenameTransactionService? = nil
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.batchRenameService = batchRenameService ?? BatchRenameTransactionService(
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator
        )
    }

    func makeRecipe(
        kind: FileOperationJobKind,
        result: FileOperationResult,
        allowsUndo: Bool
    ) async -> FileOperationUndoRecipe? {
        guard allowsUndo, !result.outcomes.isEmpty else { return nil }
        let completed: [(source: URL, destination: URL)] = result.outcomes.compactMap {
            guard case let .succeeded(source, destination?) = $0 else { return nil }
            return (source, destination)
        }
        guard completed.count == result.outcomes.count else { return nil }

        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(for: completed.flatMap {
                [$0.source, $0.destination]
            })
        } catch {
            return nil
        }
        defer { leases.forEach { $0.finish() } }

        do {
            if kind == .rename, let plan = result.batchRenameUndoMetadata() {
                guard plan.entries.count == completed.count else { return nil }
                for entry in plan.entries {
                    try Task.checkCancellation()
                    guard try await fileSystem.identity(of: entry.finalURL)
                        == entry.finalIdentity,
                        try await fileSystem.fingerprint(of: entry.finalURL)
                            == entry.finalFingerprint,
                        try await fileSystem.identity(of: entry.finalURL)
                            == entry.finalIdentity
                    else { return nil }
                }
                return .batchRename(plan)
            }
            switch kind {
            case .move, .rename, .trash:
                var entries: [FileOperationUndoMoveEntry] = []
                for item in completed {
                    try Task.checkCancellation()
                    guard let identity = result.undoDestinationIdentity(
                        for: item.destination
                    ),
                    try await fileSystem.identity(of: item.destination) == identity else {
                        return nil
                    }
                    entries.append(FileOperationUndoMoveEntry(
                        currentURL: item.destination,
                        currentIdentity: identity,
                        originalURL: item.source
                    ))
                }
                return entries.isEmpty ? nil : .moveBack(entries)

            case .copy, .createFolder, .compress, .extract:
                var entries: [FileOperationUndoCreatedEntry] = []
                for item in completed {
                    try Task.checkCancellation()
                    guard let identity = result.undoDestinationIdentity(
                        for: item.destination
                    ),
                    let fingerprint = result.undoDestinationFingerprint(
                        for: item.destination
                    ),
                    try await fileSystem.identity(of: item.destination) == identity,
                    try await fileSystem.fingerprint(of: item.destination) == fingerprint,
                    try await fileSystem.identity(of: item.destination) == identity else {
                        return nil
                    }
                    entries.append(FileOperationUndoCreatedEntry(
                        url: item.destination,
                        identity: identity,
                        fingerprint: fingerprint
                    ))
                }
                return entries.isEmpty ? nil : .removeCreated(entries)

            case .compressProtectedZIP:
                return nil

            case .undo:
                return nil
            }
        } catch {
            return nil
        }
    }

    func perform(
        _ recipe: FileOperationUndoRecipe,
        progress: @escaping OperationProgressHandler = { _ in }
    ) async -> FileOperationResult {
        let urls: [URL]
        switch recipe {
        case let .moveBack(entries):
            urls = entries.flatMap { [$0.currentURL, $0.originalURL] }
        case let .removeCreated(entries):
            urls = entries.map(\.url)
        case let .batchRename(plan):
            urls = [plan.parentURL] + plan.entries.flatMap {
                [$0.finalURL, $0.originalSource.url]
            }
        }

        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(for: urls)
        } catch {
            return failureResult(for: recipe)
        }
        defer { leases.forEach { $0.finish() } }

        switch recipe {
        case let .moveBack(entries):
            return await moveBack(entries, progress: progress)
        case let .removeCreated(entries):
            return await removeCreated(entries, progress: progress)
        case let .batchRename(plan):
            return await reverseBatchRename(plan, progress: progress)
        }
    }

    private func reverseBatchRename(
        _ plan: BatchRenameUndoPlan,
        progress: @escaping OperationProgressHandler
    ) async -> FileOperationResult {
        do {
            for entry in plan.entries {
                try Task.checkCancellation()
                guard try await fileSystem.identity(of: entry.finalURL)
                    == entry.finalIdentity,
                    try await fileSystem.fingerprint(of: entry.finalURL)
                        == entry.finalFingerprint,
                    try await fileSystem.identity(of: entry.finalURL)
                        == entry.finalIdentity
                else { throw UndoSafetyError.unavailable }
            }
        } catch is CancellationError {
            return FileOperationResult(outcomes: plan.entries.map {
                .cancelled(source: $0.finalURL)
            })
        } catch {
            return failureResult(for: .batchRename(plan))
        }

        return await batchRenameService.execute(plan.reversePlan) { update in
            await progress(FileOperationProgress(
                completedCount: update.completedCount,
                totalCount: update.totalCount,
                currentName: update.currentName
            ))
        }
    }

    private func moveBack(
        _ entries: [FileOperationUndoMoveEntry],
        progress: OperationProgressHandler
    ) async -> FileOperationResult {
        do {
            for entry in entries {
                try Task.checkCancellation()
                guard await !fileSystem.exists(entry.originalURL),
                      let current = try await fileSystem.identity(of: entry.currentURL),
                      current == entry.currentIdentity
                else { throw UndoSafetyError.unavailable }
            }
        } catch is CancellationError {
            return FileOperationResult(outcomes: entries.map {
                .cancelled(source: $0.currentURL)
            })
        } catch {
            return failureResult(for: .moveBack(entries))
        }

        var outcomes: [FileOperationItemOutcome] = []
        var completedEntries: [FileOperationUndoMoveEntry] = []
        for entry in entries.reversed() {
            do {
                try Task.checkCancellation()
                try await fileSystem.moveExclusively(
                    entry.currentURL,
                    identifiedBy: entry.currentIdentity,
                    to: entry.originalURL
                )
                outcomes.append(.succeeded(
                    source: entry.currentURL,
                    destination: entry.originalURL
                ))
                completedEntries.append(entry)
                await progress(FileOperationProgress(
                    completedCount: outcomes.count,
                    totalCount: entries.count,
                    currentName: entry.currentURL.lastPathComponent
                ))
            } catch is CancellationError {
                guard await rollbackMoves(completedEntries) else {
                    return FileOperationResult(outcomes: entries.map {
                        .recoveryNeeded(source: $0.currentURL)
                    })
                }
                return FileOperationResult(outcomes: entries.map {
                    .cancelled(source: $0.currentURL)
                })
            } catch {
                guard await rollbackMoves(completedEntries) else {
                    return FileOperationResult(outcomes: entries.map {
                        .recoveryNeeded(source: $0.currentURL)
                    })
                }
                return failureResult(for: .moveBack(entries))
            }
        }
        return FileOperationResult(outcomes: outcomes)
    }

    private func removeCreated(
        _ entries: [FileOperationUndoCreatedEntry],
        progress: OperationProgressHandler
    ) async -> FileOperationResult {
        do {
            for entry in entries {
                try Task.checkCancellation()
                guard let current = try await fileSystem.identity(of: entry.url),
                      current == entry.identity,
                      try await fileSystem.fingerprint(of: entry.url) == entry.fingerprint
                else { throw UndoSafetyError.unavailable }
            }
        } catch is CancellationError {
            return FileOperationResult(outcomes: entries.map { .cancelled(source: $0.url) })
        } catch {
            return failureResult(for: .removeCreated(entries))
        }

        var quarantines: [StorageTrashQuarantine] = []
        do {
            for entry in entries {
                try Task.checkCancellation()
                let quarantine = try await fileSystem.quarantineForTrash(
                    entry.url,
                    identifiedBy: entry.identity
                )
                quarantines.append(quarantine)
                guard try await fileSystem.fingerprint(of: quarantine)
                    .matchesAfterRelocation(entry.fingerprint)
                else { throw UndoSafetyError.unavailable }
            }
        } catch {
            let recovered = await rollback(quarantines)
            if error as? StorageTrashAccessError == .recoveryRequired {
                return FileOperationResult(outcomes: entries.map {
                    .recoveryNeeded(source: $0.url)
                })
            }
            if error is CancellationError, recovered {
                return FileOperationResult(outcomes: entries.map { .cancelled(source: $0.url) })
            }
            guard recovered else {
                return FileOperationResult(outcomes: entries.map {
                    .recoveryNeeded(source: $0.url)
                })
            }
            return failureResult(for: .removeCreated(entries))
        }

        var outcomes: [FileOperationItemOutcome] = []
        for (index, quarantine) in quarantines.enumerated() {
            do {
                try Task.checkCancellation()
                let destination = try await fileSystem.moveTrashQuarantineAtomically(quarantine)
                outcomes.append(.succeeded(
                    source: entries[index].url,
                    destination: destination
                ))
                await progress(FileOperationProgress(
                    completedCount: outcomes.count,
                    totalCount: entries.count,
                    currentName: entries[index].url.lastPathComponent
                ))
            } catch is CancellationError {
                let pendingQuarantines = Array(quarantines.dropFirst(index))
                let pendingEntries = Array(entries.dropFirst(index))
                let pendingRecovered = await rollback(pendingQuarantines)
                let mayReportCleanCancellation = pendingRecovered && outcomes.isEmpty
                outcomes.append(contentsOf: pendingEntries.map {
                    mayReportCleanCancellation
                        ? .cancelled(source: $0.url)
                        : .recoveryNeeded(source: $0.url)
                })
                break
            } catch {
                let pendingQuarantines = Array(quarantines.dropFirst(index + 1))
                let pendingEntries = Array(entries.dropFirst(index + 1))
                let pendingRecovered = await rollback(pendingQuarantines)
                if error as? StorageTrashAccessError == .failedButRestored,
                   outcomes.isEmpty {
                    outcomes.append(.failed(
                        source: entries[index].url,
                        message: error.localizedDescription
                    ))
                } else {
                    outcomes.append(.recoveryNeeded(source: entries[index].url))
                }
                outcomes.append(contentsOf: pendingEntries.map {
                    pendingRecovered
                        ? .cancelled(source: $0.url)
                        : .recoveryNeeded(source: $0.url)
                })
                break
            }
        }
        return FileOperationResult(outcomes: outcomes)
    }

    private func rollback(_ quarantines: [StorageTrashQuarantine]) async -> Bool {
        var recovered = true
        for quarantine in quarantines.reversed() {
            do {
                try await fileSystem.rollbackTrashQuarantine(quarantine)
            } catch {
                recovered = false
            }
        }
        return recovered
    }

    private func rollbackMoves(_ entries: [FileOperationUndoMoveEntry]) async -> Bool {
        var recovered = true
        for entry in entries.reversed() {
            do {
                guard await !fileSystem.exists(entry.currentURL),
                      let identity = try await fileSystem.identity(of: entry.originalURL),
                      identity == entry.currentIdentity
                else {
                    recovered = false
                    continue
                }
                try await fileSystem.moveExclusively(
                    entry.originalURL,
                    identifiedBy: entry.currentIdentity,
                    to: entry.currentURL
                )
            } catch {
                recovered = false
            }
        }
        return recovered
    }

    private func failureResult(for recipe: FileOperationUndoRecipe) -> FileOperationResult {
        let message = "Undo is unavailable because an item changed or its original location is occupied."
        switch recipe {
        case let .moveBack(entries):
            return FileOperationResult(outcomes: entries.map {
                .failed(source: $0.currentURL, message: message)
            })
        case let .removeCreated(entries):
            return FileOperationResult(outcomes: entries.map {
                .failed(source: $0.url, message: message)
            })
        case let .batchRename(plan):
            return FileOperationResult(outcomes: plan.entries.map {
                .failed(source: $0.finalURL, message: message)
            })
        }
    }
}

private extension SourceFingerprint {
    func matchesAfterRelocation(_ original: SourceFingerprint) -> Bool {
        guard entries.count == original.entries.count else { return false }
        return zip(entries, original.entries).allSatisfy { current, captured in
            guard current.relativePath == captured.relativePath,
                  current.device == captured.device,
                  current.inode == captured.inode,
                  current.mode == captured.mode,
                  current.size == captured.size,
                  current.modificationSeconds == captured.modificationSeconds,
                  current.modificationNanoseconds == captured.modificationNanoseconds
            else { return false }
            return current.relativePath == "." || (
                current.changeSeconds == captured.changeSeconds
                    && current.changeNanoseconds == captured.changeNanoseconds
            )
        }
    }
}
