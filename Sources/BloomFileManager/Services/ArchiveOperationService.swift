import Foundation

typealias ArchiveProgressHandler =
    @Sendable (ArchiveOperationProgress) async -> Void

protocol ArchiveOperating: Sendable {
    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult
}

actor ArchiveOperationService: ArchiveOperating {
    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let commandRunner: any ArchiveCommandRunning

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        commandRunner: (any ArchiveCommandRunning)? = nil
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.commandRunner = commandRunner ?? LiveArchiveCommandRunner(fileSystem: fileSystem)
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler = { _ in }
    ) async -> FileOperationResult {
        var outcomes: [FileOperationItemOutcome] = []

        for (index, request) in requests.enumerated() {
            if Task.isCancelled {
                outcomes.append(contentsOf: cancelledOutcomes(for: requests[index...]))
                break
            }

            let source = representativeSource(for: request)
            do {
                let accessLeases = try accessCoordinator.acquireAccess(
                    for: request.verifiedSources.map(\.url) + [request.finalDestination]
                )
                defer { accessLeases.forEach { $0.finish() } }

                try validate(request)
                try await perform(request, progress: progress)
                outcomes.append(.succeeded(
                    source: source,
                    destination: request.finalDestination
                ))
            } catch {
                let cancellation = Self.cancellationState(for: error)
                if cancellation.wasCancelled {
                    if cancellation.cleanupFailed {
                        outcomes.append(.recoveryNeeded(source: source))
                        outcomes.append(contentsOf: cancelledOutcomes(
                            for: requests[(index + 1)...]
                        ))
                    } else {
                        outcomes.append(contentsOf: cancelledOutcomes(
                            for: requests[index...]
                        ))
                    }
                    break
                }
                if Self.requiresRecovery(error) {
                    outcomes.append(.recoveryNeeded(source: source))
                } else {
                    outcomes.append(.failed(
                        source: source,
                        message: error.localizedDescription
                    ))
                }
            }
        }

        return FileOperationResult(outcomes: outcomes)
    }

    private func perform(
        _ request: ArchiveRequest,
        progress: @escaping ArchiveProgressHandler
    ) async throws {
        try await requireDestinationParentIdentity(request)
        let reservation = try await fileSystem.reserveStagingDirectory(
            beside: request.finalDestination,
            parentIdentifiedBy: request.destinationParentIdentity
        )
        var primaryError: (any Error)?

        do {
            try Task.checkCancellation()
            try await requireDestinationParentIdentity(request)
            let stagedIdentity = try await commandRunner.run(
                kind: request.kind,
                format: request.format,
                sources: request.verifiedSources,
                destination: reservation.item
            ) { phase in
                await progress(ArchiveOperationProgress(
                    kind: request.kind,
                    currentDisplayName: request.progressDisplayName,
                    format: request.format,
                    phase: phase
                ))
            }
            try Task.checkCancellation()
            try await requireDestinationParentIdentity(request)
            guard await fileSystem.exists(reservation.item) else {
                throw ArchiveServiceError.missingStagedOutput
            }
            guard try await fileSystem.identity(of: reservation.item) == stagedIdentity else {
                throw ArchiveOperationError.recoveryRequired
            }
            try Task.checkCancellation()
            await progress(ArchiveOperationProgress(
                kind: request.kind,
                currentDisplayName: request.progressDisplayName,
                format: request.format,
                phase: .publishing
            ))
            try await fileSystem.moveExclusively(
                reservation.item,
                identifiedBy: stagedIdentity,
                to: request.finalDestination,
                destinationParentIdentifiedBy: request.destinationParentIdentity
            )
        } catch {
            primaryError = error
        }

        let cleanupError = await cleanup(reservation)
        if let primaryError {
            throw ArchiveOperationFailure(
                primary: primaryError,
                cleanup: cleanupError
            )
        }
        if let cleanupError {
            throw ArchiveOperationFailure(
                primary: ArchiveServiceError.cleanupFailed,
                cleanup: cleanupError
            )
        }
    }

    private func cleanup(_ reservation: StagingReservation) async -> (any Error)? {
        do {
            try await fileSystem.removeStagingDirectory(reservation)
            return nil
        } catch {
            return error
        }
    }

    private func validate(_ request: ArchiveRequest) throws {
        guard !request.verifiedSources.isEmpty else {
            throw ArchiveOperationError.invalidRequest
        }
        if request.kind == .extract, request.verifiedSources.count != 1 {
            throw ArchiveOperationError.invalidRequest
        }
    }

    private func requireDestinationParentIdentity(
        _ request: ArchiveRequest
    ) async throws {
        let parent = request.finalDestination.deletingLastPathComponent()
        guard try await fileSystem.identity(of: parent) == request.destinationParentIdentity else {
            throw FileSystemAccessError.identityMismatch(parent)
        }
    }

    private func representativeSource(for request: ArchiveRequest) -> URL {
        request.verifiedSources.first?.url ?? request.finalDestination
    }

    private func cancelledOutcomes(
        for requests: ArraySlice<ArchiveRequest>
    ) -> [FileOperationItemOutcome] {
        requests.map { .cancelled(source: representativeSource(for: $0)) }
    }

    private static func cancellationState(
        for error: any Error
    ) -> (wasCancelled: Bool, cleanupFailed: Bool) {
        let operationFailure = error as? ArchiveOperationFailure
        let primary = operationFailure?.primary ?? error
        let wasCancelled = primary is CancellationError
            || (primary as? ArchiveOperationError) == .cancelled
            || Task.isCancelled
        let cleanupFailed = operationFailure?.cleanup != nil
            || (primary as? ArchiveOperationError) == .recoveryRequired
        return (wasCancelled, cleanupFailed)
    }

    private static func requiresRecovery(_ error: any Error) -> Bool {
        if (error as? ArchiveOperationError) == .recoveryRequired { return true }
        guard let failure = error as? ArchiveOperationFailure else { return false }
        return failure.cleanup != nil
            || (failure.primary as? ArchiveOperationError) == .recoveryRequired
    }
}

private struct ArchiveOperationFailure: LocalizedError {
    let primary: any Error
    let cleanup: (any Error)?

    var errorDescription: String? {
        guard let cleanup else {
            return primary.localizedDescription
        }
        return "\(primary.localizedDescription) (cleanup failed: \(cleanup.localizedDescription))"
    }
}

private enum ArchiveServiceError: LocalizedError {
    case missingStagedOutput
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .missingStagedOutput:
            "The archive command did not produce an output."
        case .cleanupFailed:
            "The archive output was published, but staging cleanup failed."
        }
    }
}
