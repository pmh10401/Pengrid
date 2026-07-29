import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CloudOperationGateTests {
    @MainActor
    @Test func quickLookPresentsOnlyAfterMaterializationSucceeds() async {
        let url = URL(filePath: "/Cloud/account/report.txt")
        let request = IdentifiedFileRequest(url: url, identity: identity("report"))
        let presenter = QuickLookPresentationRecorder()
        let controller = QuickLookController(onPresent: { urls in
            presenter.present(urls)
        })
        let failure = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [],
            failures: [.init(name: "report.txt", reason: .offline)],
            wasCancelled: false
        ))

        await controller.prepareAndPresent(requests: [request], materializer: failure)
        #expect(presenter.invocationCount == 0)
        #expect(presenter.history.isEmpty)

        let success = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [request],
            failures: [],
            wasCancelled: false
        ))
        await controller.prepareAndPresent(requests: [request], materializer: success)
        #expect(presenter.urls == [url])
        #expect(presenter.invocationCount == 1)
        #expect(presenter.history == [[url]])
    }

    @MainActor
    @Test func quickLookNeverPresentsCancelledOrIdentityMismatchedPreparation() async {
        let url = URL(filePath: "/Cloud/account/report.txt")
        let request = IdentifiedFileRequest(url: url, identity: identity("report"))
        let presenter = QuickLookPresentationRecorder()
        let controller = QuickLookController(onPresent: { urls in
            presenter.present(urls)
        })
        let cancellation = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [],
            failures: [],
            wasCancelled: true
        ))

        await controller.prepareAndPresent(requests: [request], materializer: cancellation)

        let mismatch = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [
                IdentifiedFileRequest(url: url, identity: identity("replacement"))
            ],
            failures: [],
            wasCancelled: false
        ))
        await controller.prepareAndPresent(requests: [request], materializer: mismatch)

        #expect(presenter.invocationCount == 0)
        #expect(presenter.history.isEmpty)
    }

    @MainActor
    @Test func quickLookSlowerOlderRequestCannotReplaceNewerPreview() async {
        let oldURL = URL(filePath: "/Cloud/account/old.txt")
        let newURL = URL(filePath: "/Cloud/account/new.txt")
        let oldRequest = IdentifiedFileRequest(url: oldURL, identity: identity("old"))
        let newRequest = IdentifiedFileRequest(url: newURL, identity: identity("new"))
        let presenter = QuickLookPresentationRecorder()
        let controller = QuickLookController(onPresent: { urls in
            presenter.present(urls)
        })
        let olderMaterializer = SuspendingGateMaterializer()
        let olderTask = Task { @MainActor in
            await controller.prepareAndPresent(
                requests: [oldRequest],
                materializer: olderMaterializer
            )
        }
        while !(await olderMaterializer.hasProgressed) {
            await Task.yield()
        }
        let newerMaterializer = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [newRequest],
            failures: [],
            wasCancelled: false
        ))

        await controller.prepareAndPresent(
            requests: [newRequest],
            materializer: newerMaterializer
        )
        await olderMaterializer.release()
        await olderTask.value

        #expect(presenter.invocationCount == 1)
        #expect(presenter.history == [[newURL]])
    }

    @MainActor
    @Test func openDoesNotReachNSWorkspaceAfterMaterializationFailure() async {
        let url = URL(filePath: "/Cloud/private/account/brief.pages")
        let directory = url.deletingLastPathComponent()
        let directoryItem = fileItem(at: directory, isDirectory: true)
        let item = fileItem(at: url, isDirectory: true, isPackage: true)
        let fileSystem = RecordingFileSystem(
            existingURLs: [url],
            identities: [url: identity("package")]
        )
        let materializer = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [],
            failures: [.init(name: "brief.pages", reason: .permissionDenied)],
            wasCancelled: false
        ))
        let opener = RecordingWorkspaceOpener()
        let pane = FilePaneState(
            directory: URL(filePath: "/Cloud"),
            listingService: StubDirectoryListingService(values: [:])
        )

        await WorkspaceOpenActions.open(
            [directoryItem, item],
            in: pane,
            fileSystem: fileSystem,
            materializer: materializer,
            opener: opener
        )

        #expect(opener.openedURLs.isEmpty)
        #expect(pane.currentDirectory == directory)
        #expect(await materializer.recordedPurposes == [.open])
        #expect(await materializer.recordedRequests == [
            IdentifiedFileRequest(url: url, identity: identity("package"))
        ])
    }

    @MainActor
    @Test func transferDoesNotReachFileOperationServiceAfterCancellation() async {
        let source = URL(filePath: "/Cloud/source.txt")
        let destination = URL(filePath: "/destination", directoryHint: .isDirectory)
        let sourceIdentity = identity("source")
        let destinationIdentity = identity("destination")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            identities: [source: sourceIdentity, destination: destinationIdentity]
        )
        let materializer = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [],
            failures: [],
            wasCancelled: true
        ))
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: materializer
        )
        let workspace = workspace(left: destination)
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: sourceIdentity,
            destinationRoot: destination,
            destinationRootIdentity: destinationIdentity,
            relativeParentComponents: []
        )

        #expect(controller.runIdentifiedTransfer([request], mode: .move, workspace: workspace))
        await waitUntilIdle(controller)

        #expect(await fileSystem.events.isEmpty)
        #expect(controller.lastResult?.outcomes == [
            .cancelled(source: source)
        ])
    }

    @MainActor
    @Test func urlTransferFailsClosedWhenDestinationIdentityCannotBeCaptured() async {
        let source = URL(filePath: "/Cloud/source.txt")
        let destination = URL(filePath: "/missing-destination", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            identities: [source: identity("source")]
        )
        let materializer = RecordingGateMaterializer(result: CloudMaterializationResult(
            preparedRequests: [
                IdentifiedFileRequest(url: source, identity: identity("source"))
            ],
            failures: [],
            wasCancelled: false
        ))
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: materializer
        )

        #expect(controller.runTransfer(
            [source],
            to: destination,
            mode: .copy,
            workspace: workspace(left: destination)
        ))
        await waitUntilIdle(controller)

        #expect(controller.lastResult?.outcomes == [
            .failed(
                source: source,
                message: "transfer-preparation:destination-identity-unavailable"
            )
        ])
        #expect(await materializer.recordedRequests.isEmpty)
        #expect(await fileSystem.events == ["identity:/missing-destination"])
    }

    @MainActor
    @Test func successfulTransferUsesTheRevalidatedIdentifiedRequests() async {
        let source = URL(filePath: "/Cloud/source.txt")
        let destination = URL(filePath: "/destination", directoryHint: .isDirectory)
        let originalIdentity = FileIdentity(
            entryIdentifier: "before",
            resolvedIdentifier: "stable-source"
        )
        let revalidatedIdentity = FileIdentity(
            entryIdentifier: "after",
            resolvedIdentifier: "stable-source"
        )
        let destinationIdentity = identity("destination")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            volumeIdentifiers: [source: "same", destination: "same"],
            identities: [source: originalIdentity, destination: destinationIdentity]
        )
        let materializer = TransformingGateMaterializer { requests, progress in
            await progress(.init(completedCount: 1, totalCount: 1, currentName: source.path))
            await fileSystem.replaceIdentity(at: source, with: revalidatedIdentity)
            return CloudMaterializationResult(
                preparedRequests: [
                    IdentifiedFileRequest(url: source, identity: revalidatedIdentity)
                ],
                failures: [],
                wasCancelled: false
            )
        }
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: materializer
        )
        let workspace = workspace(left: destination)
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: originalIdentity,
            destinationRoot: destination,
            destinationRootIdentity: destinationIdentity,
            relativeParentComponents: []
        )

        #expect(controller.runIdentifiedTransfer([request], mode: .move, workspace: workspace))
        await waitUntilIdle(controller)

        #expect(controller.lastResult?.hasFailures == false)
        #expect(await fileSystem.existingURLs.contains(destination.appending(path: "source.txt")))
    }

    @Test func checksumReadsBytesOnlyAfterPreparation() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let gate = SuspendingGateMaterializer()
        let progress = ChecksumProgressRecorder()
        let service = LiveChecksumService(materializer: gate, chunkSize: 4_096)

        let checksumTask = Task {
            try await service.checksum(for: pair.leftRequest) { value in
                await progress.record(value)
            }
        }
        while !(await gate.hasProgressed) {
            await Task.yield()
        }

        #expect(await progress.values.isEmpty)
        await gate.release()
        _ = try await checksumTask.value
        #expect(await progress.values.last == 1)
    }

    @MainActor
    @Test func preparationProgressPrecedesOrdinaryTransferProgress() async {
        let source = URL(filePath: "/Cloud/secret/provider/item.txt")
        let destination = URL(filePath: "/destination", directoryHint: .isDirectory)
        let sourceIdentity = identity("source")
        let destinationIdentity = identity("destination")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            volumeIdentifiers: [source: "same", destination: "same"],
            identities: [source: sourceIdentity, destination: destinationIdentity]
        )
        let gate = SuspendingGateMaterializer()
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem),
            materializer: gate
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: sourceIdentity,
            destinationRoot: destination,
            destinationRootIdentity: destinationIdentity,
            relativeParentComponents: []
        )

        #expect(controller.runIdentifiedTransfer(
            [request],
            mode: .move,
            workspace: workspace(left: destination)
        ))
        while !(await gate.hasProgressed) {
            await Task.yield()
        }

        #expect(controller.stage == .preparing(.init(
            completedCount: 1,
            totalCount: 1,
            currentName: "item.txt"
        )))
        #expect(await fileSystem.events.isEmpty)

        await gate.release()
        await waitUntilIdle(controller)
        #expect(controller.stage == .operating(.init(
            completedCount: 1,
            totalCount: 1,
            currentName: "item.txt"
        )))
    }

    private func identity(_ value: String) -> FileIdentity {
        FileIdentity(entryIdentifier: value, resolvedIdentifier: value)
    }

    private func fileItem(
        at url: URL,
        isDirectory: Bool = false,
        isPackage: Bool = false
    ) -> FileItem {
        FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: isDirectory ? "Folder" : "File"
        )
    }

    @MainActor
    private func workspace(left: URL) -> WorkspaceState {
        WorkspaceState(
            leftURL: left,
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
    }

    @MainActor
    private func waitUntilIdle(_ controller: FileOperationController) async {
        while controller.isRunning {
            await Task.yield()
        }
    }
}

@MainActor
private final class QuickLookPresentationRecorder {
    private(set) var history: [[URL]] = []

    var invocationCount: Int {
        history.count
    }

    var urls: [URL] {
        history.last ?? []
    }

    func present(_ urls: [URL]) {
        history.append(urls)
    }
}

@MainActor
private final class RecordingWorkspaceOpener: WorkspaceOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

private actor RecordingGateMaterializer: CloudMaterializing {
    private let result: CloudMaterializationResult
    private(set) var recordedPurposes: [CloudPreparationPurpose] = []
    private(set) var recordedRequests: [IdentifiedFileRequest] = []

    init(result: CloudMaterializationResult) {
        self.result = result
    }

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        recordedRequests.append(contentsOf: requests)
        recordedPurposes.append(purpose)
        return result
    }
}

private actor TransformingGateMaterializer: CloudMaterializing {
    typealias Handler = @Sendable (
        [IdentifiedFileRequest],
        @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        await handler(requests, progress)
    }
}

private actor SuspendingGateMaterializer: CloudMaterializing {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasProgressed = false

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        await progress(.init(
            completedCount: 1,
            totalCount: requests.count,
            currentName: "/private/provider/account/\(requests.first?.url.lastPathComponent ?? "")"
        ))
        hasProgressed = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return CloudMaterializationResult(
            preparedRequests: requests,
            failures: [],
            wasCancelled: false
        )
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
