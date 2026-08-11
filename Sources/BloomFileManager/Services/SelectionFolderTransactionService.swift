import Darwin
import Foundation

enum SelectionFolderTransactionFailure: LocalizedError, Sendable {
    case invalidPlan
    case parentChanged
    case sourceChanged(String)
    case destinationOccupied(String)
    case folderChanged
    case undoPreflightFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlan: "The selected items cannot be enclosed safely."
        case .parentChanged: "The containing folder changed before the operation began."
        case let .sourceChanged(name): "\(name) changed before the operation began."
        case let .destinationOccupied(name): "\(name) is already in use."
        case .folderChanged: "The created folder changed before the operation completed."
        case .undoPreflightFailed: "The enclosed items changed, so Undo could not start safely."
        }
    }
}

actor SelectionFolderTransactionService {
    typealias ProgressHandler = @Sendable (SelectionFolderTransactionProgress) async -> Void

    private struct MovedEntry: Sendable {
        let source: ContextActionSource
        let folderURL: URL
        let identity: FileIdentity
        let fingerprint: SourceFingerprint
    }

    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
    }

    func execute(_ plan: SelectionFolderPlan, progress: @escaping ProgressHandler) async -> FileOperationResult {
        let folderName = plan.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plan.sources.count >= 2,
              (try? FilenameValidator.validate(folderName)) != nil,
              plan.folderURL.standardizedFileURL == plan.parentURL.appending(
                path: folderName,
                directoryHint: .isDirectory
              ).standardizedFileURL,
              plan.sources.allSatisfy({
                  $0.item.url.deletingLastPathComponent().standardizedFileURL
                    == plan.parentURL.standardizedFileURL
              }),
              plan.sources.allSatisfy({ source in
                  let basename = source.item.url.lastPathComponent
                  return source.item.name == basename
                    && (try? FilenameValidator.validate(basename)) != nil
              }),
              Set(plan.sources.map { $0.item.url.lastPathComponent }).count == plan.sources.count
        else { return failure(plan, error: SelectionFolderTransactionFailure.invalidPlan) }

        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(for: [plan.parentURL, plan.folderURL]
                + plan.sources.map(\.item.url))
        } catch { return failure(plan, error: error) }
        defer { leases.forEach { $0.finish() } }

        var folderIdentity: FileIdentity?
        var moved: [MovedEntry] = []
        do {
            try Task.checkCancellation()
            try await preflightForward(plan)
            try Task.checkCancellation()
            await progress(.init(
                phase: .creatingFolder,
                completedCount: 0,
                totalCount: plan.sources.count,
                currentName: folderName
            ))
            let created = try await fileSystem.createEmptyItemAndCaptureIdentity(
                plan.folderURL,
                kind: .directory,
                parentIdentifiedBy: plan.parentIdentity
            )
            Darwin.close(created.descriptor)
            folderIdentity = created.identity
            guard try await fileSystem.identity(of: plan.folderURL) == created.identity else {
                throw SelectionFolderTransactionFailure.folderChanged
            }
            try Task.checkCancellation()

            for source in plan.sources {
                try Task.checkCancellation()
                let destination = plan.folderURL.appending(
                    path: source.item.url.lastPathComponent,
                    directoryHint: source.item.isDirectory ? .isDirectory : .notDirectory
                )
                try await fileSystem.moveExclusively(
                    source.item.url,
                    identifiedBy: source.identity,
                    to: destination,
                    destinationParentIdentifiedBy: created.identity
                )
                guard let movedIdentity = try await fileSystem.identity(of: destination),
                      movedIdentity == source.identity else {
                    throw SelectionFolderTransactionFailure.sourceChanged(source.item.url.lastPathComponent)
                }
                let fingerprint = try await fileSystem.fingerprint(of: destination)
                moved.append(.init(
                    source: source,
                    folderURL: destination,
                    identity: movedIdentity,
                    fingerprint: fingerprint
                ))
                await progress(.init(
                    phase: .movingItems,
                    completedCount: moved.count,
                    totalCount: plan.sources.count,
                    currentName: source.item.url.lastPathComponent
                ))
                try Task.checkCancellation()
            }
            let undo = SelectionFolderUndoPlan(
                parentURL: plan.parentURL,
                parentIdentity: plan.parentIdentity,
                folderURL: plan.folderURL,
                folderIdentity: created.identity,
                entries: moved.map { .init(
                    originalSource: $0.source,
                    folderURL: $0.folderURL,
                    folderIdentity: $0.identity,
                    fingerprint: $0.fingerprint
                ) }
            )
            return FileOperationResult(
                outcomes: moved.map { .succeeded(source: $0.source.item.url, destination: $0.folderURL) },
                selectionFolderUndoPlan: undo
            )
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            guard let folderIdentity else {
                return cancelled ? cancelledResult(plan) : failure(plan, error: error)
            }
            let fileSystem = self.fileSystem
            let unrecovered = await Task.detached {
                await Self.rollbackForward(moved, plan: plan, folderIdentity: folderIdentity,
                    fileSystem: fileSystem, progress: progress)
            }.value
            return rollbackResult(plan, error: error, cancelled: cancelled, unrecovered: unrecovered)
        }
    }

    func reverse(_ plan: SelectionFolderUndoPlan, progress: @escaping ProgressHandler) async -> FileOperationResult {
        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(for: [plan.parentURL, plan.folderURL]
                + plan.entries.flatMap { [$0.originalSource.item.url, $0.folderURL] })
        } catch { return reverseFailure(plan, error: error) }
        defer { leases.forEach { $0.finish() } }

        do { try await preflightReverse(plan) }
        catch { return reverseFailure(plan, error: error) }

        var moved: [SelectionFolderUndoEntry] = []
        do {
            for entry in plan.entries.reversed() {
                try Task.checkCancellation()
                try await fileSystem.moveExclusively(
                    entry.folderURL,
                    identifiedBy: entry.folderIdentity,
                    to: entry.originalSource.item.url,
                    destinationParentIdentifiedBy: plan.parentIdentity
                )
                moved.append(entry)
                await progress(.init(
                    phase: .movingItems,
                    completedCount: moved.count,
                    totalCount: plan.entries.count,
                    currentName: entry.originalSource.item.name
                ))
            }
            try await fileSystem.removeEmptyDirectory(plan.folderURL, identifiedBy: plan.folderIdentity)
            return FileOperationResult(outcomes: plan.entries.map {
                .succeeded(source: $0.folderURL, destination: $0.originalSource.item.url)
            })
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let fileSystem = self.fileSystem
            let unrecovered = await Task.detached {
                await Self.rollbackReverse(moved, plan: plan, fileSystem: fileSystem, progress: progress)
            }.value
            if !unrecovered.isEmpty {
                return FileOperationResult(outcomes: plan.entries.map { entry in
                    unrecovered.contains(entry.originalSource.item.url)
                        ? .recoveryNeeded(source: entry.originalSource.item.url)
                        : .failed(source: entry.originalSource.item.url, message: safeMessage(error))
                })
            }
            if cancelled {
                return FileOperationResult(outcomes: plan.entries.map {
                    .cancelled(source: $0.originalSource.item.url)
                })
            }
            return reverseFailure(plan, error: error)
        }
    }

    private func preflightForward(_ plan: SelectionFolderPlan) async throws {
        guard try await fileSystem.identity(of: plan.parentURL) == plan.parentIdentity else {
            throw SelectionFolderTransactionFailure.parentChanged
        }
        guard await !fileSystem.exists(plan.folderURL) else {
            throw SelectionFolderTransactionFailure.destinationOccupied(plan.folderName)
        }
        for source in plan.sources {
            guard try await fileSystem.identity(of: source.item.url) == source.identity else {
                throw SelectionFolderTransactionFailure.sourceChanged(source.item.name)
            }
        }
    }

    private func preflightReverse(_ plan: SelectionFolderUndoPlan) async throws {
        guard plan.entries.count >= 2,
              try await fileSystem.identity(of: plan.parentURL) == plan.parentIdentity,
              try await fileSystem.identity(of: plan.folderURL) == plan.folderIdentity,
              plan.folderURL.deletingLastPathComponent().standardizedFileURL
                == plan.parentURL.standardizedFileURL,
              Set(plan.entries.map(\.folderURL.lastPathComponent)).count == plan.entries.count,
              plan.entries.allSatisfy({
                  let basename = $0.originalSource.item.url.lastPathComponent
                  return $0.folderURL.deletingLastPathComponent().standardizedFileURL
                    == plan.folderURL.standardizedFileURL
                    && $0.originalSource.item.url.deletingLastPathComponent().standardizedFileURL
                    == plan.parentURL.standardizedFileURL
                    && $0.folderURL.lastPathComponent == basename
                    && $0.originalSource.item.name == basename
                    && $0.folderIdentity == $0.originalSource.identity
                    && (try? FilenameValidator.validate(basename)) != nil
              })
        else { throw SelectionFolderTransactionFailure.undoPreflightFailed }
        let names = try await fileSystem.names(in: plan.folderURL)
        guard names == Set(plan.entries.map { $0.folderURL.lastPathComponent }) else {
            throw SelectionFolderTransactionFailure.undoPreflightFailed
        }
        for entry in plan.entries {
            guard await !fileSystem.exists(entry.originalSource.item.url),
                  try await fileSystem.identity(of: entry.folderURL) == entry.folderIdentity,
                  try await fileSystem.fingerprint(of: entry.folderURL) == entry.fingerprint
            else { throw SelectionFolderTransactionFailure.undoPreflightFailed }
        }
    }

    private nonisolated static func rollbackForward(
        _ entries: [MovedEntry], plan: SelectionFolderPlan, folderIdentity: FileIdentity,
        fileSystem: any FileSystemAccess,
        progress: @escaping ProgressHandler
    ) async -> Set<URL> {
        var unrecovered: Set<URL> = []
        var restored = 0
        for entry in entries.reversed() {
            do {
                guard await !fileSystem.exists(entry.source.item.url) else { throw SelectionFolderTransactionFailure.destinationOccupied(entry.source.item.url.lastPathComponent) }
                guard try await fileSystem.identity(of: entry.folderURL) == entry.identity,
                      try await fileSystem.fingerprint(of: entry.folderURL) == entry.fingerprint
                else { throw SelectionFolderTransactionFailure.sourceChanged(entry.source.item.url.lastPathComponent) }
                try await fileSystem.moveExclusively(entry.folderURL, identifiedBy: entry.identity,
                    to: entry.source.item.url, destinationParentIdentifiedBy: plan.parentIdentity)
                restored += 1
                await progress(.init(phase: .rollingBack, completedCount: restored,
                    totalCount: entries.count, currentName: entry.source.item.url.lastPathComponent))
            } catch { unrecovered.insert(entry.source.item.url) }
        }
        if unrecovered.isEmpty {
            do {
                try await fileSystem.removeEmptyDirectory(plan.folderURL, identifiedBy: folderIdentity)
            } catch {
                return Set(plan.sources.map(\.item.url))
            }
        }
        return unrecovered
    }

    private nonisolated static func rollbackReverse(
        _ entries: [SelectionFolderUndoEntry], plan: SelectionFolderUndoPlan,
        fileSystem: any FileSystemAccess,
        progress: @escaping ProgressHandler
    ) async -> Set<URL> {
        var unrecovered: Set<URL> = []
        var restored = 0
        for entry in entries.reversed() {
            do {
                guard await !fileSystem.exists(entry.folderURL) else { throw SelectionFolderTransactionFailure.destinationOccupied(entry.originalSource.item.name) }
                guard try await fileSystem.identity(of: entry.originalSource.item.url)
                    == entry.folderIdentity,
                      try await fileSystem.fingerprint(of: entry.originalSource.item.url)
                    .matchesAfterRelocation(entry.fingerprint)
                else { throw SelectionFolderTransactionFailure.sourceChanged(entry.originalSource.item.name) }
                try await fileSystem.moveExclusively(entry.originalSource.item.url,
                    identifiedBy: entry.folderIdentity, to: entry.folderURL,
                    destinationParentIdentifiedBy: plan.folderIdentity)
                restored += 1
                await progress(.init(phase: .rollingBack, completedCount: restored,
                    totalCount: entries.count, currentName: entry.originalSource.item.name))
            } catch { unrecovered.insert(entry.originalSource.item.url) }
        }
        return unrecovered
    }

    private func failure(_ plan: SelectionFolderPlan, error: any Error) -> FileOperationResult {
        FileOperationResult(outcomes: plan.sources.map { .failed(source: $0.item.url, message: safeMessage(error)) })
    }

    private func cancelledResult(_ plan: SelectionFolderPlan) -> FileOperationResult {
        FileOperationResult(outcomes: plan.sources.map { .cancelled(source: $0.item.url) })
    }

    private func rollbackResult(_ plan: SelectionFolderPlan, error: any Error, cancelled: Bool,
        unrecovered: Set<URL>) -> FileOperationResult {
        FileOperationResult(outcomes: plan.sources.map { source in
            if unrecovered.contains(source.item.url) { return .recoveryNeeded(source: source.item.url) }
            return cancelled ? .cancelled(source: source.item.url)
                : .failed(source: source.item.url, message: safeMessage(error))
        })
    }

    private func reverseFailure(_ plan: SelectionFolderUndoPlan, error: any Error) -> FileOperationResult {
        FileOperationResult(outcomes: plan.entries.map {
            .failed(source: $0.originalSource.item.url, message: safeMessage(error))
        })
    }

    private func safeMessage(_ error: any Error) -> String {
        (error as? SelectionFolderTransactionFailure)?.localizedDescription
            ?? "The selected items could not be enclosed safely."
    }
}
