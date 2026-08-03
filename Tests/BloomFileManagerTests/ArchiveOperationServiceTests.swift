import Foundation
import Testing
@testable import BloomFileManager

@Suite("ArchiveOperationServiceTests")
struct ArchiveOperationServiceTests {
    @Test func compressionPublishesOneCompletedArchiveForAllSources() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let firstSource = root.url.appending(path: "First.txt")
        let secondSource = root.url.appending(path: "Second.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let publishedData = Data("completed zip".utf8)
        let runner = RecordingArchiveCommandRunner { kind, _, _, stagedDestination in
            #expect(kind == .compress)
            try publishedData.write(to: stagedDestination)
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            accessCoordinator: .init(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [firstSource, secondSource],
            finalDestination: destination
        )

        let result = await service.perform([request]) { _ in }
        let invocations = await runner.invocations

        #expect(invocations.count == 1)
        #expect(invocations.first?.kind == .compress)
        #expect(invocations.first?.format == .zip)
        #expect(invocations.first?.sources == [firstSource, secondSource])
        let stagedDestination = try #require(invocations.first?.destination)
        #expect(stagedDestination.lastPathComponent == "payload")
        #expect(stagedDestination.deletingLastPathComponent().deletingLastPathComponent()
            == destination.deletingLastPathComponent())
        #expect(try Data(contentsOf: destination) == publishedData)
        #expect(try Data(contentsOf: firstSource) == Data("first".utf8))
        #expect(try Data(contentsOf: secondSource) == Data("second".utf8))
        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: firstSource, destination: destination)
        ]))
        let destinationIdentity = try await LiveFileSystemAccess().identity(of: destination)
        #expect(result.undoDestinationIdentity(for: destination) == destinationIdentity)
        try expectNoStagingDirectories(in: root.url)
    }

    @Test func compressionForwardsTheRequestedFormatToTheCommandRunner() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.tar.gz")
        try Data("source".utf8).write(to: source)
        let runner = RecordingArchiveCommandRunner { _, _, _, stagedDestination in
            try Data("archive".utf8).write(to: stagedDestination)
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [source],
            finalDestination: destination,
            format: .tarGzip
        )

        _ = await service.perform([request]) { _ in }

        #expect(await runner.invocations.first?.format == .tarGzip)
    }

    @Test func compressionReportsRunnerPhasesBeforePublishing() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let firstSource = root.url.appending(path: "First.txt")
        let secondSource = root.url.appending(path: "Second.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let runnerPhases: [ArchiveOperationPhase] = [
            .preparingSources(completedCount: 0, totalCount: 2),
            .preparingSources(completedCount: 1, totalCount: 2),
            .preparingSources(completedCount: 2, totalCount: 2),
            .encoding
        ]
        let runner = RecordingArchiveCommandRunner(phases: runnerPhases) {
            _, _, _, stagedDestination in
            try Data("archive".utf8).write(to: stagedDestination)
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [firstSource, secondSource],
            finalDestination: destination
        )
        let recorder = ArchiveProgressRecorder()

        let result = await service.perform([request]) { update in
            await recorder.record(update)
        }

        let expected = runnerPhases.map { phase in
            ArchiveOperationProgress(
                kind: .compress,
                currentDisplayName: "Archive.zip",
                format: .zip,
                phase: phase
            )
        } + [
            ArchiveOperationProgress(
                kind: .compress,
                currentDisplayName: "Archive.zip",
                format: .zip,
                phase: .publishing
            )
        ]
        #expect(await recorder.values == expected)
        #expect(result.outcomes.count == 1)
    }

    @Test func commandFailureNeverReportsPublishing() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let runner = RecordingArchiveCommandRunner(phases: [.encoding]) {
            _, _, _, _ in
            throw ArchiveServiceTestError.commandFailed
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [source],
            finalDestination: destination
        )
        let recorder = ArchiveProgressRecorder()

        let result = await service.perform([request]) { update in
            await recorder.record(update)
        }

        #expect(await recorder.values == [
            ArchiveOperationProgress(
                kind: .compress,
                currentDisplayName: "Archive.zip",
                format: .zip,
                phase: .encoding
            )
        ])
        #expect(result.outcomes.count == 1)
    }

    @Test func extractionPublishesCompletedDirectoryAfterRunnerSuccess() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Package.zip")
        let destination = root.url.appending(path: "Package", directoryHint: .isDirectory)
        try Data("source archive".utf8).write(to: source)
        let extractedData = Data("extracted".utf8)
        let runner = RecordingArchiveCommandRunner { kind, _, sources, stagedDestination in
            #expect(kind == .extract)
            #expect(sources == [source])
            try FileManager.default.createDirectory(
                at: stagedDestination,
                withIntermediateDirectories: false
            )
            try extractedData.write(to: stagedDestination.appending(path: "Contents.txt"))
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: [source],
            finalDestination: destination
        )

        let result = await service.perform([request]) { _ in }

        #expect(try Data(contentsOf: destination.appending(path: "Contents.txt"))
            == extractedData)
        #expect(try Data(contentsOf: source) == Data("source archive".utf8))
        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: destination)
        ]))
        try expectNoStagingDirectories(in: root.url)
    }

    @Test func commandFailurePreservesUnownedPartialPayloadForRecovery() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let runner = RecordingArchiveCommandRunner { _, _, _, stagedDestination in
            try Data("partial".utf8).write(to: stagedDestination)
            throw ArchiveServiceTestError.commandFailed
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [source],
            finalDestination: destination
        )

        let result = await service.perform([request]) { _ in }

        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(try Data(contentsOf: source) == Data("source".utf8))
        #expect(result.outcomes.count == 1)
        guard case let .recoveryNeeded(failedSource) = result.outcomes.first else {
            Issue.record("Expected command failure recovery outcome")
            return
        }
        #expect(failedSource == source)
        let staging = try #require(FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".bloom-staging-") })
        #expect(try Data(contentsOf: staging.appending(path: "payload")) == Data("partial".utf8))
    }

    @Test func cancellationPreservesUnownedPartialPayloadAndRequiresRecovery() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let firstSource = root.url.appending(path: "First.zip")
        let secondSource = root.url.appending(path: "Second.zip")
        let firstDestination = root.url.appending(path: "First", directoryHint: .isDirectory)
        let secondDestination = root.url.appending(path: "Second", directoryHint: .isDirectory)
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let runner = RecordingArchiveCommandRunner { _, _, _, stagedDestination in
            try FileManager.default.createDirectory(
                at: stagedDestination,
                withIntermediateDirectories: false
            )
            try Data("partial".utf8).write(
                to: stagedDestination.appending(path: "Partial.txt")
            )
            throw ArchiveOperationError.cancelled
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let requests = [
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [firstSource],
                finalDestination: firstDestination
            ),
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [secondSource],
                finalDestination: secondDestination
            )
        ]

        let result = await service.perform(requests) { _ in }
        let invocationCount = await runner.invocationCount

        #expect(invocationCount == 1)
        #expect(result == FileOperationResult(outcomes: [
            .recoveryNeeded(source: firstSource),
            .cancelled(source: secondSource)
        ]))
        #expect(FileManager.default.fileExists(atPath: firstDestination.path) == false)
        #expect(FileManager.default.fileExists(atPath: secondDestination.path) == false)
        #expect(try Data(contentsOf: firstSource) == Data("first".utf8))
        #expect(try Data(contentsOf: secondSource) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasPrefix(".bloom-staging-") })
    }

    @Test func lateDestinationCollisionFailsWithoutReplacingEitherItem() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        let sourceData = Data("source".utf8)
        let introducedData = Data("introduced destination".utf8)
        try sourceData.write(to: source)
        let runner = RecordingArchiveCommandRunner { _, _, _, stagedDestination in
            try Data("completed archive".utf8).write(to: stagedDestination)
            try introducedData.write(to: destination)
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [source],
            finalDestination: destination
        )

        let result = await service.perform([request]) { _ in }

        #expect(try Data(contentsOf: source) == sourceData)
        #expect(try Data(contentsOf: destination) == introducedData)
        guard case let .recoveryNeeded(failedSource) = result.outcomes.first else {
            Issue.record("Expected exclusive publication collision recovery state")
            return
        }
        #expect(failedSource == source)
        #expect(try FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasPrefix(".bloom-staging-") })
    }

    @Test func publicationRefusesOutputReplacedAfterRunnerCapturedIdentity() async {
        let root = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let source = root.appending(path: "Source.txt")
        let destination = root.appending(path: "Archive.zip")
        let fileSystem = RecordingFileSystem(existingURLs: [root, source])
        let replacementIdentity = FileIdentity(
            entryIdentifier: "external-output-entry",
            resolvedIdentifier: "external-output-resolved"
        )
        let runner = ReplacingArchiveOutputRunner(
            fileSystem: fileSystem,
            replacementIdentity: replacementIdentity
        )
        let service = ArchiveOperationService(
            fileSystem: fileSystem,
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [source],
            finalDestination: destination
        )

        let result = await service.perform([request]) { _ in }
        let stagedOutput = await runner.stagedOutput

        #expect(result.outcomes == [.recoveryNeeded(source: source)])
        #expect(await fileSystem.existingURLs.contains(destination) == false)
        if let stagedOutput {
            let observedIdentity = try? await fileSystem.identity(of: stagedOutput)
            #expect(observedIdentity == replacementIdentity)
            #expect(await fileSystem.existingURLs.contains(stagedOutput))
        } else {
            Issue.record("Expected the runner to create a staged output")
        }
    }

    @Test func cancellationCleanupFailureRequiresRecoveryAndCancelsRemaining() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let firstSource = root.url.appending(path: "First.zip")
        let secondSource = root.url.appending(path: "Second.zip")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let firstDestination = root.url.appending(path: "First", directoryHint: .isDirectory)
        let secondDestination = root.url.appending(path: "Second", directoryHint: .isDirectory)
        let runner = RecordingArchiveCommandRunner { _, _, _, stagedDestination in
            let stagingDirectory = stagedDestination.deletingLastPathComponent()
            try FileManager.default.removeItem(at: stagingDirectory)
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: stagedDestination,
                withIntermediateDirectories: false
            )
            throw ArchiveOperationError.cancelled
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let requests = [
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [firstSource],
                finalDestination: firstDestination
            ),
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [secondSource],
                finalDestination: secondDestination
            )
        ]

        let result = await service.perform(requests) { _ in }
        let invocationCount = await runner.invocationCount

        #expect(invocationCount == 1)
        #expect(result.outcomes.count == 2)
        guard case let .recoveryNeeded(failedSource) = result.outcomes.first else {
            Issue.record("Expected cancellation cleanup to require recovery")
            return
        }
        #expect(failedSource == firstSource)
        #expect(result.outcomes.last == .cancelled(source: secondSource))

        let children = try FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: nil
        )
        let replacementBoundary = try #require(
            children.first { $0.lastPathComponent.hasPrefix(".bloom-staging-") }
        )
        #expect(try !FileManager.default.contentsOfDirectory(
            at: replacementBoundary,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func successfulCommandWithoutOutputFailsVerification() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)
        let runner = RecordingArchiveCommandRunner { _, _, _, _ in }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [source],
            finalDestination: destination
        )

        let result = await service.perform([request]) { _ in }

        guard case let .failed(failedSource, message) = result.outcomes.first else {
            Issue.record("Expected missing command output to fail")
            return
        }
        #expect(failedSource == source)
        #expect(message.contains("did not produce an output"))
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        try expectNoStagingDirectories(in: root.url)
    }

    @Test func cancellationDuringOutputVerificationPreventsFinalPublication() async {
        let root = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let source = root.appending(path: "Source.txt")
        let destination = root.appending(path: "Archive.zip")
        let fileSystem = RecordingFileSystem(
            existingURLs: [root, source],
            suspendExistsOfLastPathComponent: "payload"
        )
        let runner = RecordingArchiveCommandRunner(outputIdentity: { stagedDestination in
            guard let identity = try await fileSystem.identity(of: stagedDestination) else {
                throw ArchiveOperationError.invalidRequest
            }
            return identity
        }) { _, _, _, stagedDestination in
            try await fileSystem.createDirectory(stagedDestination)
        }
        let service = ArchiveOperationService(
            fileSystem: fileSystem,
            commandRunner: runner
        )
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [source],
            finalDestination: destination
        )

        let operation = Task {
            await service.perform([request]) { _ in }
        }
        while await !fileSystem.hasSuspendedExists {
            await Task.yield()
        }
        operation.cancel()
        await fileSystem.releaseSuspendedExists()
        let result = await operation.value

        #expect(result == FileOperationResult(outcomes: [
            .recoveryNeeded(source: source)
        ]))
        #expect(await fileSystem.exists(destination) == false)
        #expect(await fileSystem.existingURLs.contains { url in
            url.lastPathComponent == "payload"
        })
        #expect(await fileSystem.events.contains {
            $0.hasPrefix("moveExclusively:")
        } == false)
    }

    @Test func scopedAccessCoversEverySourceAndReleasesAfterEachRequest() async throws {
        let firstRoot = try TemporaryDirectory()
        defer { firstRoot.remove() }
        let secondRoot = try TemporaryDirectory()
        defer { secondRoot.remove() }
        let destinationRoot = try TemporaryDirectory()
        defer { destinationRoot.remove() }
        let firstSource = firstRoot.url.appending(path: "First.zip")
        let secondSource = secondRoot.url.appending(path: "Second.zip")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let firstDestination = destinationRoot.url.appending(
            path: "First",
            directoryHint: .isDirectory
        )
        let secondDestination = destinationRoot.url.appending(
            path: "Second",
            directoryHint: .isDirectory
        )
        let driver = ArchiveScopedAccessDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([
            firstRoot.url,
            secondRoot.url,
            destinationRoot.url
        ])
        let observation = ArchiveRunObservation()
        let runner = RecordingArchiveCommandRunner { _, _, _, stagedDestination in
            let call = observation.beginCall()
            let snapshot = driver.snapshot
            if call == 0 {
                #expect(snapshot.stopped.isEmpty)
            } else {
                #expect(snapshot.stopped.contains(firstRoot.url))
                #expect(snapshot.stopped.contains(destinationRoot.url))
            }
            try FileManager.default.createDirectory(
                at: stagedDestination,
                withIntermediateDirectories: false
            )
        }
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            accessCoordinator: accessCoordinator,
            commandRunner: runner
        )
        let requests = [
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [firstSource],
                finalDestination: firstDestination
            ),
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [secondSource],
                finalDestination: secondDestination
            )
        ]

        _ = await service.perform(requests) { _ in }

        let snapshot = driver.snapshot
        #expect(snapshot.started.filter { $0 == firstRoot.url }.count == 1)
        #expect(snapshot.started.filter { $0 == secondRoot.url }.count == 1)
        #expect(snapshot.started.filter { $0 == destinationRoot.url }.count == 2)
        #expect(snapshot.stopped == snapshot.started)
    }
}

private struct ArchiveCommandInvocation: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let format: ArchiveFormat
    let sources: [URL]
    let destination: URL
}

private actor RecordingArchiveCommandRunner: ArchiveCommandRunning {
    typealias Handler = @Sendable (
        ArchiveOperationKind,
        ArchiveFormat,
        [URL],
        URL
    ) async throws -> Void

    private(set) var invocations: [ArchiveCommandInvocation] = []
    var invocationCount: Int { invocations.count }
    private let phases: [ArchiveOperationPhase]
    private let outputIdentity: @Sendable (URL) async throws -> FileIdentity
    private let handler: Handler

    init(
        phases: [ArchiveOperationPhase] = [],
        outputIdentity: @escaping @Sendable (URL) async throws -> FileIdentity = {
            archiveTestIdentity(for: $0)
        },
        handler: @escaping Handler
    ) {
        self.phases = phases
        self.outputIdentity = outputIdentity
        self.handler = handler
    }

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> FileIdentity {
        let sourceURLs = sources.map(\.url)
        invocations.append(ArchiveCommandInvocation(
            kind: kind,
            format: format,
            sources: sourceURLs,
            destination: destination
        ))
        try await handler(kind, format, sourceURLs, destination)
        return try await outputIdentity(destination)
    }

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> FileIdentity {
        let sourceURLs = sources.map(\.url)
        invocations.append(ArchiveCommandInvocation(
            kind: kind,
            format: format,
            sources: sourceURLs,
            destination: destination
        ))
        for phase in phases {
            await progress(phase)
        }
        try await handler(kind, format, sourceURLs, destination)
        return try await outputIdentity(destination)
    }
}

private actor ReplacingArchiveOutputRunner: ArchiveCommandRunning {
    private let fileSystem: RecordingFileSystem
    private let replacementIdentity: FileIdentity
    private(set) var stagedOutput: URL?

    init(fileSystem: RecordingFileSystem, replacementIdentity: FileIdentity) {
        self.fileSystem = fileSystem
        self.replacementIdentity = replacementIdentity
    }

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> FileIdentity {
        try await fileSystem.createDirectory(destination)
        guard let captured = try await fileSystem.identity(of: destination) else {
            throw ArchiveOperationError.invalidRequest
        }
        stagedOutput = destination
        await fileSystem.replaceIdentity(at: destination, with: replacementIdentity)
        return captured
    }
}

private actor ArchiveProgressRecorder {
    private(set) var values: [ArchiveOperationProgress] = []

    func record(_ progress: ArchiveOperationProgress) {
        values.append(progress)
    }
}

private enum ArchiveServiceTestError: Error {
    case commandFailed
}

private final class ArchiveScopedAccessDriver:
    SecurityScopedResourceAccessing,
    @unchecked Sendable
{
    struct Snapshot {
        let started: [URL]
        let stopped: [URL]
    }

    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []

    var snapshot: Snapshot {
        lock.withLock { Snapshot(started: started, stopped: stopped) }
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { started.append(url) }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stopped.append(url) }
    }
}

private final class ArchiveRunObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func beginCall() -> Int {
        lock.withLock {
            defer { callCount += 1 }
            return callCount
        }
    }
}

private func expectNoStagingDirectories(
    in directory: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(
        children.contains { $0.lastPathComponent.hasPrefix(".bloom-staging-") } == false,
        sourceLocation: sourceLocation
    )
}
