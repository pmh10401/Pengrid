import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct SmartSearchActionRouterTests {
    @Test func manualCloudActionUsesTheRegisteredScopedLeaseAndFailsClosedWhenDenied() async throws {
        let root = URL(filePath: "/manual-cloud", directoryHint: .isDirectory)
        let url = root.appending(path: "report.txt")
        let identity = FileIdentity(entryIdentifier: "report", resolvedIdentifier: "report")
        let driver = ActionSecurityScopeDriver(permitsAccess: true)
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([root])
        let router = SmartSearchActionRouter(
            fileSystem: RecordingFileSystem(identities: [url: identity]),
            accessCoordinator: coordinator
        )

        #expect(await router.revalidatedRequest(for: actionResult(url: url, identity: identity)) != nil)
        #expect(driver.startedURLs == [root])
        #expect(driver.stoppedURLs == [root])

        let denied = CloudLocationScopedAccessCoordinator(
            driver: ActionSecurityScopeDriver(permitsAccess: false)
        )
        denied.replaceManualRoots([root])
        let deniedRouter = SmartSearchActionRouter(
            fileSystem: RecordingFileSystem(identities: [url: identity]),
            accessCoordinator: denied
        )
        #expect(await deniedRouter.revalidatedRequest(for: actionResult(url: url, identity: identity)) == nil)
        #expect(deniedRouter.error == .itemChanged)
    }
    @Test func replacementCannotBeRevalidatedForAnAction() async {
        let url = URL(filePath: "/search/report.txt")
        let searchIdentity = FileIdentity(
            entryIdentifier: "searched",
            resolvedIdentifier: "searched"
        )
        let replacementIdentity = FileIdentity(
            entryIdentifier: "replacement",
            resolvedIdentifier: "replacement"
        )
        let router = SmartSearchActionRouter(fileSystem: RecordingFileSystem(
            identities: [url: replacementIdentity]
        ))

        let request = await router.revalidatedRequest(
            for: actionResult(url: url, identity: searchIdentity)
        )

        #expect(request == nil)
        #expect(router.error == .itemChanged)
    }

    @Test func capturedOppositePaneRemainsTheActionTargetAfterPaneSwitch() async {
        let left = URL(filePath: "/left", directoryHint: .isDirectory)
        let right = URL(filePath: "/right", directoryHint: .isDirectory)
        let parent = URL(filePath: "/search", directoryHint: .isDirectory)
        let url = parent.appending(path: "report.txt")
        let identity = FileIdentity(entryIdentifier: "report", resolvedIdentifier: "report")
        let workspace = WorkspaceState(
            leftURL: left,
            rightURL: right,
            listingService: StubDirectoryListingService(values: [parent: [listedItem(at: url)]])
        )
        let capturedDestination = workspace.right
        workspace.activate(.right)
        let router = SmartSearchActionRouter(fileSystem: RecordingFileSystem(identities: [url: identity]))

        #expect(await router.openContainingFolder(
            for: actionResult(url: url, identity: identity), in: capturedDestination
        ))
        #expect(workspace.right.currentDirectory == parent)
        #expect(workspace.left.currentDirectory == left)
    }

    @Test func transferCarriesSearchAndDestinationIdentities() async throws {
        let sourceURL = URL(filePath: "/search/report.txt")
        let destinationURL = URL(filePath: "/destination", directoryHint: .isDirectory)
        let sourceIdentity = FileIdentity(
            entryIdentifier: "source",
            resolvedIdentifier: "source"
        )
        let destinationIdentity = FileIdentity(
            entryIdentifier: "destination",
            resolvedIdentifier: "destination"
        )
        let router = SmartSearchActionRouter(fileSystem: RecordingFileSystem(
            identities: [sourceURL: sourceIdentity, destinationURL: destinationIdentity]
        ))

        let requests = try await router.transferRequests(
            for: [actionResult(url: sourceURL, identity: sourceIdentity)],
            destination: destinationURL
        )

        #expect(requests == [IdentifiedTransferRequest(
            source: sourceURL,
            sourceIdentity: sourceIdentity,
            destinationRoot: destinationURL,
            destinationRootIdentity: destinationIdentity,
            relativeParentComponents: []
        )])
    }

    @Test func replacementIsNotSentToQuickLookPreparation() async {
        let url = URL(filePath: "/search/report.txt")
        let searched = FileIdentity(entryIdentifier: "searched", resolvedIdentifier: "searched")
        let replacement = FileIdentity(
            entryIdentifier: "replacement",
            resolvedIdentifier: "replacement"
        )
        let router = SmartSearchActionRouter(fileSystem: RecordingFileSystem(
            identities: [url: replacement]
        ))
        let presentation = ActionQuickLookPresentationRecorder()
        let controller = QuickLookController { presentation.present($0) }
        let materializer = InMemoryCloudMaterializer()

        let didPrepare = await router.prepareQuickLook(
            for: actionResult(url: url, identity: searched),
            controller: controller,
            materializer: materializer
        )

        #expect(!didPrepare)
        #expect(presentation.history.isEmpty)
        #expect(await materializer.recordedCalls().isEmpty)
        #expect(router.error == .itemChanged)
    }

    @Test func transferRefusalNeverFallsBackToAPathOnlyMutation() async {
        let sourceURL = URL(filePath: "/search/report.txt")
        let destinationURL = URL(filePath: "/destination", directoryHint: .isDirectory)
        let searched = FileIdentity(entryIdentifier: "searched", resolvedIdentifier: "searched")
        let replacement = FileIdentity(
            entryIdentifier: "replacement",
            resolvedIdentifier: "replacement"
        )
        let destination = FileIdentity(
            entryIdentifier: "destination",
            resolvedIdentifier: "destination"
        )
        let fileSystem = RecordingFileSystem(identities: [
            sourceURL: replacement,
            destinationURL: destination
        ])
        let router = SmartSearchActionRouter(fileSystem: fileSystem)

        do {
            _ = try await router.transferRequests(
                for: [actionResult(url: sourceURL, identity: searched)],
                destination: destinationURL
            )
            Issue.record("A replacement source must be rejected.")
        } catch let error as SmartSearchActionError {
            #expect(error == .itemChanged)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await fileSystem.events == [
            "identity:/destination",
            "identity:/search/report.txt"
        ])
    }

    @Test func missingSourceIsRejectedBeforeAnyTransferCanStart() async {
        let sourceURL = URL(filePath: "/search/report.txt")
        let destinationURL = URL(filePath: "/destination", directoryHint: .isDirectory)
        let source = FileIdentity(entryIdentifier: "source", resolvedIdentifier: "source")
        let originalDestination = FileIdentity(
            entryIdentifier: "destination",
            resolvedIdentifier: "destination"
        )
        let missingSourceRouter = SmartSearchActionRouter(fileSystem: RecordingFileSystem(
            identities: [destinationURL: originalDestination]
        ))
        let result = actionResult(url: sourceURL, identity: source)

        await assertItemChanged {
            try await missingSourceRouter.transferRequests(for: [result], destination: destinationURL)
        }

        #expect(missingSourceRouter.error == .itemChanged)
    }

    @Test func destinationReplacementAfterCaptureCannotCopyTheSearchResult() async throws {
        let sourceURL = URL(filePath: "/search/report.txt")
        let destinationURL = URL(filePath: "/destination", directoryHint: .isDirectory)
        let source = FileIdentity(entryIdentifier: "source", resolvedIdentifier: "source")
        let destination = FileIdentity(entryIdentifier: "destination", resolvedIdentifier: "destination")
        let replacement = FileIdentity(
            entryIdentifier: "replacement-destination",
            resolvedIdentifier: "replacement-destination"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [sourceURL, destinationURL],
            identities: [sourceURL: source, destinationURL: destination]
        )
        let workspace = WorkspaceState(
            leftURL: sourceURL.deletingLastPathComponent(),
            rightURL: destinationURL,
            listingService: StubDirectoryListingService(values: [:])
        )
        let operations = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: InMemoryCloudMaterializer()
        )
        let router = SmartSearchActionRouter(fileSystem: fileSystem)
        let requests = try await router.transferRequests(
            for: [actionResult(url: sourceURL, identity: source)],
            destination: destinationURL
        )
        await fileSystem.replaceIdentity(at: destinationURL, with: replacement)
        #expect(operations.runIdentifiedTransfer(
            requests,
            mode: .copy,
            workspace: workspace,
            includeSafeRelativePaths: false
        ))
        await waitUntilIdle(operations)

        let events = await fileSystem.events
        #expect(!events.contains { $0.hasPrefix("copy:") })
        guard case let .failed(source: failedSource, _)? = operations.lastResult?.outcomes.first else {
            Issue.record("A replaced destination must fail the identified transfer.")
            return
        }
        #expect(failedSource == sourceURL)
    }

    @Test func revealNavigatesToTheParentAndSelectsOnlyARevalidatedResult() async {
        let initialDirectory = URL(filePath: "/initial", directoryHint: .isDirectory)
        let parent = URL(filePath: "/search", directoryHint: .isDirectory)
        let url = parent.appending(path: "report.txt")
        let identity = FileIdentity(entryIdentifier: "report", resolvedIdentifier: "report")
        let pane = FilePaneState(
            directory: initialDirectory,
            listingService: StubDirectoryListingService(values: [parent: [listedItem(at: url)]])
        )
        let router = SmartSearchActionRouter(fileSystem: RecordingFileSystem(
            identities: [url: identity]
        ))

        let didReveal = await router.reveal(
            actionResult(url: url, identity: identity),
            in: pane
        )

        #expect(didReveal)
        #expect(pane.currentDirectory == parent)
        #expect(pane.selection == [url])
    }

    @Test func oppositePaneOpenUsesTheCapturedResultBeforeNavigating() async {
        let leftDirectory = URL(filePath: "/left", directoryHint: .isDirectory)
        let rightDirectory = URL(filePath: "/right", directoryHint: .isDirectory)
        let parent = URL(filePath: "/search", directoryHint: .isDirectory)
        let url = parent.appending(path: "report.txt")
        let identity = FileIdentity(entryIdentifier: "report", resolvedIdentifier: "report")
        let workspace = WorkspaceState(
            leftURL: leftDirectory,
            rightURL: rightDirectory,
            listingService: StubDirectoryListingService(values: [parent: [listedItem(at: url)]])
        )
        let router = SmartSearchActionRouter(fileSystem: RecordingFileSystem(
            identities: [url: identity]
        ))

        let didOpen = await router.openContainingFolderInOppositePane(
            for: actionResult(url: url, identity: identity),
            workspace: workspace
        )

        #expect(didOpen)
        #expect(workspace.right.currentDirectory == parent)
        #expect(workspace.right.selection == [url])
    }

    @Test func trashConfirmationRequiresTheCapturedOrderedResultIdentities() async {
        let firstURL = URL(filePath: "/search/first.txt")
        let secondURL = URL(filePath: "/search/second.txt")
        let firstIdentity = FileIdentity(entryIdentifier: "first", resolvedIdentifier: "first")
        let secondIdentity = FileIdentity(entryIdentifier: "second", resolvedIdentifier: "second")
        let directory = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let otherDirectory = URL(filePath: "/other", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(identities: [
            firstURL: firstIdentity,
            secondURL: secondIdentity
        ])
        let router = SmartSearchActionRouter(fileSystem: fileSystem)
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [:])
        )
        let operations = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: InMemoryCloudMaterializer()
        )
        let first = actionResult(url: firstURL, identity: firstIdentity)
        let second = actionResult(url: secondURL, identity: secondIdentity)

        let confirmation = await router.requestTrashConfirmation(
            for: [second, first],
            workspace: workspace
        )
        let didStart = await router.confirmTrash(
            confirmation,
            currentResults: [first, second],
            operationController: operations,
            workspace: workspace
        )

        #expect(confirmation?.orderedResultIdentities == [secondIdentity, firstIdentity])
        #expect(workspace.pendingTrashRequest?.items == [
            IdentifiedFileRequest(url: secondURL, identity: secondIdentity),
            IdentifiedFileRequest(url: firstURL, identity: firstIdentity)
        ])
        #expect(!didStart)
        #expect(workspace.pendingTrashRequest?.items.map(\.identity) == [secondIdentity, firstIdentity])
    }

    @Test func confirmedTrashUsesCapturedRequestsAndPrivacySafeProgress() async {
        let directory = URL(filePath: "/search", directoryHint: .isDirectory)
        let otherDirectory = URL(filePath: "/other", directoryHint: .isDirectory)
        let url = directory.appending(path: "report.txt")
        let identity = FileIdentity(entryIdentifier: "report", resolvedIdentifier: "report")
        let fileSystem = RecordingFileSystem(
            existingURLs: [url],
            identities: [url: identity]
        )
        let workspace = WorkspaceState(
            leftURL: directory,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [:])
        )
        let operations = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: InMemoryCloudMaterializer()
        )
        let router = SmartSearchActionRouter(fileSystem: fileSystem)
        let result = actionResult(url: url, identity: identity)
        let confirmation = await router.requestTrashConfirmation(for: [result], workspace: workspace)

        let didStart = await router.confirmTrash(
            confirmation,
            currentResults: [result],
            operationController: operations,
            workspace: workspace
        )
        await waitUntilIdle(operations)

        #expect(didStart)
        let existsAfterTrash = await fileSystem.exists(url)
        #expect(!existsAfterTrash)
        #expect(operations.operationHistory.first?.kind == .trash)
        #expect(operations.operationHistory.first?.itemDisplayName == "Item")
        #expect(workspace.pendingTrashRequest == nil)
    }

    private func actionResult(url: URL, identity: FileIdentity) -> SmartSearchResult {
        SmartSearchResult(
            item: FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: false,
                isPackage: false,
                modifiedAt: nil,
                byteSize: 1,
                typeDescription: "File"
            ),
            relativePath: url.lastPathComponent,
            score: 1,
            identity: identity
        )
    }

    private func listedItem(at url: URL) -> FileItem {
        FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        )
    }

    private func assertItemChanged(
        _ operation: () async throws -> [IdentifiedTransferRequest]
    ) async {
        do {
            _ = try await operation()
            Issue.record("A changed or missing item must be rejected.")
        } catch let error as SmartSearchActionError {
            #expect(error == .itemChanged)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func waitUntilIdle(_ controller: FileOperationController) async {
        while controller.isRunning {
            await Task.yield()
        }
    }
}

private final class ActionSecurityScopeDriver: SecurityScopedResourceAccessing, @unchecked Sendable {
    let permitsAccess: Bool
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    init(permitsAccess: Bool) { self.permitsAccess = permitsAccess }
    func startAccessing(_ url: URL) -> Bool { startedURLs.append(url); return permitsAccess }
    func stopAccessing(_ url: URL) { stoppedURLs.append(url) }
}

@MainActor
private final class ActionQuickLookPresentationRecorder {
    private(set) var history: [[URL]] = []

    func present(_ urls: [URL]) {
        history.append(urls)
    }
}
