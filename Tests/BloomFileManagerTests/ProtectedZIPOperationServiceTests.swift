import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite("ProtectedZIPOperationServiceTests")
struct ProtectedZIPOperationServiceTests {
    @Test func descriptorScopeDeclaresItsCrossActorResultSendable() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/BloomFileManager/Services/ProtectedZIPOperationService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("private func withClosedDescriptor<T: Sendable>("))
    }

    @Test @MainActor func preparationCompletesBeforePasswordPrompt() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let passwordProvider = RecordingArchivePasswordProvider(passwords: ["first-passphrase"])
        let engine = RecordingProtectedZIPEngine()
        let preparer = Task8RecordingArchiveSourcePreparer(
            fileSystem: fileSystem,
            root: root.url
        )
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            accessCoordinator: .init(),
            sourcePreparer: preparer,
            passwordProvider: passwordProvider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(await preparer.didFinishPreparation)
        #expect(await passwordProvider.requestCount == 1)
        #expect(await preparer.finishedBeforePrompt)
        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test @MainActor func entryCountOverflowDuringCompressionNeverPublishesOrLeavesStaging() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: Task8RecordingArchiveSourcePreparer(
                fileSystem: fileSystem,
                root: root.url
            ),
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["entry-count-overflow-passphrase"]
            ),
            engine: Task8EntryCountOverflowEngine(),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [
            .failed(
                source: source,
                message: ProtectedZIPError.entryCountOverflow.errorDescription!
            )
        ])
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func preparationEventOrderIsBeforeWaitingPhaseAndProvider() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let events = Task8EventRecorder()
        let provider = Task8RecordingPasswordProvider(
            root: root.url,
            passwords: ["event-order-passphrase"],
            events: events
        )
        let preparer = Task8RecordingArchiveSourcePreparer(
            fileSystem: fileSystem,
            root: root.url,
            events: events
        )
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: preparer,
            passwordProvider: provider,
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { update in
            if update.phase == .waitingForPassword {
                await events.append("waitingForPassword")
            }
        }

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(await events.values == ["prepared", "waitingForPassword", "provider"])
    }

    @Test @MainActor func hostileArchiveFailsBeforePasswordProvider() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Hostile.zip")
        try Data("not-a-zip".utf8).write(to: archive)
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let passwordProvider = RecordingArchivePasswordProvider(passwords: ["unused-passphrase"])
        let engine = RecordingProtectedZIPEngine(
            inspectResult: ProtectedZIPInspection(
                hasEncryptedEntries: true,
                hasUnsupportedEncryption: true
            )
        )
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: passwordProvider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(passwordProvider.requestCount == 0)
        #expect(result.outcomes.count == 1)
        #expect(result.hasFailures)
    }

    @Test @MainActor func unsafePreflightClosesAndRemovesProbeBeforeFailure() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Unsafe.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = Task8InstrumentedFileSystem(inner: LiveFileSystemAccess())
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let provider = Task8RecordingPasswordProvider(
            root: root.url,
            passwords: ["must-not-be-requested"]
        )
        let engine = Task8PreflightFailureEngine()
        let phases = Task8EventRecorder()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { update in
            if update.phase == .waitingForPassword {
                await phases.append("waitingForPassword")
            }
        }

        #expect(result.outcomes == [.failed(source: archive, message: ProtectedZIPError.unsafeEntry.errorDescription!)])
        #expect(await provider.requestCount == 0)
        #expect(await engine.events == ["inspect", "preflight"])
        #expect(await phases.values.isEmpty)
        #expect(await fileSystem.removeStagingDirectoryCalls == 2)
        #expect(await fileSystem.createdEmptyDescriptorCount >= 1)
        #expect(await fileSystem.liveDescriptorsAreClosed)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test func loggerProjectionContainsOnlyPublicFields() async {
        let logger = RecordingProtectedZIPLogger()
        let event = ProtectedZIPDiagnosticEvent(
            category: .extraction,
            archiveBasename: "/private/secret/archive.zip\ninternal-entry.txt",
            duration: 1.25,
            succeededCount: 1,
            failedCount: 2,
            skippedCount: 3,
            cancelledCount: 4
        )
        await logger.record(event)
        let recorded = await logger.events
        #expect(recorded == [event])
        #expect(recorded.first?.archiveBasename == "archive.zip")
        #expect(String(reflecting: recorded).contains("internal-entry") == false)
    }

    @Test @MainActor func operationLoggerRecordsOnlySanitizedSourceAndStableCounts() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Archive.zip\ninternal-entry.txt")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let logger = RecordingProtectedZIPLogger()
        let provider = Task8RecordingPasswordProvider(
            root: root.url,
            passwords: ["secret-sentinel-passphrase"]
        )
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: Task8RawErrorEngine(),
            logger: logger
        )

        let result = await service.perform([request]) { _ in }
        let recorded = await logger.events
        let reflected = String(reflecting: recorded)

        #expect(result.hasFailures)
        #expect(await provider.requestCount == 1)
        #expect(recorded.count == 1)
        #expect(recorded.first?.archiveBasename == "Archive.zip")
        #expect(recorded.first?.category == .extraction)
        #expect(reflected.contains("secret-sentinel-passphrase") == false)
        #expect(reflected.contains("raw-error-sentinel") == false)
        #expect(reflected.contains("internal-entry") == false)
    }

    @Test @MainActor func wrongPasswordDestroysAttemptBeforeFreshPrompt() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let events = Task8EventRecorder()
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            cleanupEvents: events
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let provider = Task8RecordingPasswordProvider(
            root: root.url,
            passwords: ["first-passphrase", "second-passphrase"],
            events: events,
            labelProviderRequests: true
        )
        let engine = Task8RetryEngine()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes.count == 1)
        #expect(result.hasFailures == false)
        #expect(await engine.passwordIdentities.count == 2)
        #expect(await engine.passwordIdentities[0] != engine.passwordIdentities[1])
        #expect(await provider.previousPromptStagingCounts == [1, 1])
        #expect(await provider.previousAttemptFlags == [false, true])
        #expect(await provider.previousSecretsUnavailable == [false, true])
        #expect(provider.requestIDs.count == 2)
        #expect(provider.requestIDs[0] != provider.requestIDs[1])
        let reservations = await fileSystem.stagingReservations
        #expect(reservations.count == 4)
        #expect(reservations[2].item != reservations[3].item)
        #expect(reservations[2].directoryIdentity != reservations[3].directoryIdentity)
        #expect(await events.values == [
            "remove-staging-1-succeeded",
            "provider-1",
            "remove-staging-2-succeeded",
            "provider-2",
            "remove-staging-3-succeeded",
            "remove-staging-4-succeeded"
        ])
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func nonPasswordEngineErrorDoesNotRetry() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let provider = Task8RecordingPasswordProvider(
            root: root.url,
            passwords: ["one-passphrase", "must-not-be-used"]
        )
        let engine = Task8NonPasswordFailureEngine()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.hasFailures)
        #expect(await provider.requestCount == 1)
        #expect(await engine.extractCount == 1)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func cancellationCleansInputStagingWithoutPromptOutput() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let provider = Task8CancellingPasswordProvider()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.cancelled(source: archive)])
        #expect(await provider.requestCount == 1)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func cancellingActivePasswordCoordinatorClearsItsPendingPrompt() async throws {
        let coordinator = ArchivePasswordPromptCoordinator()
        let request = ArchivePasswordRequest(
            id: UUID(),
            purpose: .extract,
            archiveBasename: "Archive.zip",
            previousAttemptFailed: false
        )
        let task = Task { try await coordinator.requestPassword(for: request) }
        await Task.yield()
        #expect(coordinator.pendingRequest == request)
        coordinator.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(coordinator.pendingRequest == nil)
    }

    @Test @MainActor func promptCancellationCleanupFailureTakesRecoveryPrecedence() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            failRemoveStagingCalls: [2]
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let provider = Task8CancellingPasswordProvider()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.recoveryNeeded(source: archive)])
        #expect(await provider.requestCount == 1)
        #expect(await fileSystem.removeStagingDirectoryCalls == 2)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test @MainActor func engineCancellationOutputCleanupFailureTakesRecoveryPrecedence() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            failRemoveStagingCalls: [2]
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["cancel-engine-passphrase"]
            ),
            engine: Task8CancellationEngine(),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.recoveryNeeded(source: source)])
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(await fileSystem.removeStagingDirectoryCalls >= 2)
    }

    @Test @MainActor func cancellingDuringEngineProgressCleansInputAndOutputStaging() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = Task8InstrumentedFileSystem(inner: LiveFileSystemAccess())
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let engine = Task8ProgressCancellationEngine()
        let passwordProvider = Task8RecordingPasswordProvider(
            root: root.url,
            passwords: ["progress-cancel-passphrase"]
        )
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: passwordProvider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )
        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.cancelled(source: archive)])
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func existingDestinationIsNeverReplaced() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        try Data("replacement sentinel".utf8).write(to: destination)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["creation-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.hasFailures)
        #expect(try Data(contentsOf: destination) == Data("replacement sentinel".utf8))
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func destinationCreatedAtPublicationBoundaryIsNeverReplaced() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            beforeExclusiveMove: { _, destination in
                try Data("boundary sentinel".utf8).write(to: destination)
            }
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["boundary-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.hasFailures)
        #expect(try Data(contentsOf: destination) == Data("boundary sentinel".utf8))
    }

    @Test @MainActor func checkedCapacityBudgetRejectsBeforePrompt() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Huge.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let provider = Task8RecordingPasswordProvider(root: root.url, passwords: ["unused"])
        let engine = Task8RetryEngine(inspectTotal: Int64.max)
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.hasFailures)
        #expect(await provider.requestCount == 0)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func capacityMathUsesExactReserveAndBudgetForPreflightAndExtract() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Sized.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let available: Int64 = 6 * 1_024 * 1_024 * 1_024
        let total = available - available / 10 - 1
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            availableCapacity: available
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let provider = Task8RecordingPasswordProvider(
            root: root.url,
            passwords: ["capacity-passphrase"]
        )
        let engine = Task8LimitRecordingEngine(total: total)
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: provider,
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        let expected = ProtectedZIPLimits(
            maximumOutputByteCount: available - available / 10,
            capacityReserveByteCount: available / 10
        )
        #expect(result.outcomes == [.succeeded(source: archive, destination: destination)])
        #expect(await engine.preflightLimits == [expected])
        #expect(await engine.extractLimits == [expected])
    }

    @Test @MainActor func minimumCapacityReserveRejectsEqualAndAllowsJustAbove() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Minimum.zip")
        try Data("encrypted fixture".utf8).write(to: archive)
        let parentIdentity = try #require(await LiveFileSystemAccess().identity(of: root.url))

        for (available, expectedSuccess) in [
            (ProtectedZIPLimits.minimumCapacityReserve, false),
            (ProtectedZIPLimits.minimumCapacityReserve + 1, true)
        ] {
            let destination = root.url.appending(
                path: expectedSuccess ? "JustAbove" : "EqualReserve",
                directoryHint: .isDirectory
            )
            let fileSystem = Task8InstrumentedFileSystem(
                inner: LiveFileSystemAccess(),
                availableCapacity: available
            )
            let provider = Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["minimum-passphrase"]
            )
            let engine = Task8LimitRecordingEngine(total: 0)
            let request = ArchiveRequest(
                kind: .extract,
                verifiedSources: identifiedArchiveTestSources([archive]),
                finalDestination: destination,
                destinationParentIdentity: parentIdentity,
                format: .zip
            )
            let service = ProtectedZIPOperationService(
                fileSystem: fileSystem,
                passwordProvider: provider,
                engine: engine,
                logger: RecordingProtectedZIPLogger()
            )

            let result = await service.perform([request]) { _ in }

            #expect(result.hasFailures == !expectedSuccess)
            #expect(await provider.requestCount == (expectedSuccess ? 1 : 0))
            if expectedSuccess {
                #expect(await engine.preflightLimits == [ProtectedZIPLimits(
                    maximumOutputByteCount: 1,
                    capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
                )])
            }
        }
    }

    @Test @MainActor func declaredTotalAtAndOverBudgetUsesExactPreflightLimit() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Budget.zip")
        try Data("encrypted fixture".utf8).write(to: archive)
        let available: Int64 = 2 * 1_024 * 1_024 * 1_024
        let reserve = ProtectedZIPLimits.minimumCapacityReserve
        let budget = available - reserve
        let parentIdentity = try #require(await LiveFileSystemAccess().identity(of: root.url))

        for (offset, expectedSuccess) in [(Int64(0), true), (Int64(1), false)] {
            let destination = root.url.appending(
                path: expectedSuccess ? "EqualBudget" : "OverBudget",
                directoryHint: .isDirectory
            )
            let fileSystem = Task8InstrumentedFileSystem(
                inner: LiveFileSystemAccess(),
                availableCapacity: available
            )
            let provider = Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["budget-passphrase"]
            )
            let engine = Task8LimitRecordingEngine(total: budget + offset)
            let request = ArchiveRequest(
                kind: .extract,
                verifiedSources: identifiedArchiveTestSources([archive]),
                finalDestination: destination,
                destinationParentIdentity: parentIdentity,
                format: .zip
            )
            let service = ProtectedZIPOperationService(
                fileSystem: fileSystem,
                passwordProvider: provider,
                engine: engine,
                logger: RecordingProtectedZIPLogger()
            )

            let result = await service.perform([request]) { _ in }

            #expect(result.hasFailures == !expectedSuccess)
            #expect(await provider.requestCount == (expectedSuccess ? 1 : 0))
            if expectedSuccess {
                #expect(await engine.preflightLimits == [ProtectedZIPLimits(
                    maximumOutputByteCount: budget,
                    capacityReserveByteCount: reserve
                )])
                #expect(await engine.extractLimits == [ProtectedZIPLimits(
                    maximumOutputByteCount: budget,
                    capacityReserveByteCount: reserve
                )])
            } else {
                #expect(await engine.preflightLimits.isEmpty)
                #expect(await engine.extractLimits.isEmpty)
            }
        }
    }

    @Test @MainActor func cleanupFailureReturnsRecoveryNeeded() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let logger = RecordingProtectedZIPLogger()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: Task8FailingSourcePreparer(fileSystem: fileSystem),
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["creation-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: logger
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.recoveryNeeded(source: source)])
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(result.undoDestinationIdentity(for: destination) != nil)
        #expect(result.undoDestinationFingerprint(for: destination) != nil)
        #expect(await logger.events.last?.category == .compression)
    }

    @Test @MainActor func postPublicationCompressionCleanupRetryReturnsSuccessWithUndoMetadata() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let preparer = Task8FlakySourcePreparer(fileSystem: fileSystem, failures: 1)
        let logger = RecordingProtectedZIPLogger()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: preparer,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["retry-cleanup-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: logger
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(result.undoDestinationIdentity(for: destination) != nil)
        #expect(result.undoDestinationFingerprint(for: destination) != nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(await preparer.cleanupCallCount == 2)
        #expect(await logger.events.last?.category == .compression)
    }

    @Test @MainActor func combinedCompressionCleanupFailuresPreservePublishedRecoveryMetadata() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let cleanupEvents = Task8EventRecorder()
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            failRemoveStagingCalls: [1, 2],
            cleanupEvents: cleanupEvents
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let preparer = Task8FlakySourcePreparer(
            fileSystem: fileSystem,
            failures: 1,
            cleanupEvents: cleanupEvents
        )
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: preparer,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["combined-cleanup-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.recoveryNeeded(source: source)])
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(result.undoDestinationIdentity(for: destination) != nil)
        #expect(result.undoDestinationFingerprint(for: destination) != nil)
        #expect(await fileSystem.removeStagingDirectoryCalls == 2)
        #expect(await preparer.cleanupCallCount == 1)
        #expect(await cleanupEvents.values == [
            "remove-staging-1-failed",
            "remove-staging-2-failed",
            "prepared-cleanup-1-failed"
        ])
    }

    @Test @MainActor func postPublicationExtractionCleanupRetryReturnsSuccessWithUndoMetadata() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            failPostPublicationCleanupAttempts: 1
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let logger = RecordingProtectedZIPLogger()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["extract-retry-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: logger
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.succeeded(source: archive, destination: destination)])
        #expect(result.undoDestinationIdentity(for: destination) != nil)
        #expect(result.undoDestinationFingerprint(for: destination) != nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(await logger.events.last?.category == .extraction)
    }

    @Test @MainActor func postPublicationExtractionCleanupFailurePreservesRecoveryMetadata() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let cleanupEvents = Task8EventRecorder()
        let fileSystem = Task8InstrumentedFileSystem(
            inner: LiveFileSystemAccess(),
            failPostPublicationCleanupAttempts: .max,
            cleanupEvents: cleanupEvents
        )
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let logger = RecordingProtectedZIPLogger()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["extract-persistent-cleanup-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: logger
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.recoveryNeeded(source: archive)])
        #expect(result.undoDestinationIdentity(for: destination) != nil)
        #expect(result.undoDestinationFingerprint(for: destination) != nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(await logger.events.last?.category == .extraction)
        #expect(await cleanupEvents.values == [
            "remove-staging-1-succeeded",
            "remove-staging-2-failed",
            "remove-staging-3-failed",
            "remove-staging-4-failed"
        ])
    }

    @Test @MainActor func injectedPasswordCoordinatorCancellationCleansServiceStaging() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = Task8InstrumentedFileSystem(inner: LiveFileSystemAccess())
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let coordinator = ArchivePasswordPromptCoordinator()
        let operation = Task {
            await ProtectedZIPOperationService(
                fileSystem: fileSystem,
                passwordProvider: coordinator,
                engine: Task8RetryEngine(alwaysSucceeds: true),
                logger: RecordingProtectedZIPLogger()
            ).perform([request]) { _ in }
        }

        for _ in 0..<100 where coordinator.pendingRequest == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(coordinator.pendingRequest != nil)
        operation.cancel()
        let result = await operation.value

        #expect(result.outcomes == [.cancelled(source: archive)])
        #expect(coordinator.pendingRequest == nil)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func progressCallbackCancellationIsObservedByEngineAndDoesNotPublish() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = Task8InstrumentedFileSystem(inner: LiveFileSystemAccess())
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let engine = Task8TaskCancellationBoundaryEngine()
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["callback-cancel-passphrase"]
            ),
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )
        let cancellationHandle = Task8OperationCancellationHandle()
        let operation = Task {
            await service.perform([request]) { update in
                if case .processingBytes = update.phase {
                    cancellationHandle.cancel()
                }
            }
        }
        cancellationHandle.install(operation)

        let result = await operation.value

        #expect(result.outcomes == [.cancelled(source: source)])
        #expect(await engine.observedCancellation)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        try task8ExpectNoStagingDirectories(in: root.url)
    }

    @Test func descriptorOwnerClosesExactlyOnce() throws {
        let readDescriptor = Darwin.open("/dev/null", O_RDONLY)
        #expect(readDescriptor >= 0)
        let closeCount = Task8LockedCounter()
        let owner = OpenedFileSystemItem(
            identity: FileIdentity(entryIdentifier: "fd", resolvedIdentifier: "fd"),
            descriptor: readDescriptor,
            url: URL(filePath: "/dev/null"),
            closeDescriptor: { descriptor in
                closeCount.increment()
                Darwin.close(descriptor)
            }
        )
        owner.close()
        owner.close()
        #expect(closeCount.value == 1)
    }

    @Test @MainActor func classifyAndPerformCloseDescriptorsAndScopedLeasesExactlyOnce() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = Task8InstrumentedFileSystem(inner: LiveFileSystemAccess())
        let driver = Task8RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([root.url])
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            accessCoordinator: coordinator,
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["descriptor-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        #expect(await service.classify(request) == .protected)
        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.succeeded(source: archive, destination: destination)])
        #expect(await fileSystem.openedItemCount >= 2)
        #expect(await fileSystem.liveDescriptorsAreClosed)
        #expect(driver.startCount == driver.stopCount)
        #expect(driver.startCount == 2)
        #expect(driver.activeCount == 0)
    }
}

@MainActor
final class RecordingArchivePasswordProvider: ArchivePasswordProviding {
    private(set) var requestCount = 0
    private var passwords: [String]

    init(passwords: [String]) {
        self.passwords = passwords
    }

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        requestCount += 1
        let password = passwords.isEmpty ? "fallback-passphrase" : passwords.removeFirst()
        return try ArchiveSecret.extraction(password: password)
    }
}

actor RecordingProtectedZIPLogger: ProtectedZIPLogging {
    private(set) var events: [ProtectedZIPDiagnosticEvent] = []

    func record(_ event: ProtectedZIPDiagnosticEvent) async {
        events.append(event)
    }
}

actor RecordingProtectedZIPEngine: ProtectedZIPEngine {
    private let inspectResult: ProtectedZIPInspection

    init(inspectResult: ProtectedZIPInspection = ProtectedZIPInspection()) {
        self.inspectResult = inspectResult
    }

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        inspectResult
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        inspectResult
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        await progress(ProtectedZIPProgress(completedByteCount: 0, totalByteCount: 0))
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        await progress(ProtectedZIPProgress(completedByteCount: 0, totalByteCount: 0))
    }
}

private actor Task8EntryCountOverflowEngine: ProtectedZIPEngine {
    private var remainingFailures = 1

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection()
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection()
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        guard remainingFailures > 0 else {
            await progress(ProtectedZIPProgress(completedByteCount: 0, totalByteCount: 0))
            return
        }
        remainingFailures -= 1
        throw ProtectedZIPError.entryCountOverflow
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        throw ProtectedZIPError.entryCountOverflow
    }
}

actor Task8RecordingArchiveSourcePreparer: ArchiveSourcePreparing {
    private let fileSystem: any FileSystemAccess
    private let root: URL
    private let events: Task8EventRecorder?
    private(set) var didFinishPreparation = false
    private(set) var finishedBeforePrompt = false

    fileprivate init(
        fileSystem: any FileSystemAccess,
        root: URL,
        events: Task8EventRecorder? = nil
    ) {
        self.fileSystem = fileSystem
        self.root = root
        self.events = events
    }

    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources {
        didFinishPreparation = true
        await events?.append("prepared")
        let reservation = try await fileSystem.reserveStagingDirectory(
            beside: destination,
            parentIdentifiedBy: parentIdentity
        )
        return PreparedArchiveSources(root: reservation.directory, reservation: reservation, copiedEntries: [])
    }

    func cleanup(_ prepared: PreparedArchiveSources) async throws {
        finishedBeforePrompt = didFinishPreparation
        try await fileSystem.removeStagingDirectory(prepared.reservation)
    }
}

@MainActor
private final class Task8RecordingPasswordProvider: ArchivePasswordProviding {
    private let root: URL
    private let events: Task8EventRecorder?
    private var passwords: [String]
    private var retainedSecrets: [ArchiveSecret] = []
    private(set) var requestCount = 0
    private(set) var previousPromptStagingCounts: [Int] = []
    private(set) var previousAttemptFlags: [Bool] = []
    private(set) var previousSecretsUnavailable: [Bool] = []
    private(set) var requestIDs: [UUID] = []
    private let labelProviderRequests: Bool

    init(
        root: URL,
        passwords: [String],
        events: Task8EventRecorder? = nil,
        labelProviderRequests: Bool = false
    ) {
        self.root = root
        self.passwords = passwords
        self.events = events
        self.labelProviderRequests = labelProviderRequests
    }

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        requestCount += 1
        requestIDs.append(request.id)
        await events?.append(labelProviderRequests ? "provider-\(requestCount)" : "provider")
        previousAttemptFlags.append(request.previousAttemptFailed)
        if let previous = retainedSecrets.last {
            previousSecretsUnavailable.append((try? previous.withUnsafeBytes { _ in }) == nil)
        } else {
            previousSecretsUnavailable.append(false)
        }
        let stagingCount = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".bloom-staging-") }.count) ?? -1
        previousPromptStagingCounts.append(stagingCount)
        let password = passwords.isEmpty ? "fallback-passphrase" : passwords.removeFirst()
        let secret = try ArchiveSecret.extraction(password: password)
        retainedSecrets.append(secret)
        return secret
    }
}

@MainActor
private final class Task8CancellingPasswordProvider: ArchivePasswordProviding {
    private(set) var requestCount = 0

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        requestCount += 1
        throw CancellationError()
    }
}

private actor Task8RetryEngine: ProtectedZIPEngine {
    private let inspectTotal: Int64
    private let alwaysSucceeds: Bool
    private(set) var passwordIdentities: [ObjectIdentifier] = []
    private var extractionCount = 0

    init(inspectTotal: Int64 = 0, alwaysSucceeds: Bool = false) {
        self.inspectTotal = inspectTotal
        self.alwaysSucceeds = alwaysSucceeds
    }

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(
            totalUncompressedByteCount: inspectTotal,
            hasEncryptedEntries: true,
            strongestAESStrength: 256
        )
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(
            totalUncompressedByteCount: inspectTotal,
            hasEncryptedEntries: true,
            strongestAESStrength: 256
        )
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        passwordIdentities.append(ObjectIdentifier(password))
        extractionCount += 1
        if extractionCount == 1 && !alwaysSucceeds {
            throw ProtectedZIPError.incorrectPasswordOrDamagedData
        }
    }
}

private struct Task8FailingSourcePreparer: ArchiveSourcePreparing {
    let live: LiveArchiveSourcePreparationService

    init(fileSystem: any FileSystemAccess) {
        live = LiveArchiveSourcePreparationService(fileSystem: fileSystem)
    }

    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources {
        try await live.prepare(
            sources,
            beside: destination,
            parentIdentity: parentIdentity,
            progress: progress
        )
    }

    func cleanup(_ prepared: PreparedArchiveSources) async throws {
        throw Task8CleanupError.expected
    }
}

private enum Task8CleanupError: Error {
    case expected
}

private final class Task8LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class Task8OperationCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Task<FileOperationResult, Never>?

    func install(_ operation: Task<FileOperationResult, Never>) {
        lock.withLock {
            self.operation = operation
        }
    }

    func cancel() {
        let operation = lock.withLock { self.operation }
        operation?.cancel()
    }
}

private func task8ExpectNoStagingDirectories(in directory: URL) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(children.contains {
        $0.lastPathComponent.hasPrefix(".bloom-staging-")
    } == false)
}

private actor Task8EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor Task8PreflightFailureEngine: ProtectedZIPEngine {
    private(set) var events: [String] = []

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        events.append("inspect")
        return ProtectedZIPInspection(
            hasEncryptedEntries: true,
            strongestAESStrength: 256
        )
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        events.append("preflight")
        throw ProtectedZIPError.unsafeEntry
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}
}

private actor Task8NonPasswordFailureEngine: ProtectedZIPEngine {
    private(set) var extractCount = 0

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        extractCount += 1
        throw ProtectedZIPError.engineSetupFailed
    }
}

private actor Task8CancellationEngine: ProtectedZIPEngine {
    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        throw CancellationError()
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        throw CancellationError()
    }
}

private actor Task8ProgressCancellationEngine: ProtectedZIPEngine {
    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        await progress(ProtectedZIPProgress(completedByteCount: 1, totalByteCount: 1))
        throw CancellationError()
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        await progress(ProtectedZIPProgress(completedByteCount: 1, totalByteCount: 1))
        throw CancellationError()
    }
}

private actor Task8TaskCancellationBoundaryEngine: ProtectedZIPEngine {
    private(set) var observedCancellation = false

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        await progress(ProtectedZIPProgress(completedByteCount: 1, totalByteCount: 1))
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
    }
}

private actor Task8RawErrorEngine: ProtectedZIPEngine {
    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        throw Task8RawSentinelError()
    }
}

private struct Task8RawSentinelError: LocalizedError, Sendable {
    var errorDescription: String? {
        "raw-error-sentinel secret-sentinel-passphrase internal-entry"
    }
}

private final class Task8RecordingSecurityScopeDriver: SecurityScopedResourceAccessing,
    @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var activeCount = 0

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock {
            startCount += 1
            activeCount += 1
        }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock {
            stopCount += 1
            activeCount = max(activeCount - 1, 0)
        }
    }
}

private actor Task8LimitRecordingEngine: ProtectedZIPEngine {
    private let total: Int64
    private(set) var preflightLimits: [ProtectedZIPLimits] = []
    private(set) var extractLimits: [ProtectedZIPLimits] = []

    init(total: Int64) {
        self.total = total
    }

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(
            totalUncompressedByteCount: total,
            hasEncryptedEntries: true,
            strongestAESStrength: 256
        )
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        preflightLimits.append(limits)
        return ProtectedZIPInspection(
            totalUncompressedByteCount: total,
            hasEncryptedEntries: true,
            strongestAESStrength: 256
        )
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        extractLimits.append(limits)
    }
}

private actor Task8FlakySourcePreparer: ArchiveSourcePreparing {
    private let live: LiveArchiveSourcePreparationService
    private var failuresRemaining: Int
    private let cleanupEvents: Task8EventRecorder?
    private(set) var cleanupCallCount = 0

    init(
        fileSystem: any FileSystemAccess,
        failures: Int,
        cleanupEvents: Task8EventRecorder? = nil
    ) {
        live = LiveArchiveSourcePreparationService(fileSystem: fileSystem)
        failuresRemaining = max(failures, 0)
        self.cleanupEvents = cleanupEvents
    }

    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources {
        try await live.prepare(
            sources,
            beside: destination,
            parentIdentity: parentIdentity,
            progress: progress
        )
    }

    func cleanup(_ prepared: PreparedArchiveSources) async throws {
        cleanupCallCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            await cleanupEvents?.append("prepared-cleanup-\(cleanupCallCount)-failed")
            throw Task8CleanupError.expected
        }
        await cleanupEvents?.append("prepared-cleanup-\(cleanupCallCount)-succeeded")
        try await live.cleanup(prepared)
    }
}

private actor Task8InstrumentedFileSystem: FileSystemAccess {
    private let inner: any FileSystemAccess
    private let availableCapacityOverride: Int64?
    private let beforeExclusiveMove: (@Sendable (URL, URL) throws -> Void)?
    private let cleanupEvents: Task8EventRecorder?
    private var failRemoveStagingCalls: Set<Int>
    private var failPostPublicationCleanupAttempts: Int
    private var hasPublishedOutput = false
    private(set) var removeStagingDirectoryCalls = 0
    private(set) var stagingReservations: [StagingReservation] = []
    private(set) var createdEmptyDescriptors: [Int32] = []
    private var openCloseCounters: [Task8LockedCounter] = []

    init(
        inner: any FileSystemAccess,
        availableCapacity: Int64? = nil,
        failRemoveStagingCalls: Set<Int> = [],
        failPostPublicationCleanupAttempts: Int = 0,
        beforeExclusiveMove: (@Sendable (URL, URL) throws -> Void)? = nil,
        cleanupEvents: Task8EventRecorder? = nil
    ) {
        self.inner = inner
        availableCapacityOverride = availableCapacity
        self.failRemoveStagingCalls = failRemoveStagingCalls
        self.failPostPublicationCleanupAttempts = max(failPostPublicationCleanupAttempts, 0)
        self.beforeExclusiveMove = beforeExclusiveMove
        self.cleanupEvents = cleanupEvents
    }

    var createdEmptyDescriptorCount: Int { createdEmptyDescriptors.count }

    var openedItemCount: Int { openCloseCounters.count }

    var liveDescriptorsAreClosed: Bool {
        createdEmptyDescriptors.allSatisfy {
            Darwin.fcntl($0, F_GETFD) == -1
        } && openCloseCounters.allSatisfy { $0.value == 1 }
    }

    func exists(_ url: URL) async -> Bool {
        await inner.exists(url)
    }

    func createDirectory(_ url: URL) async throws {
        try await inner.createDirectory(url)
    }

    func createEmptyItemAndCaptureIdentity(
        _ url: URL,
        kind: EmptyFileSystemItemKind,
        parentIdentifiedBy parentIdentity: FileIdentity
    ) async throws -> OpenedEmptyFileSystemItem {
        let item = try await inner.createEmptyItemAndCaptureIdentity(
            url,
            kind: kind,
            parentIdentifiedBy: parentIdentity
        )
        createdEmptyDescriptors.append(item.descriptor)
        return item
    }

    func openItem(
        _ url: URL,
        kind: OpenedFileSystemItemKind,
        identifiedBy expectedIdentity: FileIdentity
    ) async throws -> OpenedFileSystemItem {
        let original = try await inner.openItem(
            url,
            kind: kind,
            identifiedBy: expectedIdentity
        )
        let descriptor = try original.withUnsafeDescriptor { $0 }
        let closeCounter = Task8LockedCounter()
        openCloseCounters.append(closeCounter)
        return OpenedFileSystemItem(
            identity: original.identity,
            descriptor: descriptor,
            url: url,
            closeDescriptor: { _ in
                closeCounter.increment()
                original.close()
            }
        )
    }

    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity {
        try await inner.copyAndCaptureIdentity(source, to: destination)
    }

    func copyAndCaptureIdentity(
        _ source: URL,
        identifiedBy sourceIdentity: FileIdentity,
        to destination: URL
    ) async throws -> FileIdentity {
        try await inner.copyAndCaptureIdentity(
            source,
            identifiedBy: sourceIdentity,
            to: destination
        )
    }

    func move(_ source: URL, to destination: URL) async throws {
        try await inner.move(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) async throws {
        try beforeExclusiveMove?(source, destination)
        try await inner.moveExclusively(source, to: destination)
        hasPublishedOutput = true
    }

    func remove(_ url: URL) async throws {
        try await inner.remove(url)
    }

    func replace(_ destination: URL, with stagedItem: URL) async throws {
        try await inner.replace(destination, with: stagedItem)
    }

    func identity(of url: URL) async throws -> FileIdentity? {
        try await inner.identity(of: url)
    }

    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws {
        try await inner.move(source, identifiedBy: identity, to: destination)
    }

    func moveExclusively(
        _ source: URL,
        identifiedBy sourceIdentity: FileIdentity,
        to destination: URL,
        destinationParentIdentifiedBy destinationParentIdentity: FileIdentity
    ) async throws {
        try beforeExclusiveMove?(source, destination)
        try await inner.moveExclusively(
            source,
            identifiedBy: sourceIdentity,
            to: destination,
            destinationParentIdentifiedBy: destinationParentIdentity
        )
        hasPublishedOutput = true
    }

    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        try await inner.remove(url, identifiedBy: identity)
    }

    func replace(
        _ destination: URL,
        identifiedBy destinationIdentity: FileIdentity,
        with stagedItem: URL,
        identifiedBy stagedIdentity: FileIdentity
    ) async throws {
        try await inner.replace(
            destination,
            identifiedBy: destinationIdentity,
            with: stagedItem,
            identifiedBy: stagedIdentity
        )
    }

    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation {
        let reservation = try await inner.reserveStagingDirectory(beside: destination)
        stagingReservations.append(reservation)
        return reservation
    }

    func reserveStagingDirectory(
        beside destination: URL,
        parentIdentifiedBy parentIdentity: FileIdentity
    ) async throws -> StagingReservation {
        let reservation = try await inner.reserveStagingDirectory(
            beside: destination,
            parentIdentifiedBy: parentIdentity
        )
        stagingReservations.append(reservation)
        return reservation
    }

    func removeStagingDirectory(_ reservation: StagingReservation) async throws {
        removeStagingDirectoryCalls += 1
        let attempt = removeStagingDirectoryCalls
        if failRemoveStagingCalls.remove(removeStagingDirectoryCalls) != nil {
            await cleanupEvents?.append("remove-staging-\(attempt)-failed")
            throw Task8CleanupError.expected
        }
        if hasPublishedOutput, failPostPublicationCleanupAttempts > 0 {
            failPostPublicationCleanupAttempts -= 1
            await cleanupEvents?.append("remove-staging-\(attempt)-failed")
            throw Task8CleanupError.expected
        }
        try await inner.removeStagingDirectory(reservation)
        await cleanupEvents?.append("remove-staging-\(attempt)-succeeded")
    }

    func fingerprint(of source: URL) async throws -> SourceFingerprint {
        try await inner.fingerprint(of: source)
    }

    func fingerprint(of quarantine: StorageTrashQuarantine) async throws -> SourceFingerprint {
        try await inner.fingerprint(of: quarantine)
    }

    func trash(_ url: URL) async throws {
        try await inner.trash(url)
    }

    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        try await inner.trash(url, identifiedBy: identity)
    }

    func trashAndReturnResultingURL(
        _ url: URL,
        identifiedBy identity: FileIdentity
    ) async throws -> URL? {
        try await inner.trashAndReturnResultingURL(url, identifiedBy: identity)
    }

    func quarantineForTrash(
        _ url: URL,
        identifiedBy identity: FileIdentity
    ) async throws -> StorageTrashQuarantine {
        try await inner.quarantineForTrash(url, identifiedBy: identity)
    }

    func rollbackTrashQuarantine(_ quarantine: StorageTrashQuarantine) async throws {
        try await inner.rollbackTrashQuarantine(quarantine)
    }

    func moveTrashQuarantineAtomically(_ quarantine: StorageTrashQuarantine) async throws -> URL {
        try await inner.moveTrashQuarantineAtomically(quarantine)
    }

    func names(in directory: URL) async throws -> Set<String> {
        try await inner.names(in: directory)
    }

    func volumeIdentifier(for url: URL) async throws -> String {
        try await inner.volumeIdentifier(for: url)
    }

    func byteSize(of url: URL) async throws -> Int64? {
        try await inner.byteSize(of: url)
    }

    func availableCapacity(at url: URL) async throws -> Int64? {
        if let availableCapacityOverride { return availableCapacityOverride }
        return try await inner.availableCapacity(at: url)
    }

    func captureFolderPreviewRequest(
        paneID: PaneID,
        url: URL
    ) async throws -> FolderPreviewRequest? {
        try await inner.captureFolderPreviewRequest(paneID: paneID, url: url)
    }

    func snapshotFolder(
        _ request: FolderPreviewRequest,
        visibility: DirectoryVisibilityPolicy,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        try await inner.snapshotFolder(request, visibility: visibility, progress: progress)
    }

    func prepareDirectoryHierarchy(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        relativeComponents: [String]
    ) async throws -> PreparedDirectoryHierarchy {
        try await inner.prepareDirectoryHierarchy(
            root: root,
            identifiedBy: rootIdentity,
            relativeComponents: relativeComponents
        )
    }

    func removeEmptyOwnedDirectories(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        directories: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) async throws {
        try await inner.removeEmptyOwnedDirectories(
            root: root,
            identifiedBy: rootIdentity,
            directories: directories
        )
    }
}
