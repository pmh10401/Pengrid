import Darwin
import Foundation

enum ArchiveOperationRoute: Sendable, Equatable {
    case ordinary
    case protected
    case unsupported
}

typealias RoutingArchiveOperationRoute = ArchiveOperationRoute
typealias ProtectedZIPRoute = ArchiveOperationRoute

protocol ProtectedZIPOperating: Sendable {
    func classify(_ request: ArchiveRequest) async -> ArchiveOperationRoute
    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult
}

/// Performs the in-process path for password-protected ZIP jobs. The service
/// owns no password state: every prompt produces one ephemeral secret which is
/// invalidated by the engine (and defensively by this service) before the next
/// attempt.
actor ProtectedZIPOperationService: ProtectedZIPOperating, ArchiveOperating {
    typealias Route = ArchiveOperationRoute

    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let sourcePreparer: any ArchiveSourcePreparing
    private let passwordProvider: any ArchivePasswordProviding
    private let engine: any ProtectedZIPEngine
    private let logger: any ProtectedZIPLogging

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        sourcePreparer: (any ArchiveSourcePreparing)? = nil,
        passwordProvider: any ArchivePasswordProviding,
        engine: any ProtectedZIPEngine = LiveProtectedZIPEngine(),
        logger: any ProtectedZIPLogging = LiveProtectedZIPLogger()
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.sourcePreparer = sourcePreparer
            ?? LiveArchiveSourcePreparationService(fileSystem: fileSystem)
        self.passwordProvider = passwordProvider
        self.engine = engine
        self.logger = logger
    }

    init(
        fileSystem: any FileSystemAccess,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        sourcePreparer: (any ArchiveSourcePreparing)? = nil,
        passwordProvider: any ArchivePasswordProviding,
        protectedEngine: any ProtectedZIPEngine,
        protectedLogger: any ProtectedZIPLogging
    ) {
        self.init(
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator,
            sourcePreparer: sourcePreparer,
            passwordProvider: passwordProvider,
            engine: protectedEngine,
            logger: protectedLogger
        )
    }

    func classify(_ request: ArchiveRequest) async -> ArchiveOperationRoute {
        guard request.kind == .extract, request.format == .zip else {
            return request.protection == .aes256 ? .unsupported : .ordinary
        }
        guard request.verifiedSources.count == 1,
              let source = request.verifiedSources.first else {
            return .unsupported
        }

        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(for: [source.url])
        } catch {
            return .unsupported
        }
        defer { leases.forEach { $0.finish() } }

        do {
            // Keep both the scoped-access lease and descriptor owner alive for
            // the complete open → fingerprint → inspect → recheck sequence.
            let opened = try await fileSystem.openItem(
                source.url,
                kind: .regularFile,
                identifiedBy: source.identity
            )
            defer { opened.close() }
            let before = try await fileSystem.fingerprint(of: source.url)
            let inspection = try await engine.inspect(archive: opened)
            guard try await fileSystem.identity(of: source.url) == source.identity,
                  try await fileSystem.fingerprint(of: source.url) == before else {
                return .unsupported
            }
            guard inspection.hasEncryptedEntries else {
                return .ordinary
            }
            guard !inspection.hasUnsupportedEncryption,
                  !inspection.hasUnsupportedCompression else {
                return .unsupported
            }
            return .protected
        } catch {
            // Classification is deliberately advisory and fail-closed. The
            // router turns this into one safe failure instead of exposing an
            // engine or native error string.
            return .unsupported
        }
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler = { _ in }
    ) async -> FileOperationResult {
        var result = FileOperationResult(outcomes: [])
        for (index, request) in requests.enumerated() {
            if Task.isCancelled {
                let remaining = requests[index...].map {
                    FileOperationItemOutcome.cancelled(source: representativeSource(for: $0))
                }
                result = result.merging(FileOperationResult(outcomes: remaining))
                break
            }

            let startedAt = Date()
            let requestResult: FileOperationResult
            do {
                let leases = try accessCoordinator.acquireAccess(
                    for: request.verifiedSources.map(\.url) + [request.finalDestination]
                )
                defer { leases.forEach { $0.finish() } }
                requestResult = try await performOne(request, progress: progress)
            } catch {
                let source = representativeSource(for: request)
                let publishedOutput = publishedOutput(from: error)
                if requiresRecovery(error) {
                    requestResult = FileOperationResult(outcomes: [
                        .recoveryNeeded(source: source)
                    ], undoDestinationIdentities: publishedOutput.map {
                        [request.finalDestination: $0.identity]
                    } ?? [:], undoDestinationFingerprints: publishedOutput?.fingerprint.map {
                        [request.finalDestination: $0]
                    } ?? [:])
                } else if isCancellation(error) {
                    requestResult = FileOperationResult(outcomes: [
                        .cancelled(source: source)
                    ])
                } else {
                    requestResult = FileOperationResult(outcomes: [
                        .failed(source: source, message: safeMessage(for: error))
                    ])
                }
            }
            result = result.merging(requestResult)
            await logger.record(ProtectedZIPDiagnosticEvent(
                category: request.kind == .compress ? .compression : .extraction,
                archiveBasename: request.kind == .extract
                    ? request.verifiedSources.first?.url.lastPathComponent
                        ?? request.finalDestination.lastPathComponent
                    : request.finalDestination.lastPathComponent,
                duration: Date().timeIntervalSince(startedAt),
                succeededCount: requestResult.outcomes.count(where: Self.isSuccess),
                failedCount: requestResult.outcomes.count(where: Self.isFailure),
                skippedCount: requestResult.outcomes.count(where: Self.isSkipped),
                cancelledCount: requestResult.outcomes.count(where: Self.isCancelled)
            ))
            if requestResult.outcomes.contains(where: Self.isCancelled) {
                let remaining = requests.dropFirst(index + 1).map {
                    FileOperationItemOutcome.cancelled(source: representativeSource(for: $0))
                }
                result = result.merging(FileOperationResult(outcomes: remaining))
                break
            }
        }
        return result
    }

    private func performOne(
        _ request: ArchiveRequest,
        progress: @escaping ArchiveProgressHandler
    ) async throws -> FileOperationResult {
        guard request.format == .zip,
              request.verifiedSources.count == 1 || request.kind == .compress else {
            throw ProtectedZIPError.unsupportedCompression
        }
        if request.kind == .compress {
            guard request.protection == .aes256 else {
                throw ProtectedZIPError.unsupportedEncryption
            }
            return try await performCompression(request, progress: progress)
        }
        return try await performExtraction(request, progress: progress)
    }

    private func performCompression(
        _ request: ArchiveRequest,
        progress: @escaping ArchiveProgressHandler
    ) async throws -> FileOperationResult {
        guard !request.verifiedSources.isEmpty else {
            throw ArchiveOperationError.invalidRequest
        }
        let prepared = try await sourcePreparer.prepare(
            request.verifiedSources,
            beside: request.finalDestination,
            parentIdentity: request.destinationParentIdentity,
            progress: { phase in
                await progress(ArchiveOperationProgress(
                    kind: .compress,
                    currentDisplayName: request.progressDisplayName,
                    format: .zip,
                    phase: phase
                ))
            }
        )
        var preparedCleaned = false
        var preparedCleanupAttempted = false

        do {
            try await requireDestinationParentIdentity(request)
            await progress(ArchiveOperationProgress(
                kind: .compress,
                currentDisplayName: request.progressDisplayName,
                format: .zip,
                phase: .waitingForPassword
            ))
            let passwordRequest = ArchivePasswordRequest(
                id: UUID(),
                purpose: .createAES256,
                archiveBasename: request.finalDestination.lastPathComponent,
                previousAttemptFailed: false
            )
            let secret = try await passwordProvider.requestPassword(for: passwordRequest)
            defer { secret.invalidate() }

            let reservation = try await fileSystem.reserveStagingDirectory(
                beside: request.finalDestination,
                parentIdentifiedBy: request.destinationParentIdentity
            )
            var outputIdentity: FileIdentity?
            var publishedOutput: ProtectedZIPPublishedOutput?
            do {
                let output = try await fileSystem.createEmptyItemAndCaptureIdentity(
                    reservation.item,
                    kind: .regularFile,
                    parentIdentifiedBy: reservation.directoryIdentity
                )
                outputIdentity = output.identity
                try await withClosedDescriptor(output) {
                    let sourceRoot = try await fileSystem.openItem(
                        prepared.root,
                        kind: .directory,
                        identifiedBy: prepared.reservation.directoryIdentity
                    )
                    defer { sourceRoot.close() }
                    try await engine.createAES256(
                        sourceRoot: sourceRoot,
                        destination: output,
                        password: secret,
                        progress: { update in
                            await progress(ArchiveOperationProgress(
                                kind: .compress,
                                currentDisplayName: request.progressDisplayName,
                                format: .zip,
                                phase: .processingBytes(
                                    completedByteCount: update.completedByteCount,
                                    totalByteCount: update.totalByteCount
                                )
                            ))
                        }
                    )
                    guard try await fileSystem.identity(of: reservation.item) == output.identity else {
                        throw ProtectedZIPError.identityChanged
                    }
                    _ = try await fileSystem.fingerprint(of: reservation.item)
                }
                try await requireDestinationParentIdentity(request)
                await progress(ArchiveOperationProgress(
                    kind: .compress,
                    currentDisplayName: request.progressDisplayName,
                    format: .zip,
                    phase: .publishing
                ))
                try await fileSystem.moveExclusively(
                    reservation.item,
                    identifiedBy: outputIdentity!,
                    to: request.finalDestination,
                    destinationParentIdentifiedBy: request.destinationParentIdentity
                )
                publishedOutput = try await capturePublishedOutput(
                    at: request.finalDestination,
                    identity: outputIdentity!
                )
                try await cleanupPublishedReservation(
                    reservation,
                    itemIdentity: outputIdentity!,
                    publishedOutput: publishedOutput!
                )
                preparedCleanupAttempted = true
                try await cleanupPreparedSourcesAfterPublication(
                    prepared,
                    publishedOutput: publishedOutput!
                )
                preparedCleaned = true
                return result(for: publishedOutput!, request: request)
            } catch {
                if let publishedOutput {
                    if let failure = error as? ProtectedZIPFailure,
                       failure.publishedOutput != nil {
                        throw failure
                    }
                    throw ProtectedZIPFailure(
                        primary: error,
                        cleanup: nil,
                        publishedOutput: publishedOutput
                    )
                }
                let cleanupError = await cleanupOutputReservation(
                    reservation,
                    itemIdentity: outputIdentity
                )
                if cleanupError != nil {
                    throw ProtectedZIPFailure(
                        primary: error,
                        cleanup: cleanupError,
                        publishedOutput: nil
                    )
                }
                throw error
            }
        } catch {
            let primaryError = error
            if !preparedCleaned && !preparedCleanupAttempted {
                do {
                    try await sourcePreparer.cleanup(prepared)
                    preparedCleaned = true
                } catch {
                    let cleanupError = error
                    throw ProtectedZIPFailure(
                        primary: primaryError,
                        cleanup: cleanupError,
                        publishedOutput: publishedOutput(from: primaryError)
                    )
                }
            }
            throw primaryError
        }
    }

    private func performExtraction(
        _ request: ArchiveRequest,
        progress: @escaping ArchiveProgressHandler
    ) async throws -> FileOperationResult {
        guard let source = request.verifiedSources.first else {
            throw ArchiveOperationError.invalidRequest
        }
        try await requireDestinationParentIdentity(request)
        let inputReservation = try await fileSystem.reserveStagingDirectory(
            beside: request.finalDestination,
            parentIdentifiedBy: request.destinationParentIdentity
        )
        var inputIdentity: FileIdentity?
        var inputCleanupAttempted = false
        do {
            let before = try await fileSystem.fingerprint(of: source.url)
            let copied = try await fileSystem.copyAndCaptureIdentity(
                source.url,
                identifiedBy: source.identity,
                to: inputReservation.item
            )
            inputIdentity = copied
            guard try await fileSystem.identity(of: source.url) == source.identity,
                  try await fileSystem.fingerprint(of: source.url) == before else {
                throw ProtectedZIPError.identityChanged
            }

            // Reopen the private staged copy and inspect that descriptor
            // before preflight or any password request. Classification (when
            // invoked by the router) inspected the original source; this is a
            // distinct staged reinspection with a defer installed before the
            // engine can throw.
            let openedArchive = try await fileSystem.openItem(
                inputReservation.item,
                kind: .regularFile,
                identifiedBy: copied
            )
            defer { openedArchive.close() }
            let inspection = try await engine.inspect(archive: openedArchive)
            guard inspection.hasEncryptedEntries,
                  !inspection.hasUnsupportedEncryption,
                  !inspection.hasUnsupportedCompression else {
                throw ProtectedZIPError.unsupportedEncryption
            }
            let limits = try await extractionLimits(
                inspection: inspection,
                destination: request.finalDestination
            )
            let preflight = try await preflight(
                archive: openedArchive,
                limits: limits,
                destination: request.finalDestination,
                destinationParentIdentity: request.destinationParentIdentity
            )
            guard preflight.totalUncompressedByteCount <= limits.maximumOutputByteCount else {
                throw ProtectedZIPError.insufficientCapacity
            }

            var previousAttemptFailed = false
            while true {
                try Task.checkCancellation()
                await progress(ArchiveOperationProgress(
                    kind: .extract,
                    currentDisplayName: request.progressDisplayName,
                    format: .zip,
                    phase: .waitingForPassword
                ))
                let passwordRequest = ArchivePasswordRequest(
                    id: UUID(),
                    purpose: .extract,
                    archiveBasename: source.url.lastPathComponent,
                    previousAttemptFailed: previousAttemptFailed
                )
                let secret = try await passwordProvider.requestPassword(for: passwordRequest)
                defer { secret.invalidate() }
                do {
                    let publishedOutput = try await extractionAttempt(
                        request: request,
                        archive: openedArchive,
                        password: secret,
                        limits: limits,
                        progress: progress
                    )
                    do {
                        inputCleanupAttempted = true
                        try await cleanupInputReservationOrThrow(
                            inputReservation,
                            itemIdentity: inputIdentity,
                            publishedOutput: publishedOutput
                        )
                    } catch {
                        if let failure = error as? ProtectedZIPFailure,
                           failure.publishedOutput != nil {
                            throw failure
                        }
                        throw ProtectedZIPFailure(
                            primary: error,
                            cleanup: nil,
                            publishedOutput: publishedOutput
                        )
                    }
                    return result(for: publishedOutput, request: request)
                } catch let error as ProtectedZIPError
                    where error == .incorrectPasswordOrDamagedData {
                    previousAttemptFailed = true
                    continue
                }
            }
        } catch {
            if inputCleanupAttempted {
                throw error
            }
            let cleanupError = await cleanupInputReservation(
                inputReservation,
                itemIdentity: inputIdentity
            )
            if cleanupError != nil {
                throw ProtectedZIPFailure(
                    primary: error,
                    cleanup: cleanupError,
                    publishedOutput: publishedOutput(from: error)
                )
            }
            throw error
        }
    }

    private func extractionAttempt(
        request: ArchiveRequest,
        archive: OpenedFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping ArchiveProgressHandler
    ) async throws -> ProtectedZIPPublishedOutput {
        let reservation = try await fileSystem.reserveStagingDirectory(
            beside: request.finalDestination,
            parentIdentifiedBy: request.destinationParentIdentity
        )
        var outputIdentity: FileIdentity?
        var publishedOutput: ProtectedZIPPublishedOutput?
        do {
            let output = try await fileSystem.createEmptyItemAndCaptureIdentity(
                reservation.item,
                kind: .directory,
                parentIdentifiedBy: reservation.directoryIdentity
            )
            outputIdentity = output.identity
            try await withClosedDescriptor(output) {
                try await engine.extract(
                    archive: archive,
                    destinationRoot: output,
                    password: password,
                    limits: limits,
                    progress: { update in
                        await progress(ArchiveOperationProgress(
                            kind: .extract,
                            currentDisplayName: request.progressDisplayName,
                            format: .zip,
                            phase: .processingBytes(
                                completedByteCount: update.completedByteCount,
                                totalByteCount: update.totalByteCount
                            )
                        ))
                    }
                )
            }
            guard try await fileSystem.identity(of: reservation.item) == output.identity else {
                throw ProtectedZIPError.identityChanged
            }
            try await requireDestinationParentIdentity(request)
            await progress(ArchiveOperationProgress(
                kind: .extract,
                currentDisplayName: request.progressDisplayName,
                format: .zip,
                phase: .publishing
            ))
            try await fileSystem.moveExclusively(
                reservation.item,
                identifiedBy: output.identity,
                to: request.finalDestination,
                destinationParentIdentifiedBy: request.destinationParentIdentity
            )
            publishedOutput = try await capturePublishedOutput(
                at: request.finalDestination,
                identity: output.identity
            )
            try await cleanupPublishedReservation(
                reservation,
                itemIdentity: output.identity,
                publishedOutput: publishedOutput!
            )
            return publishedOutput!
        } catch {
            if let publishedOutput {
                if let failure = error as? ProtectedZIPFailure,
                   failure.publishedOutput != nil {
                    throw failure
                }
                throw ProtectedZIPFailure(
                    primary: error,
                    cleanup: nil,
                    publishedOutput: publishedOutput
                )
            }
            let cleanupError = await cleanupOutputReservation(
                reservation,
                itemIdentity: outputIdentity
            )
            if cleanupError != nil {
                throw ProtectedZIPFailure(
                    primary: error,
                    cleanup: cleanupError,
                    publishedOutput: nil
                )
            }
            throw error
        }
    }

    private func preflight(
        archive: OpenedFileSystemItem,
        limits: ProtectedZIPLimits,
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> ProtectedZIPInspection {
        let probe = try await fileSystem.reserveStagingDirectory(
            beside: destination,
            parentIdentifiedBy: destinationParentIdentity
        )
        var probeIdentity: FileIdentity?
        do {
            let openedProbe = try await fileSystem.createEmptyItemAndCaptureIdentity(
                probe.item,
                kind: .directory,
                parentIdentifiedBy: probe.directoryIdentity
            )
            probeIdentity = openedProbe.identity
            let result = try await withClosedDescriptor(openedProbe) {
                try await engine.preflight(
                    archive: archive,
                    destinationProbeRoot: openedProbe,
                    limits: limits
                )
            }
            guard await cleanupOutputReservation(probe, itemIdentity: probeIdentity) == nil else {
                throw ProtectedZIPError.recoveryRequired
            }
            return result
        } catch {
            let cleanupError = await cleanupOutputReservation(probe, itemIdentity: probeIdentity)
            if cleanupError != nil {
                throw ProtectedZIPFailure(
                    primary: error,
                    cleanup: cleanupError,
                    publishedOutput: nil
                )
            }
            throw error
        }
    }

    private func cleanupPublishedReservation(
        _ reservation: StagingReservation,
        itemIdentity: FileIdentity?,
        publishedOutput: ProtectedZIPPublishedOutput
    ) async throws {
        do {
            try await cleanupInputReservationOrThrow(
                reservation,
                itemIdentity: itemIdentity,
                publishedOutput: publishedOutput
            )
        } catch {
            if let failure = error as? ProtectedZIPFailure,
               failure.publishedOutput != nil {
                throw failure
            }
            throw ProtectedZIPFailure(
                primary: error,
                cleanup: nil,
                publishedOutput: publishedOutput
            )
        }
    }

    private func cleanupPreparedSourcesAfterPublication(
        _ prepared: PreparedArchiveSources,
        publishedOutput: ProtectedZIPPublishedOutput
    ) async throws {
        do {
            try await sourcePreparer.cleanup(prepared)
        } catch let firstError {
            do {
                try await sourcePreparer.cleanup(prepared)
            } catch let retryError {
                throw ProtectedZIPFailure(
                    primary: firstError,
                    cleanup: retryError,
                    publishedOutput: publishedOutput
                )
            }
        }
    }

    private func cleanupInputReservationOrThrow(
        _ reservation: StagingReservation,
        itemIdentity: FileIdentity?,
        publishedOutput: ProtectedZIPPublishedOutput
    ) async throws {
        do {
            try await requireCleanup(
                reservation,
                itemIdentity: itemIdentity
            )
        } catch let firstError {
            do {
                try await requireCleanup(
                    reservation,
                    itemIdentity: itemIdentity
                )
            } catch let retryError {
                throw ProtectedZIPFailure(
                    primary: firstError,
                    cleanup: retryError,
                    publishedOutput: publishedOutput
                )
            }
        }
    }

    private func requireCleanup(
        _ reservation: StagingReservation,
        itemIdentity: FileIdentity?
    ) async throws {
        if let cleanupError = await cleanupInputReservation(
            reservation,
            itemIdentity: itemIdentity
        ) {
            throw cleanupError
        }
    }

    private func capturePublishedOutput(
        at destination: URL,
        identity: FileIdentity
    ) async throws -> ProtectedZIPPublishedOutput {
        guard try await fileSystem.identity(of: destination) == identity else {
            throw ProtectedZIPError.identityChanged
        }
        return ProtectedZIPPublishedOutput(
            destination: destination,
            identity: identity,
            fingerprint: try? await fileSystem.fingerprint(of: destination)
        )
    }

    private func result(
        for publishedOutput: ProtectedZIPPublishedOutput,
        request: ArchiveRequest
    ) -> FileOperationResult {
        FileOperationResult(
            outcomes: [.succeeded(
                source: representativeSource(for: request),
                destination: request.finalDestination
            )],
            undoDestinationIdentities: [
                publishedOutput.destination: publishedOutput.identity
            ],
            undoDestinationFingerprints: publishedOutput.fingerprint.map {
                [publishedOutput.destination: $0]
            } ?? [:]
        )
    }

    private func extractionLimits(
        inspection: ProtectedZIPInspection,
        destination: URL
    ) async throws -> ProtectedZIPLimits {
        guard let available = try await fileSystem.availableCapacity(
            at: destination.deletingLastPathComponent()
        ), available >= 0 else {
            throw ProtectedZIPError.insufficientCapacity
        }
        let percentageReserve = available / 10
        let reserve = max(ProtectedZIPLimits.minimumCapacityReserve, percentageReserve)
        guard available > reserve else {
            throw ProtectedZIPError.insufficientCapacity
        }
        let budget = available - reserve
        guard inspection.totalUncompressedByteCount <= budget else {
            throw ProtectedZIPError.insufficientCapacity
        }
        return ProtectedZIPLimits(
            maximumOutputByteCount: budget,
            capacityReserveByteCount: reserve
        )
    }

    private func cleanupInputReservation(
        _ reservation: StagingReservation,
        itemIdentity: FileIdentity?
    ) async -> (any Error)? {
        var firstError: (any Error)?
        if let itemIdentity {
            do {
                if await fileSystem.exists(reservation.item) {
                    try await fileSystem.remove(reservation.item, identifiedBy: itemIdentity)
                }
            } catch {
                firstError = error
            }
        }
        do {
            try await fileSystem.removeStagingDirectory(reservation)
        } catch {
            firstError = firstError ?? error
        }
        return firstError
    }

    private func cleanupOutputReservation(
        _ reservation: StagingReservation,
        itemIdentity: FileIdentity?
    ) async -> (any Error)? {
        await cleanupInputReservation(reservation, itemIdentity: itemIdentity)
    }

    private func withClosedDescriptor<T>(
        _ item: OpenedEmptyFileSystemItem,
        operation: () async throws -> T
    ) async rethrows -> T {
        defer { Darwin.close(item.descriptor) }
        return try await operation()
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

    private static func isSuccess(_ outcome: FileOperationItemOutcome) -> Bool {
        if case .succeeded = outcome { return true }
        return false
    }

    private static func isFailure(_ outcome: FileOperationItemOutcome) -> Bool {
        switch outcome {
        case .failed, .recoveryNeeded: return true
        default: return false
        }
    }

    private static func isSkipped(_ outcome: FileOperationItemOutcome) -> Bool {
        if case .skipped = outcome { return true }
        return false
    }

    private static func isCancelled(_ outcome: FileOperationItemOutcome) -> Bool {
        if case .cancelled = outcome { return true }
        return false
    }
}

private struct ProtectedZIPPublishedOutput: Sendable {
    let destination: URL
    let identity: FileIdentity
    let fingerprint: SourceFingerprint?
}

private struct ProtectedZIPFailure: LocalizedError, Sendable {
    let primary: any Error
    let cleanup: (any Error)?
    let publishedOutput: ProtectedZIPPublishedOutput?

    var errorDescription: String? {
        cleanup == nil ? primary.localizedDescription : ProtectedZIPError.recoveryRequired.errorDescription
    }
}

private func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError || Task.isCancelled { return true }
    if let protected = error as? ProtectedZIPError, protected == .cancelled { return true }
    if let failure = error as? ProtectedZIPFailure { return isCancellation(failure.primary) }
    return false
}

private func publishedOutput(
    from error: any Error
) -> ProtectedZIPPublishedOutput? {
    if let failure = error as? ProtectedZIPFailure {
        return failure.publishedOutput ?? publishedOutput(from: failure.primary)
    }
    return nil
}

private func requiresRecovery(_ error: any Error) -> Bool {
    if let protected = error as? ProtectedZIPError, protected == .recoveryRequired {
        return true
    }
    if let operation = error as? ArchiveOperationError, operation == .recoveryRequired {
        return true
    }
    if let failure = error as? ProtectedZIPFailure {
        return failure.cleanup != nil || failure.publishedOutput != nil
    }
    return false
}

private func safeMessage(for error: any Error) -> String {
    if let error = error as? ProtectedZIPError {
        return error.errorDescription ?? ProtectedZIPError.engineSetupFailed.errorDescription!
    }
    if let error = error as? ArchiveOperationError {
        switch error {
        case .recoveryRequired: return ProtectedZIPError.recoveryRequired.errorDescription!
        case .cancelled: return ProtectedZIPError.cancelled.errorDescription!
        default: return ProtectedZIPError.engineSetupFailed.errorDescription!
        }
    }
    if error is ProtectedZIPFailure {
        return ProtectedZIPError.recoveryRequired.errorDescription!
    }
    return ProtectedZIPError.engineSetupFailed.errorDescription!
}
