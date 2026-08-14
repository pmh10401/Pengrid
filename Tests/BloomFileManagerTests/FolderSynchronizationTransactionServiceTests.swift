import Foundation
import Testing
@testable import BloomFileManager

@Suite struct FolderSynchronizationTransactionServiceTests {
    @Test func destinationParentContainmentIsComponentBounded() {
        let root = URL(filePath: "/dest", directoryHint: .isDirectory)

        #expect(FolderSynchronizationTransactionService.isContained(
            URL(filePath: "/dest/folder", directoryHint: .isDirectory),
            in: root
        ))
        #expect(!FolderSynchronizationTransactionService.isContained(
            URL(filePath: "/destination/folder", directoryHint: .isDirectory),
            in: root
        ))
    }

    @Test func stagesVerifiesPublishesAndOnlyThenReportsSuccess() async throws {
        let fixture = try await TransactionCopyFixture()

        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem, scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability()
        )
        let result = await service.execute(fixture.plan)

        #expect(result == FileOperationResult(outcomes: [.succeeded(source: fixture.source, destination: fixture.destination)]))
        #expect(await fixture.fileSystem.exists(fixture.destination))
        let events = await fixture.fileSystem.events
        let copyIndex = try #require(events.firstIndex { $0.hasPrefix("copy:") })
        let publishIndex = try #require(events.firstIndex { $0.hasPrefix("moveExclusiveChecked:") })
        #expect(copyIndex < publishIndex)
    }

    @Test func cancellationAfterStagingRemovesOnlyOwnedStagingAndLeavesDestinationAbsent() async throws {
        let fixture = try await TransactionCopyFixture(cancelAfterCopy: true)
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem, scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability()
        )

        let result = await Task.detached { await service.execute(fixture.plan) }.value

        #expect(result == FileOperationResult(outcomes: [.cancelled(source: fixture.source)]))
        #expect(await !fixture.fileSystem.exists(fixture.destination))
        let events = await fixture.fileSystem.events
        #expect(events.contains { $0.hasPrefix("removeChecked:") })
        #expect(events.contains { $0.hasPrefix("removeStaging:") })
    }

    @Test func publicationFailureRollsBackOwnedStagingAndBalancesScopes() async throws {
        let fixture = try await TransactionCopyFixture(failPublication: true)
        let scopes = TransactionTestScopedAccess()
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: scopes, availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result.outcomes.count == 1)
        #expect(await !fixture.fileSystem.exists(fixture.destination))
        #expect(scopes.isBalanced)
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("removeStaging:") })
    }

    @Test func changedPublicationWithFailedOwnedCleanupReturnsRecoveryNeeded() async throws {
        let fixture = try await TransactionCopyFixture(
            mutatePublishedItem: true,
            failPublicationCleanupAfterSideEffect: true
        )
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result == FileOperationResult(outcomes: [.recoveryNeeded(source: fixture.source)]))
    }

    @Test func stalePreflightBlocksBeforeCreatingAnyStagingResidue() async throws {
        let fixture = try await TransactionCopyFixture()
        await fixture.fileSystem.mutateContents(at: fixture.source)
        let scopes = TransactionTestScopedAccess()
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: scopes, availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result.outcomes.count == 1)
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("createDirectory:") } == false)
        #expect(scopes.isBalanced)
    }

    @Test func stagedReplacementIsPreservedAndReportedForRecovery() async throws {
        let fixture = try await TransactionCopyFixture(replaceStagedIdentity: true)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result == FileOperationResult(outcomes: [.recoveryNeeded(source: fixture.source)]))
        #expect(await !fixture.fileSystem.exists(fixture.destination))
        // The staged payload identity changed after copy.  The service must not adopt
        // it just because its enclosing directory was originally ours.
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("removeStaging:") } == false)
    }

    @Test func partialCopyFailureWithUnknownPayloadIdentityReportsRecoveryInsteadOfDeletingIt() async throws {
        let fixture = try await TransactionCopyFixture(copyFailsAfterPartialPayload: true)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result == FileOperationResult(outcomes: [.recoveryNeeded(source: fixture.source)]))
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("removeChecked:") } == false)
    }

    @Test func replaceQuarantinesThenPublishesAndOnlyThenTransfersOldItemToTrash() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result == FileOperationResult(outcomes: [.succeeded(source: fixture.source, destination: fixture.destination)]))
        let events = await fixture.fileSystem.events
        let publish = try #require(events.firstIndex { $0.hasPrefix("moveExclusiveChecked:") })
        let trash = try #require(events.firstIndex { $0.hasPrefix("trash:") })
        #expect(publish < trash)
    }

    @Test func trashOnlyQuarantinesAndTransfersWithoutAnyCopyOrPermanentRemoval() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .moveDestinationToTrash)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result == FileOperationResult(outcomes: [.succeeded(source: fixture.destination, destination: nil)]))
        let events = await fixture.fileSystem.events
        #expect(events.contains { $0.hasPrefix("trash:") })
        #expect(events.contains { $0.hasPrefix("copy:") } == false)
        #expect(events.contains { $0.hasPrefix("removeChecked:") } == false)
    }

    @Test func trashTransferFailureRestoresQuarantineAndRollsBackPublication() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace, failTrashTransfer: true)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result.outcomes.count == 1)
        #expect(try await fixture.fileSystem.identity(of: fixture.destination) == fixture.destinationIdentity)
    }

    @Test func publishedVerificationFailureIsRecoveryNeededRatherThanDeletingChangedItem() async throws {
        let fixture = try await TransactionCopyFixture(mutatePublishedItem: true)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result == FileOperationResult(outcomes: [.recoveryNeeded(source: fixture.source)]))
        #expect(await fixture.fileSystem.exists(fixture.destination))
    }

    @Test func cancellationAfterQuarantineRestoresPreexistingDestinationAndBalancesScopes() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let scopes = TransactionTestScopedAccess()
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: scopes, availabilityReader: TransactionTestAvailability())

        let result = await Task.detached {
            await service.execute(fixture.plan) { progress in
                if progress.phase == .publishing {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value

        #expect(result == FileOperationResult(outcomes: [.cancelled(source: fixture.source)]))
        #expect(try await fixture.fileSystem.identity(of: fixture.destination) == fixture.destinationIdentity)
        #expect(scopes.isBalanced)
    }

    @Test func cancellationBeforeTrashRestoresQuarantineAndRemovesOwnedPublication() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await Task.detached {
            await service.execute(fixture.plan) { progress in
                if progress.phase == .movingToTrash {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value

        #expect(result == FileOperationResult(outcomes: [.cancelled(source: fixture.source)]))
        #expect(try await fixture.fileSystem.identity(of: fixture.destination) == fixture.destinationIdentity)
    }

    @Test func preflightBlocksUnavailableSourceWithoutMaterializingOrStaging() async throws {
        let fixture = try await TransactionCopyFixture()
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionUnavailableAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result.outcomes.count == 1)
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("createDirectory:") } == false)
    }

    @Test func cancellationAtEveryCopyPhaseLeavesNoPublicationOrStagingResidue() async throws {
        let phases: [FolderSynchronizationTransactionPhase] = [
            .preflighting, .staging, .verifyingStaging, .publishing, .verifyingPublished
        ]
        for phase in phases {
            let fixture = try await TransactionCopyFixture()
            let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
                scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())
            let result = await Task.detached {
                await service.execute(fixture.plan) { progress in
                    if progress.phase == phase { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }.value
            #expect(result == FileOperationResult(outcomes: [.cancelled(source: fixture.source)]))
            #expect(await !fixture.fileSystem.exists(fixture.destination))
            #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("removeStaging:") }
                || phase == .preflighting || phase == .staging)
        }
    }

    @Test func cancellationAtQuarantineAndTrashBoundariesRestoresPreexistingDestination() async throws {
        for phase in [FolderSynchronizationTransactionPhase.quarantining, .movingToTrash] {
            let fixture = try await TransactionReplacementFixture(kind: .replace)
            let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
                scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())
            let result = await Task.detached {
                await service.execute(fixture.plan) { progress in
                    if progress.phase == phase { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }.value
            #expect(result == FileOperationResult(outcomes: [.cancelled(source: fixture.source)]))
            #expect(try await fixture.fileSystem.identity(of: fixture.destination) == fixture.destinationIdentity)
        }
    }

    @Test func quarantineBoundaryDriftFailsBeforeMovingPreexistingDestination() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan) { progress in
            if progress.phase == .quarantining { await fixture.fileSystem.mutateContents(at: fixture.destination) }
        }

        #expect(result.outcomes.count == 1)
        #expect(try await fixture.fileSystem.identity(of: fixture.destination) == fixture.destinationIdentity)
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("trash:") } == false)
    }

    @Test func overlappingPreparedActionsFailClosedBeforeStaging() async throws {
        let fixture = try await TransactionCopyFixture()
        let root = fixture.plan.draft.sourceRoot
        let parent = try ComparisonRelativePath(components: ["folder"])
        let child = try ComparisonRelativePath(components: ["folder", "item.txt"])
        let identity = FileIdentity(entryIdentifier: "untrusted", resolvedIdentifier: "untrusted")
        let entry: (ComparisonRelativePath) -> ComparisonEntry = { path in
            .init(relativePath: path, url: root.appending(path: path.string), kind: .regularFile,
                fingerprint: .init(identity: identity, byteSize: nil, modifiedAt: nil),
                symbolicLinkTarget: nil, typeDescription: "regularFile")
        }
        let draft = try FolderSynchronizationPlanDraft(direction: .leftToRight, comparisonGeneration: UUID(),
            sourceRoot: root, destinationRoot: fixture.plan.draft.destinationRoot,
            sourceRootIdentity: fixture.plan.draft.sourceRootIdentity,
            destinationRootIdentity: fixture.plan.draft.destinationRootIdentity,
            actions: [try .init(relativePath: parent, kind: .copy, source: entry(parent), destination: nil),
                      try .init(relativePath: child, kind: .copy, source: entry(child), destination: nil)],
            skipCount: 0, estimatedRegularFileCopyBytes: 0)
        let untrusted = PreparedFolderSynchronizationPlan(draft: draft, sourceFingerprints: [:],
            destinationFingerprints: [:], expectedAbsentDestinations: [], requiredCapacityBytes: 0,
            destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
            rootAuthority: fixture.plan.rootAuthority,
            destinationParentIdentities: [parent: fixture.plan.draft.destinationRootIdentity,
                child: fixture.plan.draft.destinationRootIdentity])
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(untrusted)

        #expect(result.outcomes.count == 2)
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("createDirectory:") } == false)
    }

    @Test func destinationParentReplacementAfterPreflightBlocksStaging() async throws {
        let fixture = try await TransactionCopyFixture()
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())
        let replacement = FileIdentity(entryIdentifier: "replacement-parent", resolvedIdentifier: "replacement-parent")

        let result = await service.execute(fixture.plan) { progress in
            if progress.phase == .staging {
                await fixture.fileSystem.replaceIdentity(
                    at: fixture.plan.draft.destinationRoot, with: replacement
                )
            }
        }

        #expect(result.outcomes.count == 1)
        #expect((await fixture.fileSystem.events).contains { $0.hasPrefix("createDirectory:") } == false)
    }

    @Test func partialTrashCommitKeepsCommittedItemSucceededAndRestoredFailureNonrecoverable() async throws {
        let fixture = try await TransactionTwoTrashFixture(failSecondTrashCommit: true)
        let service = FolderSynchronizationTransactionService(fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(), availabilityReader: TransactionTestAvailability())

        let result = await service.execute(fixture.plan)

        #expect(result.outcomes.count == 2)
        guard case let .succeeded(source: firstSource, destination: firstDestination) = result.outcomes[0] else {
            Issue.record("first committed Trash action was not retained as success")
            return
        }
        #expect(firstSource == fixture.first)
        #expect(firstDestination == nil)
        guard case let .failed(source: secondSource, message: _) = result.outcomes[1] else {
            Issue.record("restored precommit Trash failure was not an ordinary failure")
            return
        }
        #expect(secondSource == fixture.second)
        #expect(await !fixture.fileSystem.exists(fixture.first))
        #expect(try await fixture.fileSystem.identity(of: fixture.second) == fixture.secondIdentity)
    }
}

private struct TransactionCopyFixture {
    let source = URL(filePath: "/transaction/source/report.txt")
    let destination = URL(filePath: "/transaction/destination/report.txt")
    let fileSystem: RecordingFileSystem
    let plan: PreparedFolderSynchronizationPlan

    init(
        cancelAfterCopy: Bool = false,
        failPublication: Bool = false,
        mutatePublishedItem: Bool = false,
        replaceStagedIdentity: Bool = false,
        copyFailsAfterPartialPayload: Bool = false,
        failPublicationCleanupAfterSideEffect: Bool = false
    ) async throws {
        let sourceRoot = source.deletingLastPathComponent()
        let destinationRoot = destination.deletingLastPathComponent()
        let path = try ComparisonRelativePath(components: ["report.txt"])
        let sourceRootIdentity = FileIdentity(entryIdentifier: "source-root", resolvedIdentifier: "source-root")
        let destinationRootIdentity = FileIdentity(entryIdentifier: "destination-root", resolvedIdentifier: "destination-root")
        let sourceIdentity = FileIdentity(entryIdentifier: "source", resolvedIdentifier: "source")
        fileSystem = RecordingFileSystem(
            existingURLs: [sourceRoot, destinationRoot, source],
            availableCapacities: [destinationRoot: 1],
            cancelAfterCopy: cancelAfterCopy,
            identities: [sourceRoot: sourceRootIdentity, destinationRoot: destinationRootIdentity, source: sourceIdentity],
            copyErrorAfterCreatingPartial: copyFailsAfterPartialPayload ? CocoaError(.fileWriteUnknown) : nil,
            sourceRemovalErrorAfterSideEffect: failPublicationCleanupAfterSideEffect
                ? CocoaError(.fileWriteUnknown) : nil,
            replacementStagingIdentityAfterSuccessfulCopy: replaceStagedIdentity
                ? FileIdentity(entryIdentifier: "replacement-staged", resolvedIdentifier: "replacement-staged") : nil,
            failCheckedExclusiveMoveAttempts: failPublication ? [1] : [],
            mutateMovedDestinationAfterCheckedExclusiveMoveAttempts: mutatePublishedItem ? [1] : []
        )
        let fingerprint = try await fileSystem.fingerprint(of: source)
        let sourceEntry = ComparisonEntry(relativePath: path, url: source, kind: .regularFile,
            fingerprint: .init(identity: sourceIdentity, byteSize: nil, modifiedAt: nil),
            symbolicLinkTarget: nil, typeDescription: "regularFile")
        let action = try FolderSynchronizationAction(relativePath: path, kind: .copy, source: sourceEntry, destination: nil)
        let draft = try FolderSynchronizationPlanDraft(direction: .leftToRight, comparisonGeneration: UUID(),
            sourceRoot: sourceRoot, destinationRoot: destinationRoot, sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity, actions: [action], skipCount: 0, estimatedRegularFileCopyBytes: 0)
        plan = .init(draft: draft, sourceFingerprints: [path: fingerprint], destinationFingerprints: [:],
            expectedAbsentDestinations: [path], requiredCapacityBytes: 0,
            destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
            rootAuthority: .init(source: .init(identity: sourceRootIdentity, canonicalURL: sourceRoot,
                volumeIdentifier: "transaction", mountIdentifier: "transaction"),
                destination: .init(identity: destinationRootIdentity, canonicalURL: destinationRoot,
                    volumeIdentifier: "transaction", mountIdentifier: "transaction")),
            destinationParentIdentities: [path: destinationRootIdentity])
    }
}

private struct TransactionReplacementFixture {
    let source = URL(filePath: "/transaction/source/report.txt")
    let destination = URL(filePath: "/transaction/destination/report.txt")
    let destinationIdentity = FileIdentity(entryIdentifier: "destination", resolvedIdentifier: "destination")
    let fileSystem: RecordingFileSystem
    let plan: PreparedFolderSynchronizationPlan

    init(kind: FolderSynchronizationActionKind, failTrashTransfer: Bool = false) async throws {
        let sourceRoot = source.deletingLastPathComponent()
        let destinationRoot = destination.deletingLastPathComponent()
        let path = try ComparisonRelativePath(components: ["report.txt"])
        let sourceRootIdentity = FileIdentity(entryIdentifier: "source-root", resolvedIdentifier: "source-root")
        let destinationRootIdentity = FileIdentity(entryIdentifier: "destination-root", resolvedIdentifier: "destination-root")
        let sourceIdentity = FileIdentity(entryIdentifier: "source", resolvedIdentifier: "source")
        var urls: Set<URL> = [sourceRoot, destinationRoot, destination]
        if kind != .moveDestinationToTrash { urls.insert(source) }
        fileSystem = RecordingFileSystem(existingURLs: urls, availableCapacities: [destinationRoot: 1],
            identities: [sourceRoot: sourceRootIdentity, destinationRoot: destinationRootIdentity,
                source: sourceIdentity, destination: destinationIdentity],
            failTrashQuarantineCommitOnAttempt: failTrashTransfer ? 1 : nil)
        let sourceFingerprint = kind == .moveDestinationToTrash ? nil : try await fileSystem.fingerprint(of: source)
        let destinationFingerprint = try await fileSystem.fingerprint(of: destination)
        let sourceEntry: ComparisonEntry?
        if sourceFingerprint != nil {
            sourceEntry = ComparisonEntry(relativePath: path, url: source, kind: .regularFile,
                fingerprint: .init(identity: sourceIdentity, byteSize: nil, modifiedAt: nil),
                symbolicLinkTarget: nil, typeDescription: "regularFile")
        } else {
            sourceEntry = nil
        }
        let destinationEntry = ComparisonEntry(relativePath: path, url: destination, kind: .regularFile,
            fingerprint: .init(identity: destinationIdentity, byteSize: nil, modifiedAt: nil),
            symbolicLinkTarget: nil, typeDescription: "regularFile")
        let action = try FolderSynchronizationAction(relativePath: path, kind: kind,
            source: sourceEntry, destination: destinationEntry)
        let draft = try FolderSynchronizationPlanDraft(direction: .leftToRight, comparisonGeneration: UUID(),
            sourceRoot: sourceRoot, destinationRoot: destinationRoot, sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity, actions: [action], skipCount: 0,
            estimatedRegularFileCopyBytes: 0)
        plan = .init(draft: draft, sourceFingerprints: sourceFingerprint.map { [path: $0] } ?? [:],
            destinationFingerprints: [path: destinationFingerprint], expectedAbsentDestinations: [],
            requiredCapacityBytes: 0, destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
            rootAuthority: .init(source: .init(identity: sourceRootIdentity, canonicalURL: sourceRoot,
                volumeIdentifier: "transaction", mountIdentifier: "transaction"),
                destination: .init(identity: destinationRootIdentity, canonicalURL: destinationRoot,
                    volumeIdentifier: "transaction", mountIdentifier: "transaction")),
            // Every mutation, including a Trash-only action, is bound to its
            // destination parent namespace.
            destinationParentIdentities: [path: destinationRootIdentity])
    }
}

private struct TransactionTwoTrashFixture {
    let first = URL(filePath: "/transaction/destination/a.txt")
    let second = URL(filePath: "/transaction/destination/b.txt")
    let secondIdentity = FileIdentity(entryIdentifier: "second", resolvedIdentifier: "second")
    let fileSystem: RecordingFileSystem
    let plan: PreparedFolderSynchronizationPlan

    init(failSecondTrashCommit: Bool) async throws {
        let sourceRoot = URL(filePath: "/transaction/source", directoryHint: .isDirectory)
        let destinationRoot = first.deletingLastPathComponent()
        let sourceRootIdentity = FileIdentity(entryIdentifier: "source-root", resolvedIdentifier: "source-root")
        let destinationRootIdentity = FileIdentity(entryIdentifier: "destination-root", resolvedIdentifier: "destination-root")
        let firstIdentity = FileIdentity(entryIdentifier: "first", resolvedIdentifier: "first")
        let firstPath = try ComparisonRelativePath(components: ["a.txt"])
        let secondPath = try ComparisonRelativePath(components: ["b.txt"])
        fileSystem = RecordingFileSystem(existingURLs: [sourceRoot, destinationRoot, first, second],
            availableCapacities: [destinationRoot: 1], identities: [sourceRoot: sourceRootIdentity,
                destinationRoot: destinationRootIdentity, first: firstIdentity, second: secondIdentity],
            failTrashQuarantineCommitOnAttempt: failSecondTrashCommit ? 2 : nil)
        let firstFingerprint = try await fileSystem.fingerprint(of: first)
        let secondFingerprint = try await fileSystem.fingerprint(of: second)
        func destinationEntry(_ path: ComparisonRelativePath, _ url: URL, _ identity: FileIdentity) -> ComparisonEntry {
            .init(relativePath: path, url: url, kind: .regularFile,
                fingerprint: .init(identity: identity, byteSize: nil, modifiedAt: nil),
                symbolicLinkTarget: nil, typeDescription: "regularFile")
        }
        let actions = [
            try FolderSynchronizationAction(relativePath: firstPath, kind: .moveDestinationToTrash,
                source: nil, destination: destinationEntry(firstPath, first, firstIdentity)),
            try FolderSynchronizationAction(relativePath: secondPath, kind: .moveDestinationToTrash,
                source: nil, destination: destinationEntry(secondPath, second, secondIdentity))
        ]
        let draft = try FolderSynchronizationPlanDraft(direction: .leftToRight, comparisonGeneration: UUID(),
            sourceRoot: sourceRoot, destinationRoot: destinationRoot, sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity, actions: actions, skipCount: 0,
            estimatedRegularFileCopyBytes: 0)
        plan = .init(draft: draft, sourceFingerprints: [:],
            destinationFingerprints: [firstPath: firstFingerprint, secondPath: secondFingerprint],
            expectedAbsentDestinations: [], requiredCapacityBytes: 0,
            destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
            rootAuthority: .init(source: .init(identity: sourceRootIdentity, canonicalURL: sourceRoot,
                volumeIdentifier: "transaction", mountIdentifier: "transaction"),
                destination: .init(identity: destinationRootIdentity, canonicalURL: destinationRoot,
                    volumeIdentifier: "transaction", mountIdentifier: "transaction")),
            destinationParentIdentities: [firstPath: destinationRootIdentity,
                secondPath: destinationRootIdentity])
    }
}

extension RecordingFileSystem {
    func captureFolderSynchronizationRootAuthority(
        at url: URL,
        expectedIdentity: FileIdentity
    ) async throws -> FolderSynchronizationRootEvidence {
        .init(identity: expectedIdentity, canonicalURL: url.standardizedFileURL,
              volumeIdentifier: "transaction", mountIdentifier: "transaction")
    }
}

extension RecordingFileSystem: FolderSynchronizationRootAuthorityProviding {}

private final class TransactionTestScopedAccess: FolderSynchronizationScopedAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var acquired = 0
    private var released = 0

    func acquireAccess(for roots: [URL]) throws -> [any FolderSynchronizationScopedAccessLease] {
        lock.withLock { acquired += roots.count }
        return roots.map { _ in TransactionTestLease { [weak self] in
            self?.lock.withLock { self?.released += 1 }
        } }
    }

    var isBalanced: Bool { lock.withLock { acquired == released } }
}

private final class TransactionTestLease: FolderSynchronizationScopedAccessLease, @unchecked Sendable {
    private let onFinish: @Sendable () -> Void
    private let lock = NSLock()
    private var finished = false

    init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }

    func finish() {
        guard lock.withLock({ !finished }) else { return }
        lock.withLock { finished = true }
        onFinish()
    }
}

private actor TransactionTestAvailability: CloudItemAvailabilityReading {
    func availability(of url: URL) -> CloudItemAvailability { .availableLocally }
}

private actor TransactionUnavailableAvailability: CloudItemAvailabilityReading {
    func availability(of url: URL) -> CloudItemAvailability { .onlineOnly }
}
