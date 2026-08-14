import Foundation

struct FileOperationUndoMoveEntry: Sendable, Equatable {
    let currentURL: URL
    let currentIdentity: FileIdentity
    let currentFingerprint: SourceFingerprint
    let originalURL: URL
}

struct SelectionFolderForwardRecipe: Sendable, Equatable {
    let plan: SelectionFolderPlan
    let expectedSourceFingerprints: [URL: SourceFingerprint]
}

struct FileOperationReversalExecution: Sendable, Equatable {
    let result: FileOperationResult
    let inverseRecipe: FileOperationUndoRecipe?
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
    case selectionFolderReverse(SelectionFolderUndoPlan)
    case selectionFolderForward(SelectionFolderForwardRecipe)

    var itemCount: Int {
        switch self {
        case let .moveBack(entries): entries.count
        case let .removeCreated(entries): entries.count
        case let .batchRename(plan): plan.entries.count
        case let .selectionFolderReverse(plan): plan.entries.count
        case let .selectionFolderForward(recipe): recipe.plan.sources.count
        }
    }

    var displayName: String {
        switch self {
        case let .moveBack(entries): entries.first?.currentURL.lastPathComponent ?? "Item"
        case let .removeCreated(entries): entries.first?.url.lastPathComponent ?? "Item"
        case let .batchRename(plan): plan.entries.first?.finalURL.lastPathComponent ?? "Item"
        case let .selectionFolderReverse(plan): plan.folderURL.lastPathComponent
        case let .selectionFolderForward(recipe): recipe.plan.folderName
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
        case let .selectionFolderReverse(plan):
            [plan.parentURL, plan.folderURL]
        case let .selectionFolderForward(recipe):
            [recipe.plan.parentURL, recipe.plan.folderURL]
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
    private let selectionFolderTransactionService: SelectionFolderTransactionService

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        batchRenameService: BatchRenameTransactionService? = nil,
        selectionFolderTransactionService: SelectionFolderTransactionService? = nil
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.batchRenameService = batchRenameService ?? BatchRenameTransactionService(
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator
        )
        self.selectionFolderTransactionService = selectionFolderTransactionService
            ?? SelectionFolderTransactionService(
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
        if kind == .encloseSelection {
            return await makeSelectionFolderRecipe(result: result)
        }
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
                guard plan.entries.count == result.outcomes.count,
                      plan.entries.count == completed.count
                else { return nil }
                for (entry, outcome) in zip(plan.entries, result.outcomes) {
                    try Task.checkCancellation()
                    guard case let .succeeded(source, destination?) = outcome,
                          source.standardizedFileURL
                            == entry.originalSource.url.standardizedFileURL,
                          destination.standardizedFileURL
                            == entry.finalURL.standardizedFileURL,
                          result.undoDestinationIdentity(for: destination)
                            == entry.finalIdentity,
                          result.undoDestinationFingerprint(for: destination)
                            == entry.finalFingerprint
                    else { return nil }
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
                        currentFingerprint: try await fingerprintAfterMatchingIdentity(
                            at: item.destination,
                            identity: identity
                        ),
                        originalURL: item.source
                    ))
                }
                return entries.isEmpty ? nil : .moveBack(entries)

            case .copy, .duplicate, .createFolder, .compress, .extract:
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

            case .encloseSelection:
                return nil

            case .synchronizeFolder:
                return nil

            case .undo, .redo:
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
        await performReversal(recipe, progress: progress).result
    }

    func performReversal(
        _ recipe: FileOperationUndoRecipe,
        progress: @escaping OperationProgressHandler = { _ in }
    ) async -> FileOperationReversalExecution {
        let result = await execute(recipe, progress: progress)
        guard result.outcomes.count == recipe.itemCount,
              result.outcomes.allSatisfy({ if case .succeeded = $0 { return true }; return false }) else {
            return .init(result: result, inverseRecipe: nil)
        }
        return .init(result: result, inverseRecipe: await freshInverse(for: recipe, result: result))
    }

    private func execute(
        _ recipe: FileOperationUndoRecipe,
        progress: @escaping OperationProgressHandler
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
        case let .selectionFolderReverse(plan):
            urls = [plan.parentURL, plan.folderURL] + plan.entries.flatMap {
                [$0.originalSource.item.url, $0.folderURL]
            }
        case let .selectionFolderForward(recipe):
            urls = [recipe.plan.parentURL, recipe.plan.folderURL] + recipe.plan.sources.map(\.item.url)
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
        case let .selectionFolderReverse(plan):
            return await performSelectionFolderUndo(plan) { update in
                await progress(FileOperationProgress(
                    completedCount: update.completedCount,
                    totalCount: update.totalCount,
                    currentName: update.currentName
                ))
            }
        case let .selectionFolderForward(recipe):
            guard await selectionFolderForwardIsCurrent(recipe) else { return failureResult(for: .selectionFolderForward(recipe)) }
            return await selectionFolderTransactionService.execute(
                recipe.plan,
                expectedSourceFingerprints: recipe.expectedSourceFingerprints
            ) { update in
                await progress(.init(completedCount: update.completedCount, totalCount: update.totalCount, currentName: update.currentName))
            }
        }
    }

    func performSelectionFolderUndo(
        _ plan: SelectionFolderUndoPlan,
        progress: @escaping @Sendable (SelectionFolderTransactionProgress) async -> Void
    ) async -> FileOperationResult {
        await selectionFolderTransactionService.reverse(plan, progress: progress)
    }

    private func makeSelectionFolderRecipe(
        result: FileOperationResult
    ) async -> FileOperationUndoRecipe? {
        guard let plan = result.selectionFolderUndoMetadata(),
              plan.entries.count == result.outcomes.count,
              result.outcomes.allSatisfy({ outcome in
                  guard case .succeeded = outcome else { return false }
                  return true
              }),
              Set(result.outcomes.compactMap { outcome -> URL? in
                  guard case let .succeeded(_, destination?) = outcome else { return nil }
                  return destination.standardizedFileURL
              }) == Set(plan.entries.map { $0.folderURL.standardizedFileURL })
        else { return nil }

        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(for: [plan.parentURL, plan.folderURL]
                + plan.entries.flatMap { [$0.originalSource.item.url, $0.folderURL] })
        } catch {
            return nil
        }
        defer { leases.forEach { $0.finish() } }

        do {
            guard try await fileSystem.identity(of: plan.parentURL) == plan.parentIdentity,
                  try await fileSystem.identity(of: plan.folderURL) == plan.folderIdentity,
                  try await fileSystem.names(in: plan.folderURL)
                    == Set(plan.entries.map(\.folderURL.lastPathComponent))
            else { return nil }
            for entry in plan.entries {
                try Task.checkCancellation()
                guard await !fileSystem.exists(entry.originalSource.item.url),
                      try await fileSystem.identity(of: entry.folderURL) == entry.folderIdentity,
                      try await fileSystem.fingerprint(of: entry.folderURL) == entry.fingerprint
                else { return nil }
            }
            return .selectionFolderReverse(plan)
        } catch {
            return nil
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

        let expectedFingerprints = Dictionary(uniqueKeysWithValues: plan.entries.map {
            ($0.finalURL, $0.finalFingerprint)
        })
        return await batchRenameService.execute(
            plan.reversePlan,
            expectedSourceFingerprints: expectedFingerprints
        ) { update in
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
                      current == entry.currentIdentity,
                      try await fingerprintAfterMatchingIdentity(at: entry.currentURL, identity: entry.currentIdentity) == entry.currentFingerprint
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
                guard try await fingerprintAfterMatchingIdentity(at: entry.currentURL, identity: entry.currentIdentity) == entry.currentFingerprint else { throw UndoSafetyError.unavailable }
                try await fileSystem.moveExclusively(
                    entry.currentURL,
                    identifiedBy: entry.currentIdentity,
                    to: entry.originalURL
                )
                // This relocation is externally visible before postflight I/O.
                // Include it in recovery before awaiting further authority checks.
                completedEntries.append(entry)
                guard try await fingerprintAfterMatchingIdentity(
                    at: entry.originalURL,
                    identity: entry.currentIdentity
                ).matchesAfterRelocation(entry.currentFingerprint) else {
                    throw UndoSafetyError.unavailable
                }
                outcomes.append(.succeeded(
                    source: entry.currentURL,
                    destination: entry.originalURL
                ))
                await progress(FileOperationProgress(
                    completedCount: outcomes.count,
                    totalCount: entries.count,
                    currentName: entry.currentURL.lastPathComponent
                ))
            } catch is CancellationError {
                let fileSystem = self.fileSystem
                let recovered = await Task.detached {
                    await Self.rollbackMoves(completedEntries, fileSystem: fileSystem)
                }.value
                guard recovered else {
                    return FileOperationResult(outcomes: entries.map {
                        .recoveryNeeded(source: $0.currentURL)
                    })
                }
                return FileOperationResult(outcomes: entries.map {
                    .cancelled(source: $0.currentURL)
                })
            } catch {
                let fileSystem = self.fileSystem
                let recovered = await Task.detached {
                    await Self.rollbackMoves(completedEntries, fileSystem: fileSystem)
                }.value
                guard recovered else {
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
                let parent = entry.url.deletingLastPathComponent()
                guard let parentIdentity = try await fileSystem.identity(of: parent) else {
                    throw UndoSafetyError.unavailable
                }
                let quarantine: StorageTrashQuarantine
                do {
                    quarantine = try await fileSystem.quarantineForTrash(
                        entry.url,
                        identifiedBy: entry.identity,
                        parentIdentifiedBy: parentIdentity
                    )
                } catch let recoverable as StorageTrashRecoverableFailure {
                    quarantines.append(recoverable.quarantine)
                    throw recoverable
                }
                quarantines.append(quarantine)
                guard try await fileSystem.fingerprint(of: quarantine)
                    .matchesAfterRelocation(entry.fingerprint)
                else { throw UndoSafetyError.unavailable }
            }
        } catch {
            let recovered = await rollback(quarantines)
            if error is StorageTrashRecoverableFailure, !recovered {
                return FileOperationResult(outcomes: entries.map { .recoveryNeeded(source: $0.url) })
            }
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
            } catch let recoverable as StorageTrashRecoverableFailure {
                let restored = await rollback([recoverable.quarantine])
                let pendingQuarantines = Array(quarantines.dropFirst(index + 1))
                let pendingEntries = Array(entries.dropFirst(index + 1))
                let pendingRecovered = await rollback(pendingQuarantines)
                outcomes.append(restored && pendingRecovered
                    ? .failed(source: entries[index].url, message: "trash transfer failed")
                    : .recoveryNeeded(source: entries[index].url))
                outcomes.append(contentsOf: pendingEntries.map {
                    pendingRecovered ? .cancelled(source: $0.url) : .recoveryNeeded(source: $0.url)
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

    private nonisolated static func rollbackMoves(
        _ entries: [FileOperationUndoMoveEntry],
        fileSystem: any FileSystemAccess
    ) async -> Bool {
        var recovered = true
        for entry in entries.reversed() {
            do {
                guard await !fileSystem.exists(entry.currentURL),
                      let identity = try await fileSystem.identity(of: entry.originalURL),
                      identity == entry.currentIdentity,
                      try await fingerprintAfterMatchingIdentity(
                        at: entry.originalURL,
                        identity: entry.currentIdentity,
                        fileSystem: fileSystem
                      )
                        .matchesAfterRelocation(entry.currentFingerprint)
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
        case let .selectionFolderReverse(plan):
            return FileOperationResult(outcomes: plan.entries.map {
                .failed(source: $0.folderURL, message: message)
            })
        case let .selectionFolderForward(recipe):
            return FileOperationResult(outcomes: recipe.plan.sources.map {
                .failed(source: $0.item.url, message: message)
            })
        }
    }

    private func fingerprintAfterMatchingIdentity(at url: URL, identity: FileIdentity) async throws -> SourceFingerprint {
        try await Self.fingerprintAfterMatchingIdentity(at: url, identity: identity, fileSystem: fileSystem)
    }

    private nonisolated static func fingerprintAfterMatchingIdentity(
        at url: URL,
        identity: FileIdentity,
        fileSystem: any FileSystemAccess
    ) async throws -> SourceFingerprint {
        guard try await fileSystem.identity(of: url) == identity else { throw UndoSafetyError.unavailable }
        let fingerprint = try await fileSystem.fingerprint(of: url)
        guard try await fileSystem.identity(of: url) == identity else { throw UndoSafetyError.unavailable }
        return fingerprint
    }

    private func freshInverse(for recipe: FileOperationUndoRecipe, result: FileOperationResult) async -> FileOperationUndoRecipe? {
        switch recipe {
        case let .moveBack(expectedEntries):
            let completed = result.outcomes.compactMap { outcome -> (URL, URL)? in
                guard case let .succeeded(source, destination?) = outcome else { return nil }
                return (source, destination)
            }
            guard completed.count == result.outcomes.count,
                  completed.count == expectedEntries.count else { return nil }
            do {
                var entries: [FileOperationUndoMoveEntry] = []
                for (original, current) in completed {
                    guard let expected = expectedEntries.first(where: {
                        $0.currentURL == original && $0.originalURL == current
                    }),
                    try await fileSystem.identity(of: current) == expected.currentIdentity else { return nil }
                    let fingerprint = try await fingerprintAfterMatchingIdentity(
                        at: current,
                        identity: expected.currentIdentity
                    )
                    guard fingerprint.matchesAfterRelocation(expected.currentFingerprint) else { return nil }
                    entries.append(.init(currentURL: current, currentIdentity: expected.currentIdentity, currentFingerprint: fingerprint, originalURL: original))
                }
                return .moveBack(entries)
            } catch { return nil }
        case let .removeCreated(entries):
            let destinations = result.outcomes.compactMap { outcome -> URL? in
                guard case let .succeeded(_, destination?) = outcome else { return nil }
                return destination
            }
            guard destinations.count == entries.count else { return nil }
            do {
                var inverseEntries: [FileOperationUndoMoveEntry] = []
                for (entry, destination) in zip(entries, destinations) {
                    guard try await fileSystem.identity(of: destination) == entry.identity else { return nil }
                    let fingerprint = try await fingerprintAfterMatchingIdentity(
                        at: destination,
                        identity: entry.identity
                    )
                    guard fingerprint.matchesAfterRelocation(entry.fingerprint) else { return nil }
                    inverseEntries.append(.init(
                        currentURL: destination,
                        currentIdentity: entry.identity,
                        currentFingerprint: fingerprint,
                        originalURL: entry.url
                    ))
                }
                return .moveBack(inverseEntries)
            } catch {
                return nil
            }
        case .batchRename:
            return await makeRecipe(kind: .rename, result: result, allowsUndo: true)
        case let .selectionFolderReverse(plan):
            guard await !fileSystem.exists(plan.folderURL) else { return nil }
            do {
                var expected: [URL: SourceFingerprint] = [:]
                for entry in plan.entries {
                    guard try await fileSystem.identity(of: entry.originalSource.item.url)
                        == entry.folderIdentity else { return nil }
                    let fingerprint = try await fingerprintAfterMatchingIdentity(
                        at: entry.originalSource.item.url,
                        identity: entry.folderIdentity
                    )
                    guard fingerprint.matchesAfterRelocation(entry.fingerprint) else { return nil }
                    expected[entry.originalSource.item.url] = fingerprint
                }
                return .selectionFolderForward(.init(
                    plan: .init(parentURL: plan.parentURL, parentIdentity: plan.parentIdentity, folderName: plan.folderURL.lastPathComponent, folderURL: plan.folderURL, sources: plan.entries.map(\.originalSource)),
                    expectedSourceFingerprints: expected
                ))
            } catch { return nil }
        case .selectionFolderForward:
            return await makeSelectionFolderRecipe(result: result)
        }
    }

    private func selectionFolderForwardIsCurrent(_ recipe: SelectionFolderForwardRecipe) async -> Bool {
        guard await !fileSystem.exists(recipe.plan.folderURL) else { return false }
        do {
            for source in recipe.plan.sources {
                guard let expected = recipe.expectedSourceFingerprints[source.item.url],
                      try await fileSystem.identity(of: source.item.url) == source.identity,
                      try await fingerprintAfterMatchingIdentity(at: source.item.url, identity: source.identity) == expected else { return false }
            }
            return true
        } catch { return false }
    }
}
