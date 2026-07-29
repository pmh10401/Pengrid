import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite("ComparisonTransferTests")
struct ComparisonTransferTests {
    @Test func recursiveChildCreatesMissingParentsWithoutFlattening() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let sourceRoot = try makeDirectory("left", in: temporary.url)
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let sourceParent = try makeDirectory("A/B", in: sourceRoot)
        let source = sourceParent.appending(path: "report.txt")
        try Data("report".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let sourceIdentity = try #require(try await fileSystem.identity(of: source))
        let destinationIdentity = try #require(try await fileSystem.identity(of: destinationRoot))
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [IdentifiedTransferRequest(
                source: source,
                sourceIdentity: sourceIdentity,
                destinationRoot: destinationRoot,
                destinationRootIdentity: destinationIdentity,
                relativeParentComponents: ["A", "B"]
            )],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures == false)
        #expect(FileManager.default.fileExists(
            atPath: destinationRoot.appending(path: "A/B/report.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: destinationRoot.appending(path: "report.txt").path
        ))
    }

    @Test func symlinkAncestorRejectsWithoutMutation() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let external = try makeDirectory("external", in: temporary.url)
        let marker = external.appending(path: "marker.txt")
        try Data("unchanged".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: destinationRoot.appending(path: "A"),
            withDestinationURL: external
        )
        let fileSystem = LiveFileSystemAccess()
        let rootIdentity = try #require(try await fileSystem.identity(of: destinationRoot))

        await #expect(throws: (any Error).self) {
            _ = try await fileSystem.prepareDirectoryHierarchy(
                root: destinationRoot,
                identifiedBy: rootIdentity,
                relativeComponents: ["A", "B"]
            )
        }

        #expect(try Data(contentsOf: marker) == Data("unchanged".utf8))
        #expect(!FileManager.default.fileExists(atPath: external.appending(path: "B").path))
    }

    @Test func ownedCleanupPreservesReplacementDirectory() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let fileSystem = LiveFileSystemAccess()
        let rootIdentity = try #require(try await fileSystem.identity(of: destinationRoot))
        let prepared = try await fileSystem.prepareDirectoryHierarchy(
            root: destinationRoot,
            identifiedBy: rootIdentity,
            relativeComponents: ["A"]
        )
        let original = destinationRoot.appending(path: "original-A")
        try FileManager.default.moveItem(at: prepared.destinationDirectory, to: original)
        let replacement = try makeDirectory("A", in: destinationRoot)
        let marker = replacement.appending(path: "replacement.txt")
        try Data("replacement".utf8).write(to: marker)

        await #expect(throws: (any Error).self) {
            try await fileSystem.removeEmptyOwnedDirectories(
                root: destinationRoot,
                identifiedBy: rootIdentity,
                directories: prepared.createdDirectories
            )
        }

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func invalidHierarchyComponentFailsBeforeCreatingAnything() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let fileSystem = LiveFileSystemAccess()
        let rootIdentity = try #require(try await fileSystem.identity(of: destinationRoot))

        await #expect(throws: FilenameError.dotEntry) {
            _ = try await fileSystem.prepareDirectoryHierarchy(
                root: destinationRoot,
                identifiedBy: rootIdentity,
                relativeComponents: ["safe", ".."]
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destinationRoot.appending(path: "safe").path))
    }

    @Test func destinationRootReplacementFailsBeforeCreatingAnything() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let fileSystem = LiveFileSystemAccess()
        let capturedIdentity = try #require(try await fileSystem.identity(of: destinationRoot))
        try FileManager.default.moveItem(
            at: destinationRoot,
            to: temporary.url.appending(path: "old-right", directoryHint: .isDirectory)
        )
        _ = try makeDirectory("right", in: temporary.url)

        await #expect(throws: FileSystemAccessError.identityMismatch(destinationRoot)) {
            _ = try await fileSystem.prepareDirectoryHierarchy(
                root: destinationRoot,
                identifiedBy: capturedIdentity,
                relativeComponents: ["safe"]
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destinationRoot.appending(path: "safe").path))
    }

    @Test func sourceReplacementAfterComparisonFailsIdentityCheck() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let sourceRoot = try makeDirectory("left", in: temporary.url)
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let source = sourceRoot.appending(path: "report.txt")
        try Data("old".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let comparedIdentity = try #require(try await fileSystem.identity(of: source))
        let destinationIdentity = try #require(try await fileSystem.identity(of: destinationRoot))
        try FileManager.default.removeItem(at: source)
        try Data("replacement".utf8).write(to: source)
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [IdentifiedTransferRequest(
                source: source,
                sourceIdentity: comparedIdentity,
                destinationRoot: destinationRoot,
                destinationRootIdentity: destinationIdentity,
                relativeParentComponents: []
            )],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(!FileManager.default.fileExists(
            atPath: destinationRoot.appending(path: "report.txt").path
        ))
    }

    @Test func liveListedSymlinkSourceCopiesByNoFollowEntryIdentity() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let sourceRoot = try makeDirectory("left", in: temporary.url)
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let target = temporary.url.appending(path: "target.txt")
        try Data("target".utf8).write(to: target)
        let source = sourceRoot.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let listing = LiveComparisonListingService()
        let records = try await listing.collect(.recursive(root: sourceRoot))
        let entry = try #require(records.compactMap(\.entry).first {
            $0.relativePath.string == "alias"
        })
        let fileSystem = LiveFileSystemAccess()
        let destinationIdentity = try #require(try await fileSystem.identity(of: destinationRoot))

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [IdentifiedTransferRequest(
                source: entry.url,
                sourceIdentity: entry.fingerprint.identity,
                destinationRoot: destinationRoot,
                destinationRootIdentity: destinationIdentity,
                relativeParentComponents: []
            )],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures == false)
        let copied = destinationRoot.appending(path: "alias")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.path) == target.path)
    }

    @Test func failedRecursiveTransferRemovesOnlyCreatedEmptyParents() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let sourceRoot = try makeDirectory("left", in: temporary.url)
        let destinationRoot = try makeDirectory("right", in: temporary.url)
        let existingParent = try makeDirectory("A", in: destinationRoot)
        let source = sourceRoot.appending(path: "unsupported.fifo")
        let created: Int32 = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, 0o600)
        }
        #expect(created == 0)
        let fileSystem = LiveFileSystemAccess()
        let sourceIdentity = try #require(try await fileSystem.identity(of: source))
        let destinationIdentity = try #require(try await fileSystem.identity(of: destinationRoot))
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [IdentifiedTransferRequest(
                source: source,
                sourceIdentity: sourceIdentity,
                destinationRoot: destinationRoot,
                destinationRootIdentity: destinationIdentity,
                relativeParentComponents: ["A", "B"]
            )],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(FileManager.default.fileExists(atPath: existingParent.path))
        #expect(!FileManager.default.fileExists(atPath: existingParent.appending(path: "B").path))
    }

    @Test func cancelledIdentifiedCopyCleansCreatedParentsAndCancelsRemainingItems() async {
        let destinationRoot = URL(filePath: "/dest", directoryHint: .isDirectory)
        let first = URL(filePath: "/source/first")
        let second = URL(filePath: "/source/second")
        let rootIdentity = FileIdentity(entryIdentifier: "dest", resolvedIdentifier: "dest")
        let firstIdentity = FileIdentity(entryIdentifier: "first", resolvedIdentifier: "first")
        let secondIdentity = FileIdentity(entryIdentifier: "second", resolvedIdentifier: "second")
        let fileSystem = RecordingFileSystem(
            existingURLs: [destinationRoot, first, second],
            cancelAfterCopy: true,
            identities: [
                destinationRoot: rootIdentity,
                first: firstIdentity,
                second: secondIdentity
            ]
        )
        let service = FileOperationService(fileSystem: fileSystem)
        let requests = [
            IdentifiedTransferRequest(
                source: first,
                sourceIdentity: firstIdentity,
                destinationRoot: destinationRoot,
                destinationRootIdentity: rootIdentity,
                relativeParentComponents: ["A"]
            ),
            IdentifiedTransferRequest(
                source: second,
                sourceIdentity: secondIdentity,
                destinationRoot: destinationRoot,
                destinationRootIdentity: rootIdentity,
                relativeParentComponents: ["B"]
            )
        ]

        let result = await service.transfer(
            requests,
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.outcomes == [
            .cancelled(source: first),
            .cancelled(source: second)
        ])
        let remaining = await fileSystem.existingURLs
        #expect(!remaining.contains(destinationRoot.appending(path: "A")))
        #expect(!remaining.contains(destinationRoot.appending(path: "B")))
    }

    @Test func actionPolicyAllowsSafeCopyAndBlocksUnsafeAncestors() throws {
        let leftFile = try entry(path: "A/report.txt", side: "left", kind: .regularFile)
        let destinationDirectory = try entry(path: "A", side: "right", kind: .directory)
        let sourceDirectory = try entry(path: "A", side: "left", kind: .directory)
        let parent = ComparisonRow(
            relativePath: sourceDirectory.relativePath,
            left: sourceDirectory,
            right: destinationDirectory,
            status: .identical(.quick)
        )
        let child = ComparisonRow(
            relativePath: leftFile.relativePath,
            left: leftFile,
            right: nil,
            status: .leftOnly
        )

        #expect(ComparisonActionPolicy.canCopy(
            [child], direction: .leftToRight, allRows: [parent, child]
        ))

        let blockedParent = ComparisonRow(
            relativePath: sourceDirectory.relativePath,
            left: sourceDirectory,
            right: try entry(path: "A", side: "right", kind: .symbolicLink),
            status: .typeConflict
        )
        #expect(!ComparisonActionPolicy.canCopy(
            [child], direction: .leftToRight, allRows: [blockedParent, child]
        ))
        #expect(!ComparisonActionPolicy.canCopy(
            [ComparisonRow(
                relativePath: leftFile.relativePath,
                left: leftFile,
                right: nil,
                status: .checking(nil)
            )],
            direction: .leftToRight,
            allRows: []
        ))
    }

    @MainActor @Test func coordinatorCopiesSelectedRelativePathThroughOperationController() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let leftRoot = try makeDirectory("left", in: temporary.url)
        let rightRoot = try makeDirectory("right", in: temporary.url)
        let sourceParent = try makeDirectory("A/B", in: leftRoot)
        let source = sourceParent.appending(path: "report.txt")
        try Data("coordinated".utf8).write(to: source)
        let workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: LiveComparisonListingService(),
            checksums: LiveChecksumService(),
            monitor: InMemoryComparisonTreeMonitor()
        )
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitUntil {
            coordinator.phase == .upToDate
                && coordinator.rows.contains { $0.id.string == "A/B/report.txt" }
        })
        let path = try ComparisonRelativePath(components: ["A", "B", "report.txt"])
        coordinator.selection = [path]
        let operationController = FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess())
        )

        #expect(coordinator.canCopy(.leftToRight))
        #expect(coordinator.copy(
            direction: .leftToRight,
            operationController: operationController,
            workspace: workspace
        ))
        #expect(await waitUntil { !operationController.isRunning })
        #expect(operationController.lastResult?.hasFailures == false)
        #expect(operationController.lastResult?.safeRelativePath(for: source) == path)
        #expect(FileManager.default.fileExists(
            atPath: rightRoot.appending(path: "A/B/report.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: rightRoot.appending(path: "report.txt").path
        ))
        coordinator.stop()
    }

    @MainActor @Test func selectedDirectorySuppressesItsSelectedDescendantTransfer() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let leftRoot = try makeDirectory("left", in: temporary.url)
        let rightRoot = try makeDirectory("right", in: temporary.url)
        let sourceDirectory = try makeDirectory("Folder", in: leftRoot)
        try Data("once".utf8).write(to: sourceDirectory.appending(path: "report.txt"))
        try Data("sibling".utf8).write(to: leftRoot.appending(path: "sibling.txt"))
        let workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: LiveComparisonListingService(),
            checksums: LiveChecksumService(),
            monitor: InMemoryComparisonTreeMonitor()
        )
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitUntil {
            coordinator.phase == .upToDate
                && coordinator.rows.contains { $0.id.string == "Folder/report.txt" }
                && coordinator.rows.contains { $0.id.string == "sibling.txt" }
        })
        coordinator.selection = [
            try ComparisonRelativePath(components: ["Folder"]),
            try ComparisonRelativePath(components: ["Folder", "report.txt"]),
            try ComparisonRelativePath(components: ["sibling.txt"])
        ]
        let operations = FileOperationController(
            service: FileOperationService(fileSystem: LiveFileSystemAccess())
        )

        #expect(coordinator.copy(
            direction: .leftToRight,
            operationController: operations,
            workspace: workspace
        ))
        #expect(await waitUntil { operations.pendingConflict != nil || !operations.isRunning })
        let presentedDuplicateConflict = operations.pendingConflict != nil
        if presentedDuplicateConflict {
            operations.resolvePendingConflict(.keepBoth, applyToAll: false)
        }
        #expect(await waitUntil { !operations.isRunning })

        #expect(!presentedDuplicateConflict)
        #expect(operations.lastResult?.outcomes.count == 2)
        #expect(FileManager.default.fileExists(
            atPath: rightRoot.appending(path: "Folder/report.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: rightRoot.appending(path: "Folder/report 2.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: rightRoot.appending(path: "sibling.txt").path
        ))
        coordinator.stop()
    }

    private func makeDirectory(_ relativePath: String, in root: URL) throws -> URL {
        let directory = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func entry(
        path string: String,
        side: String,
        kind: ComparisonEntryKind
    ) throws -> ComparisonEntry {
        let path = try ComparisonRelativePath(components: string.split(separator: "/").map(String.init))
        let identity = FileIdentity(
            entryIdentifier: "\(side):\(string)",
            resolvedIdentifier: "\(side):\(string)"
        )
        return ComparisonEntry(
            relativePath: path,
            url: URL(filePath: "/\(side)/\(string)"),
            kind: kind,
            fingerprint: .init(identity: identity, byteSize: 1, modifiedAt: Date(timeIntervalSince1970: 1)),
            symbolicLinkTarget: kind == .symbolicLink ? "/external" : nil,
            typeDescription: kind.rawValue
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
