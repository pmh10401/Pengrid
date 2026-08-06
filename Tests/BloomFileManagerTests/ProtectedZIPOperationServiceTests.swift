import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite("ProtectedZIPOperationServiceTests")
struct ProtectedZIPOperationServiceTests {
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

    @Test @MainActor func wrongPasswordDestroysAttemptBeforeFreshPrompt() async throws {
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
            passwords: ["first-passphrase", "second-passphrase"]
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
        let service = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: Task8FailingSourcePreparer(fileSystem: fileSystem),
            passwordProvider: Task8RecordingPasswordProvider(
                root: root.url,
                passwords: ["creation-passphrase"]
            ),
            engine: Task8RetryEngine(alwaysSucceeds: true),
            logger: RecordingProtectedZIPLogger()
        )

        let result = await service.perform([request]) { _ in }

        #expect(result.outcomes == [.recoveryNeeded(source: source)])
        #expect(FileManager.default.fileExists(atPath: destination.path))
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

actor Task8RecordingArchiveSourcePreparer: ArchiveSourcePreparing {
    private let fileSystem: any FileSystemAccess
    private let root: URL
    private(set) var didFinishPreparation = false
    private(set) var finishedBeforePrompt = false

    init(fileSystem: any FileSystemAccess, root: URL) {
        self.fileSystem = fileSystem
        self.root = root
    }

    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources {
        didFinishPreparation = true
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
    private var passwords: [String]
    private var retainedSecrets: [ArchiveSecret] = []
    private(set) var requestCount = 0
    private(set) var previousPromptStagingCounts: [Int] = []
    private(set) var previousAttemptFlags: [Bool] = []
    private(set) var previousSecretsUnavailable: [Bool] = []

    init(root: URL, passwords: [String]) {
        self.root = root
        self.passwords = passwords
    }

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        requestCount += 1
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

private func task8ExpectNoStagingDirectories(in directory: URL) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(children.contains {
        $0.lastPathComponent.hasPrefix(".bloom-staging-")
    } == false)
}
