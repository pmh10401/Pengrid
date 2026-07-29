import Foundation
import Testing
@testable import BloomFileManager

@Suite("FileOperationMutationTests")
struct FileOperationMutationTests {
    @Test func createFolderUsesExpectedDestination() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }

        let service = FileOperationService(fileSystem: LiveFileSystemAccess())
        let folder = try await service.createFolder(in: root.url, named: "New Folder")

        #expect(folder == root.url.appending(path: "New Folder", directoryHint: .isDirectory))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func renameUsesExpectedDestination() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "New Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let service = FileOperationService(fileSystem: LiveFileSystemAccess())
        let renamed = try await service.rename(source, to: "Projects")

        #expect(renamed == root.url.appending(path: "Projects"))
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func createRejectsInvalidNameWithoutMutation() async {
        let fileSystem = RecordingFileSystem()
        let service = FileOperationService(fileSystem: fileSystem)

        await #expect(throws: FilenameError.containsPathSeparator) {
            try await service.createFolder(in: URL(filePath: "/workspace"), named: "a/b")
        }
        #expect(await fileSystem.events == [])
    }

    @Test func renameRejectsInvalidNameWithoutMutation() async {
        let source = URL(filePath: "/workspace/original")
        let fileSystem = RecordingFileSystem(existingURLs: [source])
        let service = FileOperationService(fileSystem: fileSystem)

        await #expect(throws: FilenameError.containsPathSeparator) {
            try await service.rename(source, to: "a/b")
        }
        #expect(await fileSystem.events == [])
    }

    @Test func createRejectsExistingDestinationWithoutMutation() async {
        let directory = URL(filePath: "/workspace")
        let destination = directory.appending(path: "Existing", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(existingURLs: [destination])
        let service = FileOperationService(fileSystem: fileSystem)

        await #expect(throws: CocoaError(.fileWriteFileExists)) {
            try await service.createFolder(in: directory, named: "Existing")
        }
        #expect(await fileSystem.events == [])
        #expect(await fileSystem.existingURLs == [destination])
    }

    @Test func renameRejectsExistingDestinationWithoutMutation() async {
        let source = URL(filePath: "/workspace/original")
        let destination = URL(filePath: "/workspace/Existing")
        let fileSystem = RecordingFileSystem(existingURLs: [source, destination])
        let service = FileOperationService(fileSystem: fileSystem)

        await #expect(throws: CocoaError(.fileWriteFileExists)) {
            try await service.rename(source, to: "Existing")
        }
        #expect(await fileSystem.events == [])
        #expect(await fileSystem.existingURLs == [source, destination])
    }

    @Test func createRaceDoesNotReplaceExistingDestination() async {
        let directory = URL(filePath: "/workspace")
        let destination = directory.appending(path: "Raced", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(
            existingURLs: [destination],
            existsResponses: [destination: false],
            failures: [.createDirectory(destination): CocoaError(.fileWriteFileExists)]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        await #expect(throws: CocoaError(.fileWriteFileExists)) {
            try await service.createFolder(in: directory, named: "Raced")
        }
        #expect(await fileSystem.existingURLs == [destination])
        #expect(await fileSystem.events == ["createDirectory:/workspace/Raced"])
    }

    @Test func renameRaceDoesNotReplaceDestinationOrRemoveSource() async {
        let source = URL(filePath: "/workspace/original")
        let destination = URL(filePath: "/workspace/Raced")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            existsResponses: [destination: false],
            failures: [.move(source, destination): CocoaError(.fileWriteFileExists)]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        await #expect(throws: CocoaError(.fileWriteFileExists)) {
            try await service.rename(source, to: "Raced")
        }
        #expect(await fileSystem.existingURLs == [source, destination])
        #expect(await fileSystem.events == ["move:/workspace/original->/workspace/Raced"])
    }

    @Test func trashDelegatesAndReturnsExactSuccessOutcome() async {
        let source = URL(filePath: "/temporary/item")
        let fileSystem = RecordingFileSystem(existingURLs: [source])
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.trash([source])

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: nil)
        ]))
        #expect(await fileSystem.events == ["trash:/temporary/item"])
    }

    @Test func trashContinuesAfterFailureAndReturnsOrderedOutcomes() async {
        let first = URL(filePath: "/temporary/first")
        let second = URL(filePath: "/temporary/second")
        let third = URL(filePath: "/temporary/third")
        let failure = CocoaError(.fileReadNoSuchFile)
        let fileSystem = RecordingFileSystem(
            existingURLs: [first, second, third],
            failures: [.trash(second): failure]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.trash([first, second, third])

        #expect(result.outcomes == [
            .succeeded(source: first, destination: nil),
            .failed(source: second, message: failure.localizedDescription),
            .succeeded(source: third, destination: nil)
        ])
        #expect(result.hasFailures == true)
        #expect(await fileSystem.events == [
            "trash:/temporary/first",
            "trash:/temporary/second",
            "trash:/temporary/third"
        ])
        #expect(await fileSystem.existingURLs == [second])
    }

    @Test func trashCancellationAfterFirstItemPreservesRemainingItemsAndReportsProgress() async {
        let first = URL(filePath: "/temporary/first")
        let second = URL(filePath: "/temporary/second")
        let third = URL(filePath: "/temporary/third")
        let fileSystem = RecordingFileSystem(
            existingURLs: [first, second, third],
            cancelAfterTrashOf: first
        )
        let progressRecorder = TrashProgressRecorder()
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.trash([first, second, third]) { progress in
            await progressRecorder.append(progress)
        }

        #expect(result.outcomes == [
            .succeeded(source: first, destination: nil),
            .cancelled(source: second),
            .cancelled(source: third)
        ])
        #expect(await fileSystem.events == ["trash:/temporary/first"])
        #expect(await fileSystem.existingURLs == [second, third])
        #expect(await progressRecorder.values == [
            FileOperationProgress(completedCount: 1, totalCount: 3, currentName: "first")
        ])
    }

    @Test func liveTrashQuarantineUsesSameVolumeStagingAndRollsBackExactly() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "valuable.bin")
        try Data([0x42]).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let identity = try #require(await fileSystem.identity(of: source))

        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(quarantine.reservation.directory.deletingLastPathComponent()
            == source.deletingLastPathComponent())

        try await fileSystem.rollbackTrashQuarantine(quarantine)
        let restoredIdentity = try await fileSystem.identity(of: source)
        #expect(restoredIdentity == identity)
        #expect(!FileManager.default.fileExists(
            atPath: quarantine.reservation.directory.path
        ))
    }

    @Test func liveTrashQuarantineRejectsWrongIdentityWithoutMovingSource() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "replacement.bin")
        try Data([0x24]).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let replacementIdentity = try #require(await fileSystem.identity(of: source))
        let staleIdentity = FileIdentity(
            entryIdentifier: "stale",
            resolvedIdentifier: "stale"
        )

        await #expect(throws: FileSystemAccessError.identityMismatch(source)) {
            _ = try await fileSystem.quarantineForTrash(
                source,
                identifiedBy: staleIdentity
            )
        }
        let currentIdentity = try await fileSystem.identity(of: source)
        #expect(currentIdentity == replacementIdentity)
    }

    @Test func atomicStorageTrashMovesVerifiedInodeIntoAppropriateTrash() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "atomic-trash.bin")
        try Data([0x11, 0x22]).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let identity = try #require(await fileSystem.identity(of: source))
        let expectedTrash = try FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: source,
            create: true
        )
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        let trashed = try await fileSystem.moveTrashQuarantineAtomically(quarantine)
        defer { try? FileManager.default.removeItem(at: trashed) }
        let trashedIdentity = try await fileSystem.identity(of: trashed)

        #expect(trashedIdentity == identity)
        #expect(trashed.deletingLastPathComponent() == expectedTrash.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func trashDestinationCollisionNeverOverwritesAndRollsBack() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "collision-source.bin")
        try Data([0x33]).write(to: source)
        let trashName = "bloom-collision-\(UUID().uuidString)"
        let collisionURL = try FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: source,
            create: true
        ).appending(path: trashName)
        try Data([0x99]).write(to: collisionURL)
        defer { try? FileManager.default.removeItem(at: collisionURL) }
        let fileSystem = LiveFileSystemAccess(storageTrashName: { trashName })
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        await #expect(throws: StorageTrashAccessError.failedButRestored) {
            _ = try await fileSystem.moveTrashQuarantineAtomically(quarantine)
        }

        #expect(try Data(contentsOf: collisionURL) == Data([0x99]))
        #expect(try await fileSystem.identity(of: source) == identity)
    }

    @Test func identityReadFailureAfterStagingRollsBackOrReportsRecoverableItem() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "identity-read.bin")
        try Data([0x44]).write(to: source)
        let fileSystem = LiveFileSystemAccess(
            onAfterStorageQuarantineRename: {
                throw MutationFixtureError.injected
            }
        )
        let identity = try #require(await fileSystem.identity(of: source))

        await #expect(throws: StorageTrashAccessError.failedButRestored) {
            _ = try await fileSystem.quarantineForTrash(
                source,
                identifiedBy: identity
            )
        }

        #expect(try await fileSystem.identity(of: source) == identity)
    }

    @Test func ordinaryStagedPathReplacementCannotEnterTrash() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "isolated.bin")
        try Data([0x55]).write(to: source)
        let replacementAttempted = MutationLockedState(false)
        let fileSystem = LiveFileSystemAccess(
            onBeforeStorageTrashMove: { quarantine in
                do {
                    try Data([0xEE]).write(to: quarantine.quarantinedURL)
                    replacementAttempted.withValue { $0 = true }
                } catch {
                    replacementAttempted.withValue { $0 = false }
                }
            }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        let trashed = try await fileSystem.moveTrashQuarantineAtomically(quarantine)
        defer { try? FileManager.default.removeItem(at: trashed) }

        #expect(!replacementAttempted.withValue { $0 })
        #expect(try await fileSystem.identity(of: trashed) == identity)
    }

    @Test func rollbackNoReplaceNeverOverwritesRacedReplacement() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "rollback-race.bin")
        try Data([0x66]).write(to: source)
        let fileSystem = LiveFileSystemAccess(
            onBeforeStorageRollbackMove: { original in
                try Data([0xAB]).write(to: original)
            }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        await #expect(throws: StorageTrashAccessError.recoveryRequired) {
            try await fileSystem.rollbackTrashQuarantine(quarantine)
        }

        #expect(try Data(contentsOf: source) == Data([0xAB]))
        #expect(try await fileSystem.identity(of: quarantine.quarantinedURL) == identity)
    }

    @Test func postMoveRollbackFailureReportsRecoverableResidue() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "post-move-recovery.bin")
        let trashDirectory = root.url.appending(path: "trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: false
        )
        try Data([0x75]).write(to: source)
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in trashDirectory },
            onAfterStorageTrashRename: { quarantine in
                try Data([0xEE]).write(to: quarantine.quarantinedURL)
                throw MutationFixtureError.injected
            }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        await #expect(throws: StorageTrashAccessError.recoveryRequired) {
            _ = try await fileSystem.moveTrashQuarantineAtomically(quarantine)
        }

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: quarantine.quarantinedURL.path))
        let stagedURLs = try FileManager.default.contentsOfDirectory(
            at: quarantine.reservation.directory,
            includingPropertiesForKeys: nil
        )
        var originalRemainsStaged = false
        for stagedURL in stagedURLs {
            if try await fileSystem.identity(of: stagedURL) == identity {
                originalRemainsStaged = true
            }
        }
        #expect(originalRemainsStaged)
    }

    @Test func trashDirectoryChainRejectsIntermediateSymlink() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let canonicalRoot = root.url
        let source = canonicalRoot.appending(path: "symlink-chain.bin")
        let realParent = canonicalRoot.appending(path: "real", directoryHint: .isDirectory)
        let realTrash = realParent.appending(path: "trash", directoryHint: .isDirectory)
        let link = canonicalRoot.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: realTrash,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realParent)
        try Data([0x71]).write(to: source)
        let requestedTrash = link.appending(path: "trash", directoryHint: .isDirectory)
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in requestedTrash }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        await #expect(throws: StorageTrashAccessError.failedButRestored) {
            _ = try await fileSystem.moveTrashQuarantineAtomically(quarantine)
        }

        #expect(try await fileSystem.identity(of: source) == identity)
        #expect(try FileManager.default.contentsOfDirectory(atPath: realTrash.path).isEmpty)
    }

    @Test func anchoredTrashDirectoryCannotBeRedirectedAfterFinalOpen() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let canonicalRoot = root.url
        let source = canonicalRoot.appending(path: "anchored.bin")
        let trashParent = canonicalRoot.appending(
            path: "trash-parent",
            directoryHint: .isDirectory
        )
        let activeTrash = trashParent.appending(path: "active", directoryHint: .isDirectory)
        let anchoredTrash = trashParent.appending(
            path: "anchored-original",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: activeTrash,
            withIntermediateDirectories: true
        )
        try Data([0x72]).write(to: source)
        let trashName = "anchored-\(UUID().uuidString)"
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in activeTrash },
            storageTrashName: { trashName },
            onBeforeStorageTrashMove: { _ in
                try FileManager.default.moveItem(at: activeTrash, to: anchoredTrash)
                try FileManager.default.createDirectory(
                    at: activeTrash,
                    withIntermediateDirectories: false
                )
            }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        _ = try await fileSystem.moveTrashQuarantineAtomically(quarantine)

        let anchoredItem = anchoredTrash.appending(path: trashName)
        let redirectedItem = activeTrash.appending(path: trashName)
        #expect(try await fileSystem.identity(of: anchoredItem) == identity)
        #expect(!FileManager.default.fileExists(atPath: redirectedItem.path))
    }

    @Test func nestedTrashDirectoryChainSupportsDescriptorAnchoredMove() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let canonicalRoot = root.url
        let source = canonicalRoot.appending(path: "nested.bin")
        let nestedTrash = canonicalRoot
            .appending(path: "volume", directoryHint: .isDirectory)
            .appending(path: ".Trashes", directoryHint: .isDirectory)
            .appending(path: "501", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: nestedTrash,
            withIntermediateDirectories: true
        )
        try Data([0x73]).write(to: source)
        let trashName = "nested-\(UUID().uuidString)"
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in nestedTrash },
            storageTrashName: { trashName }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        _ = try await fileSystem.moveTrashQuarantineAtomically(quarantine)

        #expect(
            try await fileSystem.identity(
                of: nestedTrash.appending(path: trashName)
            ) == identity
        )
    }

    @Test func trashDirectoryChainRejectsParentEscape() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let canonicalRoot = root.url
        let source = canonicalRoot.appending(path: "escape.bin")
        let base = canonicalRoot.appending(path: "base", directoryHint: .isDirectory)
        let escaped = canonicalRoot.appending(path: "escaped", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: false)
        try Data([0x74]).write(to: source)
        let requestedTrash = base
            .appending(path: "..", directoryHint: .isDirectory)
            .appending(path: "escaped", directoryHint: .isDirectory)
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in requestedTrash }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let quarantine = try await fileSystem.quarantineForTrash(
            source,
            identifiedBy: identity
        )

        await #expect(throws: StorageTrashAccessError.failedButRestored) {
            _ = try await fileSystem.moveTrashQuarantineAtomically(quarantine)
        }

        #expect(try await fileSystem.identity(of: source) == identity)
        #expect(try FileManager.default.contentsOfDirectory(atPath: escaped.path).isEmpty)
    }

    @Test func storageDestinationCollisionRestoresOriginalAndReportsFailed() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let keepURL = root.url.appending(path: "keep.bin")
        let source = root.url.appending(path: "collision-service.bin")
        let trashDirectory = root.url.appending(path: "trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: false
        )
        try Data([0x81]).write(to: keepURL)
        try Data([0x81]).write(to: source)
        let trashName = "collision-\(UUID().uuidString)"
        try Data([0xFF]).write(to: trashDirectory.appending(path: trashName))
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in trashDirectory },
            storageTrashName: { trashName }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let keep = try await liveStorageEntry(keepURL, name: "keep.bin")
        let selected = try await liveStorageEntry(source, name: "collision-service.bin")
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.trashStorageCleanup([
            StorageCleanupMutationGroup(keep: keep, trash: [selected])
        ])

        #expect(result.outcomes == [
            .failed(source: source, message: "cleanup-trash-failed")
        ])
        #expect(try await fileSystem.identity(of: source) == identity)
    }

    @Test func storageFingerprintReadFailureReportsFailed() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let keepURL = root.url.appending(path: "fingerprint-keep.bin")
        let source = root.url.appending(path: "fingerprint-failure.bin")
        try Data([0x84]).write(to: keepURL)
        try Data([0x84]).write(to: source)
        let keep = try await liveStorageEntry(keepURL, name: "fingerprint-keep.bin")
        let selected = try await liveStorageEntry(source, name: "fingerprint-failure.bin")
        let fingerprints = MutationStorageFingerprintReader(
            fingerprints: [
                keep.url: keep.fingerprint,
                selected.url: selected.fingerprint
            ],
            failingURLs: [keep.url]
        )
        let service = FileOperationService(
            fileSystem: LiveFileSystemAccess(),
            storageFingerprints: fingerprints
        )

        let result = await service.trashStorageCleanup([
            StorageCleanupMutationGroup(keep: keep, trash: [selected])
        ])

        #expect(result.outcomes == [
            .failed(source: source, message: "cleanup-trash-failed")
        ])
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func ordinaryQuarantineSetupFailureReportsFailed() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let keepURL = root.url.appending(path: "quarantine-keep.bin")
        let source = root.url.appending(path: "quarantine-setup-failure.bin")
        try Data([0x85]).write(to: keepURL)
        try Data([0x85]).write(to: source)
        let keep = try await liveStorageEntry(keepURL, name: "quarantine-keep.bin")
        let selected = try await liveStorageEntry(
            source,
            name: "quarantine-setup-failure.bin"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [keep.url, selected.url],
            identities: [
                keep.url: keep.fingerprint.identity,
                selected.url: selected.fingerprint.identity
            ],
            stagingReservationIdentityError: CocoaError(.fileReadNoPermission)
        )
        let fingerprints = MutationStorageFingerprintReader(fingerprints: [
            keep.url: keep.fingerprint,
            selected.url: selected.fingerprint
        ])
        let service = FileOperationService(
            fileSystem: fileSystem,
            storageFingerprints: fingerprints
        )

        let result = await service.trashStorageCleanup([
            StorageCleanupMutationGroup(keep: keep, trash: [selected])
        ])

        #expect(result.outcomes == [
            .failed(source: source, message: "cleanup-trash-failed")
        ])
        #expect(await fileSystem.exists(source))
    }

    @Test func postMoveFailureWithSuccessfulRollbackReportsFailed() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let keepURL = root.url.appending(path: "keep.bin")
        let source = root.url.appending(path: "post-move-service.bin")
        let trashDirectory = root.url.appending(path: "trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: false
        )
        try Data([0x82]).write(to: keepURL)
        try Data([0x82]).write(to: source)
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in trashDirectory },
            onAfterStorageTrashRename: { _ in
                throw MutationFixtureError.injected
            }
        )
        let identity = try #require(await fileSystem.identity(of: source))
        let keep = try await liveStorageEntry(keepURL, name: "keep.bin")
        let selected = try await liveStorageEntry(source, name: "post-move-service.bin")
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.trashStorageCleanup([
            StorageCleanupMutationGroup(keep: keep, trash: [selected])
        ])

        #expect(result.outcomes == [
            .failed(source: source, message: "cleanup-trash-failed")
        ])
        #expect(try await fileSystem.identity(of: source) == identity)
    }

    @Test func quarantineRecoveryRequiredIsNeverReportedAsSkipped() async throws {
        let root = try AnchoredTrashTemporaryDirectory()
        defer { root.remove() }
        let keepURL = root.url.appending(path: "keep.bin")
        let source = root.url.appending(path: "quarantine-recovery.bin")
        let trashDirectory = root.url.appending(path: "trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: false
        )
        try Data([0x83]).write(to: keepURL)
        try Data([0x83]).write(to: source)
        let fileSystem = LiveFileSystemAccess(
            storageTrashDirectory: { _ in trashDirectory },
            onAfterStorageQuarantineRename: {
                throw MutationFixtureError.injected
            },
            onBeforeStorageRollbackMove: { original in
                try Data([0xEE]).write(to: original)
            }
        )
        let keep = try await liveStorageEntry(keepURL, name: "keep.bin")
        let selected = try await liveStorageEntry(source, name: "quarantine-recovery.bin")
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.trashStorageCleanup([
            StorageCleanupMutationGroup(keep: keep, trash: [selected])
        ])

        #expect(result.outcomes == [.recoveryNeeded(source: source)])
    }

    private func liveStorageEntry(
        _ url: URL,
        name: String
    ) async throws -> StorageEntry {
        StorageEntry(
            relativePath: try StorageRelativePath(components: [name]),
            url: url,
            kind: .regularFile,
            category: .other,
            fingerprint: try await LiveStorageEntryFingerprintReader().fingerprint(of: url),
            typeDescription: "File"
        )
    }
}

private actor TrashProgressRecorder {
    private(set) var values: [FileOperationProgress] = []

    func append(_ value: FileOperationProgress) {
        values.append(value)
    }
}

private final class MutationLockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private enum MutationFixtureError: Error {
    case injected
}

private struct MutationStorageFingerprintReader: StorageEntryFingerprintReading {
    let fingerprints: [URL: ComparisonFingerprint]
    var failingURLs: Set<URL> = []

    func fingerprint(of url: URL) async throws -> ComparisonFingerprint {
        guard !failingURLs.contains(url),
              let fingerprint = fingerprints[url] else {
            throw MutationFixtureError.injected
        }
        return fingerprint
    }
}

private struct AnchoredTrashTemporaryDirectory {
    let url: URL

    init() throws {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        url = repository
            .appending(path: ".build", directoryHint: .isDirectory)
            .appending(
                path: "anchored-trash-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
