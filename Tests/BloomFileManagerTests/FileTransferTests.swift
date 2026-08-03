import Foundation
import Testing
@testable import BloomFileManager

@Suite("FileTransferTests")
struct FileTransferTests {
    @Test func fileIdentityDistinguishesEntryOwnershipFromResolvedAliasEquality() {
        let direct = FileIdentity(entryIdentifier: "target", resolvedIdentifier: "target")
        let alias = FileIdentity(entryIdentifier: "symlink", resolvedIdentifier: "target")

        #expect(direct != alias)
        #expect(direct.refersToSameItem(as: alias))
    }

    @Test func liveIdentityRecognizesSymlinkAliasButRetainsEntryOwnership() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let target = root.url.appending(path: "target")
        let alias = root.url.appending(path: "alias")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let fileSystem = LiveFileSystemAccess()

        let targetIdentity = try #require(await fileSystem.identity(of: target))
        let aliasIdentity = try #require(await fileSystem.identity(of: alias))

        #expect(targetIdentity != aliasIdentity)
        #expect(targetIdentity.refersToSameItem(as: aliasIdentity))
    }

    @Test func liveIdentityCheckedRemovalPreservesReplacementEntry() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let item = root.url.appending(path: "item")
        let original = root.url.appending(path: "original")
        try Data("old".utf8).write(to: item)
        let fileSystem = LiveFileSystemAccess()
        let oldIdentity = try #require(await fileSystem.identity(of: item))
        try FileManager.default.moveItem(at: item, to: original)
        try Data("new".utf8).write(to: item)

        await #expect(throws: FileSystemAccessError.identityMismatch(item)) {
            try await fileSystem.remove(item, identifiedBy: oldIdentity)
        }
        #expect(FileManager.default.fileExists(atPath: item.path))
    }

    @Test func volumeIdentifierNormalizationIsRepeatableForSupportedFoundationTypes() throws {
        let uuid = UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!
        let identifiers: [(Any, String)] = [
            ("disk", "string:disk"),
            (uuid, "uuid:12345678-1234-5678-9abc-def012345678"),
            (NSNumber(value: 42), "number:42"),
            (Data([0x00, 0x0f, 0xff]), "data:000fff")
        ]

        for (identifier, expected) in identifiers {
            #expect(try VolumeIdentifierNormalizer.normalize(identifier) == expected)
            #expect(try VolumeIdentifierNormalizer.normalize(identifier) == expected)
        }
    }

    @Test func keepBothCopiesToNumberedDestination() async {
        let source = URL(filePath: "/source/Report.pdf")
        let destination = URL(filePath: "/dest/Report.pdf")
        let numberedDestination = URL(filePath: "/dest/Report 2.pdf")
        let fileSystem = RecordingFileSystem(existingURLs: [source, destination])
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { _ in .keepBoth },
            progress: { _ in }
        )

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: numberedDestination)
        ]))
        let stagedItems = await fileSystem.copiedDestinations
        #expect(stagedItems.count == 1)
        #expect(stagedItems.first?.path.contains("/.bloom-staging-") == true)
        #expect(await fileSystem.existingURLs.contains(numberedDestination))
        #expect(await fileSystem.existingURLs.contains(destination))
    }

    @Test func crossVolumeMoveRemovesSourceOnlyAfterVerifiedCopy() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            recordsExistenceChecks: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: destination)
        ]))
        let events = await fileSystem.events
        let staged = await fileSystem.copiedDestinations[0]
        let copyIndex = events.firstIndex(of: "copy:/source/a->\(staged.path)")
        let commitIndex = events.firstIndex(of: "moveChecked:\(staged.path)->/dest/a")
        let verifyIndex = events.lastIndex(of: "identity:/dest/a")
        let removeIndex = events.firstIndex(of: "removeChecked:/source/a")
        #expect(copyIndex != nil && commitIndex != nil && verifyIndex != nil && removeIndex != nil)
        if let copyIndex, let commitIndex, let verifyIndex, let removeIndex {
            #expect(copyIndex < commitIndex)
            #expect(commitIndex < verifyIndex)
            #expect(verifyIndex < removeIndex)
        }
    }

    @Test func knownFileLargerThanAvailableCapacityFailsBeforeCopy() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            byteSizes: [source: 2_000],
            availableCapacities: [directory: 1_000]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.copiedDestinations.isEmpty)
        #expect(await fileSystem.existingURLs.contains(source))
    }

    @Test func failedReplacementPreservesExistingDestinationAndSource() async {
        let source = URL(filePath: "/source/a")
        let destination = URL(filePath: "/dest/a")
        let copyError = CocoaError(.fileWriteUnknown)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            injectedCopyError: copyError
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .move,
            resolveConflict: { _ in .replace },
            progress: { _ in }
        )

        #expect(result == FileOperationResult(outcomes: [
            .failed(source: source, message: copyError.localizedDescription)
        ]))
        #expect(await fileSystem.events.contains { $0.hasPrefix("replace:/dest/a") } == false)
        #expect(await fileSystem.removedURLs.contains(source) == false)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination))
    }

    @Test func successfulReplacementStagesAndVerifiesBeforeReplacingAndRemovingSource() async {
        let source = URL(filePath: "/source/a")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            recordsExistenceChecks: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        _ = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .move,
            resolveConflict: { _ in .replace },
            progress: { _ in }
        )

        let copiedDestinations = await fileSystem.copiedDestinations
        #expect(copiedDestinations.count == 1)
        guard let staged = copiedDestinations.first else {
            Issue.record("Expected one staged replacement item")
            return
        }
        #expect(staged.deletingLastPathComponent().lastPathComponent.hasPrefix(".bloom-staging-"))
        #expect(staged.lastPathComponent == "payload")
        let events = await fileSystem.events
        let copyIndex = events.firstIndex(of: "copy:/source/a->\(staged.path)")
        let commitIndex = events.firstIndex { $0 == "replaceChecked:/dest/a<-\(staged.path)" }
        let verifyIndex = events.lastIndex(of: "identity:/dest/a")
        let removeIndex = events.firstIndex(of: "removeChecked:/source/a")
        #expect(copyIndex != nil && commitIndex != nil && verifyIndex != nil && removeIndex != nil)
        if let copyIndex, let commitIndex, let verifyIndex, let removeIndex {
            #expect(copyIndex < commitIndex)
            #expect(commitIndex < verifyIndex)
            #expect(verifyIndex < removeIndex)
        }
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.existingURLs.contains(source) == false)
    }

    @Test func cancellationAfterCrossVolumeCopyCleansDestinationAndPreservesSource() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            cancelAfterCopy: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await Task {
            await service.transfer(
                [source],
                to: directory,
                mode: .move,
                resolveConflict: { _ in .cancel },
                progress: { _ in }
            )
        }.value

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination) == false)
        #expect(await fileSystem.removedURLs.contains(destination) == false)
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func cancellationAfterDirectCopyCleansDestinationAndPreservesSource() async {
        let source = URL(filePath: "/source/a")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            cancelAfterCopy: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await Task {
            await service.transfer(
                [source],
                to: URL(filePath: "/dest"),
                mode: .copy,
                resolveConflict: { _ in .cancel },
                progress: { _ in }
            )
        }.value

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination) == false)
        #expect(await fileSystem.removedURLs.contains(destination) == false)
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func moveReplacementNeverRemovesPathWhenSourceEqualsDestination() async {
        let source = URL(filePath: "/source/a")
        let fileSystem = RecordingFileSystem(existingURLs: [source])
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/source"),
            mode: .move,
            resolveConflict: { _ in .replace },
            progress: { _ in }
        )

        #expect(result.hasFailures == false)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func failedPostCommitVerificationPreservesCommittedDestinationAndSource() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            hidesCommittedDestinationIdentity: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(destination) == false)
    }

    @Test func copyRaceDoesNotDeleteDestinationNotCreatedByThisInvocation() async {
        let source = URL(filePath: "/source/a")
        let destination = URL(filePath: "/dest/a")
        let copyError = CocoaError(.fileWriteFileExists)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            existsResponses: [destination: false],
            injectedCopyError: copyError
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(destination) == false)
    }

    @Test func reportsExactProgressAndOnePathFreeSummary() async {
        let first = URL(filePath: "/source/first")
        let second = URL(filePath: "/source/second")
        let logger = RecordingOperationLogger()
        let progressRecorder = ProgressRecorder()
        let fileSystem = RecordingFileSystem(existingURLs: [first, second])
        let service = FileOperationService(fileSystem: fileSystem, logger: logger)

        let result = await service.transfer(
            [first, second],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { value in await progressRecorder.append(value) }
        )

        #expect(result.hasFailures == false)
        #expect(await progressRecorder.values == [
            FileOperationProgress(completedCount: 1, totalCount: 2, currentName: "first"),
            FileOperationProgress(completedCount: 2, totalCount: 2, currentName: "second")
        ])
        #expect(await logger.events == [
            RecordingOperationLogger.Event(kind: .copy, succeeded: 2, failed: 0, skipped: 0)
        ])
    }

    @Test func postCommitSourceRemovalSideEffectThenErrorPreservesDestination() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let removalError = CocoaError(.fileWriteUnknown)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            sourceRemovalErrorAfterSideEffect: removalError
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result == FileOperationResult(outcomes: [
            .recoveryNeeded(source: source)
        ]))
        #expect(await fileSystem.existingURLs.contains(source) == false)
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(destination) == false)
    }

    @Test func cleanupRefusesExternalReplacementAtStagingPathAndSurfacesFailure() async {
        let source = URL(filePath: "/source/a")
        let copyError = CocoaError(.fileWriteUnknown)
        let externalIdentity = FileIdentity(
            entryIdentifier: "external-entry",
            resolvedIdentifier: "external-target"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            copyErrorAfterCreatingPartial: copyError,
            replacementStagingIdentityAfterPartialCopy: externalIdentity
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        guard case let .recoveryNeeded(recoverySource) = result.outcomes.first else {
            Issue.record("Expected identity-checked cleanup recovery state")
            return
        }
        #expect(recoverySource == source)
        let stagingPath = await fileSystem.copiedDestinations.first
        #expect(stagingPath != nil)
        if let stagingPath {
            #expect((try? await fileSystem.identity(of: stagingPath)) == externalIdentity)
            #expect(await fileSystem.removedURLs.contains(stagingPath) == false)
        }
    }

    @Test func changedSourceIdentityIsNotRemovedAfterCommittedCrossVolumeCopy() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let replacementIdentity = FileIdentity(
            entryIdentifier: "replacement-entry",
            resolvedIdentifier: "replacement-target"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            replacementSourceIdentityBeforeRemoval: replacementIdentity
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect((try? await fileSystem.identity(of: source)) == replacementIdentity)
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func lostSourceIdentityAfterCommitDoesNotTriggerPathRemoval() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            losesSourceIdentityBeforeRemoval: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func partialCopyCleanupNeverAdoptsExternalReplacementIdentity() async {
        let source = URL(filePath: "/source/a")
        let externalIdentity = FileIdentity(
            entryIdentifier: "external-entry",
            resolvedIdentifier: "external-target"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            copyErrorAfterCreatingPartial: CocoaError(.fileWriteUnknown),
            replacementStagingIdentityAfterPartialCopy: externalIdentity
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        let stagingPath = await fileSystem.copiedDestinations.first
        #expect(stagingPath != nil)
        if let stagingPath {
            #expect((try? await fileSystem.identity(of: stagingPath)) == externalIdentity)
            #expect(await fileSystem.removedURLs.contains(stagingPath) == false)
        }
    }

    @Test func successfulCopyNeverAdoptsImmediateExternalPayloadReplacement() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let externalIdentity = FileIdentity(
            entryIdentifier: "external-entry",
            resolvedIdentifier: "external-target"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            replacementStagingIdentityAfterSuccessfulCopy: externalIdentity
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination) == false)
        let stagingPath = await fileSystem.copiedDestinations.first
        #expect(stagingPath != nil)
        if let stagingPath {
            let events = await fileSystem.events
            #expect(events.contains("identity:\(stagingPath.path)") == false)
            #expect((try? await fileSystem.identity(of: stagingPath)) == externalIdentity)
            #expect(await fileSystem.removedURLs.contains(stagingPath) == false)
        }
    }

    @Test func changedRegularFileFingerprintPreventsCrossVolumeSourceRemoval() async {
        let source = URL(filePath: "/source/file")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/file")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            mutatesSourcesAfterCopy: [source]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination) == false)
    }

    @Test func changedDirectoryManifestPreventsCrossVolumeSourceRemoval() async {
        let source = URL(filePath: "/source/folder", directoryHint: .isDirectory)
        let child = source.appending(path: "child")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/folder", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, child],
            volumeIdentifiers: [source: "A", directory: "B"],
            mutatesSourcesAfterCopy: [source]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(child))
        #expect(await fileSystem.existingURLs.contains(destination) == false)
    }

    @Test func sourceMutationDuringCommitPreventsCrossVolumeSourceRemoval() async {
        let source = URL(filePath: "/source/file")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/file")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            mutatesSourcesAfterCommit: [source]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func stagingReservationIdentityFailureCleansEmptyOwnedDirectory() async {
        let source = URL(filePath: "/source/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            stagingReservationIdentityError: CocoaError(.fileReadUnknown)
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result.hasFailures)
        let stagingDirectories = await fileSystem.existingURLs.filter {
            $0.lastPathComponent.hasPrefix(".bloom-staging-")
        }
        #expect(stagingDirectories.isEmpty)
    }

    @Test func copyCancellationAfterPublicCommitReturnsSuccess() async {
        let source = URL(filePath: "/source/a")
        let destination = URL(filePath: "/dest/a")
        let logger = RecordingOperationLogger()
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            cancelAfterCommit: true
        )
        let service = FileOperationService(fileSystem: fileSystem, logger: logger)

        let result = await Task {
            await service.transfer(
                [source],
                to: URL(filePath: "/dest"),
                mode: .copy,
                resolveConflict: { _ in .cancel },
                progress: { _ in }
            )
        }.value

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: destination)
        ]))
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await logger.events == [
            RecordingOperationLogger.Event(kind: .copy, succeeded: 1, failed: 0, skipped: 0)
        ])
    }

    @Test func moveCancellationAfterPublicCommitPreservesSourceAndDestination() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            cancelAfterCommit: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await Task {
            await service.transfer(
                [source],
                to: directory,
                mode: .move,
                resolveConflict: { _ in .cancel },
                progress: { _ in }
            )
        }.value

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func cancellationDuringFinalFingerprintPreservesSourceAndDestination() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "B"],
            cancelOnFingerprintCall: 3
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await Task {
            await service.transfer(
                [source],
                to: directory,
                mode: .move,
                resolveConflict: { _ in .cancel },
                progress: { _ in }
            )
        }.value

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination))
        #expect(await fileSystem.removedURLs.contains(source) == false)
    }

    @Test func resolvedAliasIdentityPreventsSelfReplacementAndRemoval() async {
        let source = URL(filePath: "/source/alias")
        let destination = URL(filePath: "/dest/alias")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, destination],
            identities: [
                source: FileIdentity(entryIdentifier: "symlink", resolvedIdentifier: "target"),
                destination: FileIdentity(entryIdentifier: "target", resolvedIdentifier: "target")
            ]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .move,
            resolveConflict: { _ in .replace },
            progress: { _ in }
        )

        #expect(result == FileOperationResult(outcomes: [.skipped(source: source)]))
        #expect(await fileSystem.copiedDestinations.isEmpty)
        #expect(await fileSystem.removedURLs.isEmpty)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(destination))
    }

    @Test func stagingCleanupErrorRequiresRecoveryReview() async {
        let source = URL(filePath: "/source/a")
        let cleanupError = CocoaError(.fileWriteNoPermission)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            cancelAfterCopy: true,
            stagingCleanupError: cleanupError
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        guard case let .recoveryNeeded(recoverySource) = result.outcomes.first else {
            Issue.record("Expected transfer cleanup recovery state")
            return
        }
        #expect(recoverySource == source)
    }

    @Test func nativeSameVolumeMoveDoesNotPerformCopyCapacityPreflight() async {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest")
        let destination = URL(filePath: "/dest/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            volumeIdentifiers: [source: "A", directory: "A"],
            byteSizes: [source: 2_000],
            availableCapacities: [directory: 1_000]
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .move,
            resolveConflict: { _ in .cancel },
            progress: { _ in }
        )

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: destination)
        ]))
        let events = await fileSystem.events
        #expect(events.contains("byteSize:/source/a") == false)
        #expect(events.contains("availableCapacity:/dest") == false)
        #expect(events.contains("fingerprint:/source/a") == false)
        #expect(await fileSystem.copiedDestinations.isEmpty)
    }

    @Test func multiItemFailureSkipAndCancelProduceExactOutcomesProgressAndLogCounts() async {
        let failedSource = URL(filePath: "/source/failed")
        let skippedSource = URL(filePath: "/source/skipped")
        let cancelledSource = URL(filePath: "/source/cancelled")
        let skippedDestination = URL(filePath: "/dest/skipped")
        let cancelledDestination = URL(filePath: "/dest/cancelled")
        let copyError = CocoaError(.fileWriteUnknown)
        let logger = RecordingOperationLogger()
        let progressRecorder = ProgressRecorder()
        let fileSystem = RecordingFileSystem(
            existingURLs: [
                failedSource, skippedSource, cancelledSource,
                skippedDestination, cancelledDestination
            ],
            copyErrorsBySource: [failedSource: copyError]
        )
        let service = FileOperationService(fileSystem: fileSystem, logger: logger)

        let result = await service.transfer(
            [failedSource, skippedSource, cancelledSource],
            to: URL(filePath: "/dest"),
            mode: .copy,
            resolveConflict: { conflict in
                conflict.source == skippedSource ? .skip : .cancel
            },
            progress: { value in await progressRecorder.append(value) }
        )

        #expect(result == FileOperationResult(outcomes: [
            .failed(source: failedSource, message: copyError.localizedDescription),
            .skipped(source: skippedSource),
            .cancelled(source: cancelledSource)
        ]))
        #expect(await progressRecorder.values == [
            FileOperationProgress(completedCount: 1, totalCount: 3, currentName: "failed"),
            FileOperationProgress(completedCount: 2, totalCount: 3, currentName: "skipped")
        ])
        #expect(await logger.events == [
            RecordingOperationLogger.Event(kind: .copy, succeeded: 0, failed: 1, skipped: 1)
        ])
    }

    @Test func cancellationIsCheckedBeforeRetryingStagingReservation() async {
        let source = URL(filePath: "/source/a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source],
            cancelFirstStagingReservation: true
        )
        let service = FileOperationService(fileSystem: fileSystem)

        let result = await Task {
            await service.transfer(
                [source],
                to: URL(filePath: "/dest"),
                mode: .copy,
                resolveConflict: { _ in .cancel },
                progress: { _ in }
            )
        }.value

        #expect(result.hasFailures)
        let attempts = await fileSystem.events.filter { $0.hasPrefix("createDirectory:/dest/.bloom-staging-") }
        #expect(attempts.count == 1)
        #expect(await fileSystem.copiedDestinations.isEmpty)
    }
}

private actor ProgressRecorder {
    private(set) var values: [FileOperationProgress] = []

    func append(_ value: FileOperationProgress) {
        values.append(value)
    }
}

private actor RecordingOperationLogger: OperationLogging {
    struct Event: Equatable, Sendable {
        let kind: FileOperationKind
        let succeeded: Int
        let failed: Int
        let skipped: Int
    }

    private(set) var events: [Event] = []

    func record(
        kind: FileOperationKind,
        duration: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int
    ) async {
        events.append(Event(kind: kind, succeeded: succeeded, failed: failed, skipped: skipped))
    }
}
