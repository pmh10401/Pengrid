import Foundation
import Testing
@testable import BloomFileManager

@Suite("FolderPreviewListingTests")
struct FolderPreviewListingTests {
    @Test func liveListingPassesTheExactRequestAndSharedVisibilityToFileSystem() async throws {
        let request = listingRequest("live")
        let expected = listingSnapshot(request, name: "child.txt")
        let fileSystem = ListingRecordingFileSystem(expectedSnapshot: expected)
        let listing = LiveFolderPreviewListing(fileSystem: fileSystem, visibility: .baseline)
        let recorder = ListingProgressRecorder()

        let actual = try await listing.snapshot(request, progress: recorder.record)

        #expect(actual == expected)
        #expect(await fileSystem.snapshotRequests == [request])
        #expect(await fileSystem.visibilities == [.baseline])
        #expect(recorder.values == [expected.entries.count])
    }

    @Test func liveListingRejectsASnapshotForAnotherExactRequest() async {
        let request = listingRequest("expected")
        let mismatched = listingSnapshot(listingRequest("replacement"), name: "child.txt")
        let listing = LiveFolderPreviewListing(
            fileSystem: ListingRecordingFileSystem(expectedSnapshot: mismatched),
            visibility: .baseline
        )

        await #expect(throws: FileSystemAccessError.identityMismatch(request.url)) {
            try await listing.snapshot(request, progress: { _ in })
        }
    }
}

private actor ListingRecordingFileSystem: FileSystemAccess {
    let expectedSnapshot: FolderPreviewSnapshot
    private(set) var snapshotRequests: [FolderPreviewRequest] = []
    private(set) var visibilities: [DirectoryVisibilityPolicy] = []

    init(expectedSnapshot: FolderPreviewSnapshot) {
        self.expectedSnapshot = expectedSnapshot
    }

    func snapshotFolder(_ request: FolderPreviewRequest, visibility: DirectoryVisibilityPolicy, progress: @escaping @Sendable (Int) -> Void) async throws -> FolderPreviewSnapshot {
        snapshotRequests.append(request)
        visibilities.append(visibility)
        progress(expectedSnapshot.entries.count)
        return expectedSnapshot
    }

    func exists(_ url: URL) async -> Bool { false }
    func createDirectory(_ url: URL) async throws {}
    func createEmptyItemAndCaptureIdentity(_ url: URL, kind: EmptyFileSystemItemKind, parentIdentifiedBy parentIdentity: FileIdentity) async throws -> OpenedEmptyFileSystemItem { fatalError("unused") }
    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity { fatalError("unused") }
    func move(_ source: URL, to destination: URL) async throws {}
    func moveExclusively(_ source: URL, to destination: URL) async throws {}
    func remove(_ url: URL) async throws {}
    func replace(_ destination: URL, with stagedItem: URL) async throws {}
    func identity(of url: URL) async throws -> FileIdentity? { nil }
    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws {}
    func moveExclusively(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws {}
    func moveExclusively(_ source: URL, identifiedBy sourceIdentity: FileIdentity, to destination: URL, destinationParentIdentifiedBy destinationParentIdentity: FileIdentity) async throws {}
    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws {}
    func replace(_ destination: URL, identifiedBy destinationIdentity: FileIdentity, with stagedItem: URL, identifiedBy stagedIdentity: FileIdentity) async throws {}
    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation { fatalError("unused") }
    func reserveStagingDirectory(beside destination: URL, parentIdentifiedBy parentIdentity: FileIdentity) async throws -> StagingReservation { fatalError("unused") }
    func removeStagingDirectory(_ reservation: StagingReservation) async throws {}
    func fingerprint(of source: URL) async throws -> SourceFingerprint { fatalError("unused") }
    func trash(_ url: URL) async throws {}
    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws {}
    func names(in directory: URL) async throws -> Set<String> { [] }
    func volumeIdentifier(for url: URL) async throws -> String { "" }
    func byteSize(of url: URL) async throws -> Int64? { nil }
    func availableCapacity(at url: URL) async throws -> Int64? { nil }
    func prepareDirectoryHierarchy(root: URL, identifiedBy rootIdentity: FileIdentity, relativeComponents: [String]) async throws -> PreparedDirectoryHierarchy { fatalError("unused") }
    func removeEmptyOwnedDirectories(root: URL, identifiedBy rootIdentity: FileIdentity, directories: [PreparedDirectoryHierarchy.OwnedDirectory]) async throws {}
}

private final class ListingProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func record(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

private func listingRequest(_ name: String) -> FolderPreviewRequest {
    FolderPreviewRequest(
        paneID: .left,
        url: URL(filePath: "/preview/\(name)", directoryHint: .isDirectory),
        identity: FileIdentity(entryIdentifier: name, resolvedIdentifier: name),
        kind: .ordinaryDirectory
    )
}

private func listingSnapshot(_ request: FolderPreviewRequest, name: String) -> FolderPreviewSnapshot {
    FolderPreviewSnapshot(request: request, entries: [
        FolderPreviewEntry(name: name, isDirectory: false, isPackage: false, byteSize: 1, modifiedAt: nil)
    ])
}
