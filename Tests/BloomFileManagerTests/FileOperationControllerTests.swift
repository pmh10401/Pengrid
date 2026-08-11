import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FileOperationControllerTests {
    @Test func duplicateQueuesASeparateKeepBothJobAndSelectsOnlyCapturedParentOutputs() async throws {
        let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/other", directoryHint: .isDirectory)
        let source = parent.appending(path: "Report.txt")
        let item = FileItem(
            url: source,
            name: "Report.txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: .distantPast,
            byteSize: 12,
            typeDescription: "Text"
        )
        let fileSystem = RecordingFileSystem(existingURLs: [parent, opposite, source])
        let workspace = WorkspaceState(
            leftURL: parent,
            rightURL: opposite,
            listingService: StubDirectoryListingService(values: [parent: [item], opposite: []])
        )
        await workspace.loadInitialDirectories()
        let sourceIdentity = try #require(await fileSystem.identity(of: source))
        let parentIdentity = try #require(await fileSystem.identity(of: parent))
        let oppositeIdentity = try #require(await fileSystem.identity(of: opposite))
        let snapshot = ContextActionSnapshot(
            draft: ContextActionDraft(
                sources: [item],
                sourcePaneID: .left,
                oppositePaneID: .right,
                sourceDirectory: parent,
                oppositeDirectory: opposite,
                sourceCapability: .writable,
                oppositeCapability: .readOnly
            )!,
            sources: [ContextActionSource(item: item, identity: sourceIdentity)],
            sourceDirectory: IdentifiedFileRequest(url: parent, identity: parentIdentity),
            oppositeDirectory: IdentifiedFileRequest(url: opposite, identity: oppositeIdentity)
        )!
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: InMemoryCloudMaterializer()
        )

        #expect(controller.duplicate(snapshot, in: workspace.left, workspace: workspace))
        #expect(controller.activeJob?.kind == .duplicate)
        #expect(controller.activeJob?.title == "Duplicate")
        await waitUntilQueueIsIdle(controller)

        let destination = parent.appending(path: "Report 2.txt")
        let job = try #require(controller.operationHistory.first)
        #expect(job.state == .succeeded)
        #expect(job.canUndo)
        #expect(workspace.left.selection == [destination])
        #expect(await fileSystem.existingURLs.contains(destination))
    }

    @Test func duplicatePartialFailureKeepsStableOrderAndNeverOffersGroupUndo() async throws {
        let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/other", directoryHint: .isDirectory)
        let first = parent.appending(path: "First.txt")
        let second = parent.appending(path: "Second.txt")
        let firstItem = FileItem(
            url: first, name: "First.txt", isDirectory: false, isPackage: false,
            modifiedAt: .distantPast, byteSize: 1, typeDescription: "Text"
        )
        let secondItem = FileItem(
            url: second, name: "Second.txt", isDirectory: false, isPackage: false,
            modifiedAt: .distantPast, byteSize: 1, typeDescription: "Text"
        )
        let copyFailure = CocoaError(.fileWriteUnknown)
        let fileSystem = RecordingFileSystem(
            existingURLs: [parent, opposite, first, second],
            copyErrorsBySource: [first: copyFailure]
        )
        let workspace = WorkspaceState(
            leftURL: parent,
            rightURL: opposite,
            listingService: StubDirectoryListingService(values: [
                parent: [firstItem, secondItem], opposite: []
            ])
        )
        await workspace.loadInitialDirectories()
        let parentIdentity = try #require(await fileSystem.identity(of: parent))
        let oppositeIdentity = try #require(await fileSystem.identity(of: opposite))
        let snapshot = ContextActionSnapshot(
            draft: ContextActionDraft(
                sources: [firstItem, secondItem], sourcePaneID: .left, oppositePaneID: .right,
                sourceDirectory: parent, oppositeDirectory: opposite,
                sourceCapability: .writable, oppositeCapability: .readOnly
            )!,
            sources: [
                ContextActionSource(item: firstItem, identity: try #require(await fileSystem.identity(of: first))),
                ContextActionSource(item: secondItem, identity: try #require(await fileSystem.identity(of: second)))
            ],
            sourceDirectory: IdentifiedFileRequest(url: parent, identity: parentIdentity),
            oppositeDirectory: IdentifiedFileRequest(url: opposite, identity: oppositeIdentity)
        )!
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: InMemoryCloudMaterializer()
        )

        #expect(controller.duplicate(snapshot, in: workspace.left, workspace: workspace))
        await waitUntilQueueIsIdle(controller)

        let completedSecond = parent.appending(path: "Second 2.txt")
        #expect(controller.lastResult?.outcomes == [
            .failed(source: first, message: copyFailure.localizedDescription),
            .succeeded(source: second, destination: completedSecond)
        ])
        let job = try #require(controller.operationHistory.first)
        #expect(job.state == .failed)
        #expect(job.canUndo == false)
        #expect(controller.undoJob(job.id) == false)
    }

    @Test func legacyCompressionMethodValueRemainsTwoArgumentCallable() async throws {
        let fixture = await makeProtectedWorkspace()
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fixture.fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )
        let legacy: @MainActor (WorkspaceState, ArchiveFormat) async -> Bool =
            controller.compressSelection

        #expect(await legacy(fixture.workspace, .zip))
        await waitUntilIdle(controller)
        #expect(await archiveService.recordedRequests().count == 1)
        #expect(await archiveService.recordedRequests().first?.protection == ArchiveProtection.none)
    }

    @Test func archivePreparationPublicationIsLimitedToTenHertzExceptBoundaries() {
        var gate = ArchiveProgressPublicationGate()
        let start = ContinuousClock.now

        let initial = gate.shouldPublish(completedCount: 0, totalCount: 20, at: start)
        let duplicateInitial = gate.shouldPublish(
            completedCount: 0,
            totalCount: 20,
            at: start.advanced(by: .milliseconds(1))
        )
        let early = gate.shouldPublish(
            completedCount: 1,
            totalCount: 20,
            at: start.advanced(by: .milliseconds(50))
        )
        let interval = gate.shouldPublish(
            completedCount: 2,
            totalCount: 20,
            at: start.advanced(by: .milliseconds(100))
        )
        let final = gate.shouldPublish(
            completedCount: 20,
            totalCount: 20,
            at: start.advanced(by: .milliseconds(101))
        )
        let duplicateFinal = gate.shouldPublish(
            completedCount: 20,
            totalCount: 20,
            at: start.advanced(by: .milliseconds(102))
        )

        #expect(initial)
        #expect(!duplicateInitial)
        #expect(!early)
        #expect(interval)
        #expect(final)
        #expect(!duplicateFinal)
    }

    @Test func compressionUsesTheRequestedArchiveFormat() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let source = directory.appending(path: "Project Notes")
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [fileItem(at: source)],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [directory, source])
            ),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )

        #expect(await controller.compressSelection(workspace, format: .tarGzip))
        await waitUntilIdle(controller)

        let requests = await archiveService.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.kind == .compress)
        #expect(requests.first?.verifiedSources.map(\.url) == [source])
        #expect(requests.first?.finalDestination == directory.appending(path: "Project Notes.tar.gz"))
        #expect(requests.first?.progressDisplayName == "Project Notes.tar.gz")
        #expect(requests.first?.format == .tarGzip)
    }

    @Test func compressionUsesDisplayNameAndKeepBothDestination() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let source = directory.appending(path: "provider-token")
        let existingArchive = directory.appending(path: "Project Notes.zip")
        let selectedItem = FileItem(
            url: source,
            name: "Project Notes",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Document"
        )
        let listingService = StubDirectoryListingService(values: [
            directory: [
                selectedItem,
                fileItem(at: existingArchive)
            ],
            otherDirectory: []
        ])
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: listingService
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [directory, source])
            ),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )

        #expect(await controller.compressSelection(workspace))
        await waitUntilIdle(controller)

        let requests = await archiveService.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.kind == .compress)
        #expect(requests.first?.verifiedSources.map(\.url) == [source])
        #expect(requests.first?.finalDestination == directory.appending(path: "Project Notes 2.zip"))
        #expect(requests.first?.format == .zip)
        #expect(requests.first?.progressDisplayName == "Project Notes 2.zip")
    }

    @Test func protectedCompressionQueuesSafeMetadataAndUsesEncryptedTitle() async throws {
        let fixture = await makeProtectedWorkspace()
        let passwordCoordinator = ArchivePasswordPromptCoordinator()
        let archiveOperator = ControllerProtectedArchiveOperator(
            passwordProvider: passwordCoordinator,
            mode: .promptAndWait
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fixture.fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveOperator
        )

        #expect(await controller.compressSelection(
            fixture.workspace,
            format: .zip,
            protection: .aes256
        ))
        let waiting = await waitUntilBounded {
            controller.activeJob?.state == .waitingForPassword
        }
        #expect(waiting)
        #expect(controller.activeJob?.kind == .compressProtectedZIP)
        #expect(controller.activeJob?.title == "Compress Encrypted ZIP")
        #expect(controller.activeJob?.progress?.detail == "Waiting for password")
        #expect(await archiveOperator.recordedRequests().first?.protection == .aes256)

        #expect(await controller.compressSelection(
            fixture.workspace,
            format: .zip,
            protection: .aes256
        ))
        let queued = try #require(controller.queuedJobs.first)
        #expect(queued.kind == .compressProtectedZIP)
        #expect(queued.title == "Compress Encrypted ZIP")
        let visible = (controller.queuedJobs + controller.operationHistory)
            .map { "\($0.title)|\($0.itemDisplayName)|\($0.state.label)|\($0.accessibilityLabel)" }
            .joined(separator: "\n")
        #expect(!visible.contains(ControllerProtectedArchiveOperator.sentinel))

        controller.cancelActiveJob()
        #expect(await waitUntilBounded { controller.operationHistory.count == 1 })
        controller.cancelActiveJob()
        #expect(await waitUntilBounded { !controller.isRunning && controller.queuedJobs.isEmpty })
    }

    @Test func protectedAES256CompressionRejectsTARWithoutStartingAnOperation() async {
        let fixture = await makeProtectedWorkspace()
        let archiveOperator = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fixture.fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveOperator
        )

        let accepted = await controller.compressSelection(
            fixture.workspace,
            format: .tarGzip,
            protection: .aes256
        )
        #expect(!accepted)
        #expect(!controller.isRunning)
        #expect(controller.activeJob == nil)
        #expect(controller.queuedJobs.isEmpty)
        #expect(controller.operationHistory.isEmpty)
        #expect(await archiveOperator.recordedRequests().isEmpty)
    }

    @Test func protectedArchiveWaitingDisablesPauseAndBoundsByteProgress() async {
        let fixture = await makeProtectedWorkspace()
        let archiveOperator = ControllerProtectedArchiveOperator(mode: .waitingThenBytes)
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fixture.fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveOperator
        )

        #expect(await controller.compressSelection(
            fixture.workspace,
            format: .zip,
            protection: .aes256
        ))
        #expect(await waitUntilBounded {
            controller.activeJob?.state == .waitingForPassword
        })
        await controller.pauseActiveJob()
        #expect(controller.isPaused == false)
        #expect(controller.activeJob?.state == .waitingForPassword)

        #expect(await waitUntilBounded { await archiveOperator.didEmitBytes })
        #expect(await waitUntilBounded {
            controller.activeJob?.state == .running
                && controller.activeJob?.progress?.completedCount == 10
                && controller.activeJob?.progress?.totalCount == 10
        })

        controller.cancelActiveJob()
        #expect(await waitUntilBounded { !controller.isRunning })
        #expect(controller.operationHistory.first?.state == .cancelled)
    }

    @Test func cancellingProtectedPromptDismissesCoordinatorAndReturnsToHistory() async {
        let fixture = await makeProtectedWorkspace()
        let passwordCoordinator = ArchivePasswordPromptCoordinator()
        let archiveOperator = ControllerProtectedArchiveOperator(
            passwordProvider: passwordCoordinator,
            mode: .promptAndWait
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fixture.fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveOperator
        )

        #expect(await controller.compressSelection(
            fixture.workspace,
            format: .zip,
            protection: .aes256
        ))
        #expect(await waitUntilBounded { passwordCoordinator.pendingRequest != nil })
        controller.cancelActiveJob()
        #expect(await waitUntilBounded { !controller.isRunning })
        #expect(passwordCoordinator.pendingRequest == nil)
        #expect(controller.operationHistory.first?.state == .cancelled)
    }

    @Test func failedProtectedAttemptRetriesWithFreshPromptWithoutSecretOrUndo() async throws {
        let fixture = await makeProtectedWorkspace()
        let passwordCoordinator = ArchivePasswordPromptCoordinator()
        let archiveOperator = ControllerProtectedArchiveOperator(
            passwordProvider: passwordCoordinator,
            mode: .promptAndFail
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fixture.fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveOperator
        )

        #expect(await controller.compressSelection(
            fixture.workspace,
            format: .zip,
            protection: .aes256
        ))
        #expect(await waitUntilBounded { passwordCoordinator.pendingRequest != nil })
        let firstRequestID = try #require(passwordCoordinator.pendingRequest?.id)
        passwordCoordinator.submit(
            password: ControllerProtectedArchiveOperator.sentinel,
            confirmation: ControllerProtectedArchiveOperator.sentinel,
            requestID: firstRequestID
        )
        #expect(await waitUntilBounded { !controller.isRunning })
        let failed = try #require(controller.operationHistory.first)
        #expect(failed.state == .failed)
        #expect(failed.canRetry)
        #expect(!failed.canUndo)

        #expect(controller.retryJob(failed.id))
        #expect(await waitUntilBounded { passwordCoordinator.pendingRequest != nil })
        let secondRequestID = try #require(passwordCoordinator.pendingRequest?.id)
        #expect(secondRequestID != firstRequestID)
        let visible = (controller.queuedJobs + controller.operationHistory)
            .map { "\($0.title)|\($0.itemDisplayName)|\($0.state.label)|\($0.accessibilityLabel)" }
            .joined(separator: "\n")
        #expect(!visible.contains(ControllerProtectedArchiveOperator.sentinel))

        controller.cancelActiveJob()
        #expect(await waitUntilBounded { !controller.isRunning })
    }

    @Test func multipleItemsCompressToTheFirstAvailableArchiveName() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let first = directory.appending(path: "First.txt")
        let second = directory.appending(path: "Second.txt")
        let items = [
            fileItem(at: first),
            fileItem(at: second),
            fileItem(at: directory.appending(path: "Archive.zip")),
            fileItem(at: directory.appending(path: "Archive 2.zip"))
        ]
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: items,
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [second, first]
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [directory, first, second])
            ),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )

        #expect(await controller.compressSelection(workspace))
        await waitUntilIdle(controller)

        let requests = await archiveService.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.kind == .compress)
        #expect(requests.first?.verifiedSources.map(\.url) == [first, second])
        #expect(requests.first?.finalDestination == directory.appending(path: "Archive 3.zip"))
        #expect(requests.first?.progressDisplayName == "Archive 3.zip")
        #expect(requests.first?.format == .zip)
    }

    @Test func eachSelectedZIPExtractsIntoItsOwnAvailableStemFolder() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let first = directory.appending(path: "First.zip")
        let second = directory.appending(path: "Second.ZIP")
        let items = [
            fileItem(at: first),
            fileItem(at: second),
            fileItem(at: directory.appending(path: "First")),
            fileItem(at: directory.appending(path: "First 2")),
            fileItem(at: directory.appending(path: "Second"))
        ]
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: items,
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [second, first]
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [directory, first, second])
            ),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )

        #expect(await controller.extractSelection(workspace))
        await waitUntilIdle(controller)

        let requests = await archiveService.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.map(\.kind) == [.extract, .extract])
        #expect(requests.map { $0.verifiedSources.map(\.url) } == [[first], [second]])
        #expect(requests.map(\.finalDestination) == [
            directory.appending(path: "First 3", directoryHint: .isDirectory),
            directory.appending(path: "Second 2", directoryHint: .isDirectory)
        ])
        #expect(requests.map(\.progressDisplayName) == ["First.zip", "Second.ZIP"])
        #expect(requests.map(\.format) == [.zip, .zip])
    }

    @Test func extractionKeepsSelectedZIPDisplayNameAcrossEveryServicePhase() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "provider-token")
        let otherDirectory = root.url.appending(path: "other", directoryHint: .isDirectory)
        try Data("archive".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: otherDirectory,
            withIntermediateDirectories: false
        )
        let selectedItem = FileItem(
            url: source,
            name: "Backup.zip",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "ZIP archive"
        )
        let workspace = WorkspaceState(
            leftURL: root.url,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                root.url: [selectedItem],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let fileSystem = LiveFileSystemAccess()
        let archiveService = GatedControllerArchiveOperator(underlying: ArchiveOperationService(
            fileSystem: fileSystem,
            commandRunner: CompletingControllerArchiveCommandRunner()
        ))
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )

        let didStart = await controller.extractSelection(workspace)
        #expect(didStart)
        guard didStart else { return }
        let expectedStage = FileOperationStage.archiving(ArchiveOperationProgress(
            kind: .extract,
            currentDisplayName: "Backup.zip"
        ))
        await archiveService.waitUntilStarted()
        #expect(controller.stage == expectedStage)

        await controller.pauseActiveJob()
        #expect(controller.activeJob?.state == .pauseRequested)
        await archiveService.proceed()
        await waitUntil { controller.isPaused }
        #expect(controller.activeJob?.state == .paused)
        await controller.resumeActiveJob()
        await waitUntilIdle(controller)
        #expect(controller.stage == .archiving(ArchiveOperationProgress(
            kind: .extract,
            currentDisplayName: "Backup.zip",
            phase: .publishing
        )))
        #expect(await archiveService.recordedProgress() == [
            ArchiveOperationProgress(
                kind: .extract,
                currentDisplayName: "Backup.zip"
            ),
            ArchiveOperationProgress(
                kind: .extract,
                currentDisplayName: "Backup.zip",
                phase: .publishing
            )
        ])
        #expect(FileManager.default.fileExists(
            atPath: root.url.appending(
                path: "Backup",
                directoryHint: .isDirectory
            ).path
        ))
    }

    @Test func archiveServiceWaitsForArchivePurposeMaterialization() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let source = directory.appending(path: "cloud.txt")
        let item = fileItem(at: source, availability: .onlineOnly)
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [item],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let materializer = SuspendingArchiveMaterializer()
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [directory, source])
            ),
            materializer: materializer,
            archiveService: archiveService
        )

        #expect(await controller.compressSelection(workspace))
        await materializer.waitUntilStarted()

        #expect(await archiveService.recordedRequests().isEmpty)
        let purpose = await materializer.recordedPurpose()
        guard case .archive = purpose else {
            Issue.record("Archive preparation used the wrong cloud purpose")
            await materializer.resume()
            return
        }

        await materializer.resume()
        await waitUntilIdle(controller)
        #expect(await archiveService.recordedRequests().first?.verifiedSources.map(\.url) == [source])
    }

    @Test func cancellationDuringArchivePreparationPreventsArchiveWork() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let source = directory.appending(path: "cloud.txt")
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [fileItem(at: source, availability: .onlineOnly)],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let materializer = SuspendingArchiveMaterializer()
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [directory, source])
            ),
            materializer: materializer,
            archiveService: archiveService
        )

        #expect(await controller.compressSelection(workspace))
        await materializer.waitUntilStarted()
        controller.cancel()
        await materializer.resume()
        await waitUntilIdle(controller)

        #expect(await archiveService.recordedRequests().isEmpty)
        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .cancelled(source: source)
        ]))
    }

    @Test func changedIdentityAfterArchivePreparationPreventsArchiveWork() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let source = directory.appending(path: "cloud.txt")
        let capturedIdentity = FileIdentity(
            entryIdentifier: "captured",
            resolvedIdentifier: "captured"
        )
        let replacementIdentity = FileIdentity(
            entryIdentifier: "replacement",
            resolvedIdentifier: "replacement"
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [fileItem(at: source, availability: .onlineOnly)],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let fileSystem = RecordingFileSystem(
            existingURLs: [directory, source],
            identities: [source: capturedIdentity]
        )
        let materializer = IdentityReplacingArchiveMaterializer(
            fileSystem: fileSystem,
            source: source,
            replacementIdentity: replacementIdentity
        )
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: materializer,
            archiveService: archiveService
        )

        #expect(await controller.compressSelection(workspace))
        await waitUntilIdle(controller)

        #expect(await archiveService.recordedRequests().isEmpty)
        #expect(controller.lastPreparationFailures == [
            CloudMaterializationFailure(name: "cloud.txt", reason: .itemChanged)
        ])
    }

    @Test func replacementBeforeArchiveOperationTaskNeverReachesArchiveService() async throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let directory = temporaryDirectory.url
        let otherDirectory = directory.appending(
            path: "Other",
            directoryHint: .isDirectory
        )
        let source = directory.appending(path: "Selected.txt")
        try Data("selected".utf8).write(to: source)
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [fileItem(at: source)],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess()),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )

        #expect(await controller.compressSelection(workspace))
        try FileManager.default.removeItem(at: source)
        try Data("replacement".utf8).write(to: source)
        await waitUntilIdle(controller)

        #expect(await archiveService.recordedRequests().isEmpty)
    }

    @Test func invalidExtractionSelectionsAreRejectedBeforeOperationStart() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let zipDirectory = directory.appending(path: "Folder.zip", directoryHint: .isDirectory)
        let archive = directory.appending(path: "Archive.zip")
        let text = directory.appending(path: "notes.txt")
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [
                    fileItem(at: zipDirectory, isDirectory: true),
                    fileItem(at: archive),
                    fileItem(at: text)
                ],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        let archiveService = RecordingArchiveOperator()
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(
                    existingURLs: [directory, zipDirectory, archive, text]
                )
            ),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )

        #expect(await controller.extractSelection(workspace) == false)
        workspace.left.selection = [zipDirectory]
        #expect(await controller.extractSelection(workspace) == false)
        workspace.left.selection = [archive, text]
        #expect(await controller.extractSelection(workspace) == false)

        #expect(controller.isRunning == false)
        #expect(await archiveService.recordedRequests().isEmpty)
    }

    @Test func archiveSuccessRefreshesOnlyPanesShowingTheDestinationFolder() async {
        let directory = URL(filePath: "/workspace")
        let otherDirectory = URL(filePath: "/other")
        let source = directory.appending(path: "Item.txt")
        let listingService = ArchiveRequestRecordingListingService(values: [
            directory: [fileItem(at: source)],
            otherDirectory: []
        ])
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: listingService
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [directory, source])
            ),
            materializer: InMemoryCloudMaterializer(),
            archiveService: RecordingArchiveOperator()
        )

        #expect(await controller.compressSelection(workspace))
        await waitUntilIdle(controller)

        #expect(await listingService.requestCount(for: directory) == 2)
        #expect(await listingService.requestCount(for: otherDirectory) == 1)
    }

    @Test func conflictWaitsForExplicitUserDecision() async {
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem())
        )
        let conflict = FileConflict(
            source: URL(filePath: "/a"),
            proposedDestination: URL(filePath: "/b/a")
        )

        let task = Task { await controller.requestDecision(for: conflict) }
        await Task.yield()

        #expect(controller.pendingConflict == conflict)
        controller.resolvePendingConflict(.skip, applyToAll: false)
        #expect(await task.value == .skip)
    }

    @Test func applyToAllReusesDecisionWithoutAnotherSheet() async {
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem())
        )
        let first = FileConflict(
            source: URL(filePath: "/a"),
            proposedDestination: URL(filePath: "/dest/a")
        )
        let firstTask = Task { await controller.requestDecision(for: first) }
        await Task.yield()

        controller.resolvePendingConflict(.keepBoth, applyToAll: true)
        #expect(await firstTask.value == .keepBoth)

        let second = FileConflict(
            source: URL(filePath: "/b"),
            proposedDestination: URL(filePath: "/dest/b")
        )
        #expect(await controller.requestDecision(for: second) == .keepBoth)
        #expect(controller.pendingConflict == nil)
    }

    @Test func cancelResumesAWaitingConflictAsCancel() async {
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem())
        )
        let conflict = FileConflict(
            source: URL(filePath: "/source/item"),
            proposedDestination: URL(filePath: "/destination/item")
        )
        let task = Task { await controller.requestDecision(for: conflict) }
        await Task.yield()

        controller.cancel()

        #expect(await task.value == .cancel)
        #expect(controller.pendingConflict == nil)
    }

    @Test func cancellationAtTheDestinationIdentityGateNeverPresentsAConflict() async {
        let source = URL(filePath: "/source/item")
        let destinationDirectory = URL(filePath: "/destination")
        let destination = destinationDirectory.appending(path: "item")
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(
                    existingURLs: [source, destinationDirectory, destination],
                    cancelAfterIdentityOf: destination
                )
            )
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )

        var observedConflict: FileConflict?
        for _ in 0..<200 {
            observedConflict = controller.pendingConflict
            if observedConflict != nil || !controller.isRunning { break }
            await Task.yield()
        }
        if controller.pendingConflict != nil {
            controller.cancel()
        }
        await waitUntilIdle(controller)

        #expect(observedConflict == nil)
        #expect(controller.pendingConflict == nil)
        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .cancelled(source: source)
        ]))
    }

    @Test func requestDecisionOnAnAlreadyCancelledTaskReturnsCancelWithoutPendingState() async {
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem())
        )
        let conflict = FileConflict(
            source: URL(filePath: "/source/item"),
            proposedDestination: URL(filePath: "/destination/item")
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await controller.requestDecision(for: conflict)
        }

        var observedPendingConflict = false
        for _ in 0..<200 {
            if controller.pendingConflict != nil {
                observedPendingConflict = true
                controller.cancel()
                break
            }
            await Task.yield()
        }
        let decision = await task.value

        #expect(decision == .cancel)
        #expect(observedPendingConflict == false)
        #expect(controller.pendingConflict == nil)
    }

    @Test func secondUnresolvedDecisionCannotReplaceTheFirstContinuation() async {
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem())
        )
        let first = FileConflict(
            source: URL(filePath: "/source/first"),
            proposedDestination: URL(filePath: "/destination/first")
        )
        let second = FileConflict(
            source: URL(filePath: "/source/second"),
            proposedDestination: URL(filePath: "/destination/second")
        )
        let firstTask = Task { await controller.requestDecision(for: first) }
        await Task.yield()

        let secondDecision = await controller.requestDecision(for: second)

        #expect(secondDecision == .cancel)
        #expect(controller.pendingConflict == first)
        controller.resolvePendingConflict(.skip, applyToAll: false)
        #expect(await firstTask.value == .skip)
    }

    @Test func transferPublishesProgressAndRefreshesOnlyTouchedVisibleDirectories() async {
        let source = URL(filePath: "/source/item")
        let destinationDirectory = URL(filePath: "/destination")
        let untouchedDirectory = URL(filePath: "/untouched")
        let fileSystem = RecordingFileSystem(existingURLs: [source, destinationDirectory])
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let listingService = RequestRecordingListingService()
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: untouchedDirectory,
            listingService: listingService
        )
        await workspace.loadInitialDirectories()

        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitUntilIdle(controller)

        #expect(controller.progress == FileOperationProgress(
            completedCount: 1,
            totalCount: 1,
            currentName: "item"
        ))
        #expect(controller.stage == .operating(FileOperationProgress(
            completedCount: 1,
            totalCount: 1,
            currentName: "item"
        )))
        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .succeeded(
                source: source,
                destination: destinationDirectory.appending(path: "item")
            )
        ]))
        #expect(await listingService.requestCount(for: destinationDirectory) == 2)
        #expect(await listingService.requestCount(for: untouchedDirectory) == 1)
    }

    @Test func capturedTransferUsesItsImmutableDestinationAndOrdinaryCopyPipeline() async {
        let source = URL(filePath: "/source/report.txt")
        let capturedDestination = URL(filePath: "/captured-destination", directoryHint: .isDirectory)
        let initialOtherPaneDestination = URL(filePath: "/initial-other-pane", directoryHint: .isDirectory)
        let liveOtherPaneDestination = URL(filePath: "/later-navigation", directoryHint: .isDirectory)
        let sourceIdentity = FileIdentity(entryIdentifier: "source", resolvedIdentifier: "source")
        let destinationIdentity = FileIdentity(
            entryIdentifier: "captured-destination",
            resolvedIdentifier: "captured-destination"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [
                source, capturedDestination, initialOtherPaneDestination, liveOtherPaneDestination
            ],
            identities: [
                source: sourceIdentity,
                capturedDestination: destinationIdentity
            ]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let listingService = RequestRecordingListingService()
        let workspace = WorkspaceState(
            leftURL: capturedDestination,
            rightURL: initialOtherPaneDestination,
            listingService: listingService
        )
        await workspace.loadInitialDirectories()
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: sourceIdentity,
            destinationRoot: capturedDestination,
            destinationRootIdentity: destinationIdentity,
            relativeParentComponents: []
        )
        await workspace.right.navigate(to: liveOtherPaneDestination)

        #expect(controller.transferToCapturedDirectory([request], mode: .copy, workspace: workspace))
        await waitUntilIdle(controller)

        let copied = capturedDestination.appending(path: "report.txt")
        #expect(await fileSystem.existingURLs.contains(copied))
        #expect(await !fileSystem.existingURLs.contains(
            liveOtherPaneDestination.appending(path: "report.txt")
        ))
        #expect(await listingService.requestCount(for: capturedDestination) == 2)
        #expect(controller.operationHistory.first?.canUndo == true)
        #expect(controller.undoJob(controller.operationHistory.first!.id))
        await waitUntilIdle(controller)
        #expect(await !fileSystem.existingURLs.contains(copied))
    }

    @Test func transferCollisionRemainsRunningUntilThePendingConflictIsResolved() async {
        let source = URL(filePath: "/source/item")
        let destinationDirectory = URL(filePath: "/destination")
        let destination = destinationDirectory.appending(path: "item")
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(
                    existingURLs: [source, destinationDirectory, destination]
                )
            )
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)

        #expect(controller.isRunning)
        #expect(controller.pendingConflict == FileConflict(
            source: source,
            proposedDestination: destination
        ))

        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilIdle(controller)

        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .skipped(source: source)
        ]))
    }

    @Test func runningOperationQueuesASecondOperationWithoutReplacingItsConflict() async {
        let firstSource = URL(filePath: "/source/first")
        let secondSource = URL(filePath: "/source/second")
        let destinationDirectory = URL(filePath: "/destination")
        let firstDestination = destinationDirectory.appending(path: "first")
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(
                    existingURLs: [
                        firstSource,
                        secondSource,
                        destinationDirectory,
                        firstDestination
                    ]
                )
            )
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        await controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)

        let didStartSecond = await controller.runTransfer(
            [secondSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )

        #expect(didStartSecond)
        #expect(controller.queuedJobs.count == 1)
        #expect(controller.pendingConflict?.source == firstSource)
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)
    }

    @Test func applyToAllDecisionResetsBetweenCompletedOperations() async {
        let source = URL(filePath: "/source/item")
        let destinationDirectory = URL(filePath: "/destination")
        let destination = destinationDirectory.appending(path: "item")
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(
                    existingURLs: [source, destinationDirectory, destination]
                )
            )
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)
        controller.resolvePendingConflict(.skip, applyToAll: true)
        await waitUntilIdle(controller)

        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        let presentedAgain = await waitForConflictOrCompletion(controller)

        #expect(presentedAgain)
        if controller.pendingConflict != nil {
            controller.resolvePendingConflict(.skip, applyToAll: false)
        }
        await waitUntilIdle(controller)
    }

    @Test func cancellingATransferStillRefreshesTouchedVisibleDirectories() async {
        let source = URL(filePath: "/source/item")
        let destinationDirectory = URL(filePath: "/destination")
        let destination = destinationDirectory.appending(path: "item")
        let originalItem = fileItem(at: destinationDirectory.appending(path: "original"))
        let refreshedItem = fileItem(at: destinationDirectory.appending(path: "refreshed"))
        let listingService = SequencedListingService(
            directory: destinationDirectory,
            firstItems: [originalItem],
            refreshedItems: [refreshedItem]
        )
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(
                    existingURLs: [source, destinationDirectory, destination]
                )
            )
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: listingService
        )
        await workspace.loadInitialDirectories()

        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)
        controller.cancel()
        await waitUntilIdle(controller)

        #expect(controller.pendingConflict == nil)
        #expect(workspace.left.items == [refreshedItem])
    }

    @Test func createRenameAndTrashPublishResultsAndRefreshTheirParent() async {
        let directory = URL(filePath: "/workspace")
        let original = directory.appending(path: "Original")
        let renamed = directory.appending(path: "Renamed")
        let fileSystem = RecordingFileSystem(existingURLs: [directory, original])
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let listingService = RequestRecordingListingService()
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: listingService
        )
        await workspace.loadInitialDirectories()

        await controller.createFolder(in: directory, named: "New Folder", workspace: workspace)
        await waitUntilIdle(controller)
        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .succeeded(
                source: directory.appending(path: "New Folder", directoryHint: .isDirectory),
                destination: directory.appending(path: "New Folder", directoryHint: .isDirectory)
            )
        ]))

        controller.rename(original, to: "Renamed", workspace: workspace)
        await waitUntilIdle(controller)
        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .succeeded(source: original, destination: renamed)
        ]))

        controller.trash([renamed], workspace: workspace)
        await waitUntilIdle(controller)
        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .succeeded(source: renamed, destination: nil)
        ]))
        let refreshCount = await listingService.requestCount(for: directory)
        #expect(refreshCount == 4, "Expected initial load plus three targeted refreshes; got \(refreshCount)")
    }

    @Test func createFolderCompletionRunsAfterTheRefreshedRowIsVisible() async {
        let directory = URL(filePath: "/workspace")
        let created = directory.appending(path: "New Folder", directoryHint: .isDirectory)
        let listingService = SequencedListingService(
            directory: directory,
            firstItems: [],
            refreshedItems: [fileItem(at: created)]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem())
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: listingService
        )
        await workspace.loadInitialDirectories()
        var rowWasVisibleAtCompletion = false

        await controller.createFolder(
            in: directory,
            named: "New Folder",
            workspace: workspace,
            onCompletion: { result in
                rowWasVisibleAtCompletion = workspace.left.items.contains { $0.url == created }
                #expect(result.outcomes.count == 1)
            }
        )
        await waitUntilIdle(controller)

        #expect(rowWasVisibleAtCompletion)
    }

    @Test func multiItemTrashPublishesTheLastCompletedItemProgress() async {
        let directory = URL(filePath: "/workspace")
        let first = directory.appending(path: "first")
        let second = directory.appending(path: "second")
        let third = directory.appending(path: "third")
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(existingURLs: [first, second, third])
            )
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        controller.trash([first, second, third], workspace: workspace)
        await waitUntilIdle(controller)

        #expect(controller.progress == FileOperationProgress(
            completedCount: 3,
            totalCount: 3,
            currentName: "third"
        ))
    }

    @Test func identifiedTrashCompletionRunsAfterTheRefreshedRowIsVisible() async {
        let directory = URL(filePath: "/workspace")
        let source = directory.appending(path: "selected")
        let identity = FileIdentity(
            entryIdentifier: "selected",
            resolvedIdentifier: "selected"
        )
        let listingService = SequencedListingService(
            directory: directory,
            firstItems: [fileItem(at: source)],
            refreshedItems: []
        )
        let controller = FileOperationController(
            service: FileOperationService(
                fileSystem: RecordingFileSystem(
                    existingURLs: [source],
                    identities: [source: identity]
                )
            )
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: listingService
        )
        await workspace.loadInitialDirectories()
        var rowWasAbsentAtCompletion = false

        controller.trash(
            [IdentifiedFileRequest(url: source, identity: identity)],
            workspace: workspace,
            onCompletion: { result in
                rowWasAbsentAtCompletion = workspace.left.items.allSatisfy {
                    $0.url != source
                }
                #expect(result.outcomes == [
                    .succeeded(source: source, destination: nil)
                ])
            }
        )
        await waitUntilIdle(controller)

        #expect(rowWasAbsentAtCompletion)
    }

    @Test func controllerTrashCancellationAfterFirstItemDoesNotTrashTheRemainder() async {
        let directory = URL(filePath: "/workspace")
        let first = directory.appending(path: "first")
        let second = directory.appending(path: "second")
        let third = directory.appending(path: "third")
        let fileSystem = RecordingFileSystem(
            existingURLs: [first, second, third],
            cancelAfterTrashOf: first
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        controller.trash([first, second, third], workspace: workspace)
        await waitUntilIdle(controller)

        #expect(await fileSystem.events == [
            "identity:/workspace/first",
            "identity:/workspace/second",
            "identity:/workspace/third",
            "trash:/workspace/first"
        ])
        #expect(await fileSystem.existingURLs == [second, third])
        #expect(controller.progress == FileOperationProgress(
            completedCount: 3,
            totalCount: 3,
            currentName: "first"
        ))
        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .succeeded(source: first, destination: nil),
            .cancelled(source: second),
            .cancelled(source: third)
        ]))
        #expect(controller.operationHistory.first?.canRetry == false)
    }

    @Test func queuedOperationsRunFIFOWithOnlyOneActiveJob() async {
        let source = URL(filePath: "/source/first")
        let destinationDirectory = URL(filePath: "/destination")
        let collision = destinationDirectory.appending(path: "first")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destinationDirectory, collision]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await waitForPendingConflict(controller)
        #expect(await controller.createFolder(
            in: destinationDirectory,
            named: "Second",
            workspace: workspace
        ))
        #expect(await controller.createFolder(
            in: destinationDirectory,
            named: "Third",
            workspace: workspace
        ))

        #expect(controller.activeJob?.kind == .copy)
        #expect(controller.queuedJobs.map(\.kind) == [.createFolder, .createFolder])
        #expect(controller.queuedJobs.map(\.itemDisplayName) == ["Second", "Third"])

        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(await fileSystem.existingURLs.contains(
            destinationDirectory.appending(path: "Second", directoryHint: .isDirectory)
        ))
        #expect(await fileSystem.existingURLs.contains(
            destinationDirectory.appending(path: "Third", directoryHint: .isDirectory)
        ))
        #expect(controller.operationHistory.map(\.kind) == [
            .createFolder, .createFolder, .copy
        ])
    }

    @Test func recoveryNeededHaltsQueuedMutationsUntilExplicitContinue() async throws {
        let directory = URL(filePath: "/workspace")
        let keepURL = directory.appending(path: "keep.bin")
        let recoveryURL = directory.appending(path: "recovery.bin")
        let keepFingerprint = ComparisonFingerprint(
            identity: FileIdentity(entryIdentifier: "keep", resolvedIdentifier: "keep"),
            byteSize: 1,
            modifiedAt: Date(timeIntervalSince1970: 100),
            rawModifiedAt: ComparisonModificationTimestamp(seconds: 100, nanoseconds: 1)
        )
        let recoveryFingerprint = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "recovery",
                resolvedIdentifier: "recovery"
            ),
            byteSize: 1,
            modifiedAt: Date(timeIntervalSince1970: 100),
            rawModifiedAt: ComparisonModificationTimestamp(seconds: 100, nanoseconds: 1)
        )
        let reader = SuspendingOperationCenterFingerprintReader([
            keepURL: keepFingerprint,
            recoveryURL: recoveryFingerprint
        ])
        let fileSystem = RecordingFileSystem(
            existingURLs: [directory, keepURL, recoveryURL],
            identities: [
                keepURL: keepFingerprint.identity,
                recoveryURL: recoveryFingerprint.identity
            ],
            forceTrashQuarantineRecovery: true
        )
        let controller = FileOperationController(service: FileOperationService(
            fileSystem: fileSystem,
            storageFingerprints: reader
        ))
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        let keep = StorageEntry(
            relativePath: try StorageRelativePath(components: ["keep.bin"]),
            url: keepURL,
            kind: .regularFile,
            category: .other,
            fingerprint: keepFingerprint,
            typeDescription: "File"
        )
        let recovery = StorageEntry(
            relativePath: try StorageRelativePath(components: ["recovery.bin"]),
            url: recoveryURL,
            kind: .regularFile,
            category: .other,
            fingerprint: recoveryFingerprint,
            typeDescription: "File"
        )

        #expect(controller.trashStorageCleanup(
            [StorageCleanupMutationGroup(keep: keep, trash: [recovery])],
            workspace: workspace
        ))
        await waitUntil { await reader.hasSuspended }
        #expect(await !controller.createFolder(
            in: directory,
            named: "After Recovery",
            workspace: workspace
        ))
        #expect(controller.queuedJobs.isEmpty)

        await reader.release()
        await waitUntilIdle(controller)

        #expect(controller.isQueueBlockedByRecovery)
        #expect(await controller.createFolder(
            in: directory,
            named: "After Recovery",
            workspace: workspace
        ))
        #expect(controller.queuedJobs.count == 1)
        #expect(await !fileSystem.existingURLs.contains(
            directory.appending(path: "After Recovery", directoryHint: .isDirectory)
        ))
        #expect(controller.continueAfterRecovery())
        await waitUntilQueueIsIdle(controller)
        #expect(!controller.isQueueBlockedByRecovery)
        #expect(await fileSystem.existingURLs.contains(
            directory.appending(path: "After Recovery", directoryHint: .isDirectory)
        ))
    }

    @Test func cancellationWhileNewFolderPreflightWaitsDoesNotMutate() async {
        let directory = URL(filePath: "/workspace")
        let destination = directory.appending(
            path: "Cancelled Folder",
            directoryHint: .isDirectory
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [directory],
            suspendExistsOfLastPathComponent: "Cancelled Folder"
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(await controller.createFolder(
            in: directory,
            named: "Cancelled Folder",
            workspace: workspace
        ))
        await waitUntil { await fileSystem.hasSuspendedExists }
        controller.cancelActiveJob()
        await fileSystem.releaseSuspendedExists()
        await waitUntilQueueIsIdle(controller)

        #expect(await !fileSystem.existingURLs.contains(destination))
        #expect(controller.operationHistory.first?.state == .cancelled)
    }

    @Test func queuedTransferUsesSourceIdentityCapturedBeforeWaiting() async {
        let firstSource = URL(filePath: "/source/first")
        let queuedSource = URL(filePath: "/source/queued")
        let destinationDirectory = URL(filePath: "/destination")
        let firstCollision = destinationDirectory.appending(path: "first")
        let queuedDestination = destinationDirectory.appending(path: "queued")
        let fileSystem = RecordingFileSystem(
            existingURLs: [
                firstSource, queuedSource, destinationDirectory, firstCollision
            ]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        await controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)

        #expect(await controller.runTransfer(
            [queuedSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await fileSystem.replaceIdentity(
            at: queuedSource,
            with: FileIdentity(
                entryIdentifier: "replacement-entry",
                resolvedIdentifier: "replacement-resolved"
            )
        )
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(await !fileSystem.existingURLs.contains(queuedDestination))
        #expect(controller.operationHistory.first?.kind == .copy)
        #expect(controller.operationHistory.first?.state == .failed)
    }

    @Test func queuedTransferUsesDestinationIdentityCapturedBeforeWaiting() async {
        let firstSource = URL(filePath: "/source/first")
        let queuedSource = URL(filePath: "/source/queued")
        let destinationDirectory = URL(filePath: "/destination")
        let firstCollision = destinationDirectory.appending(path: "first")
        let queuedDestination = destinationDirectory.appending(path: "queued")
        let fileSystem = RecordingFileSystem(
            existingURLs: [
                firstSource, queuedSource, destinationDirectory, firstCollision
            ]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        await controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)

        #expect(await controller.runTransfer(
            [queuedSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await fileSystem.replaceIdentity(
            at: destinationDirectory,
            with: FileIdentity(
                entryIdentifier: "replacement-root-entry",
                resolvedIdentifier: "replacement-root-resolved"
            )
        )
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(await !fileSystem.existingURLs.contains(queuedDestination))
        #expect(controller.operationHistory.first?.state == .failed)
    }

    @Test func queuedCreateFolderUsesDirectoryIdentityCapturedBeforeWaiting() async {
        let firstSource = URL(filePath: "/source/first")
        let destinationDirectory = URL(filePath: "/destination", directoryHint: .isDirectory)
        let firstCollision = destinationDirectory.appending(path: "first")
        let queuedFolder = destinationDirectory.appending(
            path: "Queued Folder",
            directoryHint: .isDirectory
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [firstSource, destinationDirectory, firstCollision]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        await controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)

        #expect(await controller.createFolder(
            in: destinationDirectory,
            named: "Queued Folder",
            workspace: workspace
        ))
        await fileSystem.replaceIdentity(
            at: destinationDirectory,
            with: FileIdentity(
                entryIdentifier: "replacement-root-entry",
                resolvedIdentifier: "replacement-root-resolved"
            )
        )
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(await fileSystem.existingURLs.contains(queuedFolder) == false)
        #expect(controller.operationHistory.first?.kind == .createFolder)
        #expect(controller.operationHistory.first?.state == .failed)
    }

    @Test func queuedImmediateTrashUsesIdentityCapturedBeforeWaiting() async {
        let firstSource = URL(filePath: "/source/first")
        let queuedSource = URL(filePath: "/source/queued")
        let destinationDirectory = URL(filePath: "/destination")
        let collision = destinationDirectory.appending(path: "first")
        let fileSystem = RecordingFileSystem(
            existingURLs: [firstSource, queuedSource, destinationDirectory, collision]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        #expect(await controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await waitForPendingConflict(controller)

        #expect(await controller.trashImmediately([queuedSource], workspace: workspace))
        await fileSystem.replaceIdentity(
            at: queuedSource,
            with: FileIdentity(
                entryIdentifier: "replacement-entry",
                resolvedIdentifier: "replacement-resolved"
            )
        )
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(await fileSystem.existingURLs.contains(queuedSource))
        #expect(controller.operationHistory.first?.kind == .trash)
        #expect(controller.operationHistory.first?.state == .failed)
    }

    @Test func queuedArchiveUsesDestinationIdentityCapturedBeforeWaiting() async {
        let directory = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let otherDirectory = URL(filePath: "/other", directoryHint: .isDirectory)
        let firstSource = URL(filePath: "/source/first")
        let collision = directory.appending(path: "first")
        let archiveSource = directory.appending(path: "Report.txt")
        let fileSystem = RecordingFileSystem(
            existingURLs: [directory, otherDirectory, firstSource, collision, archiveSource]
        )
        let archiveService = ArchiveOperationService(
            fileSystem: fileSystem,
            commandRunner: CompletingControllerArchiveCommandRunner()
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: InMemoryCloudMaterializer(),
            archiveService: archiveService
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [fileItem(at: archiveSource)],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [archiveSource]
        #expect(await controller.runTransfer(
            [firstSource],
            to: directory,
            mode: .copy,
            workspace: workspace
        ))
        await waitForPendingConflict(controller)

        #expect(await controller.compressSelection(workspace))
        await fileSystem.replaceIdentity(
            at: directory,
            with: FileIdentity(
                entryIdentifier: "replacement-directory-entry",
                resolvedIdentifier: "replacement-directory-resolved"
            )
        )
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(await !fileSystem.existingURLs.contains(
            directory.appending(path: "Report.txt.zip")
        ))
        #expect(controller.operationHistory.first?.kind == .compress(.zip))
        #expect(controller.operationHistory.first?.state == .failed)
    }

    @Test func queuedJobCanBeCancelledWithoutExecuting() async {
        let source = URL(filePath: "/source/first")
        let destinationDirectory = URL(filePath: "/destination")
        let collision = destinationDirectory.appending(path: "first")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destinationDirectory, collision]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await waitForPendingConflict(controller)
        #expect(await controller.createFolder(
            in: destinationDirectory,
            named: "Never Created",
            workspace: workspace
        ))
        let queuedID = controller.queuedJobs[0].id

        #expect(controller.cancelQueuedJob(queuedID))
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(await !fileSystem.existingURLs.contains(
            destinationDirectory.appending(path: "Never Created", directoryHint: .isDirectory)
        ))
        #expect(controller.operationHistory.first { $0.id == queuedID }?.state == .cancelled)
    }

    @Test func cancellingQueuedJobDeliversItsImmutableCancellationResultOnce() async {
        let firstSource = URL(filePath: "/source/first")
        let queuedSource = URL(filePath: "/source/queued")
        let destinationDirectory = URL(filePath: "/destination")
        let collision = destinationDirectory.appending(path: "first")
        let queuedIdentity = FileIdentity(
            entryIdentifier: "queued-entry",
            resolvedIdentifier: "queued-resolved"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [firstSource, queuedSource, destinationDirectory, collision],
            identities: [queuedSource: queuedIdentity]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        #expect(await controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await waitForPendingConflict(controller)
        var completions: [FileOperationResult] = []
        let accepted = controller.trash(
            [IdentifiedFileRequest(url: queuedSource, identity: queuedIdentity)],
            workspace: workspace,
            onCompletion: { completions.append($0) }
        )
        #expect(accepted)
        let queuedID = try? #require(controller.queuedJobs.first?.id)

        #expect(queuedID.map(controller.cancelQueuedJob) == true)
        #expect(completions == [FileOperationResult(outcomes: [
            .cancelled(source: queuedSource)
        ])])
        #expect(queuedID.map(controller.cancelQueuedJob) == false)
        #expect(completions.count == 1)
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)
    }

    @Test func cancellingBeforeWorkerStartDeliversPerItemCancellation() async {
        let source = URL(filePath: "/workspace/queued")
        let identity = FileIdentity(
            entryIdentifier: "queued-entry",
            resolvedIdentifier: "queued-resolved"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            identities: [source: identity]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/workspace"),
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        var completions: [FileOperationResult] = []
        let accepted = controller.trash(
            [IdentifiedFileRequest(url: source, identity: identity)],
            workspace: workspace,
            onCompletion: { completions.append($0) }
        )
        #expect(accepted)

        controller.cancelActiveJob()
        await waitUntilQueueIsIdle(controller)

        let cancellation = FileOperationResult(outcomes: [.cancelled(source: source)])
        #expect(controller.lastResult == cancellation)
        #expect(completions == [cancellation])
        #expect(await fileSystem.existingURLs.contains(source))
    }

    @Test func queuedJobsCanBeMovedBeforeTheyExecute() async {
        let firstSource = URL(filePath: "/source/first")
        let destinationDirectory = URL(filePath: "/destination", directoryHint: .isDirectory)
        let collision = destinationDirectory.appending(path: "first")
        let fileSystem = RecordingFileSystem(
            existingURLs: [firstSource, destinationDirectory, collision]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        #expect(await controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await waitForPendingConflict(controller)
        #expect(await controller.createFolder(
            in: destinationDirectory,
            named: "First Queued",
            workspace: workspace
        ))
        #expect(await controller.createFolder(
            in: destinationDirectory,
            named: "Second Queued",
            workspace: workspace
        ))
        let secondID = try? #require(controller.queuedJobs.last?.id)

        #expect(secondID.map { controller.moveQueuedJob($0, by: -1) } == true)
        #expect(controller.queuedJobs.map(\.itemDisplayName) == [
            "Second Queued", "First Queued"
        ])
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        #expect(controller.operationHistory.prefix(2).map(\.itemDisplayName) == [
            "First Queued", "Second Queued"
        ])
        #expect(controller.operationHistory.prefix(2).allSatisfy { $0.state == .succeeded })
    }

    @Test func activeJobPauseResumeAndCancelUpdateOperationCenterState() async {
        let source = URL(filePath: "/source/first")
        let destinationDirectory = URL(filePath: "/destination")
        let collision = destinationDirectory.appending(path: "first")
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem(
                existingURLs: [source, destinationDirectory, collision]
            ))
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)

        await controller.pauseActiveJob()
        #expect(!controller.isPaused)
        #expect(controller.activeJob?.state == .pauseRequested)
        await controller.resumeActiveJob()
        #expect(!controller.isPaused)
        #expect(controller.activeJob?.state == .running)

        controller.cancelActiveJob()
        await waitUntilQueueIsIdle(controller)
        #expect(controller.operationHistory.first?.state == .cancelled)
    }

    @Test func failedJobRetryCreatesANewAttemptAndHistoryIsBounded() async {
        let directory = URL(filePath: "/workspace")
        let existing = directory.appending(path: "Existing", directoryHint: .isDirectory)
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem(
                existingURLs: [directory, existing]
            )),
            materializer: InMemoryCloudMaterializer(),
            historyLimit: 2
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        await controller.createFolder(in: directory, named: "Existing", workspace: workspace)
        await waitUntilQueueIsIdle(controller)
        let firstAttempt = controller.operationHistory[0]
        #expect(firstAttempt.state == .failed)
        #expect(firstAttempt.canRetry)

        #expect(controller.retryJob(firstAttempt.id))
        await waitUntilQueueIsIdle(controller)
        #expect(controller.operationHistory.count == 2)
        #expect(controller.operationHistory[0].id != controller.operationHistory[1].id)

        await controller.createFolder(in: directory, named: "Existing", workspace: workspace)
        await waitUntilQueueIsIdle(controller)
        #expect(controller.operationHistory.count == 2)
        #expect(!controller.operationHistory.contains { $0.id == firstAttempt.id })
    }

    @Test func successfulCopyExposesUndoAndRunsItThroughTheSameQueue() async throws {
        let source = URL(filePath: "/source/Report.txt")
        let destinationDirectory = URL(filePath: "/destination", directoryHint: .isDirectory)
        let copied = destinationDirectory.appending(path: source.lastPathComponent)
        let fileSystem = RecordingFileSystem(existingURLs: [source, destinationDirectory])
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await waitUntilQueueIsIdle(controller)
        let copyJob = try #require(controller.operationHistory.first)
        #expect(copyJob.canUndo)
        #expect(await fileSystem.existingURLs.contains(copied))

        #expect(controller.undoJob(copyJob.id))
        #expect(controller.activeJob?.kind == .undo)
        await waitUntilQueueIsIdle(controller)

        #expect(await fileSystem.existingURLs.contains(copied) == false)
        #expect(controller.operationHistory.first?.kind == .undo)
        #expect(controller.operationHistory.first?.state == .succeeded)
        #expect(controller.operationHistory.first { $0.id == copyJob.id }?.canUndo == false)
    }

    @Test func replacementConflictNeverExposesUndo() async throws {
        let source = URL(filePath: "/source/Report.txt")
        let destinationDirectory = URL(filePath: "/destination", directoryHint: .isDirectory)
        let existing = destinationDirectory.appending(path: source.lastPathComponent)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destinationDirectory, existing]
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        ))
        await waitForPendingConflict(controller)
        controller.resolvePendingConflict(.replace, applyToAll: false)
        await waitUntilQueueIsIdle(controller)

        let job = try #require(controller.operationHistory.first)
        #expect(job.state == .succeeded)
        #expect(job.canUndo == false)
        #expect(controller.undoJob(job.id) == false)
    }

    @Test func changedCopyMakesQueuedUndoFailClosedAndRemainInHistory() async throws {
        let source = URL(filePath: "/source/Notes.md")
        let destinationDirectory = URL(filePath: "/destination", directoryHint: .isDirectory)
        let copied = destinationDirectory.appending(path: source.lastPathComponent)
        let fileSystem = RecordingFileSystem(existingURLs: [source, destinationDirectory])
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: destinationDirectory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        await controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitUntilQueueIsIdle(controller)
        let copyJob = try #require(controller.operationHistory.first)
        await fileSystem.mutateContents(at: copied)

        #expect(controller.undoJob(copyJob.id))
        await waitUntilQueueIsIdle(controller)

        #expect(await fileSystem.existingURLs.contains(copied))
        #expect(controller.operationHistory.first?.kind == .undo)
        #expect(controller.operationHistory.first?.state == .failed)
        #expect(controller.operationHistory.first?.canRetry == false)
        #expect(controller.operationHistory.first { $0.id == copyJob.id }?.canUndo == false)
    }

    @Test func laterMutationInTheSameDirectoryInvalidatesAnOlderUndoRecipe() async throws {
        let directory = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(existingURLs: [directory])
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        await controller.createFolder(in: directory, named: "First", workspace: workspace)
        await waitUntilQueueIsIdle(controller)
        let first = try #require(controller.operationHistory.first)
        #expect(first.canUndo)

        await controller.createFolder(in: directory, named: "Second", workspace: workspace)
        await waitUntilQueueIsIdle(controller)

        #expect(controller.operationHistory.first?.canUndo == true)
        #expect(controller.operationHistory.first { $0.id == first.id }?.canUndo == false)
        #expect(controller.undoJob(first.id) == false)
    }

    @Test func ancestorMutationInvalidatesANestedUndoRecipe() async throws {
        let root = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(existingURLs: [root, nested])
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: root,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(await controller.createFolder(
            in: nested,
            named: "Nested Output",
            workspace: workspace
        ))
        await waitUntilQueueIsIdle(controller)
        let nestedJob = try #require(controller.operationHistory.first)
        #expect(nestedJob.canUndo)

        #expect(await controller.createFolder(
            in: root,
            named: "Root Output",
            workspace: workspace
        ))
        await waitUntilQueueIsIdle(controller)

        #expect(controller.operationHistory.first { $0.id == nestedJob.id }?.canUndo == false)
        #expect(controller.undoJob(nestedJob.id) == false)
    }

    @Test func retargetedAliasCannotHideUndoDirectoryOverlap() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let firstTarget = fixture.url.appending(path: "First", directoryHint: .isDirectory)
        let secondTarget = fixture.url.appending(path: "Second", directoryHint: .isDirectory)
        let alias = fixture.url.appending(path: "Alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: firstTarget
        )
        let fileSystem = RecordingFileSystem(existingURLs: [firstTarget, secondTarget, alias])
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: firstTarget,
            rightURL: secondTarget,
            listingService: StubDirectoryListingService(values: [:])
        )

        #expect(await controller.createFolder(
            in: alias,
            named: "Aliased Output",
            workspace: workspace
        ))
        await waitUntilQueueIsIdle(controller)
        let aliasedJob = try #require(controller.operationHistory.first)
        #expect(aliasedJob.canUndo)

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: secondTarget
        )
        #expect(await controller.createFolder(
            in: firstTarget,
            named: "Direct Output",
            workspace: workspace
        ))
        await waitUntilQueueIsIdle(controller)

        #expect(controller.operationHistory.first { $0.id == aliasedJob.id }?.canUndo == false)
    }

    @Test func operationStatusSummaryCountsEveryOutcomeForAccessibility() {
        let result = FileOperationResult(outcomes: [
            .succeeded(source: URL(filePath: "/a"), destination: URL(filePath: "/dest/a")),
            .failed(source: URL(filePath: "/b"), message: "cloud-preparation:offline"),
            .skipped(source: URL(filePath: "/c"))
        ])
        let summary = OperationStatusSummary(result: result)
        let details = OperationResultDetails(result: result)

        #expect(summary.succeeded == 1)
        #expect(summary.failed == 1)
        #expect(summary.skipped == 1)
        #expect(summary.cancelled == 0)
        #expect(summary.accessibilityLabel == "1 succeeded, 1 failed, 1 skipped, 0 cancelled")
        #expect(details.items.first?.guidance == "Connect to the internet, then try the download again.")
    }

    @Test func batchRenameRunsAsOneExclusiveJobAndSelectsFinalItems() async throws {
        let fixture = try await BatchRenameControllerFixture(
            suspendCheckedExclusiveMoveAttempt: 2
        )

        #expect(fixture.controller.batchRename(fixture.plan, workspace: fixture.workspace))
        await fixture.fileSystem.waitForSuspendedCheckedExclusiveMove()
        #expect(fixture.controller.activeJob?.kind == .rename)
        #expect(fixture.controller.activeJob?.title == "Rename 2 Items")
        #expect(fixture.controller.activeJob?.progress == FileOperationJobProgress(
            completedCount: 1,
            totalCount: 2,
            detail: "Staging names"
        ))
        await fixture.fileSystem.releaseSuspendedCheckedExclusiveMove()
        await waitUntilQueueIsIdle(fixture.controller)

        let job = try #require(fixture.controller.operationHistory.first)
        #expect(job.state == .succeeded)
        #expect(job.canUndo)
        #expect(fixture.workspace.left.selection == [
            fixture.url("new-A.txt"),
            fixture.url("new-B.txt")
        ])
    }

    @Test func batchRenameUndoRunsThroughTheSameExclusiveQueue() async throws {
        let fixture = try await BatchRenameControllerFixture()
        #expect(fixture.controller.batchRename(fixture.plan, workspace: fixture.workspace))
        await waitUntilQueueIsIdle(fixture.controller)
        let renameJob = try #require(fixture.controller.operationHistory.first)

        #expect(fixture.controller.undoJob(renameJob.id))
        #expect(fixture.controller.activeJob?.kind == .undo)
        await waitUntilQueueIsIdle(fixture.controller)

        #expect(fixture.controller.operationHistory.first?.state == .succeeded)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("A.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("B.txt")))
    }

    @Test func failedBatchRenameRetryReusesTheCapturedImmutablePlan() async throws {
        let fixture = try await BatchRenameControllerFixture(
            failCheckedExclusiveMoveAttempts: [1]
        )
        #expect(fixture.controller.batchRename(fixture.plan, workspace: fixture.workspace))
        await waitUntilQueueIsIdle(fixture.controller)
        let failed = try #require(fixture.controller.operationHistory.first)
        #expect(failed.state == .failed)
        #expect(failed.canRetry)

        fixture.workspace.left.selection = []
        #expect(fixture.controller.retryJob(failed.id))
        await waitUntilQueueIsIdle(fixture.controller)

        #expect(fixture.controller.operationHistory.first?.state == .succeeded)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("new-A.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("new-B.txt")))
    }

    @Test func identifiedConflictUsesStableContentIdentity() {
        let conflict = FileConflict(
            source: URL(filePath: "/source/a"),
            proposedDestination: URL(filePath: "/destination/a")
        )

        #expect(IdentifiedFileConflict(conflict).id == IdentifiedFileConflict(conflict).id)
        #expect(
            IdentifiedFileConflict(conflict).id != IdentifiedFileConflict(
                FileConflict(
                    source: conflict.source,
                    proposedDestination: URL(filePath: "/other/a")
                )
            ).id
        )
    }

    private func waitUntilIdle(_ controller: FileOperationController) async {
        while controller.isRunning {
            await Task.yield()
        }
    }

    private func waitUntilQueueIsIdle(_ controller: FileOperationController) async {
        while controller.isRunning || !controller.queuedJobs.isEmpty {
            await Task.yield()
        }
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool
    ) async {
        while !(await condition()) {
            await Task.yield()
        }
    }

    private func waitUntilBounded(
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForPendingConflict(_ controller: FileOperationController) async {
        while controller.pendingConflict == nil {
            await Task.yield()
        }
    }

    private func waitForConflictOrCompletion(_ controller: FileOperationController) async -> Bool {
        for _ in 0..<200 {
            if controller.pendingConflict != nil { return true }
            if !controller.isRunning { return false }
            await Task.yield()
        }
        return controller.pendingConflict != nil
    }

    private func fileItem(
        at url: URL,
        isDirectory: Bool = false,
        availability: CloudItemAvailability = .availableLocally
    ) -> FileItem {
        FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: isDirectory ? "Folder" : "File",
            availability: availability
        )
    }

    private func makeProtectedWorkspace() async -> ProtectedWorkspaceFixture {
        let directory = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let otherDirectory = URL(filePath: "/other", directoryHint: .isDirectory)
        let source = directory.appending(path: "Report.txt")
        let fileSystem = RecordingFileSystem(existingURLs: [directory, otherDirectory, source])
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory: [fileItem(at: source)],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        return ProtectedWorkspaceFixture(
            workspace: workspace,
            fileSystem: fileSystem
        )
    }
}

@MainActor
private struct BatchRenameControllerFixture {
    let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
    let fileSystem: RecordingFileSystem
    let controller: FileOperationController
    let workspace: WorkspaceState
    let plan: BatchRenamePlan

    init(
        suspendCheckedExclusiveMoveAttempt: Int? = nil,
        failCheckedExclusiveMoveAttempts: Set<Int> = []
    ) async throws {
        let parentURL = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let sourceNames = ["A.txt", "B.txt"]
        let sourceURLs = sourceNames.map { parentURL.appending(path: $0) }
        fileSystem = RecordingFileSystem(
            existingURLs: Set([parentURL] + sourceURLs),
            caseInsensitivePaths: true,
            suspendCheckedExclusiveMoveAttempt: suspendCheckedExclusiveMoveAttempt,
            failCheckedExclusiveMoveAttempts: failCheckedExclusiveMoveAttempts
        )
        let transaction = BatchRenameTransactionService(
            fileSystem: fileSystem,
            temporaryName: { ".pengrid-rename-controller-\($0)" }
        )
        controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            batchRenameService: transaction
        )
        workspace = WorkspaceState(
            leftURL: parentURL,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
        workspace.left.selection = Set(sourceURLs)
        var sources: [BatchRenameSource] = []
        for name in sourceNames {
            let url = parentURL.appending(path: name)
            sources.append(BatchRenameSource(
                url: url,
                identity: try #require(await fileSystem.identity(of: url)),
                name: name,
                isDirectory: false,
                isPackage: false
            ))
        }
        let request = BatchRenamePlanningRequest(
            parentURL: parentURL,
            parentIdentity: try #require(await fileSystem.identity(of: parentURL)),
            sources: sources
        )
        plan = try #require(BatchRenamePlanner.preview(
            request: request,
            proposedNames: ["new-A.txt", "new-B.txt"],
            occupiedNames: Set(sourceNames),
            comparisonPolicy: .caseInsensitiveCanonical
        ).plan)
        await fileSystem.clearEvents()
    }

    func url(_ name: String) -> URL { parent.appending(path: name) }
}

private struct ProtectedWorkspaceFixture {
    let workspace: WorkspaceState
    let fileSystem: RecordingFileSystem
}

private actor RecordingArchiveOperator: ArchiveOperating {
    private var requests: [ArchiveRequest] = []

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        self.requests.append(contentsOf: requests)
        return FileOperationResult(outcomes: requests.map { request in
            .succeeded(
                source: request.verifiedSources.first?.url ?? request.finalDestination,
                destination: request.finalDestination
            )
        })
    }

    func recordedRequests() -> [ArchiveRequest] {
        requests
    }
}

private actor ControllerProtectedArchiveOperator: ArchiveOperating {
    enum Mode: Sendable {
        case promptAndWait
        case promptAndFail
        case waitingThenBytes
    }

    static let sentinel = "secret-sentinel-passphrase"

    private let passwordProvider: (any ArchivePasswordProviding)?
    private let mode: Mode
    private var requests: [ArchiveRequest] = []
    private var release: CheckedContinuation<Void, Never>?
    private(set) var didEmitBytes = false

    init(
        passwordProvider: (any ArchivePasswordProviding)? = nil,
        mode: Mode
    ) {
        self.passwordProvider = passwordProvider
        self.mode = mode
    }

    func perform(
        _ inputRequests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        guard let request = inputRequests.first else {
            return FileOperationResult(outcomes: [])
        }
        requests.append(contentsOf: inputRequests)
        let source = request.verifiedSources.first?.url ?? request.finalDestination
        await progress(ArchiveOperationProgress(
            kind: request.kind,
            currentDisplayName: request.progressDisplayName,
            format: request.format,
            phase: .waitingForPassword
        ))

        switch mode {
        case .promptAndWait:
            guard let passwordProvider else {
                return await waitForCancellation(
                    source: source,
                    destination: request.finalDestination
                )
            }
            do {
                let secret = try await passwordProvider.requestPassword(for: ArchivePasswordRequest(
                    id: UUID(),
                    purpose: .createAES256,
                    archiveBasename: request.finalDestination.lastPathComponent,
                    previousAttemptFailed: false
                ))
                secret.invalidate()
                return await waitForCancellation(
                    source: source,
                    destination: request.finalDestination
                )
            } catch is CancellationError {
                return FileOperationResult(outcomes: [.cancelled(source: source)])
            } catch {
                return FileOperationResult(outcomes: [.failed(source: source, message: "safe failure")])
            }

        case .promptAndFail:
            guard let passwordProvider else {
                return FileOperationResult(outcomes: [.failed(source: source, message: "safe failure")])
            }
            do {
                let secret = try await passwordProvider.requestPassword(for: ArchivePasswordRequest(
                    id: UUID(),
                    purpose: .createAES256,
                    archiveBasename: request.finalDestination.lastPathComponent,
                    previousAttemptFailed: false
                ))
                secret.invalidate()
                return FileOperationResult(outcomes: [.failed(source: source, message: "safe failure")])
            } catch is CancellationError {
                return FileOperationResult(outcomes: [.cancelled(source: source)])
            } catch {
                return FileOperationResult(outcomes: [.failed(source: source, message: "safe failure")])
            }

        case .waitingThenBytes:
            await progress(ArchiveOperationProgress(
                kind: request.kind,
                currentDisplayName: request.progressDisplayName,
                format: request.format,
                phase: .processingBytes(completedByteCount: 99, totalByteCount: 10)
            ))
            didEmitBytes = true
            return await waitForCancellation(
                source: source,
                destination: request.finalDestination
            )
        }
    }

    private func waitForCancellation(
        source: URL,
        destination: URL
    ) async -> FileOperationResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                release = continuation
            }
        }, onCancel: {
            Task { await self.resumeRelease() }
        })
        return FileOperationResult(outcomes: [
            Task.isCancelled
                ? .cancelled(source: source)
                : .succeeded(source: source, destination: destination)
        ])
    }

    private func resumeRelease() {
        release?.resume()
        release = nil
    }

    func recordedRequests() -> [ArchiveRequest] {
        requests
    }
}

private struct CompletingControllerArchiveCommandRunner: ArchiveCommandRunning {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> FileIdentity {
        switch kind {
        case .compress:
            try Data("archive".utf8).write(to: destination)
        case .extract:
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
        }
        return archiveTestIdentity(for: destination)
    }
}

private actor GatedControllerArchiveOperator: ArchiveOperating {
    private let underlying: any ArchiveOperating
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private var emittedProgress: [ArchiveOperationProgress] = []

    init(underlying: any ArchiveOperating) {
        self.underlying = underlying
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
        return await underlying.perform(requests) { update in
            await self.record(update)
            await progress(update)
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func proceed() {
        release?.resume()
        release = nil
    }

    func recordedProgress() -> [ArchiveOperationProgress] {
        emittedProgress
    }

    private func record(_ progress: ArchiveOperationProgress) {
        emittedProgress.append(progress)
    }
}

private actor IdentityReplacingArchiveMaterializer: CloudMaterializing {
    private let fileSystem: RecordingFileSystem
    private let source: URL
    private let replacementIdentity: FileIdentity

    init(
        fileSystem: RecordingFileSystem,
        source: URL,
        replacementIdentity: FileIdentity
    ) {
        self.fileSystem = fileSystem
        self.source = source
        self.replacementIdentity = replacementIdentity
    }

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        await fileSystem.replaceIdentity(at: source, with: replacementIdentity)
        return CloudMaterializationResult(
            preparedRequests: requests,
            failures: [],
            wasCancelled: false
        )
    }
}

private actor SuspendingArchiveMaterializer: CloudMaterializing {
    private var requests: [IdentifiedFileRequest] = []
    private var purpose: CloudPreparationPurpose?
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        self.requests = requests
        self.purpose = purpose
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
        if Task.isCancelled {
            return CloudMaterializationResult(
                preparedRequests: [],
                failures: [],
                wasCancelled: true
            )
        }
        return CloudMaterializationResult(
            preparedRequests: requests,
            failures: [],
            wasCancelled: false
        )
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func recordedPurpose() -> CloudPreparationPurpose? {
        purpose
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

private actor ArchiveRequestRecordingListingService: DirectoryListingService {
    private let values: [URL: [FileItem]]
    private var requestCounts: [URL: Int] = [:]

    init(values: [URL: [FileItem]]) {
        self.values = values
    }

    nonisolated func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(await response(for: directory))
                continuation.finish()
            }
        }
    }

    func requestCount(for directory: URL) -> Int {
        requestCounts[directory, default: 0]
    }

    private func response(for directory: URL) -> [FileItem] {
        requestCounts[directory, default: 0] += 1
        return values[directory] ?? []
    }
}

private actor RequestRecordingListingService: DirectoryListingService {
    private var requests: [URL: Int] = [:]

    nonisolated func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(directory)
                continuation.finish()
            }
        }
    }

    func requestCount(for directory: URL) -> Int {
        requests[directory, default: 0]
    }

    private func record(_ directory: URL) {
        requests[directory, default: 0] += 1
    }
}

private actor SequencedListingService: DirectoryListingService {
    private let directory: URL
    private let firstItems: [FileItem]
    private let refreshedItems: [FileItem]
    private var requestCount = 0

    init(directory: URL, firstItems: [FileItem], refreshedItems: [FileItem]) {
        self.directory = directory
        self.firstItems = firstItems
        self.refreshedItems = refreshedItems
    }

    nonisolated func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            Task {
                let response = await response(for: directory)
                if response.isRefresh {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                continuation.yield(response.items)
                continuation.finish()
            }
        }
    }

    private func response(for requestedDirectory: URL) -> (items: [FileItem], isRefresh: Bool) {
        guard requestedDirectory == directory else { return ([], false) }
        requestCount += 1
        return requestCount == 1 ? (firstItems, false) : (refreshedItems, true)
    }
}

private actor SuspendingOperationCenterFingerprintReader:
    StorageEntryFingerprintReading {
    private let fingerprints: [URL: ComparisonFingerprint]
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasSuspended = false
    private var didSuspend = false

    init(_ fingerprints: [URL: ComparisonFingerprint]) {
        self.fingerprints = fingerprints
    }

    func fingerprint(of url: URL) async throws -> ComparisonFingerprint {
        if !didSuspend {
            didSuspend = true
            hasSuspended = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        guard let fingerprint = fingerprints[url] else {
            throw CocoaError(.fileReadUnknown)
        }
        return fingerprint
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
