import Foundation

struct StorageCleanupMutationGroup: Sendable {
    let keep: StorageEntry
    let trash: [StorageEntry]
}

actor FileOperationService {
    private let fileSystem: any FileSystemAccess
    private let logger: any OperationLogging
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let storageFingerprints: any StorageEntryFingerprintReading

    init(
        fileSystem: any FileSystemAccess,
        logger: any OperationLogging = LiveOperationLogger(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        storageFingerprints: any StorageEntryFingerprintReading =
            LiveStorageEntryFingerprintReader()
    ) {
        self.fileSystem = fileSystem
        self.logger = logger
        self.accessCoordinator = accessCoordinator
        self.storageFingerprints = storageFingerprints
    }

    nonisolated func makeArchiveOperationService(
        commandRunner: any ArchiveCommandRunning = LiveArchiveCommandRunner()
    ) -> ArchiveOperationService {
        ArchiveOperationService(
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator,
            commandRunner: commandRunner
        )
    }

    nonisolated func makeUndoService() -> FileOperationUndoService {
        FileOperationUndoService(
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator
        )
    }

    func trashStorageCleanup(
        _ groups: [StorageCleanupMutationGroup],
        progress: OperationProgressHandler = { _ in }
    ) async -> FileOperationResult {
        let reviewed = groups.flatMap(\.trash)
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(
                for: groups.flatMap { [$0.keep.url] + $0.trash.map(\.url) }
            )
        } catch {
            return FileOperationResult(outcomes: reviewed.map {
                .failed(source: $0.url, message: "cleanup-access-unavailable")
            })
        }
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        var outcomes: [FileOperationItemOutcome] = []

        groupLoop: for group in groups {
            for (index, entry) in group.trash.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard try await exactStorageMatch(group.keep) else {
                        outcomes.append(contentsOf: group.trash[index...].map {
                            .skipped(source: $0.url)
                        })
                        continue groupLoop
                    }
                    guard try await exactStorageMatch(entry) else {
                        outcomes.append(.skipped(source: entry.url))
                        continue
                    }

                    let quarantine = try await fileSystem.quarantineForTrash(
                        entry.url,
                        identifiedBy: entry.fingerprint.identity
                    )
                    do {
                        _ = try await fileSystem.moveTrashQuarantineAtomically(
                            quarantine
                        )
                        outcomes.append(.succeeded(
                            source: entry.url,
                            destination: nil
                        ))
                    } catch let error as StorageTrashAccessError {
                        outcomes.append(Self.storageTrashOutcome(
                            for: error,
                            source: entry.url
                        ))
                    } catch {
                        outcomes.append(.failed(
                            source: entry.url,
                            message: "cleanup-trash-failed"
                        ))
                    }
                } catch is CancellationError {
                    let completed = Set(outcomes.map(Self.sourceURL))
                    outcomes.append(contentsOf: reviewed.filter {
                        !completed.contains($0.url)
                    }.map { .cancelled(source: $0.url) })
                    break groupLoop
                } catch let error as StorageTrashAccessError {
                    outcomes.append(Self.storageTrashOutcome(
                        for: error,
                        source: entry.url
                    ))
                } catch {
                    outcomes.append(.failed(
                        source: entry.url,
                        message: "cleanup-trash-failed"
                    ))
                }
                await reportProgress(
                    completedCount: outcomes.count,
                    totalCount: reviewed.count,
                    source: entry.url,
                    handler: progress
                )
            }
        }
        let succeeded = outcomes.count {
            if case .succeeded = $0 { true } else { false }
        }
        let failed = outcomes.count {
            switch $0 {
            case .recoveryNeeded, .failed: true
            default: false
            }
        }
        let skipped = outcomes.count {
            if case .skipped = $0 { true } else { false }
        }
        await logger.record(
            kind: .trash,
            duration: Date().timeIntervalSince(startedAt),
            succeeded: succeeded,
            failed: failed,
            skipped: skipped
        )
        return FileOperationResult(outcomes: outcomes)
    }

    private func exactStorageMatch(_ entry: StorageEntry) async throws -> Bool {
        let current = try await storageFingerprints.fingerprint(of: entry.url)
        return current.identity == entry.fingerprint.identity
            && current.byteSize == entry.fingerprint.byteSize
            && current.rawModifiedAt == entry.fingerprint.rawModifiedAt
    }

    private static func storageTrashOutcome(
        for error: StorageTrashAccessError,
        source: URL
    ) -> FileOperationItemOutcome {
        switch error {
        case .failedButRestored:
            .failed(source: source, message: "cleanup-trash-failed")
        case .recoveryRequired:
            .recoveryNeeded(source: source)
        }
    }

    private static func sourceURL(_ outcome: FileOperationItemOutcome) -> URL {
        switch outcome {
        case let .succeeded(source, _),
             let .recoveryNeeded(source),
             let .skipped(source),
             let .cancelled(source),
             let .failed(source, _):
            source
        }
    }

    func createFolder(in directory: URL, named name: String) async throws -> URL {
        let accessLeases = try accessCoordinator.acquireAccess(for: [directory])
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        do {
            try FilenameValidator.validate(name)
            let destination = directory.appending(path: name, directoryHint: .isDirectory)
            guard await !fileSystem.exists(destination) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try await fileSystem.createDirectory(destination)
            await logger.record(
                kind: .createFolder,
                duration: Date().timeIntervalSince(startedAt),
                succeeded: 1,
                failed: 0,
                skipped: 0
            )
            return destination
        } catch {
            await logger.record(
                kind: .createFolder,
                duration: Date().timeIntervalSince(startedAt),
                succeeded: 0,
                failed: 1,
                skipped: 0
            )
            throw error
        }
    }

    func createFolder(
        in directory: URL,
        identifiedBy directoryIdentity: FileIdentity,
        named name: String
    ) async throws -> URL {
        let accessLeases = try accessCoordinator.acquireAccess(for: [directory])
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        let destination = directory.appending(path: name, directoryHint: .isDirectory)
        do {
            try Task.checkCancellation()
            try FilenameValidator.validate(name)
            guard await !fileSystem.exists(destination) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try Task.checkCancellation()
            let prepared = try await fileSystem.prepareDirectoryHierarchy(
                root: directory,
                identifiedBy: directoryIdentity,
                relativeComponents: [name]
            )
            guard prepared.destinationDirectory.standardizedFileURL == destination.standardizedFileURL,
                  prepared.createdDirectories.count == 1,
                  prepared.createdDirectories[0].relativeComponents == [name]
            else {
                throw CocoaError(.fileWriteFileExists)
            }
            await logger.record(
                kind: .createFolder,
                duration: Date().timeIntervalSince(startedAt),
                succeeded: 1,
                failed: 0,
                skipped: 0
            )
            return destination
        } catch {
            await logger.record(
                kind: .createFolder,
                duration: Date().timeIntervalSince(startedAt),
                succeeded: 0,
                failed: 1,
                skipped: 0
            )
            throw error
        }
    }

    func rename(_ source: URL, to name: String) async throws -> URL {
        let accessLeases = try accessCoordinator.acquireAccess(for: [source])
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        do {
            try FilenameValidator.validate(name)
            let destination = source.deletingLastPathComponent().appending(path: name)
            guard await !fileSystem.exists(destination) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try await fileSystem.move(source, to: destination)
            await logger.record(
                kind: .rename, duration: Date().timeIntervalSince(startedAt),
                succeeded: 1, failed: 0, skipped: 0
            )
            return destination
        } catch {
            await logger.record(
                kind: .rename, duration: Date().timeIntervalSince(startedAt),
                succeeded: 0, failed: 1, skipped: 0
            )
            throw error
        }
    }

    func identity(of source: URL) async throws -> FileIdentity {
        let accessLeases = try accessCoordinator.acquireAccess(for: [source])
        defer { accessLeases.forEach { $0.finish() } }
        guard let identity = try await fileSystem.identity(of: source) else {
            throw FileTransferError.missingIdentity
        }
        return identity
    }

    func rename(_ source: URL, identifiedBy identity: FileIdentity, to name: String) async throws -> URL {
        let accessLeases = try accessCoordinator.acquireAccess(for: [source])
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        do {
            try Task.checkCancellation()
            try FilenameValidator.validate(name)
            let destination = source.deletingLastPathComponent().appending(path: name)
            guard await !fileSystem.exists(destination) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try Task.checkCancellation()
            try await fileSystem.move(source, identifiedBy: identity, to: destination)
            await logger.record(
                kind: .rename,
                duration: Date().timeIntervalSince(startedAt),
                succeeded: 1,
                failed: 0,
                skipped: 0
            )
            return destination
        } catch {
            await logger.record(
                kind: .rename,
                duration: Date().timeIntervalSince(startedAt),
                succeeded: 0,
                failed: 1,
                skipped: 0
            )
            throw error
        }
    }

    func trash(
        _ sources: [URL],
        progress: OperationProgressHandler = { _ in }
    ) async -> FileOperationResult {
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: sources)
        } catch {
            return FileOperationResult(outcomes: sources.map {
                .failed(source: $0, message: error.localizedDescription)
            })
        }
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        var outcomes: [FileOperationItemOutcome] = []
        var succeeded = 0
        var failed = 0
        for (index, source) in sources.enumerated() {
            do {
                try Task.checkCancellation()
                try await fileSystem.trash(source)
                outcomes.append(.succeeded(source: source, destination: nil))
                succeeded += 1
            } catch is CancellationError {
                outcomes.append(contentsOf: sources[index...].map { .cancelled(source: $0) })
                break
            } catch {
                outcomes.append(.failed(source: source, message: error.localizedDescription))
                failed += 1
            }
            await reportProgress(
                completedCount: outcomes.count,
                totalCount: sources.count,
                source: source,
                handler: progress
            )
        }
        await logger.record(
            kind: .trash,
            duration: Date().timeIntervalSince(startedAt),
            succeeded: succeeded,
            failed: failed,
            skipped: 0
        )
        return FileOperationResult(outcomes: outcomes)
    }

    func trash(
        _ requests: [IdentifiedFileRequest],
        progress: OperationProgressHandler = { _ in }
    ) async -> FileOperationResult {
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: requests.map(\.url))
        } catch {
            return FileOperationResult(outcomes: requests.map {
                .failed(source: $0.url, message: error.localizedDescription)
            })
        }
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        var outcomes: [FileOperationItemOutcome] = []
        var succeeded = 0
        var failed = 0

        for (index, request) in requests.enumerated() {
            let source = request.url
            do {
                try Task.checkCancellation()
                let resultingURL = try await fileSystem.trashAndReturnResultingURL(
                    source,
                    identifiedBy: request.identity
                )
                outcomes.append(.succeeded(source: source, destination: resultingURL))
                succeeded += 1
            } catch is CancellationError {
                outcomes.append(contentsOf: requests[index...].map { .cancelled(source: $0.url) })
                break
            } catch {
                outcomes.append(.failed(source: source, message: error.localizedDescription))
                failed += 1
            }

            await reportProgress(
                completedCount: outcomes.count,
                totalCount: requests.count,
                source: source,
                handler: progress
            )
        }

        await logger.record(
            kind: .trash,
            duration: Date().timeIntervalSince(startedAt),
            succeeded: succeeded,
            failed: failed,
            skipped: 0
        )
        return FileOperationResult(outcomes: outcomes)
    }

    func transfer(
        _ sources: [URL],
        to directory: URL,
        mode: TransferMode,
        resolveConflict: ConflictResolver,
        progress: OperationProgressHandler
    ) async -> FileOperationResult {
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: sources + [directory])
        } catch {
            return FileOperationResult(outcomes: sources.map {
                .failed(source: $0, message: error.localizedDescription)
            })
        }
        defer { accessLeases.forEach { $0.finish() } }
        var requests: [IdentifiedTransferRequest] = []
        if let destinationRootIdentity = try? await fileSystem.identity(of: directory) {
            for source in sources {
                guard let sourceIdentity = try? await fileSystem.identity(of: source) else {
                    return await legacyTransfer(
                        sources,
                        to: directory,
                        mode: mode,
                        resolveConflict: resolveConflict,
                        progress: progress
                    )
                }
                requests.append(IdentifiedTransferRequest(
                    source: source,
                    sourceIdentity: sourceIdentity,
                    destinationRoot: directory,
                    destinationRootIdentity: destinationRootIdentity,
                    relativeParentComponents: []
                ))
            }
            return await transfer(
                requests,
                mode: mode,
                resolveConflict: resolveConflict,
                progress: progress
            )
        }
        return await legacyTransfer(
            sources,
            to: directory,
            mode: mode,
            resolveConflict: resolveConflict,
            progress: progress
        )
    }

    private func legacyTransfer(
        _ sources: [URL],
        to directory: URL,
        mode: TransferMode,
        resolveConflict: ConflictResolver,
        progress: OperationProgressHandler
    ) async -> FileOperationResult {
        let startedAt = Date()
        var outcomes: [FileOperationItemOutcome] = []
        var succeeded = 0
        var failed = 0
        var skipped = 0

        for (index, source) in sources.enumerated() {
            if Task.isCancelled {
                outcomes.append(contentsOf: sources[index...].map { .cancelled(source: $0) })
                break
            }

            do {
                guard let outcome = try await transferItem(
                    source,
                    to: directory,
                    mode: mode,
                    resolveConflict: resolveConflict
                ) else {
                    outcomes.append(contentsOf: sources[index...].map { .cancelled(source: $0) })
                    break
                }
                outcomes.append(outcome)
                switch outcome {
                case .succeeded:
                    succeeded += 1
                case .skipped:
                    skipped += 1
                case .cancelled:
                    break
                case .recoveryNeeded, .failed:
                    failed += 1
                }
            } catch is CancellationError {
                outcomes.append(contentsOf: sources[index...].map { .cancelled(source: $0) })
                break
            } catch {
                let cleanupFailed = (error as? TransferFailure)?.cleanup != nil
                if Task.isCancelled && !cleanupFailed {
                    outcomes.append(contentsOf: sources[index...].map { .cancelled(source: $0) })
                    break
                }
                outcomes.append(.failed(source: source, message: error.localizedDescription))
                failed += 1
            }

            await reportProgress(
                completedCount: outcomes.count,
                totalCount: sources.count,
                source: source,
                handler: progress
            )
        }

        await logger.record(
            kind: mode == .copy ? .copy : .move,
            duration: Date().timeIntervalSince(startedAt),
            succeeded: succeeded,
            failed: failed,
            skipped: skipped
        )
        return FileOperationResult(outcomes: outcomes)
    }

    func transfer(
        _ requests: [IdentifiedTransferRequest],
        mode: TransferMode,
        resolveConflict: ConflictResolver,
        progress: OperationProgressHandler
    ) async -> FileOperationResult {
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(
                for: requests.flatMap { [$0.source, $0.destinationRoot] }
            )
        } catch {
            return FileOperationResult(outcomes: requests.map {
                .failed(source: $0.source, message: error.localizedDescription)
            })
        }
        defer { accessLeases.forEach { $0.finish() } }
        let startedAt = Date()
        var outcomes: [FileOperationItemOutcome] = []
        var succeeded = 0
        var failed = 0
        var skipped = 0

        for (index, request) in requests.enumerated() {
            let source = request.source
            if Task.isCancelled {
                outcomes.append(contentsOf: requests[index...].map {
                    .cancelled(source: $0.source)
                })
                break
            }

            var preparedHierarchy: PreparedDirectoryHierarchy?
            do {
                guard try await fileSystem.identity(of: source)?.entryIdentifier
                    == request.sourceIdentity.entryIdentifier
                else {
                    throw FileTransferError.identityChanged
                }
                let prepared = try await fileSystem.prepareDirectoryHierarchy(
                    root: request.destinationRoot,
                    identifiedBy: request.destinationRootIdentity,
                    relativeComponents: request.relativeParentComponents
                )
                preparedHierarchy = prepared
                guard let outcome = try await transferItem(
                    source,
                    identifiedBy: request.sourceIdentity,
                    to: prepared.destinationDirectory,
                    mode: mode,
                    resolveConflict: resolveConflict
                ) else {
                    if let cleanupError = await cleanupOwnedDirectories(
                        prepared.createdDirectories,
                        for: request
                    ) {
                        outcomes.append(.failed(
                            source: source,
                            message: TransferFailure(
                                primary: CancellationError(),
                                cleanup: cleanupError
                            ).localizedDescription
                        ))
                        failed += 1
                        outcomes.append(contentsOf: requests[(index + 1)...].map {
                            .cancelled(source: $0.source)
                        })
                    } else {
                        outcomes.append(contentsOf: requests[index...].map {
                            .cancelled(source: $0.source)
                        })
                    }
                    break
                }
                outcomes.append(outcome)
                switch outcome {
                case .succeeded:
                    succeeded += 1
                case .skipped:
                    skipped += 1
                    if let cleanupError = await cleanupOwnedDirectories(
                        prepared.createdDirectories,
                        for: request
                    ) {
                        outcomes[outcomes.count - 1] = .failed(
                            source: source,
                            message: cleanupError.localizedDescription
                        )
                        skipped -= 1
                        failed += 1
                    }
                case .cancelled:
                    break
                case .recoveryNeeded, .failed:
                    failed += 1
                }
            } catch is CancellationError {
                let cleanupError = await cleanupOwnedDirectories(
                    preparedHierarchy?.createdDirectories ?? [],
                    for: request
                )
                if let cleanupError {
                    outcomes.append(.failed(
                        source: source,
                        message: TransferFailure(
                            primary: CancellationError(),
                            cleanup: cleanupError
                        ).localizedDescription
                    ))
                    failed += 1
                    outcomes.append(contentsOf: requests[(index + 1)...].map {
                        .cancelled(source: $0.source)
                    })
                } else {
                    outcomes.append(contentsOf: requests[index...].map {
                        .cancelled(source: $0.source)
                    })
                }
                break
            } catch {
                let cleanupError = await cleanupOwnedDirectories(
                    preparedHierarchy?.createdDirectories ?? [],
                    for: request
                )
                let transferCleanupFailed = (error as? TransferFailure)?.cleanup != nil
                if Task.isCancelled, !transferCleanupFailed, cleanupError == nil {
                    outcomes.append(contentsOf: requests[index...].map {
                        .cancelled(source: $0.source)
                    })
                    break
                } else {
                    outcomes.append(.failed(
                        source: source,
                        message: TransferFailure(
                            primary: error,
                            cleanup: cleanupError
                        ).localizedDescription
                    ))
                    failed += 1
                }
            }

            await reportProgress(
                completedCount: outcomes.count,
                totalCount: requests.count,
                source: source,
                handler: progress
            )
        }

        await logger.record(
            kind: mode == .copy ? .copy : .move,
            duration: Date().timeIntervalSince(startedAt),
            succeeded: succeeded,
            failed: failed,
            skipped: skipped
        )
        return FileOperationResult(outcomes: outcomes)
    }

    private func transferItem(
        _ source: URL,
        identifiedBy expectedSourceIdentity: FileIdentity? = nil,
        to directory: URL,
        mode: TransferMode,
        resolveConflict: ConflictResolver
    ) async throws -> FileOperationItemOutcome? {
        guard let currentSourceIdentity = try await fileSystem.identity(of: source) else {
            throw FileTransferError.missingIdentity
        }
        if let expectedSourceIdentity,
           currentSourceIdentity.entryIdentifier != expectedSourceIdentity.entryIdentifier {
            throw FileTransferError.identityChanged
        }
        let sourceIdentity = expectedSourceIdentity ?? currentSourceIdentity

        try await validateTransferDestination(directory, sourceIdentity: sourceIdentity)

        var destination = directory.appending(path: source.lastPathComponent)
        var replacedIdentity: FileIdentity?

        if await fileSystem.exists(destination) {
            guard let destinationIdentity = try await fileSystem.identity(of: destination) else {
                throw FileTransferError.missingIdentity
            }
            switch await resolveConflict(
                FileConflict(source: source, proposedDestination: destination)
            ) {
            case .replace:
                guard !sourceIdentity.refersToSameItem(as: destinationIdentity) else {
                    return .skipped(source: source)
                }
                replacedIdentity = destinationIdentity
            case .keepBoth:
                destination = try await availableKeepBothDestination(
                    for: source.lastPathComponent,
                    in: directory
                )
            case .skip:
                return .skipped(source: source)
            case .cancel:
                return nil
            }
        }

        if mode == .move, replacedIdentity == nil {
            let sourceVolume = try await fileSystem.volumeIdentifier(for: source)
            let destinationVolume = try await fileSystem.volumeIdentifier(for: directory)
            if sourceVolume == destinationVolume {
                try Task.checkCancellation()
                try await fileSystem.move(source, identifiedBy: sourceIdentity, to: destination)
                return .succeeded(source: source, destination: destination)
            }
        }

        try await ensureCapacity(for: source, at: directory)
        let sourceFingerprint = mode == .move
            ? try await fileSystem.fingerprint(of: source)
            : nil
        let prepared = try await prepareStagedCopy(
            of: source,
            sourceIdentity: sourceIdentity,
            sourceFingerprint: sourceFingerprint,
            beside: destination
        )
        try await commit(
            prepared,
            to: destination,
            replacing: replacedIdentity
        )

        if mode == .move {
            try Task.checkCancellation()
            if let sourceFingerprint,
               try await fileSystem.fingerprint(of: source) != sourceFingerprint {
                throw FileTransferError.sourceChangedDuringTransfer
            }
            try Task.checkCancellation()
            try await fileSystem.remove(source, identifiedBy: sourceIdentity)
        }
        return .succeeded(source: source, destination: destination)
    }

    private func cleanupOwnedDirectories(
        _ directories: [PreparedDirectoryHierarchy.OwnedDirectory],
        for request: IdentifiedTransferRequest
    ) async -> (any Error)? {
        guard !directories.isEmpty else { return nil }
        do {
            try await fileSystem.removeEmptyOwnedDirectories(
                root: request.destinationRoot,
                identifiedBy: request.destinationRootIdentity,
                directories: directories
            )
            return nil
        } catch {
            return error
        }
    }

    private func validateTransferDestination(
        _ directory: URL,
        sourceIdentity: FileIdentity
    ) async throws {
        let lexicalDirectory = directory.standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        var roots = [lexicalDirectory]
        if resolvedDirectory != lexicalDirectory {
            roots.append(resolvedDirectory)
        }

        for root in roots {
            var ancestor = root
            while true {
                if let identity = try await fileSystem.identity(of: ancestor),
                   sourceIdentity.refersToSameItem(as: identity) {
                    throw FileTransferError.destinationInsideSource
                }
                if ancestor.path == "/" { break }
                let parent = ancestor.deletingLastPathComponent().standardizedFileURL
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
        }
    }

    private func availableKeepBothDestination(
        for originalName: String,
        in directory: URL
    ) async throws -> URL {
        var occupied = try await fileSystem.names(in: directory)
        while true {
            try Task.checkCancellation()
            let name = KeepBothNamer.availableName(for: originalName, existing: occupied)
            let candidate = directory.appending(path: name)
            if await !fileSystem.exists(candidate) {
                return candidate
            }
            occupied.insert(name)
        }
    }

    private func ensureCapacity(for source: URL, at directory: URL) async throws {
        guard let byteSize = try await fileSystem.byteSize(of: source),
              let availableCapacity = try await fileSystem.availableCapacity(at: directory)
        else {
            return
        }
        guard byteSize <= availableCapacity else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private func prepareStagedCopy(
        of source: URL,
        sourceIdentity: FileIdentity,
        sourceFingerprint: SourceFingerprint?,
        beside destination: URL
    ) async throws -> PreparedStagedCopy {
        let reservation = try await fileSystem.reserveStagingDirectory(beside: destination)
        var itemIdentity: FileIdentity?
        do {
            try Task.checkCancellation()
            let copiedItemIdentity = try await fileSystem.copyAndCaptureIdentity(
                source,
                to: reservation.item
            )
            itemIdentity = copiedItemIdentity
            guard try await fileSystem.identity(of: source)?.entryIdentifier
                == sourceIdentity.entryIdentifier
            else {
                throw FileTransferError.identityChanged
            }
            if let sourceFingerprint,
               try await fileSystem.fingerprint(of: source) != sourceFingerprint {
                throw FileTransferError.sourceChangedDuringTransfer
            }
            try Task.checkCancellation()
            return PreparedStagedCopy(
                reservation: reservation,
                itemIdentity: copiedItemIdentity
            )
        } catch {
            let cleanupError = await cleanupStaging(
                reservation,
                itemIdentity: itemIdentity
            )
            throw TransferFailure(primary: error, cleanup: cleanupError)
        }
    }

    private func commit(
        _ prepared: PreparedStagedCopy,
        to destination: URL,
        replacing destinationIdentity: FileIdentity?
    ) async throws {
        do {
            try Task.checkCancellation()
            if let destinationIdentity {
                try await fileSystem.replace(
                    destination,
                    identifiedBy: destinationIdentity,
                    with: prepared.reservation.item,
                    identifiedBy: prepared.itemIdentity
                )
            } else {
                try await fileSystem.move(
                    prepared.reservation.item,
                    identifiedBy: prepared.itemIdentity,
                    to: destination
                )
            }
        } catch let commitError {
            do {
                if try await fileSystem.identity(of: destination)?.entryIdentifier
                    == prepared.itemIdentity.entryIdentifier {
                    let cleanupError = await cleanupStagingDirectory(prepared.reservation)
                    throw TransferFailure(primary: commitError, cleanup: cleanupError)
                }
            } catch let identityError as TransferFailure {
                throw identityError
            } catch let identityLookupError {
                throw TransferFailure(primary: commitError, cleanup: identityLookupError)
            }
            let cleanupError = await cleanupStaging(
                prepared.reservation,
                itemIdentity: prepared.itemIdentity
            )
            throw TransferFailure(primary: commitError, cleanup: cleanupError)
        }

        let verificationError: (any Error)?
        do {
            verificationError = try await fileSystem.identity(of: destination)?.entryIdentifier
                == prepared.itemIdentity.entryIdentifier
                ? nil
                : FileTransferError.destinationVerificationFailed
        } catch {
            verificationError = error
        }
        let cleanupError = await cleanupStagingDirectory(prepared.reservation)
        if let verificationError {
            throw TransferFailure(primary: verificationError, cleanup: cleanupError)
        }
        if let cleanupError {
            throw TransferFailure(primary: FileTransferError.cleanupFailed, cleanup: cleanupError)
        }
    }

    private func cleanupStaging(
        _ reservation: StagingReservation,
        itemIdentity: FileIdentity?
    ) async -> (any Error)? {
        do {
            if let itemIdentity {
                try await fileSystem.remove(reservation.item, identifiedBy: itemIdentity)
            } else if await fileSystem.exists(reservation.item) {
                return FileTransferError.unverifiedStagingPayload
            }
        } catch {
            return error
        }
        return await cleanupStagingDirectory(reservation)
    }

    private func cleanupStagingDirectory(_ reservation: StagingReservation) async -> (any Error)? {
        do {
            try await fileSystem.removeStagingDirectory(reservation)
            return nil
        } catch {
            return error
        }
    }

    private func reportProgress(
        completedCount: Int,
        totalCount: Int,
        source: URL,
        handler: OperationProgressHandler
    ) async {
        await handler(
            FileOperationProgress(
                completedCount: completedCount,
                totalCount: totalCount,
                currentName: source.lastPathComponent
            )
        )
    }
}

private struct PreparedStagedCopy: Sendable {
    let reservation: StagingReservation
    let itemIdentity: FileIdentity
}

private struct TransferFailure: LocalizedError {
    let primary: any Error
    let cleanup: (any Error)?

    var errorDescription: String? {
        guard let cleanup else {
            return primary.localizedDescription
        }
        return "\(primary.localizedDescription) (cleanup failed: \(cleanup.localizedDescription))"
    }
}

private enum FileTransferError: Error {
    case missingIdentity
    case identityChanged
    case sourceChangedDuringTransfer
    case destinationVerificationFailed
    case cleanupFailed
    case unverifiedStagingPayload
    case destinationInsideSource
}
