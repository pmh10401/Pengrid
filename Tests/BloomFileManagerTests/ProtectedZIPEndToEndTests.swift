import Foundation
import CryptoKit
import Testing
@testable import BloomFileManager

@Suite("ProtectedZIPEndToEndTests", .serialized)
struct ProtectedZIPEndToEndTests {
    @Test @MainActor func protectedZIPEndToEndPublishesOnlyAuthenticatedOutput() async throws {
        let sentinel = "e2e-public-test-passphrase"
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let archive = root.url.appending(path: "Source.txt.zip")
        let extraction = root.url.appending(path: "Source.txt", directoryHint: .isDirectory)
        let originalBytes = Data("protected e2e bytes".utf8)
        try originalBytes.write(to: source)

        let passwordProvider = E2ERecordingArchivePasswordProvider(
            passwords: [sentinel, sentinel]
        )
        let logger = RecordingProtectedZIPLogger()
        let service = FileOperationService(fileSystem: LiveFileSystemAccess())
        let archiveService = service.makeRoutingArchiveOperationService(
            passwordProvider: passwordProvider,
            protectedEngine: LiveProtectedZIPEngine(),
            protectedLogger: logger
        )
        let controller = FileOperationController(
            service: service,
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )
        let workspace = ProtectedZIPEndToEndTests.workspace(
            directory: root.url,
            items: [ProtectedZIPEndToEndTests.fileItem(at: source)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]

        #expect(await controller.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(controller)
        #expect(controller.lastResult?.outcomes == [
            .succeeded(source: source, destination: archive)
        ])
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(try Data(contentsOf: archive).range(of: Data(sentinel.utf8)) == nil)
        try FileManager.default.removeItem(at: source)

        let extractionWorkspace = ProtectedZIPEndToEndTests.workspace(
            directory: root.url,
            items: [ProtectedZIPEndToEndTests.fileItem(at: archive)]
        )
        await extractionWorkspace.loadInitialDirectories()
        extractionWorkspace.left.selection = [archive]
        #expect(await controller.extractSelection(extractionWorkspace))
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes == [
            .succeeded(source: archive, destination: extraction)
        ])
        #expect(try Data(contentsOf: extraction.appending(path: source.lastPathComponent)) == originalBytes)
        #expect(String(reflecting: await logger.events).contains(sentinel) == false)
        #expect(controller.observableTextForTesting.contains(sentinel) == false)
        #expect(String(reflecting: controller.lastResult).contains(sentinel) == false)
        #expect(String(reflecting: controller.operationHistory).contains(sentinel) == false)
        #expect(String(reflecting: controller.lastPreparationFailures).contains(sentinel) == false)
        let publicNames = try FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).joined(separator: "|")
        #expect(publicNames.contains(sentinel) == false)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func wrongPasswordThenCorrectPasswordUsesFreshPromptAndCleansAttempts() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Retry.txt")
        let archive = root.url.appending(path: "Retry.txt.zip")
        let extraction = root.url.appending(path: "Retry.txt", directoryHint: .isDirectory)
        let expected = Data("retry authenticated bytes".utf8)
        try expected.write(to: source)

        let createProvider = E2ERecordingArchivePasswordProvider(passwords: ["retry-passphrase"])
        let createLogger = RecordingProtectedZIPLogger()
        let service = FileOperationService(fileSystem: LiveFileSystemAccess())
        let createController = Self.makeController(
            service: service,
            passwordProvider: createProvider,
            logger: createLogger
        )
        let createWorkspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: source)]
        )
        await createWorkspace.loadInitialDirectories()
        createWorkspace.left.selection = [source]
        #expect(await createController.compressSelection(
            createWorkspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(createController)
        #expect(createController.lastResult?.hasFailures == false)
        try FileManager.default.removeItem(at: source)

        let provider = E2ERecordingArchivePasswordProvider(
            passwords: ["wrong-retry-passphrase", "retry-passphrase"]
        )
        let logger = RecordingProtectedZIPLogger()
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: logger
        )
        let extractionWorkspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: archive)]
        )
        await extractionWorkspace.loadInitialDirectories()
        extractionWorkspace.left.selection = [archive]
        #expect(await controller.extractSelection(extractionWorkspace))
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes == [
            .succeeded(source: archive, destination: extraction)
        ])
        #expect(try Data(contentsOf: extraction.appending(path: source.lastPathComponent)) == expected)
        #expect(provider.requests.map(\.previousAttemptFailed) == [false, true])
        #expect(provider.requests.map(\.id).count == 2)
        #expect(provider.requests[0].id != provider.requests[1].id)
        #expect(provider.retainedSecretAvailability() == [false, false])
        #expect(controller.observableTextForTesting.contains("wrong-retry-passphrase") == false)
        #expect(String(reflecting: await logger.events).contains("wrong-retry-passphrase") == false)
        #expect(String(reflecting: controller.lastResult).contains("wrong-retry-passphrase") == false)
        #expect(String(reflecting: controller.operationHistory).contains("wrong-retry-passphrase") == false)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func cancellingWhilePasswordPromptWaitsLeavesNoOutputOrOrphans() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Prompt.txt")
        let archive = root.url.appending(path: "Prompt.txt.zip")
        try Data("prompt cancellation bytes".utf8).write(to: source)
        let creator = E2ERecordingArchivePasswordProvider(passwords: ["prompt-passphrase"])
        let creatorController = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: creator,
            logger: RecordingProtectedZIPLogger()
        )
        let createWorkspace = Self.workspace(directory: root.url, items: [Self.fileItem(at: source)])
        await createWorkspace.loadInitialDirectories()
        createWorkspace.left.selection = [source]
        #expect(await creatorController.compressSelection(
            createWorkspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(creatorController)
        try FileManager.default.removeItem(at: source)

        let gate = ArchiveTestPromptGate()
        let provider = E2EBlockingArchivePasswordProvider(password: "prompt-passphrase", gate: gate)
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger()
        )
        let extractWorkspace = Self.workspace(directory: root.url, items: [Self.fileItem(at: archive)])
        await extractWorkspace.loadInitialDirectories()
        extractWorkspace.left.selection = [archive]
        #expect(await controller.extractSelection(extractWorkspace))
        await gate.waitUntilEntered()
        #expect(controller.activeJob?.state == .waitingForPassword)

        controller.cancelActiveJob()
        await waitForControllerIdle(controller)
        #expect(controller.lastResult?.outcomes == [.cancelled(source: archive)])
        #expect(controller.operationHistory.first?.state == .cancelled)
        #expect(provider.requests.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.url.appending(path: "Prompt.txt").path) == false)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test(arguments: [
        ProtectedFixture.aes128,
        ProtectedFixture.aes192,
        ProtectedFixture.aes256,
        ProtectedFixture.aesPasswordOne,
        ProtectedFixture.aesPassword257,
        ProtectedFixture.aesPassword1024,
        ProtectedFixture.zipCrypto
    ])
    @MainActor
    func committedIndependentFixturesFollowCompatibilityPolicy(_ fixture: ProtectedFixture) async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let fixtureURL = Self.fixtureURL(fixture.filename)
        let archive = root.url.appending(path: fixture.filename)
        try FileManager.default.copyItem(at: fixtureURL, to: archive)
        #expect(Self.sha256(of: archive) == fixture.sha256)

        let provider = E2ERecordingArchivePasswordProvider(passwords: [fixture.password])
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger()
        )
        let extractionWorkspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: archive)]
        )
        await extractionWorkspace.loadInitialDirectories()
        extractionWorkspace.left.selection = [archive]

        #expect(await controller.extractSelection(extractionWorkspace))
        await waitForControllerIdle(controller)

        let extraction = root.url.appending(
            path: fixture.stem,
            directoryHint: .isDirectory
        )
        #expect(controller.lastResult?.outcomes == [
            .succeeded(source: archive, destination: extraction)
        ])
        #expect(try Data(contentsOf: extraction.appending(path: fixture.entry)) == fixture.bytes)
        #expect(provider.requestCount == 1)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func mixedEncryptedAndPlainSelectionsRouteWithoutLeakingSecrets() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let protectedSource = root.url.appending(path: "Secret.txt")
        let protectedArchive = root.url.appending(path: "Secret.txt.zip")
        let plainSource = root.url.appending(path: "Plain.txt")
        let plainArchive = root.url.appending(path: "Plain.txt.zip")
        try Data("encrypted selection".utf8).write(to: protectedSource)
        try Data("plain selection".utf8).write(to: plainSource)

        let creator = E2ERecordingArchivePasswordProvider(passwords: ["mixed-passphrase"])
        let creatorController = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: creator,
            logger: RecordingProtectedZIPLogger()
        )
        let protectedWorkspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: protectedSource)]
        )
        await protectedWorkspace.loadInitialDirectories()
        protectedWorkspace.left.selection = [protectedSource]
        #expect(await creatorController.compressSelection(
            protectedWorkspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(creatorController)
        try FileManager.default.removeItem(at: protectedSource)

        try await LiveArchiveCommandRunner().run(
            kind: .compress,
            format: .zip,
            sources: [plainSource],
            destination: plainArchive
        )
        try FileManager.default.removeItem(at: plainSource)

        let provider = E2ERecordingArchivePasswordProvider(passwords: ["mixed-passphrase"])
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger()
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: protectedArchive), Self.fileItem(at: plainArchive)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [protectedArchive, plainArchive]
        #expect(await controller.extractSelection(workspace))
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes.count == 2)
        #expect(controller.lastResult?.outcomes.allSatisfy {
            if case .succeeded = $0 { return true }
            return false
        } == true)
        #expect(provider.requestCount == 1)
        #expect(try Data(contentsOf: root.url.appending(path: "Secret.txt/Secret.txt"))
            == Data("encrypted selection".utf8))
        #expect(try Data(contentsOf: root.url.appending(path: "Plain.txt/Plain.txt"))
            == Data("plain selection".utf8))
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func mixedEncryptedAndPlainEntriesUseProtectedExtractionPolicy() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let plain = root.url.appending(path: "plain.txt")
        let encrypted = root.url.appending(path: "secret.txt")
        let archive = root.url.appending(path: "mixed-entry.zip")
        let extraction = root.url.appending(path: "mixed-entry", directoryHint: .isDirectory)
        let password = "mixed-entry-passphrase"
        let plainBytes = Data("plain mixed entry".utf8)
        let encryptedBytes = Data("encrypted mixed entry".utf8)
        // Build both entries in-process. This keeps the password out of every
        // child-process argument, environment, and stdout/stderr stream while
        // still exercising the real ZipCrypto reader policy.
        try writeMixedZipFixture(
            to: archive,
            plainName: plain.lastPathComponent,
            plainBytes: plainBytes,
            encryptedName: encrypted.lastPathComponent,
            encryptedBytes: encryptedBytes,
            password: password
        )

        let provider = E2ERecordingArchivePasswordProvider(passwords: [password])
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger()
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: archive)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [archive]
        #expect(await controller.extractSelection(workspace))
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes == [
            .succeeded(source: archive, destination: extraction)
        ])
        #expect(try Data(contentsOf: extraction.appending(path: "plain.txt")) == plainBytes)
        #expect(try Data(contentsOf: extraction.appending(path: "secret.txt")) == encryptedBytes)
        #expect(provider.requestCount == 1)
        #expect(try Data(contentsOf: archive).range(of: Data(password.utf8)) == nil)
        #expect(controller.observableTextForTesting.contains(password) == false)
        #expect(String(reflecting: controller.lastResult).contains(password) == false)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func sourceIdentityChangeAfterMaterializationRefusesPromptAndPublication() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Changed.txt")
        let archive = root.url.appending(path: "Changed.txt.zip")
        try Data("captured source".utf8).write(to: source)

        let provider = E2ERecordingArchivePasswordProvider(passwords: ["must-not-prompt"])
        let materializer = IdentityChangingArchiveMaterializer(
            url: source,
            replacement: Data("replacement source".utf8)
        )
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger(),
            materializer: materializer
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: source)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]

        #expect(await controller.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes == [
            .failed(source: source, message: "cloud-preparation:item-changed")
        ])
        #expect(controller.lastPreparationFailures == [CloudMaterializationFailure(
            name: "Changed.txt",
            reason: .itemChanged
        )])
        #expect(provider.requestCount == 0)
        #expect(FileManager.default.fileExists(atPath: archive.path) == false)
        #expect(try Data(contentsOf: source) == Data("replacement source".utf8))
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func destinationCollisionDoesNotReplaceExistingArchive() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Collision.txt")
        let archive = root.url.appending(path: "Collision.txt.zip")
        let sentinel = Data("pre-existing archive must survive".utf8)
        try Data("collision source".utf8).write(to: source)
        try sentinel.write(to: archive)

        // The listing intentionally omits the stale destination so the
        // controller's planner selects the colliding public name.
        let provider = E2ERecordingArchivePasswordProvider(passwords: ["collision-passphrase"])
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger()
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: source)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]

        #expect(await controller.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(controller)

        guard case .failed = controller.lastResult?.outcomes.first else {
            Issue.record("Expected protected archive destination collision to fail")
            return
        }
        #expect(try Data(contentsOf: archive) == sentinel)
        #expect(provider.requestCount == 1)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func cleanupFailurePublishesRecoveryOutcomeAndBlocksQueue() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Recovery.txt")
        let archive = root.url.appending(path: "Recovery.txt.zip")
        let passphrase = "recovery-passphrase"
        try Data("recovery source".utf8).write(to: source)

        let fileSystem = LiveFileSystemAccess()
        let preparer = E2EFaultingArchiveSourcePreparer(fileSystem: fileSystem, failures: 2)
        let provider = E2ERecordingArchivePasswordProvider(passwords: [passphrase])
        let controller = Self.makeControllerWithSourcePreparer(
            fileSystem: fileSystem,
            sourcePreparer: preparer,
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger()
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: source)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]

        #expect(await controller.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes == [.recoveryNeeded(source: source)])
        #expect(controller.lastResult?.undoDestinationIdentity(for: archive) != nil)
        #expect(controller.lastResult?.undoDestinationFingerprint(for: archive) != nil)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(controller.isQueueBlockedByRecovery)
        #expect(controller.operationHistory.first?.state == .failed)
        #expect(controller.operationHistory.first?.canRetry == false)
        let retainedRecoveryStaging = try archiveTestStagingDirectories(in: root.url)
        #expect(retainedRecoveryStaging.isEmpty == false)
        #expect(controller.continueAfterRecovery())
        #expect(controller.isQueueBlockedByRecovery == false)
        #expect(provider.requestCount == 1)
        // The injected failure models an unrecoverable cleanup boundary. The
        // published archive and recovery metadata remain available while the
        // temporary source-preparation reservation is intentionally retained
        // for an external recovery action.
    }

    @Test @MainActor func KoreanPublicNamesRemainVisibleWithoutPasswordLeakage() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let name = "보고서 비밀.txt"
        let source = root.url.appending(path: name)
        let archive = root.url.appending(path: "\(name).zip")
        let sentinel = "korean-public-sentinel"
        try Data("한국어 보호 ZIP".utf8).write(to: source)

        let logger = RecordingProtectedZIPLogger()
        let provider = E2ERecordingArchivePasswordProvider(passwords: [sentinel])
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: logger
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: source)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        #expect(await controller.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes == [
            .succeeded(source: source, destination: archive)
        ])
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(controller.observableTextForTesting.contains(name))
        #expect(controller.observableTextForTesting.contains(sentinel) == false)
        #expect(String(reflecting: await logger.events).contains(name))
        #expect(String(reflecting: await logger.events).contains(sentinel) == false)
        #expect(try Data(contentsOf: archive).range(of: Data(sentinel.utf8)) == nil)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func selectedSymlinkRoundTripsAsAContainedLink() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let target = root.url.appending(path: "target.txt")
        let link = root.url.appending(path: "링크")
        let archive = root.url.appending(path: "링크.zip")
        try Data("symlink target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target.lastPathComponent
        )

        let creator = E2ERecordingArchivePasswordProvider(passwords: ["symlink-passphrase"])
        let creatorController = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: creator,
            logger: RecordingProtectedZIPLogger()
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: link)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [link]
        #expect(await creatorController.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        ))
        await waitForControllerIdle(creatorController)
        #expect(creatorController.lastResult?.hasFailures == false)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.removeItem(at: target)
        let provider = E2ERecordingArchivePasswordProvider(passwords: ["symlink-passphrase"])
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger()
        )
        let extractionWorkspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: archive)]
        )
        await extractionWorkspace.loadInitialDirectories()
        extractionWorkspace.left.selection = [archive]
        #expect(await controller.extractSelection(extractionWorkspace))
        await waitForControllerIdle(controller)

        let extractedLink = root.url.appending(path: "링크/링크")
        #expect(controller.lastResult?.hasFailures == false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: extractedLink.path) == "target.txt")
        #expect(provider.requestCount == 1)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @Test @MainActor func cancellingDuringAuthenticatedEntryLeavesNoPublishedArchive() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "MidEntry.txt")
        let archive = root.url.appending(path: "MidEntry.txt.zip")
        try Data(repeating: 0x41, count: 64 * 1_024 * 1_024).write(to: source)

        let progressGate = MidEntryProgressGate()
        let engine = MidEntryCancellationEngine(
            inner: LiveProtectedZIPEngine(),
            gate: progressGate
        )
        let provider = E2ERecordingArchivePasswordProvider(passwords: ["mid-entry-passphrase"])
        let controller = Self.makeController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            passwordProvider: provider,
            logger: RecordingProtectedZIPLogger(),
            protectedEngine: engine
        )
        let workspace = Self.workspace(
            directory: root.url,
            items: [Self.fileItem(at: source)]
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        #expect(await controller.compressSelection(
            workspace,
            format: .zip,
            protection: .aes256
        ))
        await progressGate.waitUntilEntered()
        controller.cancelActiveJob()
        await progressGate.release()
        await waitForControllerIdle(controller)

        #expect(controller.lastResult?.outcomes == [.cancelled(source: source)])
        #expect(controller.operationHistory.first?.state == .cancelled)
        #expect(FileManager.default.fileExists(atPath: archive.path) == false)
        #expect(provider.requestCount == 1)
        try archiveTestExpectNoStagingDirectories(in: root.url)
    }

    @MainActor
    private static func workspace(directory: URL, items: [FileItem]) -> WorkspaceState {
        WorkspaceState(
            leftURL: directory,
            rightURL: directory,
            listingService: StubDirectoryListingService(values: [
                directory: items
            ])
        )
    }

    private static func fileItem(at url: URL) -> FileItem {
        FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "File"
        )
    }

    @MainActor
    private static func makeController(
        service: FileOperationService,
        passwordProvider: any ArchivePasswordProviding,
        logger: any ProtectedZIPLogging,
        materializer: any CloudMaterializing = InMemoryCloudMaterializer(),
        protectedEngine: any ProtectedZIPEngine = LiveProtectedZIPEngine()
    ) -> FileOperationController {
        let archiveService = service.makeRoutingArchiveOperationService(
            passwordProvider: passwordProvider,
            protectedEngine: protectedEngine,
            protectedLogger: logger
        )
        return FileOperationController(
            service: service,
            materializer: materializer,
            archiveService: archiveService
        )
    }

    @MainActor
    private static func makeControllerWithSourcePreparer(
        fileSystem: any FileSystemAccess,
        sourcePreparer: any ArchiveSourcePreparing,
        passwordProvider: any ArchivePasswordProviding,
        logger: any ProtectedZIPLogging
    ) -> FileOperationController {
        let service = FileOperationService(fileSystem: fileSystem)
        let ordinary = service.makeArchiveOperationService(
            commandRunner: LiveArchiveCommandRunner(
                fileSystem: fileSystem,
                sourcePreparer: sourcePreparer
            )
        )
        let protected = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: sourcePreparer,
            passwordProvider: passwordProvider,
            protectedEngine: LiveProtectedZIPEngine(),
            protectedLogger: logger
        )
        return FileOperationController(
            service: service,
            materializer: InMemoryCloudMaterializer(),
            archiveService: RoutingArchiveOperationService(
                ordinary: ordinary,
                protected: protected
            )
        )
    }

    private static func fixtureURL(_ filename: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ProtectedZIP")
            .appending(path: filename)
    }

    private static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct IdentityChangingArchiveMaterializer: CloudMaterializing {
    let url: URL
    let replacement: Data

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose _: CloudPreparationPurpose,
        progress _: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        try? FileManager.default.removeItem(at: url)
        try? replacement.write(to: url)
        return CloudMaterializationResult(
            preparedRequests: requests,
            failures: [],
            wasCancelled: false
        )
    }
}

actor MidEntryProgressGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    func holdOnFirstProcessingUpdate() async {
        guard !entered else { return }
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
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

struct MidEntryCancellationEngine: ProtectedZIPEngine {
    let inner: LiveProtectedZIPEngine
    let gate: MidEntryProgressGate

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        try await inner.inspect(archive: archive)
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        try await inner.preflight(
            archive: archive,
            destinationProbeRoot: destinationProbeRoot,
            limits: limits
        )
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        try await inner.createAES256(
            sourceRoot: sourceRoot,
            destination: destination,
            password: password,
            progress: { update in
                if update.completedByteCount > 0 {
                    await self.gate.holdOnFirstProcessingUpdate()
                }
                await progress(update)
            }
        )
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        try await inner.extract(
            archive: archive,
            destinationRoot: destinationRoot,
            password: password,
            limits: limits,
            progress: progress
        )
    }
}

private func writeMixedZipFixture(
    to destination: URL,
    plainName: String,
    plainBytes: Data,
    encryptedName: String,
    encryptedBytes: Data,
    password: String
) throws {
    struct Entry {
        let name: String
        let bytes: Data
        let encryptedBytes: Data
        let flags: UInt16
        let crc: UInt32
        let offset: UInt32
    }

    let plainCRC = mixedZIPCRC32(plainBytes)
    let encryptedCRC = mixedZIPCRC32(encryptedBytes)
    let encryptedPayload = mixedZIPCryptoPayload(
        encryptedBytes,
        password: password,
        crc: encryptedCRC
    )
    var archive = Data()
    var entries: [Entry] = []

    func appendLocal(
        name: String,
        payload: Data,
        flags: UInt16,
        crc: UInt32,
        uncompressedCount: Int
    ) throws -> UInt32 {
        let offset = UInt32(archive.count)
        let nameBytes = Array(name.utf8)
        guard nameBytes.count <= Int(UInt16.max),
              payload.count <= Int(UInt32.max),
              uncompressedCount <= Int(UInt32.max)
        else { throw NSError(domain: "MixedZIPFixture", code: 1) }
        archive.appendLE(UInt32(0x04034b50))
        archive.appendLE(UInt16(20))
        archive.appendLE(flags)
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(crc)
        archive.appendLE(UInt32(payload.count))
        archive.appendLE(UInt32(uncompressedCount))
        archive.appendLE(UInt16(nameBytes.count))
        archive.appendLE(UInt16(0))
        archive.append(contentsOf: nameBytes)
        archive.append(payload)
        return offset
    }

    let plainOffset = try appendLocal(
        name: plainName,
        payload: plainBytes,
        flags: 0,
        crc: plainCRC,
        uncompressedCount: plainBytes.count
    )
    entries.append(Entry(
        name: plainName,
        bytes: plainBytes,
        encryptedBytes: plainBytes,
        flags: 0,
        crc: plainCRC,
        offset: plainOffset
    ))
    let encryptedOffset = try appendLocal(
        name: encryptedName,
        payload: encryptedPayload,
        flags: 1,
        crc: encryptedCRC,
        uncompressedCount: encryptedBytes.count
    )
    entries.append(Entry(
        name: encryptedName,
        bytes: encryptedBytes,
        encryptedBytes: encryptedPayload,
        flags: 1,
        crc: encryptedCRC,
        offset: encryptedOffset
    ))

    let centralOffset = UInt32(archive.count)
    for entry in entries {
        let nameBytes = Array(entry.name.utf8)
        archive.appendLE(UInt32(0x02014b50))
        archive.appendLE(UInt16(20))
        archive.appendLE(UInt16(20))
        archive.appendLE(entry.flags)
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(entry.crc)
        archive.appendLE(UInt32(entry.encryptedBytes.count))
        archive.appendLE(UInt32(entry.bytes.count))
        archive.appendLE(UInt16(nameBytes.count))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt32(0x81a40000))
        archive.appendLE(entry.offset)
        archive.append(contentsOf: nameBytes)
    }
    let centralSize = UInt32(archive.count) - centralOffset
    archive.appendLE(UInt32(0x06054b50))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(entries.count))
    archive.appendLE(UInt16(entries.count))
    archive.appendLE(centralSize)
    archive.appendLE(centralOffset)
    archive.appendLE(UInt16(0))
    try archive.write(to: destination)
}

private struct MixedZIPCryptoState {
    private var key0: UInt32 = 0x12345678
    private var key1: UInt32 = 0x23456789
    private var key2: UInt32 = 0x34567890

    mutating func update(_ byte: UInt8) {
        key0 = mixedZIPCRCUpdate(key0, byte)
        key1 = key1 &+ (key0 & 0xff)
        key1 = key1 &* 134_775_813 &+ 1
        key2 = mixedZIPCRCUpdate(key2, UInt8((key1 >> 24) & 0xff))
    }

    mutating func encrypt(_ bytes: [UInt8]) -> Data {
        var result = Data(capacity: bytes.count)
        for byte in bytes {
            let temporary = key2 | 2
            let stream = UInt8(((temporary &* (temporary ^ 1)) >> 8) & 0xff)
            result.append(byte ^ stream)
            update(byte)
        }
        return result
    }
}

private func mixedZIPCryptoPayload(
    _ bytes: Data,
    password: String,
    crc: UInt32
) -> Data {
    var state = MixedZIPCryptoState()
    for byte in password.utf8 { state.update(byte) }
    let header = Array(0..<11).map { UInt8(0x31 + $0) }
        + [UInt8((crc >> 24) & 0xff)]
    var result = state.encrypt(header)
    result.append(state.encrypt(Array(bytes)))
    return result
}

private func mixedZIPCRC32(_ data: Data) -> UInt32 {
    var result: UInt32 = 0xffffffff
    for byte in data {
        result = mixedZIPCRCUpdate(result, byte)
    }
    return ~result
}

private func mixedZIPCRCUpdate(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
    var result = crc ^ UInt32(byte)
    for _ in 0..<8 {
        result = result & 1 == 0
            ? result >> 1
            : (result >> 1) ^ 0xedb88320
    }
    return result
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

enum ProtectedFixture: String, CaseIterable, Sendable {
    case aes128
    case aes192
    case aes256
    case aesPasswordOne
    case aesPassword257
    case aesPassword1024
    case zipCrypto

    var filename: String {
        switch self {
        case .aes128: "minizip-aes128.zip"
        case .aes192: "minizip-aes192.zip"
        case .aes256: "7zip-aes256.zip"
        case .aesPasswordOne: "aes-password-1.zip"
        case .aesPassword257: "aes-password-257.zip"
        case .aesPassword1024: "aes-password-1024.zip"
        case .zipCrypto: "infozip-zipcrypto.zip"
        }
    }

    var stem: String { String(filename.dropLast(4)) }

    var password: String {
        switch self {
        case .aes128: "fixture-aes128-passphrase"
        case .aes192: "fixture-aes192-passphrase"
        case .aes256: "fixture-aes256-passphrase"
        case .aesPasswordOne: String(repeating: "p", count: 1)
        case .aesPassword257: String(repeating: "p", count: 257)
        case .aesPassword1024: String(repeating: "p", count: 1_024)
        case .zipCrypto: "fixture-zipcrypto-password"
        }
    }

    var entry: String {
        switch self {
        case .aes256: "자료.txt"
        case .zipCrypto: "Legacy.txt"
        default: "Strength.txt"
        }
    }

    var bytes: Data {
        switch self {
        case .aes256: Data("7-Zip AES-256 compatibility fixture\n".utf8)
        case .zipCrypto: Data("Info-ZIP ZipCrypto compatibility fixture\n".utf8)
        default: Data("AES compatibility fixture\n".utf8)
        }
    }

    var sha256: String {
        switch self {
        case .aes256: "136ca9275ad091af11e700886d0afb41d9be0c04804df22bdb39b098fed3f99c"
        case .aes128: "b02a342fd9c6694155d7ee87c9e1eff12c2bdd69ac8dd23979db2085943efb75"
        case .aes192: "6e501670d5e2259400b28f0f126ae257f17af125841fc08010e9112d5084c91e"
        case .aesPasswordOne: "0d6dca4bc5923cdeb23c6a3120c304376879826c6f7c831bb40fe18983c8ff6e"
        case .aesPassword257: "d3c81a181b198de65bd64e7e58b7de4022c69572af8b57a53ef070979ce7930e"
        case .aesPassword1024: "95f64f040e506e695e9e94074827bf2a793b1595dac1ea6e0576d17e9409eb87"
        case .zipCrypto: "e9bcc8168d54002f0c8b0176db37b456e79864e6ebe3a89e259ad462c9a5ff0c"
        }
    }
}

@MainActor
private func waitForControllerIdle(_ controller: FileOperationController) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if !controller.isRunning { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for file operation controller")
}
