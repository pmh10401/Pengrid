import Foundation
import Testing
@testable import BloomFileManager

private final class ProgressRecorder: @unchecked Sendable {
    private var values: [Int] = []
    private let lock = NSLock()

    func append(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func latest() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

@Suite("FileSystemAccessTests")
struct FileSystemAccessTests {
    @Test func folderSnapshotRejectsSymlinkAndReplacement() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let original = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)

        let target = root.url.appending(path: "target", directoryHint: .isDirectory)
        let link = root.url.appending(path: "link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try await LiveFileSystemAccess().captureFolderPreviewRequest(
            paneID: .left,
            url: link
        ) == nil)

        let fileSystem = LiveFileSystemAccess(onAfterFolderPreviewOpen: { request in
            try FileManager.default.moveItem(at: request.url, to: root.url.appending(path: "old"))
            try FileManager.default.createDirectory(at: request.url, withIntermediateDirectories: false)
        })
        let request = try #require(await fileSystem.captureFolderPreviewRequest(
            paneID: .left,
            url: original
        ))

        await #expect(throws: FileSystemAccessError.self) {
            try await fileSystem.snapshotFolder(request, visibility: .baseline, progress: { _ in })
        }
    }

    @Test func folderSnapshotUsesNoFollowChildMetadataAndLocalizedFolderOrder() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([1, 2]).write(to: folder.appending(path: "z-file"))
        try FileManager.default.createDirectory(
            at: folder.appending(path: "a-folder", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "linked-child"),
            withDestinationURL: folder.appending(path: "a-folder", directoryHint: .isDirectory)
        )

        let fileSystem = LiveFileSystemAccess()
        let request = try #require(await fileSystem.captureFolderPreviewRequest(
            paneID: .left,
            url: folder
        ))
        let progress = ProgressRecorder()
        let snapshot = try await fileSystem.snapshotFolder(
            request,
            visibility: .baseline,
            progress: progress.append
        )

        #expect(snapshot.entries.map(\.name) == ["a-folder", "linked-child", "z-file"])
        #expect(snapshot.entries.first?.isDirectory == true)
        #expect(snapshot.entries.first(where: { $0.name == "linked-child" })?.isDirectory == false)
        #expect(snapshot.entries.first(where: { $0.name == "linked-child" })?.byteSize != nil)
        let latestProgress = progress.latest()
        #expect(latestProgress == snapshot.entries.count)
    }

    @Test func folderSnapshotHonorsCancellationAfterOpeningItsDescriptor() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([1]).write(to: folder.appending(path: "child"))
        let fileSystem = LiveFileSystemAccess(onAfterFolderPreviewOpen: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let request = try #require(await fileSystem.captureFolderPreviewRequest(
            paneID: .left,
            url: folder
        ))

        await #expect(throws: CancellationError.self) {
            try await fileSystem.snapshotFolder(request, visibility: .baseline, progress: { _ in })
        }
    }

    @Test func folderCaptureRejectsPackageDirectories() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let package = root.url.appending(path: "Preview.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)

        let request = try await LiveFileSystemAccess().captureFolderPreviewRequest(
            paneID: .left,
            url: package
        )

        #expect(request == nil)
    }

    @Test func exclusiveMovePreservesExistingDestination() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let stagedItem = root.url.appending(path: "staged.zip")
        let destination = root.url.appending(path: "archive.zip")
        let stagedData = Data("staged archive".utf8)
        let existingData = Data("existing archive".utf8)
        try stagedData.write(to: stagedItem)
        try existingData.write(to: destination)
        let fileSystem = LiveFileSystemAccess()
        let destinationIdentity = try #require(await fileSystem.identity(of: destination))

        await #expect(throws: POSIXError(.EEXIST)) {
            try await fileSystem.moveExclusively(stagedItem, to: destination)
        }

        #expect(try Data(contentsOf: destination) == existingData)
        #expect(try await fileSystem.identity(of: destination) == destinationIdentity)
        #expect(try Data(contentsOf: stagedItem) == stagedData)
    }

    @Test func exclusiveMovePublishesStagedItemAtAbsentDestination() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let stagedItem = root.url.appending(path: "staged.zip")
        let destination = root.url.appending(path: "archive.zip")
        let stagedData = Data("staged archive".utf8)
        try stagedData.write(to: stagedItem)
        let fileSystem = LiveFileSystemAccess()
        let stagedIdentity = try #require(await fileSystem.identity(of: stagedItem))

        try await fileSystem.moveExclusively(stagedItem, to: destination)

        #expect(try Data(contentsOf: destination) == stagedData)
        #expect(try await fileSystem.identity(of: destination) == stagedIdentity)
        #expect(FileManager.default.fileExists(atPath: stagedItem.path) == false)
    }

    @Test func identifiedCopyRefusesAReplacementSource() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source.txt")
        let replacement = root.url.appending(path: "replacement.txt")
        let destination = root.url.appending(path: "copied.txt")
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: replacement)
        let fileSystem = LiveFileSystemAccess()
        let expectedIdentity = try #require(await fileSystem.identity(of: source))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: replacement, to: source)

        await #expect(throws: FileSystemAccessError.identityMismatch(source)) {
            _ = try await fileSystem.copyAndCaptureIdentity(
                source,
                identifiedBy: expectedIdentity,
                to: destination
            )
        }

        #expect(try Data(contentsOf: source) == Data("replacement".utf8))
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func identifiedTrashReturnsTheActualURLAndPreservesIdentity() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "trash-result-(UUID().uuidString).txt")
        try Data("temporary test fixture".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let identity = try #require(await fileSystem.identity(of: source))
        let resultingURL = try #require(
            try await fileSystem.trashAndReturnResultingURL(source, identifiedBy: identity)
        )
        defer { try? FileManager.default.removeItem(at: resultingURL) }

        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(try await fileSystem.identity(of: resultingURL) == identity)

        try await fileSystem.move(resultingURL, identifiedBy: identity, to: source)
        #expect(try await fileSystem.identity(of: source) == identity)
    }
}
