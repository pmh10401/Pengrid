import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FileOperationControllerTests {
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

        #expect(await archiveService.recordedRequests() == [
            ArchiveRequest(
                kind: .compress,
                verifiedSources: [source],
                finalDestination: directory.appending(path: "Project Notes.tar.gz"),
                format: .tarGzip
            )
        ])
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
        #expect(requests == [
            ArchiveRequest(
                kind: .compress,
                verifiedSources: [source],
                finalDestination: directory.appending(path: "Project Notes 2.zip")
            )
        ])
        #expect(requests.first?.progressDisplayName == "Project Notes 2.zip")
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

        #expect(await archiveService.recordedRequests() == [
            ArchiveRequest(
                kind: .compress,
                verifiedSources: [first, second],
                finalDestination: directory.appending(path: "Archive 3.zip")
            )
        ])
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

        #expect(await archiveService.recordedRequests() == [
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [first],
                finalDestination: directory.appending(
                    path: "First 3",
                    directoryHint: .isDirectory
                )
            ),
            ArchiveRequest(
                kind: .extract,
                verifiedSources: [second],
                finalDestination: directory.appending(
                    path: "Second 2",
                    directoryHint: .isDirectory
                )
            )
        ])
    }

    @Test func extractionKeepsSelectedZIPDisplayNameAcrossInitialAndRealServiceProgress() async throws {
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

        await archiveService.proceed()
        await waitUntilIdle(controller)
        #expect(controller.stage == expectedStage)
        #expect(await archiveService.recordedProgress() == [
            ArchiveOperationProgress(
                kind: .extract,
                currentDisplayName: "Backup.zip"
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
        #expect(await archiveService.recordedRequests().first?.verifiedSources == [source])
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

        controller.runTransfer(
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

        controller.runTransfer(
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

        controller.runTransfer(
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

    @Test func runningOperationRejectsASecondOperationWithoutReplacingItsConflict() async {
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
        controller.runTransfer(
            [firstSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)

        let didStartSecond = controller.runTransfer(
            [secondSource],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )

        #expect(didStartSecond == false)
        #expect(controller.pendingConflict?.source == firstSource)
        controller.resolvePendingConflict(.skip, applyToAll: false)
        await waitUntilIdle(controller)
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
        controller.runTransfer(
            [source],
            to: destinationDirectory,
            mode: .copy,
            workspace: workspace
        )
        await waitForPendingConflict(controller)
        controller.resolvePendingConflict(.skip, applyToAll: true)
        await waitUntilIdle(controller)

        controller.runTransfer(
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

        controller.runTransfer(
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
        let fileSystem = RecordingFileSystem(existingURLs: [original])
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

        controller.createFolder(in: directory, named: "New Folder", workspace: workspace)
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

        controller.createFolder(
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
}

private actor RecordingArchiveOperator: ArchiveOperating {
    private var requests: [ArchiveRequest] = []

    func perform(
        _ requests: [ArchiveRequest],
        progress: ArchiveProgressHandler
    ) async -> FileOperationResult {
        self.requests.append(contentsOf: requests)
        return FileOperationResult(outcomes: requests.map { request in
            .succeeded(
                source: request.verifiedSources.first ?? request.finalDestination,
                destination: request.finalDestination
            )
        })
    }

    func recordedRequests() -> [ArchiveRequest] {
        requests
    }
}

private struct CompletingControllerArchiveCommandRunner: ArchiveCommandRunning {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL
    ) async throws {
        switch kind {
        case .compress:
            try Data("archive".utf8).write(to: destination)
        case .extract:
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
        }
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
        progress: ArchiveProgressHandler
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
