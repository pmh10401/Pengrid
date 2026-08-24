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

    @Test func disabledIdentifiedTransferNeverCreatesAVerificationSession() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(existingURLs: [source, directory])
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events }
        )
        let logger = RecordingOperationLogger()
        let service = FileOperationService(
            fileSystem: fileSystem,
            logger: logger,
            verificationSessionFactory: factory
        )

        let result = await service.transfer(
            [source],
            to: directory,
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .disabled,
            progress: { _ in }
        )

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: directory.appending(path: "a"))
        ]))
        #expect(factory.policies.isEmpty)
        #expect(await factory.recorder.events.isEmpty)
        #expect(await logger.verificationEvents.isEmpty)
    }

    @Test func enabledIdentifiedCopyCapturesPolicyAndVerifiesBeforePublication() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory],
            byteSizes: [source: 12],
            availableCapacities: [directory: 100]
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events }
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let verificationProgress = VerificationProgressRecorder()
        let sourceIdentity = try #require(await fileSystem.identity(of: source))
        let directoryIdentity = try #require(await fileSystem.identity(of: directory))
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: sourceIdentity,
            destinationRoot: directory,
            destinationRootIdentity: directoryIdentity,
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { value in
                await verificationProgress.append(value)
            }
        )

        #expect(result.outcomes == [
            .succeeded(source: source, destination: directory.appending(path: "a"))
        ])
        #expect(result.verificationReport != nil)
        #expect(factory.policies == [.sha256(maxConcurrentPairs: 2)])
        #expect(await verificationProgress.values.count == 1)
        #expect(await verificationProgress.values.first?.phase == .finalValidation)

        let events = await factory.recorder.events
        guard events.count == 3 else {
            Issue.record("Expected capture, verify, and revalidate events")
            return
        }
        guard case let .capture(
            capturedURL,
            capturedIdentity,
            comparisonPolicy,
            captureFilesystemEvents
        ) = events[0],
        case let .verify(_, _, verifyFilesystemEvents) = events[1],
        case let .revalidate(revalidateFilesystemEvents) = events[2]
        else {
            Issue.record("Unexpected verification event order")
            return
        }

        #expect(capturedURL == source)
        #expect(capturedIdentity == sourceIdentity)
        #expect(comparisonPolicy == .caseSensitiveCanonical)
        #expect(captureFilesystemEvents.contains("byteSize:/source/a"))
        #expect(captureFilesystemEvents.contains("availableCapacity:/dest"))

        let copyIndex = verifyFilesystemEvents.firstIndex {
            $0.hasPrefix("copy:/source/a->/dest/.bloom-staging-")
        }
        #expect(copyIndex != nil)
        #expect(revalidateFilesystemEvents.contains {
            $0.hasPrefix("copy:/source/a->/dest/.bloom-staging-")
        })
        #expect(revalidateFilesystemEvents.contains {
            $0.hasPrefix("moveChecked:/dest/.bloom-staging-")
        } == false)
        #expect(await fileSystem.events.contains {
            $0.hasPrefix("moveChecked:/dest/.bloom-staging-")
        })
    }

    @Test func URLIdentityCaptureFailureKeepsDisabledLegacyPathButEnabledFailsClosed() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)

        let disabledFileSystem = RecordingFileSystem(existingURLs: [source])
        let disabledFactory = RecordingTransferVerificationSessionFactory(
            eventSource: { await disabledFileSystem.events }
        )
        let disabledService = FileOperationService(
            fileSystem: disabledFileSystem,
            verificationSessionFactory: disabledFactory
        )
        let disabledResult = await disabledService.transfer(
            [source],
            to: directory,
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .disabled,
            progress: { _ in }
        )

        #expect(disabledResult.outcomes == [
            .succeeded(source: source, destination: directory.appending(path: "a"))
        ])
        #expect(await disabledFileSystem.copiedDestinations.isEmpty == false)
        #expect(disabledFactory.policies.isEmpty)

        let enabledFileSystem = RecordingFileSystem(existingURLs: [source])
        let enabledFactory = RecordingTransferVerificationSessionFactory(
            eventSource: { await enabledFileSystem.events }
        )
        let enabledService = FileOperationService(
            fileSystem: enabledFileSystem,
            verificationSessionFactory: enabledFactory
        )
        let enabledResult = await enabledService.transfer(
            [source],
            to: directory,
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(enabledResult.hasFailures)
        #expect(enabledResult.verificationReport != nil)
        #expect(await enabledFileSystem.copiedDestinations.isEmpty)
        #expect(await enabledFactory.recorder.events.isEmpty)
    }

    @Test func enabledSameVolumeMoveWithoutReplacementSkipsVerifierAndReportsNoByteTransfer() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let destination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory],
            volumeIdentifiers: [source: "same", directory: "same"]
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events }
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let sourceIdentity = try #require(await fileSystem.identity(of: source))
        let directoryIdentity = try #require(await fileSystem.identity(of: directory))
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: sourceIdentity,
            destinationRoot: directory,
            destinationRootIdentity: directoryIdentity,
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .move,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 1,
            failedVerificationItemCount: 0
        ))
        #expect(await factory.recorder.events.isEmpty)
        #expect(await fileSystem.copiedDestinations.isEmpty)
        #expect(await fileSystem.events.contains("moveChecked:/source/a->/dest/a"))
    }

    @Test func enabledReplacementMismatchPreservesTheOldDestinationAndReportsOneFailure() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let destination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory, destination]
        )
        let logger = RecordingOperationLogger()
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events },
            configuration: .init(
                verifyFailuresByCall: [1: .contentMismatch]
            )
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            logger: logger,
            verificationSessionFactory: factory
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: directory,
            destinationRootIdentity: try #require(await fileSystem.identity(of: directory)),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .replace },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(await fileSystem.exists(source))
        #expect(await fileSystem.exists(destination))
        #expect(await fileSystem.events.contains { $0.hasPrefix("replaceChecked:") } == false)
        #expect(await fileSystem.existingURLs.contains {
            $0.lastPathComponent.hasPrefix(".bloom-staging-")
        } == false)
        let report = TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1
        )
        #expect(result.verificationReport == report)
        #expect(await logger.verificationEvents == [TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1,
            failureCategory: .contentMismatch
        )])
    }

    @Test func enabledReceiptFailureCleansStagingBeforeReplacementPublication() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let destination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory, destination]
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events },
            configuration: .init(
                revalidateFailuresByCall: [1: .stagedOutputChanged]
            )
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: directory,
            destinationRootIdentity: try #require(await fileSystem.identity(of: directory)),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .replace },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect(await fileSystem.exists(source))
        #expect(await fileSystem.exists(destination))
        #expect(await fileSystem.events.contains { $0.hasPrefix("replaceChecked:") } == false)
        #expect(await fileSystem.existingURLs.contains {
            $0.lastPathComponent.hasPrefix(".bloom-staging-")
        } == false)
    }

    @Test func failedVerificationWithFailedStagingCleanupRequiresRecovery() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let destination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory, destination],
            stagingCleanupError: CocoaError(.fileWriteUnknown)
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events },
            configuration: .init(
                verifyFailuresByCall: [1: .structureMismatch]
            )
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: directory,
            destinationRootIdentity: try #require(await fileSystem.identity(of: directory)),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .replace },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.outcomes == [.recoveryNeeded(source: source)])
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect(await fileSystem.exists(source))
        #expect(await fileSystem.exists(destination))
        #expect(await fileSystem.events.contains { $0.hasPrefix("replaceChecked:") } == false)
    }

    @Test func enabledCrossVolumeMovePublishesVerifiedCopyBeforeRemovingSource() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let destination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory],
            volumeIdentifiers: [source: "source-volume", directory: "destination-volume"]
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events },
            configuration: .init(
                summariesByVerifyCall: [1: .init(
                    verifiedFileCount: 2,
                    verifiedLogicalByteCount: 42,
                    noByteTransferItemCount: 0
                )]
            )
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: directory,
            destinationRootIdentity: try #require(await fileSystem.identity(of: directory)),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .move,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 2,
            verifiedLogicalByteCount: 42,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        let events = await fileSystem.events
        let publishIndex = try #require(events.firstIndex {
            $0.hasPrefix("moveChecked:/dest/.bloom-staging-")
        })
        let removeIndex = try #require(events.firstIndex(of: "removeChecked:/source/a"))
        #expect(publishIndex < removeIndex)
        #expect(await factory.recorder.events.count == 3)
        #expect(await fileSystem.exists(source) == false)
        #expect(await fileSystem.exists(destination))
    }

    @Test func enabledCrossVolumeReadFailurePreservesSourceAndPublishesNothing() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let destination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory],
            volumeIdentifiers: [source: "source-volume", directory: "destination-volume"]
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events },
            configuration: .init(verifyFailuresByCall: [1: .readFailed])
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: directory,
            destinationRootIdentity: try #require(await fileSystem.identity(of: directory)),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .move,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect(await fileSystem.exists(source))
        #expect(await fileSystem.exists(destination) == false)
        #expect(await fileSystem.events.contains("removeChecked:/source/a") == false)
    }

    @Test func enabledSameVolumeReplacementUsesVerifiedStagingInsteadOfDirectRename() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let destination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, directory, destination],
            volumeIdentifiers: [source: "same", directory: "same"]
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events }
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: directory,
            destinationRootIdentity: try #require(await fileSystem.identity(of: directory)),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .move,
            resolveConflict: { _ in .replace },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.hasFailures == false)
        #expect(await factory.recorder.events.count == 3)
        #expect(await fileSystem.events.contains("moveChecked:/source/a->/dest/a") == false)
        #expect(await fileSystem.events.contains { $0.hasPrefix("replaceChecked:/dest/a<-") })
        #expect(await fileSystem.exists(source) == false)
        #expect(await fileSystem.exists(destination))
    }

    @Test func enabledSkipAndCapacityFailureNeverCaptureAndReturnAZeroReport() async throws {
        let first = URL(filePath: "/source/a")
        let second = URL(filePath: "/source/b")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let firstDestination = directory.appending(path: "a")
        let fileSystem = RecordingFileSystem(
            existingURLs: [first, second, directory, firstDestination],
            byteSizes: [second: 100],
            availableCapacities: [directory: 10]
        )
        let logger = RecordingOperationLogger()
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events }
        )
        let directoryIdentity = try #require(await fileSystem.identity(of: directory))
        let requests = [
            IdentifiedTransferRequest(
                source: first,
                sourceIdentity: try #require(await fileSystem.identity(of: first)),
                destinationRoot: directory,
                destinationRootIdentity: directoryIdentity,
                relativeParentComponents: []
            ),
            IdentifiedTransferRequest(
                source: second,
                sourceIdentity: try #require(await fileSystem.identity(of: second)),
                destinationRoot: directory,
                destinationRootIdentity: directoryIdentity,
                relativeParentComponents: []
            )
        ]
        let service = FileOperationService(
            fileSystem: fileSystem,
            logger: logger,
            verificationSessionFactory: factory
        )

        let result = await service.transfer(
            requests,
            mode: .copy,
            resolveConflict: { _ in .skip },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.outcomes.first == .skipped(source: first))
        #expect(result.outcomes.count == 2)
        #expect(result.hasFailures)
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(await factory.recorder.events.isEmpty)
        #expect(await logger.verificationEvents.count == 1)
    }

    @Test func enabledBatchAggregatesSuccessfulSummaryAndVerificationFailureOnce() async throws {
        let first = URL(filePath: "/source/a")
        let second = URL(filePath: "/source/b")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(existingURLs: [first, second, directory])
        let logger = RecordingOperationLogger()
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events },
            configuration: .init(
                verifyFailuresByCall: [2: .readFailed],
                summariesByVerifyCall: [1: .init(
                    verifiedFileCount: 3,
                    verifiedLogicalByteCount: 20,
                    noByteTransferItemCount: 0
                )]
            )
        )
        let directoryIdentity = try #require(await fileSystem.identity(of: directory))
        let requests = [
            IdentifiedTransferRequest(
                source: first,
                sourceIdentity: try #require(await fileSystem.identity(of: first)),
                destinationRoot: directory,
                destinationRootIdentity: directoryIdentity,
                relativeParentComponents: []
            ),
            IdentifiedTransferRequest(
                source: second,
                sourceIdentity: try #require(await fileSystem.identity(of: second)),
                destinationRoot: directory,
                destinationRootIdentity: directoryIdentity,
                relativeParentComponents: []
            )
        ]
        let service = FileOperationService(
            fileSystem: fileSystem,
            logger: logger,
            verificationSessionFactory: factory
        )

        let result = await service.transfer(
            requests,
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        let report = TransferVerificationReport(
            verifiedFileCount: 3,
            verifiedLogicalByteCount: 20,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1
        )
        #expect(result.verificationReport == report)
        #expect(result.outcomes.count == 2)
        #expect(result.hasFailures)
        #expect(await logger.verificationEvents == [TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: 3,
            verifiedLogicalByteCount: 20,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1,
            failureCategory: .readFailed
        )])
    }

    @Test func enabledVerificationCancellationCleansPrivateStageAndLogsBoundedCategory() async throws {
        let source = URL(filePath: "/source/a")
        let directory = URL(filePath: "/dest", directoryHint: .isDirectory)
        let fileSystem = RecordingFileSystem(existingURLs: [source, directory])
        let logger = RecordingOperationLogger()
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fileSystem.events },
            configuration: .init(
                verifyFailuresByCall: [1: .cancelled],
                cancellingVerifyCalls: [1]
            )
        )
        let service = FileOperationService(
            fileSystem: fileSystem,
            logger: logger,
            verificationSessionFactory: factory
        )
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: directory,
            destinationRootIdentity: try #require(await fileSystem.identity(of: directory)),
            relativeParentComponents: []
        )

        let result = await Task {
            await service.transfer(
                [request],
                mode: .copy,
                resolveConflict: { _ in .cancel },
                verificationPolicy: .sha256(maxConcurrentPairs: 2),
                progress: { _ in }
            )
        }.value

        #expect(result.outcomes == [.cancelled(source: source)])
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect(await logger.verificationEvents.first?.failureCategory == .cancelled)
        #expect(await fileSystem.existingURLs.contains {
            $0.lastPathComponent.hasPrefix(".bloom-staging-")
        } == false)
        #expect(await fileSystem.exists(source))
    }

    @Test func liveEnabledCopyVerifiesSingleFileContentsBeforePublishing() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sourceRoot = root.url.appending(path: "Source", directoryHint: .isDirectory)
        let destinationRoot = root.url.appending(
            path: "Destination",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: false
        )
        let payload = Data("verified-single-file".utf8)
        let source = sourceRoot.appending(path: "Report.txt")
        let destination = destinationRoot.appending(path: "Report.txt")
        try payload.write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let service = FileOperationService(fileSystem: fileSystem)
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: destinationRoot,
            destinationRootIdentity: try #require(
                await fileSystem.identity(of: destinationRoot)
            ),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 1,
            verifiedLogicalByteCount: Int64(payload.count),
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func liveEnabledCopyVerifiesRecursiveDirectoryContentsBeforePublishing() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sourceRoot = root.url.appending(path: "Source", directoryHint: .isDirectory)
        let destinationRoot = root.url.appending(
            path: "Destination",
            directoryHint: .isDirectory
        )
        let source = sourceRoot.appending(path: "Folder", directoryHint: .isDirectory)
        let nested = source.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: false
        )
        let first = Data("first".utf8)
        let second = Data("second payload".utf8)
        try first.write(to: source.appending(path: "First.txt"))
        try second.write(to: nested.appending(path: "Second.txt"))
        let destination = destinationRoot.appending(path: "Folder")
        let fileSystem = LiveFileSystemAccess()
        let service = FileOperationService(fileSystem: fileSystem)
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: destinationRoot,
            destinationRootIdentity: try #require(
                await fileSystem.identity(of: destinationRoot)
            ),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 2,
            verifiedLogicalByteCount: Int64(first.count + second.count),
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(try Data(contentsOf: destination.appending(path: "First.txt")) == first)
        #expect(try Data(
            contentsOf: destination.appending(path: "Nested/Second.txt")
        ) == second)
    }

    @Test func liveEnabledCopyVerifiesSymbolicLinkPayloadWithoutFollowingTarget() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sourceRoot = root.url.appending(path: "Source", directoryHint: .isDirectory)
        let destinationRoot = root.url.appending(
            path: "Destination",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: false
        )
        let target = sourceRoot.appending(path: "Target.txt")
        try Data("target bytes are not hashed through the link".utf8).write(to: target)
        let source = sourceRoot.appending(path: "Target Link")
        try FileManager.default.createSymbolicLink(
            at: source,
            withDestinationURL: target
        )
        let destination = destinationRoot.appending(path: "Target Link")
        let fileSystem = LiveFileSystemAccess()
        let service = FileOperationService(fileSystem: fileSystem)
        let request = IdentifiedTransferRequest(
            source: source,
            sourceIdentity: try #require(await fileSystem.identity(of: source)),
            destinationRoot: destinationRoot,
            destinationRootIdentity: try #require(
                await fileSystem.identity(of: destinationRoot)
            ),
            relativeParentComponents: []
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
            == FileManager.default.destinationOfSymbolicLink(atPath: source.path))
    }
}

private actor ProgressRecorder {
    private(set) var values: [FileOperationProgress] = []

    func append(_ value: FileOperationProgress) {
        values.append(value)
    }
}

private actor VerificationProgressRecorder {
    private(set) var values: [TransferVerificationProgress] = []

    func append(_ value: TransferVerificationProgress) {
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
    private(set) var verificationEvents: [TransferVerificationLogEvent] = []

    func record(
        kind: FileOperationKind,
        duration: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int
    ) async {
        events.append(Event(kind: kind, succeeded: succeeded, failed: failed, skipped: skipped))
    }

    func recordTransferVerification(
        _ event: TransferVerificationLogEvent
    ) async {
        verificationEvents.append(event)
    }
}
