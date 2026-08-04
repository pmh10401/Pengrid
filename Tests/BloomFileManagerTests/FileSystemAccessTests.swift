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

private enum FolderPreviewFixtureError: Error, Sendable {
    case expected
}

private final class FolderPreviewPackageMetadataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    private let packageNames: Set<String>

    init(packageNames: Set<String>) {
        self.packageNames = packageNames
    }

    func isPackage(_ url: URL) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        recordedURLs.append(url)
        return packageNames.contains(resolvedName(for: url))
    }

    func urls() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    private func resolvedName(for url: URL) -> String {
        guard url.path.hasPrefix("/dev/fd/"),
              let descriptor = Int32(url.lastPathComponent) else {
            return url.lastPathComponent
        }
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.fcntl(descriptor, F_GETPATH, &path) == 0 else {
            return url.lastPathComponent
        }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(filePath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
    }
}

private func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

@Suite("FileSystemAccessTests", .serialized)
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

    @Test func folderCaptureUsesAuthoritativePackageMetadataForRegisteredPackageNames() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let packageNames: Set<String> = [
            "Document.pages", "Workbook.numbers", "Deck.key", "Library.photoslibrary", "Project.xcworkspace"
        ]
        for name in packageNames {
            try FileManager.default.createDirectory(
                at: root.url.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }
        let ordinary = root.url.appending(path: "ordinary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: false)
        let recorder = FolderPreviewPackageMetadataRecorder(packageNames: packageNames)
        let fileSystem = LiveFileSystemAccess(folderPreviewPackageMetadata: recorder.isPackage)

        for name in packageNames {
            let request = try await fileSystem.captureFolderPreviewRequest(
                paneID: .left,
                url: root.url.appending(path: name, directoryHint: .isDirectory)
            )
            #expect(request == nil)
        }
        let ordinaryRequest = try await fileSystem.captureFolderPreviewRequest(
            paneID: .left,
            url: ordinary
        )
        #expect(ordinaryRequest != nil)
        #expect(recorder.urls().allSatisfy { $0.path.hasPrefix("/dev/fd/") })
    }

    @Test func defaultFoundationPackageMetadataRecognizesCommonPackagesAtRootAndChild() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let packageNames: Set<String> = [
            "Document.pages", "Workbook.numbers", "Deck.key", "Library.photoslibrary", "Project.xcworkspace"
        ]
        let fileSystem = LiveFileSystemAccess()
        for name in packageNames {
            let package = root.url.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            #expect(try await fileSystem.captureFolderPreviewRequest(paneID: .left, url: package) == nil)
        }
        let ordinary = root.url.appending(path: "ordinary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: false)
        #expect(try await fileSystem.captureFolderPreviewRequest(paneID: .left, url: ordinary) != nil)

        let parent = root.url.appending(path: "parent", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        for name in packageNames {
            try FileManager.default.createDirectory(
                at: parent.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.createDirectory(
            at: parent.appending(path: "ordinary-child", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let request = try #require(await fileSystem.captureFolderPreviewRequest(paneID: .left, url: parent))
        let snapshot = try await fileSystem.snapshotFolder(request, visibility: .baseline, progress: { _ in })

        #expect(Set(snapshot.entries.filter(\.isPackage).map(\.name)) == packageNames)
        #expect(snapshot.entries.first(where: { $0.name == "ordinary-child" })?.isPackage == false)
    }

    @Test func folderSnapshotUsesAnchoredAuthoritativePackageMetadataForChildren() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let packageNames: Set<String> = [
            "Document.pages", "Workbook.numbers", "Deck.key", "Library.photoslibrary", "Project.xcworkspace"
        ]
        for name in packageNames {
            try FileManager.default.createDirectory(
                at: folder.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }
        let recorder = FolderPreviewPackageMetadataRecorder(packageNames: packageNames)
        let fileSystem = LiveFileSystemAccess(folderPreviewPackageMetadata: recorder.isPackage)
        let request = try #require(await fileSystem.captureFolderPreviewRequest(paneID: .left, url: folder))

        let snapshot = try await fileSystem.snapshotFolder(
            request,
            visibility: .baseline,
            progress: { _ in }
        )

        #expect(Set(snapshot.entries.filter(\.isPackage).map(\.name)) == packageNames)
        #expect(recorder.urls().filter { $0.lastPathComponent != "folder" }.allSatisfy {
            $0.path.hasPrefix("/dev/fd/")
        })
    }

    @Test func folderSnapshotFailsClosedWhenPackageMetadataFails() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "child", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let fileSystem = LiveFileSystemAccess(folderPreviewPackageMetadata: { _ in
            throw FolderPreviewFixtureError.expected
        })
        let request = try #require(await LiveFileSystemAccess().captureFolderPreviewRequest(
            paneID: .left,
            url: folder
        ))

        await #expect(throws: FolderPreviewFixtureError.self) {
            try await fileSystem.snapshotFolder(request, visibility: .baseline, progress: { _ in })
        }
    }

    @Test func folderSnapshotRejectsEntryIdentityMismatchEvenWhenResolvedIdentityMatches() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fileSystem = LiveFileSystemAccess()
        let request = try #require(await fileSystem.captureFolderPreviewRequest(paneID: .left, url: folder))
        let replacementIdentity = FileIdentity(
            entryIdentifier: "replacement-entry",
            resolvedIdentifier: request.identity.resolvedIdentifier
        )
        let replacementRequest = FolderPreviewRequest(
            paneID: request.paneID,
            url: request.url,
            identity: replacementIdentity,
            kind: request.kind
        )

        await #expect(throws: FileSystemAccessError.identityMismatch(folder)) {
            try await fileSystem.snapshotFolder(
                replacementRequest,
                visibility: .baseline,
                progress: { _ in }
            )
        }
    }

    @Test func folderSnapshotRejectsPostHookReplacementBeforeEnumerating() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([1]).write(to: folder.appending(path: "original"))
        let fileSystem = LiveFileSystemAccess(onAfterFolderPreviewOpen: { request in
            let old = root.url.appending(path: "old", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: request.url, to: old)
            try FileManager.default.createDirectory(at: request.url, withIntermediateDirectories: false)
            try Data([2]).write(to: request.url.appending(path: "replacement"))
        })
        let request = try #require(await fileSystem.captureFolderPreviewRequest(paneID: .left, url: folder))

        await #expect(throws: FileSystemAccessError.identityMismatch(folder)) {
            try await fileSystem.snapshotFolder(request, visibility: .baseline, progress: { _ in })
        }
    }

    @Test func folderSnapshotAcceptsPostHookRestorationOfTheSameEntry() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        let old = root.url.appending(path: "old", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([1]).write(to: folder.appending(path: "original"))
        let fileSystem = LiveFileSystemAccess(onAfterFolderPreviewOpen: { request in
            try FileManager.default.moveItem(at: request.url, to: old)
            try FileManager.default.createDirectory(at: request.url, withIntermediateDirectories: false)
            try Data([2]).write(to: request.url.appending(path: "temporary"))
            try FileManager.default.removeItem(at: request.url)
            try FileManager.default.moveItem(at: old, to: request.url)
        })
        let request = try #require(await fileSystem.captureFolderPreviewRequest(paneID: .left, url: folder))

        let snapshot = try await fileSystem.snapshotFolder(
            request,
            visibility: .baseline,
            progress: { _ in }
        )

        #expect(snapshot.entries.map(\.name) == ["original"])
    }

    @Test func folderSnapshotClosesEveryDescriptorAcrossFailurePaths() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "child", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let baseline = try openFileDescriptorCount()

        let normal = LiveFileSystemAccess()
        let normalRequest = try #require(await normal.captureFolderPreviewRequest(paneID: .left, url: folder))
        for _ in 0..<8 {
            _ = try await normal.snapshotFolder(normalRequest, visibility: .baseline, progress: { _ in })
        }
        let cancellation = LiveFileSystemAccess(onAfterFolderPreviewOpen: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let cancellationRequest = try #require(await cancellation.captureFolderPreviewRequest(paneID: .left, url: folder))
        await #expect(throws: CancellationError.self) {
            try await cancellation.snapshotFolder(cancellationRequest, visibility: .baseline, progress: { _ in })
        }
        let hookFailure = LiveFileSystemAccess(onAfterFolderPreviewOpen: { _ in
            throw FolderPreviewFixtureError.expected
        })
        let hookRequest = try #require(await hookFailure.captureFolderPreviewRequest(paneID: .left, url: folder))
        await #expect(throws: FolderPreviewFixtureError.self) {
            try await hookFailure.snapshotFolder(hookRequest, visibility: .baseline, progress: { _ in })
        }
        let metadataFailure = LiveFileSystemAccess(folderPreviewPackageMetadata: { _ in
            throw FolderPreviewFixtureError.expected
        })
        let metadataRequest = try #require(await normal.captureFolderPreviewRequest(paneID: .left, url: folder))
        await #expect(throws: FolderPreviewFixtureError.self) {
            try await metadataFailure.snapshotFolder(
                metadataRequest,
                visibility: .baseline,
                progress: { _ in }
            )
        }
        let streamFailure = LiveFileSystemAccess(folderPreviewDirectoryStream: { _ in
            errno = EMFILE
            return nil
        })
        let streamRequest = try #require(await streamFailure.captureFolderPreviewRequest(paneID: .left, url: folder))
        await #expect(throws: POSIXError(.EMFILE)) {
            try await streamFailure.snapshotFolder(streamRequest, visibility: .baseline, progress: { _ in })
        }

        #expect(try openFileDescriptorCount() == baseline)
    }

    @Test func folderSnapshotDuplicatesDirectoryDescriptorWithCloseOnExec() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fileSystem = LiveFileSystemAccess(onAfterFolderPreviewDuplicate: { descriptor in
            let flags = Darwin.fcntl(descriptor, F_GETFD)
            guard flags >= 0, flags & FD_CLOEXEC != 0 else {
                throw FolderPreviewFixtureError.expected
            }
        })
        let request = try #require(await fileSystem.captureFolderPreviewRequest(paneID: .left, url: folder))

        _ = try await fileSystem.snapshotFolder(request, visibility: .baseline, progress: { _ in })
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
