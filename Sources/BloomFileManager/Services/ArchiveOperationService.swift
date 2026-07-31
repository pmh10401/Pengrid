import Foundation

typealias ArchiveProgressHandler =
    @Sendable (ArchiveOperationProgress) async -> Void

protocol ArchiveOperating: Sendable {
    func perform(
        _ requests: [ArchiveRequest],
        progress: ArchiveProgressHandler
    ) async -> FileOperationResult
}

actor ArchiveOperationService: ArchiveOperating {
    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let commandRunner: any ArchiveCommandRunning

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        commandRunner: any ArchiveCommandRunning = LiveArchiveCommandRunner()
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.commandRunner = commandRunner
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: ArchiveProgressHandler = { _ in }
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
                    for: request.verifiedSources + [request.finalDestination]
                )
                defer { accessLeases.forEach { $0.finish() } }

                try validate(request)
                await progress(ArchiveOperationProgress(
                    kind: request.kind,
                    currentDisplayName: request.finalDestination.lastPathComponent
                ))
                try await perform(request)
                outcomes.append(.succeeded(
                    source: source,
                    destination: request.finalDestination
                ))
            } catch {
                let cancellation = Self.cancellationState(for: error)
                if cancellation.wasCancelled {
                    if cancellation.cleanupFailed {
                        outcomes.append(.failed(
                            source: source,
                            message: error.localizedDescription
                        ))
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
                outcomes.append(.failed(
                    source: source,
                    message: error.localizedDescription
                ))
            }
        }

        return FileOperationResult(outcomes: outcomes)
    }

    private func perform(_ request: ArchiveRequest) async throws {
        let reservation = try await fileSystem.reserveStagingDirectory(
            beside: request.finalDestination
        )
        var primaryError: (any Error)?

        do {
            try Task.checkCancellation()
            try await commandRunner.run(
                kind: request.kind,
                sources: request.verifiedSources,
                destination: reservation.item
            )
            try Task.checkCancellation()
            guard await fileSystem.exists(reservation.item) else {
                throw ArchiveServiceError.missingStagedOutput
            }
            try await fileSystem.moveExclusively(
                reservation.item,
                to: request.finalDestination
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
        var payloadCleanupError: (any Error)?
        do {
            try await fileSystem.removeStagedPayload(reservation)
        } catch {
            payloadCleanupError = error
        }

        do {
            try await fileSystem.removeStagingDirectory(reservation)
        } catch {
            if let payloadCleanupError {
                return ArchiveCleanupFailure(
                    payload: payloadCleanupError,
                    stagingDirectory: error
                )
            }
            return error
        }
        return payloadCleanupError
    }

    private func validate(_ request: ArchiveRequest) throws {
        guard !request.verifiedSources.isEmpty else {
            throw ArchiveOperationError.invalidRequest
        }
        if request.kind == .extract, request.verifiedSources.count != 1 {
            throw ArchiveOperationError.invalidRequest
        }
    }

    private func representativeSource(for request: ArchiveRequest) -> URL {
        request.verifiedSources.first ?? request.finalDestination
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
        return (wasCancelled, operationFailure?.cleanup != nil)
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

private struct ArchiveCleanupFailure: LocalizedError {
    let payload: any Error
    let stagingDirectory: any Error

    var errorDescription: String? {
        "\(payload.localizedDescription); staging directory: "
            + stagingDirectory.localizedDescription
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
