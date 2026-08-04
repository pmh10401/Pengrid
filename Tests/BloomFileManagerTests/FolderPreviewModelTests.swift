import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FolderPreviewModelTests {
    @Test func rowsPublishOnlyAfterValidatedSnapshotCompletes() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let request = folderPreviewRequest("one")
        let snapshot = folderPreviewSnapshot(request, name: "child.txt")

        model.load(request)
        #expect(await waitForAsyncCondition("the initial listing to start") {
            await listing.hasStarted(count: 1)
        })
        await listing.reportProgress(200, for: request)
        #expect(await waitForFolderPreview("the first progress update") {
            model.examinedCount == 200
        })
        #expect(model.entries.isEmpty)
        #expect(model.phase == .loading)

        await listing.finish(request: request, with: snapshot)
        #expect(await waitForFolderPreview("the completed snapshot") {
            model.entries == snapshot.entries
        })

        #expect(model.phase == .loaded)
    }

    @Test func staleErrorAndProgressCannotPublishOverANewerGeneration() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let first = folderPreviewRequest("first")
        let second = folderPreviewRequest("second")
        let newSnapshot = folderPreviewSnapshot(second, name: "new.txt")

        model.load(first)
        #expect(await waitForAsyncCondition("the first listing to start") {
            await listing.hasStarted(count: 1)
        })
        await listing.reportProgress(4, for: first)
        #expect(await waitForFolderPreview("first-generation progress") {
            model.examinedCount == 4
        })

        model.load(second)
        #expect(await waitForAsyncCondition("the replacement listing to start") {
            await listing.hasStarted(count: 2)
        })
        await listing.reportProgress(900, for: first)
        await listing.fail(request: first, with: FolderPreviewFixtureError.expected)
        #expect(await waitForFolderPreview("the replacement loading state") {
            model.phase == .loading && model.examinedCount == 0
        })

        #expect(model.entries.isEmpty)
        #expect(model.phase == .loading)
        #expect(model.examinedCount == 0)

        await listing.finish(request: second, with: newSnapshot)
        #expect(await waitForFolderPreview("the replacement snapshot") {
            model.entries == newSnapshot.entries
        })

        #expect(model.entries == newSnapshot.entries)
        #expect(model.phase == .loaded)
    }

    @Test func staleSuccessfulSnapshotCannotPublishOverANewerGeneration() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let first = folderPreviewRequest("first-success")
        let second = folderPreviewRequest("second-success")
        let oldSnapshot = folderPreviewSnapshot(first, name: "old.txt")
        let newSnapshot = folderPreviewSnapshot(second, name: "new.txt")

        model.load(first)
        #expect(await waitForAsyncCondition("the first listing to start") {
            await listing.hasStarted(count: 1)
        })
        model.load(second)
        #expect(await waitForAsyncCondition("the replacement listing to start") {
            await listing.hasStarted(count: 2)
        })

        await listing.finish(request: first, with: oldSnapshot)
        #expect(await waitForFolderPreview("the replacement to remain loading after stale success") {
            model.entries.isEmpty && model.phase == .loading
        })

        await listing.finish(request: second, with: newSnapshot)
        #expect(await waitForFolderPreview("the current successful snapshot") {
            model.entries == newSnapshot.entries
        })
        #expect(model.entries == newSnapshot.entries)
        #expect(model.phase == .loaded)
    }

    @Test func cancelClearsStateAndPreventsANonCooperativeListingFromPublishing() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let request = folderPreviewRequest("cancel")

        model.load(request)
        #expect(await waitForAsyncCondition("the listing to start before cancellation") {
            await listing.hasStarted(count: 1)
        })
        model.cancel()
        await listing.finish(request: request, with: folderPreviewSnapshot(request, name: "late.txt"))
        #expect(await waitForFolderPreview("the cleared cancellation state") {
            model.request == nil && model.phase == .idle
        })

        #expect(model.request == nil)
        #expect(model.entries.isEmpty)
        #expect(model.examinedCount == 0)
        #expect(model.phase == .idle)
    }

    @Test func replacementLoadCancelsThePriorListingTask() async {
        let listing = CancellationObservingFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)

        model.load(folderPreviewRequest("first"))
        #expect(await waitForAsyncCondition("the first cancellation-observing listing to start") {
            await listing.hasStarted(count: 1)
        })
        model.load(folderPreviewRequest("second"))
        #expect(await waitForAsyncCondition("the replaced listing task to receive cancellation") {
            await listing.hasCancelled(count: 1)
        })
        #expect(await waitForAsyncCondition("the second listing to start") {
            await listing.hasStarted(count: 2)
        })

        #expect(await listing.cancelledCount == 1)
        #expect(model.request == folderPreviewRequest("second"))
        #expect(model.entries.isEmpty)
        #expect(model.phase == .loading)
        model.cancel()
    }

    @Test func mapsIdentityMismatchAndUnexpectedErrorsWithoutPublishingRows() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let request = folderPreviewRequest("errors")

        model.load(request)
        #expect(await waitForAsyncCondition("the identity-mismatch listing to start") {
            await listing.hasStarted(count: 1)
        })
        await listing.fail(request: request, with: FileSystemAccessError.identityMismatch(request.url))
        #expect(await waitForFolderPreview("the folder-changed error") {
            model.phase == .failed(.folderChanged)
        })
        #expect(model.entries.isEmpty)
        #expect(model.statusText == "Folder changed. Close the preview and try again.")

        model.load(request)
        #expect(await waitForAsyncCondition("the unavailable listing to start") {
            await listing.hasStarted(count: 2)
        })
        await listing.fail(request: request, with: FolderPreviewFixtureError.expected)
        #expect(await waitForFolderPreview("the unavailable error") {
            model.phase == .failed(.unavailable)
        })
        #expect(model.entries.isEmpty)
        #expect(model.statusText == "Folder contents are unavailable without downloading.")
    }

    @Test func aMismatchedSnapshotFailsClosedAsFolderChanged() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let request = folderPreviewRequest("expected")

        model.load(request)
        #expect(await waitForAsyncCondition("the mismatched-snapshot listing to start") {
            await listing.hasStarted(count: 1)
        })
        await listing.finish(
            request: request,
            with: folderPreviewSnapshot(folderPreviewRequest("replacement"), name: "replacement.txt")
        )
        #expect(await waitForFolderPreview("the mismatched snapshot failure") {
            model.phase == .failed(.folderChanged)
        })

        #expect(model.entries.isEmpty)
    }

    @Test func ownerDeinitializationCancelsNoncooperativeWorkAndEndsItsProgressPath() async {
        let listing = NoncooperativeLifetimeFolderPreviewListing()
        weak var weakModel: FolderPreviewModel?
        let request = folderPreviewRequest("lifetime")

        do {
            let model = FolderPreviewModel(listing: listing)
            weakModel = model
            model.load(request)
            #expect(await waitForAsyncCondition("the noncooperative listing to start") {
                await listing.hasStarted
            })
            await listing.reportProgress(1)
            #expect(await waitForFolderPreview("the progress consumer to receive the initial update") {
                model.examinedCount == 1
            })
        }

        #expect(await waitForFolderPreview("the model to deinitialize") { weakModel == nil })
        #expect(await waitForAsyncCondition("the noncooperative listing task to receive cancellation") {
            await listing.hasObservedCancellation
        })
        await listing.reportProgress(2)
        await listing.allowCompletion()
        #expect(await waitForAsyncCondition("the cancelled listing task to exit") {
            await listing.hasExited
        })
        #expect(weakModel == nil)
    }
}

private enum FolderPreviewFixtureError: Error, Sendable {
    case expected
}

private actor SuspendedFolderPreviewListing: FolderPreviewListing {
    private struct Wait {
        let request: FolderPreviewRequest
        let progress: @Sendable (Int) -> Void
        let continuation: CheckedContinuation<FolderPreviewSnapshot, any Error>
    }

    private var waits: [Wait] = []
    private var startedCount = 0

    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            startedCount += 1
            waits.append(Wait(request: request, progress: progress, continuation: continuation))
        }
    }

    func hasStarted(count: Int) -> Bool { startedCount >= count }

    func reportProgress(_ count: Int, for request: FolderPreviewRequest) {
        waits.last(where: { $0.request == request })?.progress(count)
    }

    func finish(request: FolderPreviewRequest, with snapshot: FolderPreviewSnapshot) {
        guard let index = waits.firstIndex(where: { $0.request == request }) else { return }
        waits.remove(at: index).continuation.resume(returning: snapshot)
    }

    func fail(request: FolderPreviewRequest, with error: any Error) {
        guard let index = waits.firstIndex(where: { $0.request == request }) else { return }
        waits.remove(at: index).continuation.resume(throwing: error)
    }
}

private actor CancellationObservingFolderPreviewListing: FolderPreviewListing {
    private var startedCount = 0
    private(set) var cancelledCount = 0
    private var continuations: [UUID: CheckedContinuation<FolderPreviewSnapshot, any Error>] = [:]

    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        startedCount += 1
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[requestID] = continuation
            }
        } onCancel: {
            Task { await self.cancel(requestID) }
        }
    }

    func hasStarted(count: Int) -> Bool { startedCount >= count }
    func hasCancelled(count: Int) -> Bool { cancelledCount >= count }

    private func cancel(_ requestID: UUID) {
        cancelledCount += 1
        continuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }
}

private actor NoncooperativeLifetimeFolderPreviewListing: FolderPreviewListing {
    private var started = false
    private var observedCancellation = false
    private var completionAllowed = false
    private var exited = false
    private var progress: (@Sendable (Int) -> Void)?
    private var completionContinuation: CheckedContinuation<Void, Never>?

    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        self.progress = progress
        started = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completionContinuation = continuation
                if completionAllowed {
                    completionContinuation = nil
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        exited = true
        return folderPreviewSnapshot(request, name: "late.txt")
    }

    var hasStarted: Bool { started }
    var hasObservedCancellation: Bool { observedCancellation }
    var hasExited: Bool { exited }

    func reportProgress(_ count: Int) {
        progress?(count)
    }

    func allowCompletion() {
        completionAllowed = true
        completionContinuation?.resume()
        completionContinuation = nil
    }

    private func recordCancellation() {
        observedCancellation = true
    }
}

private func folderPreviewRequest(_ name: String) -> FolderPreviewRequest {
    FolderPreviewRequest(
        paneID: .left,
        url: URL(filePath: "/preview/\(name)", directoryHint: .isDirectory),
        identity: FileIdentity(entryIdentifier: name, resolvedIdentifier: name),
        kind: .ordinaryDirectory
    )
}

private func folderPreviewSnapshot(_ request: FolderPreviewRequest, name: String) -> FolderPreviewSnapshot {
    FolderPreviewSnapshot(request: request, entries: [
        FolderPreviewEntry(name: name, isDirectory: false, isPackage: false, byteSize: 1, modifiedAt: nil)
    ])
}

@MainActor
private func waitForFolderPreview(
    _ description: String,
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for \(description).")
            return false
        }
        await Task.yield()
    }
    return true
}

private func waitForAsyncCondition(
    _ description: String,
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for \(description).")
            return false
        }
        await Task.yield()
    }
    return true
}
