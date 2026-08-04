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
        await listing.waitUntilStarted(count: 1)
        await listing.reportProgress(200, for: request)
        await waitForFolderPreview { model.examinedCount == 200 }
        #expect(model.entries.isEmpty)
        #expect(model.phase == .loading)

        await listing.finish(request: request, with: snapshot)
        await waitForFolderPreview { model.entries == snapshot.entries }

        #expect(model.phase == .loaded)
    }

    @Test func staleGenerationCannotPublishRowsErrorOrProgress() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let first = folderPreviewRequest("first")
        let second = folderPreviewRequest("second")
        let oldSnapshot = folderPreviewSnapshot(first, name: "old.txt")
        let newSnapshot = folderPreviewSnapshot(second, name: "new.txt")

        model.load(first)
        await listing.waitUntilStarted(count: 1)
        await listing.reportProgress(4, for: first)
        await waitForFolderPreview { model.examinedCount == 4 }

        model.load(second)
        await listing.waitUntilStarted(count: 2)
        await listing.reportProgress(900, for: first)
        await listing.fail(request: first, with: FolderPreviewFixtureError.expected)
        await Task.yield()

        #expect(model.entries.isEmpty)
        #expect(model.phase == .loading)
        #expect(model.examinedCount == 0)

        await listing.finish(request: second, with: newSnapshot)
        await waitForFolderPreview { model.entries == newSnapshot.entries }
        await listing.finishIfWaiting(request: first, with: oldSnapshot)

        #expect(model.entries == newSnapshot.entries)
        #expect(model.phase == .loaded)
    }

    @Test func cancelClearsStateAndPreventsANonCooperativeListingFromPublishing() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let request = folderPreviewRequest("cancel")

        model.load(request)
        await listing.waitUntilStarted(count: 1)
        model.cancel()
        await listing.finish(request: request, with: folderPreviewSnapshot(request, name: "late.txt"))
        await Task.yield()

        #expect(model.request == nil)
        #expect(model.entries.isEmpty)
        #expect(model.examinedCount == 0)
        #expect(model.phase == .idle)
    }

    @Test func replacementLoadCancelsThePriorListingTask() async {
        let listing = CancellationObservingFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)

        model.load(folderPreviewRequest("first"))
        await listing.waitUntilStarted(count: 1)
        model.load(folderPreviewRequest("second"))
        await listing.waitUntilCancelled(count: 1)
        await listing.waitUntilStarted(count: 2)

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
        await listing.waitUntilStarted(count: 1)
        await listing.fail(request: request, with: FileSystemAccessError.identityMismatch(request.url))
        await waitForFolderPreview { model.phase == .failed(.folderChanged) }
        #expect(model.entries.isEmpty)
        #expect(model.statusText == "Folder changed. Close the preview and try again.")

        model.load(request)
        await listing.waitUntilStarted(count: 2)
        await listing.fail(request: request, with: FolderPreviewFixtureError.expected)
        await waitForFolderPreview { model.phase == .failed(.unavailable) }
        #expect(model.entries.isEmpty)
        #expect(model.statusText == "Folder contents are unavailable without downloading.")
    }

    @Test func aMismatchedSnapshotFailsClosedAsFolderChanged() async {
        let listing = SuspendedFolderPreviewListing()
        let model = FolderPreviewModel(listing: listing)
        let request = folderPreviewRequest("expected")

        model.load(request)
        await listing.waitUntilStarted(count: 1)
        await listing.finish(
            request: request,
            with: folderPreviewSnapshot(folderPreviewRequest("replacement"), name: "replacement.txt")
        )
        await waitForFolderPreview { model.phase == .failed(.folderChanged) }

        #expect(model.entries.isEmpty)
    }

    @Test func ownerDeinitializationDoesNotKeepItselfAliveThroughANonCooperativeListing() async {
        let listing = SuspendedFolderPreviewListing()
        weak var weakModel: FolderPreviewModel?
        let request = folderPreviewRequest("lifetime")

        do {
            let model = FolderPreviewModel(listing: listing)
            weakModel = model
            model.load(request)
            await listing.waitUntilStarted(count: 1)
        }

        await waitForFolderPreview { weakModel == nil }
        #expect(weakModel == nil)
        await listing.finish(request: request, with: folderPreviewSnapshot(request, name: "late.txt"))
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

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await Task.yield()
        }
    }

    func reportProgress(_ count: Int, for request: FolderPreviewRequest) {
        waits.last(where: { $0.request == request })?.progress(count)
    }

    func finish(request: FolderPreviewRequest, with snapshot: FolderPreviewSnapshot) {
        guard let index = waits.firstIndex(where: { $0.request == request }) else { return }
        waits.remove(at: index).continuation.resume(returning: snapshot)
    }

    func finishIfWaiting(request: FolderPreviewRequest, with snapshot: FolderPreviewSnapshot) {
        finish(request: request, with: snapshot)
    }

    func fail(request: FolderPreviewRequest, with error: any Error) {
        guard let index = waits.firstIndex(where: { $0.request == request }) else { return }
        waits.remove(at: index).continuation.resume(throwing: error)
    }
}

private actor CancellationObservingFolderPreviewListing: FolderPreviewListing {
    private var startedCount = 0
    private(set) var cancelledCount = 0

    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        startedCount += 1
        while !Task.isCancelled {
            await Task.yield()
        }
        cancelledCount += 1
        throw CancellationError()
    }

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await Task.yield()
        }
    }

    func waitUntilCancelled(count: Int) async {
        while cancelledCount < count {
            await Task.yield()
        }
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
    _ condition: @escaping @MainActor () -> Bool
) async {
    while !condition() {
        await Task.yield()
    }
}
