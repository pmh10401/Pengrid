import Darwin
import Foundation
import AppKit
import Testing
@testable import BloomFileManager

@Suite("Application termination safety", .serialized)
struct ApplicationTerminationTests {
    @MainActor
    @Test func idleTerminationIsImmediateAndDoesNotReply() {
        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: nil,
            passwordCoordinator: nil,
            timeout: .milliseconds(100),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )

        #expect(coordinator.applicationShouldTerminate() == .terminateNow)
        #expect(replies.values.isEmpty)
    }

    @MainActor
    @Test func activeOperationUsesTerminateLaterAndCancelsBeforeReplying() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let gate = TerminationGate()
        let controller = fixture.makeController(
            archiveOperator: GatedTerminationArchiveOperator(gate: gate)
        )
        let workspace = fixture.workspace
        workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(workspace, format: .zip, protection: .aes256))
        await gate.waitUntilEntered()

        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .seconds(2),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )

        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        #expect(replies.values.isEmpty)
        await waitForTerminationReply(replies)
        #expect(replies.values == [true])
        #expect(controller.isRunning == false)
        await gate.release()
    }

    @MainActor
    @Test func promptUsesTerminateLaterAndCancelsPrompt() async throws {
        let prompt = ArchivePasswordPromptCoordinator()
        let task = Task { try await prompt.requestPassword(for: TerminationFixture.request) }
        await waitUntilTerminationCondition { prompt.pendingRequest != nil }

        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: nil,
            passwordCoordinator: prompt,
            timeout: .seconds(2),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )
        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        await waitForTerminationReply(replies)
        #expect(replies.values == [true])
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(prompt.pendingRequest == nil)
    }

    @MainActor
    @Test func timeoutRepliesFalseExactlyOnce() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let gate = TerminationGate()
        let controller = fixture.makeController(
            archiveOperator: NonCooperativeTerminationArchiveOperator(gate: gate)
        )
        fixture.workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(fixture.workspace, format: .zip, protection: .aes256))
        await gate.waitUntilEntered()

        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .milliseconds(10),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )
        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        await waitForTerminationReply(replies)
        #expect(replies.values == [false])
        await Task.yield()
        #expect(replies.values == [false])

        controller.cancelActiveJob()
        await gate.release()
        await waitUntilTerminationCondition { !controller.isRunning }
    }

    @MainActor
    @Test func recoveryResultRepliesFalse() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let controller = fixture.makeController(archiveOperator: RecoveryTerminationArchiveOperator())
        fixture.workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(fixture.workspace, format: .zip, protection: .aes256))
        await waitUntilTerminationCondition { !controller.isRunning }
        #expect(controller.isQueueBlockedByRecovery)

        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .seconds(1),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )
        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        await waitForTerminationReply(replies)
        #expect(replies.values == [false])
    }

    @MainActor
    @Test func recoveryAcknowledgementAllowsImmediateRetryQuit() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let controller = fixture.makeController(archiveOperator: RecoveryTerminationArchiveOperator())
        fixture.workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(fixture.workspace, format: .zip, protection: .aes256))
        await waitUntilTerminationCondition { !controller.isRunning }
        #expect(controller.isQueueBlockedByRecovery)

        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .seconds(1),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )
        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        await waitForTerminationReply(replies)
        #expect(replies.values == [false])
        #expect(controller.continueAfterRecovery())
        #expect(coordinator.applicationShouldTerminate() == .terminateNow)
        #expect(replies.values == [false])
    }

    @MainActor
    @Test func successfulCancellationRepliesTrueOnlyAfterControllerIdle() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let gate = TerminationGate()
        let controller = fixture.makeController(archiveOperator: GatedTerminationArchiveOperator(gate: gate))
        fixture.workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(fixture.workspace, format: .zip, protection: .aes256))
        await gate.waitUntilEntered()

        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .seconds(2),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )
        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        #expect(replies.values.isEmpty)
        await waitForTerminationReply(replies)
        #expect(replies.values == [true])
        #expect(controller.isRunning == false)
        await gate.release()
    }

    @MainActor
    @Test func reentrantTerminationDoesNotDuplicatePreparationOrReply() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let gate = TerminationGate()
        let controller = fixture.makeController(archiveOperator: GatedTerminationArchiveOperator(gate: gate))
        fixture.workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(fixture.workspace, format: .zip, protection: .aes256))
        await gate.waitUntilEntered()

        let replies = TerminationReplyRecorder()
        let coordinator = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .seconds(2),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )
        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        #expect(coordinator.applicationShouldTerminate() == .terminateLater)
        await waitForTerminationReply(replies)
        #expect(replies.values == [true])
        await gate.release()
    }

    @MainActor
    @Test func releasingCoordinatorInvalidatesPreparationWithoutReplyOrStuckGate() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let gate = TerminationGate()
        let controller = fixture.makeController(
            archiveOperator: GatedTerminationArchiveOperator(gate: gate)
        )
        fixture.workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(fixture.workspace, format: .zip, protection: .aes256))
        await gate.waitUntilEntered()

        let replies = TerminationReplyRecorder()
        var coordinator: ApplicationTerminationCoordinator? = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .seconds(2),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )
        let weakCoordinator = WeakTerminationCoordinatorBox(coordinator)
        #expect(coordinator?.applicationShouldTerminate() == .terminateLater)
        coordinator = nil

        await waitUntilTerminationCondition {
            weakCoordinator.value == nil && !controller.isTerminationPreparationActive
        }
        #expect(replies.values.isEmpty)
        #expect(controller.isTerminationPreparationActive == false)
        await gate.release()
        await waitUntilTerminationCondition { !controller.isRunning }
    }

    @MainActor
    @Test func appDelegateReconfigurationInvalidatesOldPreparationAndRepliesOnceFromNewCoordinator() async {
        let fixture = try! TerminationFixture()
        await fixture.workspace.loadInitialDirectories()
        let gate = TerminationGate()
        let controller = fixture.makeController(
            archiveOperator: GatedTerminationArchiveOperator(gate: gate)
        )
        fixture.workspace.left.selection = [fixture.source]
        #expect(await controller.compressSelection(fixture.workspace, format: .zip, protection: .aes256))
        await gate.waitUntilEntered()

        let appDelegate = AppDelegate()
        let oldReplies = TerminationReplyRecorder()
        let newReplies = TerminationReplyRecorder()
        let passwordCoordinator = ArchivePasswordPromptCoordinator()
        appDelegate.configureTermination(
            operationController: controller,
            passwordCoordinator: passwordCoordinator,
            reply: { oldReplies.append($0) }
        )
        #expect(appDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)

        appDelegate.configureTermination(
            operationController: controller,
            passwordCoordinator: passwordCoordinator,
            reply: { newReplies.append($0) }
        )
        await Task.yield()
        #expect(oldReplies.values.isEmpty)
        #expect(newReplies.values.isEmpty)
        #expect(controller.isTerminationPreparationActive == false)

        #expect(appDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        await waitForTerminationReply(newReplies)
        #expect(oldReplies.values.isEmpty)
        #expect(newReplies.values == [true])
        await gate.release()
    }

    /// Load-bearing lifecycle coverage: the protected extraction engine has
    /// already written plaintext into its private output staging directory
    /// when Quit is requested. No reply may be emitted until cancellation
    /// unwinds and the protected service's deferred cleanup removes both
    /// private reservations and the unpublished destination.
    @MainActor
    @Test func protectedExtractionQuitWaitsForPlaintextStagingCleanup() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "aes-password-1.zip")
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ProtectedZIP/aes-password-1.zip")
        try FileManager.default.copyItem(at: fixture, to: archive)

        let gate = PlaintextExtractionGate()
        defer { Task { await gate.release() } }
        let engine = GatedPlaintextExtractionEngine(gate: gate)
        let service = FileOperationService(fileSystem: LiveFileSystemAccess())
        let passwordProvider = E2ERecordingArchivePasswordProvider(passwords: ["load-bearing"])
        let archiveService = service.makeRoutingArchiveOperationService(
            passwordProvider: passwordProvider,
            protectedEngine: engine,
            protectedLogger: RecordingProtectedZIPLogger()
        )
        let controller = FileOperationController(
            service: service,
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )
        let workspace = WorkspaceState(
            leftURL: root.url,
            rightURL: root.url,
            listingService: StubDirectoryListingService(values: [
                root.url: [FileItem(
                    url: archive,
                    name: archive.lastPathComponent,
                    isDirectory: false,
                    isPackage: false,
                    modifiedAt: nil,
                    byteSize: nil,
                    typeDescription: "ZIP archive"
                )]
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [archive]

        #expect(await controller.extractSelection(workspace))
        await gate.waitUntilEntered()
        let privateStagingBeforeQuit = try plaintextStagingDescendants(in: root.url)
        #expect(privateStagingBeforeQuit.contains { $0.lastPathComponent == "plaintext.txt" })

        let replies = TerminationReplyRecorder()
        let termination = ApplicationTerminationCoordinator(
            operationController: controller,
            passwordCoordinator: nil,
            timeout: .seconds(2),
            pollInterval: .milliseconds(1),
            reply: { replies.append($0) }
        )

        #expect(termination.applicationShouldTerminate() == .terminateLater)
        await Task.yield()
        #expect(replies.values.isEmpty)
        #expect(try plaintextStagingDescendants(in: root.url).contains {
            $0.lastPathComponent == "plaintext.txt"
        })

        await gate.release()
        await waitForTerminationReply(replies)
        #expect(replies.values == [true])
        #expect(controller.isRunning == false)
        #expect(try archiveTestStagingDirectories(in: root.url).isEmpty)
        #expect(try plaintextStagingDescendants(in: root.url).isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: root.url.appending(path: "aes-password-1").path
        ) == false)
    }
}

@MainActor
private final class TerminationReplyRecorder {
    private(set) var values: [Bool] = []

    func append(_ value: Bool) {
        values.append(value)
    }
}

@MainActor
private final class WeakTerminationCoordinatorBox {
    weak var value: ApplicationTerminationCoordinator?

    init(_ value: ApplicationTerminationCoordinator?) {
        self.value = value
    }
}

private actor TerminationGate {
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withTaskCancellationHandler(operation: {
            if released { return }
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.release() }
        })
    }

    func waitIgnoringCancellation() async {
        if released { return }
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedTerminationArchiveOperator: ArchiveOperating {
    private let gate: TerminationGate

    init(gate: TerminationGate) {
        self.gate = gate
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        await progress(ArchiveOperationProgress(
            kind: .compress,
            currentDisplayName: requests.first?.finalDestination.lastPathComponent ?? "Archive.zip",
            format: .zip,
            phase: .processingBytes(completedByteCount: 1, totalByteCount: 2)
        ))
        await gate.wait()
        return FileOperationResult(outcomes: requests.map {
            .cancelled(source: $0.verifiedSources.first?.url ?? $0.finalDestination)
        })
    }
}

private actor NonCooperativeTerminationArchiveOperator: ArchiveOperating {
    private let gate: TerminationGate

    init(gate: TerminationGate) {
        self.gate = gate
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        await progress(ArchiveOperationProgress(
            kind: .compress,
            currentDisplayName: requests.first?.finalDestination.lastPathComponent ?? "Archive.zip",
            format: .zip,
            phase: .processingBytes(completedByteCount: 1, totalByteCount: 2)
        ))
        await gate.waitIgnoringCancellation()
        return FileOperationResult(outcomes: requests.map {
            .cancelled(source: $0.verifiedSources.first?.url ?? $0.finalDestination)
        })
    }
}

private actor RecoveryTerminationArchiveOperator: ArchiveOperating {
    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        FileOperationResult(outcomes: requests.map {
            .recoveryNeeded(source: $0.verifiedSources.first?.url ?? $0.finalDestination)
        })
    }
}

private actor PlaintextExtractionGate {
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func markEntered() {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
    }

    func waitIgnoringCancellation() async {
        if released { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedPlaintextExtractionEngine: ProtectedZIPEngine {
    private let gate: PlaintextExtractionGate

    init(gate: PlaintextExtractionGate) {
        self.gate = gate
    }

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection(
            entryCount: 1,
            totalUncompressedByteCount: 16,
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
            entryCount: 1,
            totalUncompressedByteCount: 16,
            hasEncryptedEntries: true,
            strongestAESStrength: 256
        )
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        throw ProtectedZIPError.unsupportedEncryption
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let name = "plaintext.txt"
        let descriptor = name.withCString {
            Darwin.openat(
                destinationRoot.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_TRUNC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = Array("private plaintext".utf8)
        _ = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        _ = Darwin.close(descriptor)
        await gate.markEntered()
        await progress(ProtectedZIPProgress(
            completedByteCount: Int64(bytes.count),
            totalByteCount: Int64(bytes.count)
        ))
        await gate.waitIgnoringCancellation()
        try Task.checkCancellation()
    }
}

private func plaintextStagingDescendants(in root: URL) throws -> [URL] {
    let directories = try archiveTestStagingDirectories(in: root)
    return directories.flatMap { directory in
        (FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )?.allObjects as? [URL]) ?? []
    }
}

@MainActor
private struct TerminationFixture {
    static let request = ArchivePasswordRequest(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        purpose: .extract,
        archiveBasename: "Termination.zip",
        previousAttemptFailed: false
    )

    let root: TemporaryDirectory
    let source: URL
    let workspace: WorkspaceState

    init() throws {
        root = try TemporaryDirectory()
        source = root.url.appending(path: "Source.txt")
        try Data("termination fixture".utf8).write(to: source)
        workspace = WorkspaceState(
            leftURL: root.url,
            rightURL: root.url,
            listingService: StubDirectoryListingService(values: [
                root.url: [FileItem(
                    url: source,
                    name: source.lastPathComponent,
                    isDirectory: false,
                    isPackage: false,
                    modifiedAt: nil,
                    byteSize: 18,
                    typeDescription: "Text"
                )]
            ])
        )
    }

    func makeController(archiveOperator: any ArchiveOperating) -> FileOperationController {
        FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveOperator
        )
    }
}

@MainActor
private func waitUntilTerminationCondition(
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for termination condition")
}

@MainActor
private func waitForTerminationReply(_ recorder: TerminationReplyRecorder) async {
    await waitUntilTerminationCondition { !recorder.values.isEmpty }
}
