import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct StorageAnalysisStoreTests {
    @Test func progressiveBatchesPublishBeforeDuplicateVerification() async throws {
        let fixture = try StorageStoreFixture.twoControlledBatches()
        fixture.store.enter()

        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        #expect(await fixture.scanner.waitForRequestCount(1))
        fixture.scanner.releaseFirstBatch()
        await waitUntil { fixture.store.entries.count == fixture.firstBatchCount }

        #expect(fixture.store.phase == .scanning)
        #expect(fixture.store.entries.count == fixture.firstBatchCount)
        #expect(fixture.store.verificationStates[fixture.fixtureEntries[0].id] == .unverified)
        fixture.scanner.finish()
        await scan.value

        #expect(fixture.store.phase == .complete)
    }

    @Test func olderCancelledGenerationCannotPublishRowsOrGroups() async throws {
        let fixture = try StorageStoreFixture.overlappingScans()
        fixture.store.enter()

        let old = Task {
            await fixture.store.requestScan(at: fixture.oldRoot, options: .init())
        }
        #expect(await fixture.scanner.waitForRequestCount(1))
        await fixture.store.requestScan(at: fixture.newRoot, options: .init())
        fixture.scanner.releaseOldResult()
        await old.value

        #expect(fixture.store.rootURL == fixture.newRoot)
        #expect(fixture.store.entries.map(\.url).allSatisfy {
            $0.path.hasPrefix(fixture.newRoot.path)
        })
        #expect(fixture.store.duplicateGroups.isEmpty)
    }

    @Test func protectedRootRequiresExplicitConfirmationAndCloudRootNeverStarts() async throws {
        let fixture = try StorageStoreFixture.locationDecisions()
        fixture.store.enter()

        await fixture.store.requestScan(at: fixture.protectedRoot, options: .init())

        #expect(fixture.store.pendingProtectedRoot == fixture.protectedRoot)
        #expect(fixture.scanner.requestCount == 0)
        #expect(fixture.scanner.identityRequestCount == 0)

        await fixture.store.requestScan(at: fixture.cloudRoot, options: .init())

        #expect(fixture.scanner.requestCount == 0)
        #expect(fixture.scanner.identityRequestCount == 0)
    }

    @Test func protectedConfirmationUsesTheOriginalRequestOptions() async throws {
        let fixture = try StorageStoreFixture.locationDecisions()
        fixture.store.enter()
        await fixture.store.requestScan(
            at: fixture.protectedRoot,
            options: StorageScanOptions(includeHiddenItems: true)
        )

        await fixture.store.confirmProtectedScan(options: .init())

        #expect(fixture.scanner.requests.count == 1)
        #expect(fixture.scanner.requests[0].options.includeHiddenItems)
        #expect(fixture.store.phase == .complete)
    }

    @Test func cancellingProtectedRequestPreservesCompletedAnalysisAndPreferences() async throws {
        let fixture = try StorageStoreFixture.verifiedDuplicateGroup()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.root, options: .init())
        fixture.store.section = .duplicates
        fixture.store.thresholds = StorageAnalysisThresholds(
            largeFileBytes: 500,
            longUnmodifiedDays: 180
        )
        fixture.store.preferredKeepFolder = fixture.fixtureEntries[0].id
        fixture.store.selectedEntryIDs = [fixture.fixtureEntries[1].id]
        let generation = fixture.store.currentGeneration
        let rootURL = fixture.store.rootURL
        let rootIdentity = fixture.store.rootIdentity
        let entries = fixture.store.entries
        let failures = fixture.store.failures
        let duplicateGroups = fixture.store.duplicateGroups
        let verificationStates = fixture.store.verificationStates

        await fixture.store.requestScan(
            at: fixture.protectedRoot,
            options: StorageScanOptions(includeHiddenItems: true)
        )
        #expect(fixture.store.pendingProtectedRoot == fixture.protectedRoot)

        fixture.store.cancelProtectedScanRequest()

        #expect(fixture.store.pendingProtectedRoot == nil)
        #expect(fixture.store.isActive)
        #expect(fixture.store.phase == .complete)
        #expect(fixture.store.currentGeneration == generation)
        #expect(fixture.store.rootURL == rootURL)
        #expect(fixture.store.rootIdentity == rootIdentity)
        #expect(fixture.store.entries == entries)
        #expect(fixture.store.failures == failures)
        #expect(fixture.store.duplicateGroups == duplicateGroups)
        #expect(fixture.store.verificationStates == verificationStates)
        #expect(fixture.store.section == .duplicates)
        #expect(fixture.store.thresholds == StorageAnalysisThresholds(
            largeFileBytes: 500,
            longUnmodifiedDays: 180
        ))
        #expect(fixture.store.preferredKeepFolder == fixture.fixtureEntries[0].id)
        #expect(fixture.store.selectedEntryIDs == [fixture.fixtureEntries[1].id])

        await fixture.store.confirmProtectedScan(options: .init())
        #expect(fixture.scanner.requestCount == 1)
    }

    @Test func changedRootIdentityPausesBeforeDuplicateDetection() async throws {
        let fixture = try StorageStoreFixture.changedRootIdentity()
        fixture.store.enter()

        await fixture.store.requestScan(at: fixture.root, options: .init())

        #expect(fixture.store.phase == .paused)
        #expect(fixture.store.entries.count == 1)
        #expect(fixture.duplicates.requestCount == 0)
    }

    @Test func rootIdentityChangeBetweenEnumerationBatchesRejectsTheReplacementBatch() async throws {
        let fixture = try StorageStoreFixture.identityChangeBetweenBatches()
        fixture.store.enter()

        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        #expect(await fixture.scanner.waitForRequestCount(1))
        fixture.scanner.releaseFirstBatch()
        await waitUntil { fixture.store.entries.count == 1 }

        fixture.scanner.replaceRootIdentity()
        fixture.scanner.finish()
        await scan.value

        #expect(fixture.store.phase == .paused)
        #expect(fixture.store.entries.map(\.id) == [fixture.fixtureEntries[0].id])
        #expect(fixture.duplicates.requestCount == 0)
    }

    @Test func protectedAcknowledgementMustBeRepeatedAfterExit() async throws {
        let fixture = try StorageStoreFixture.locationDecisions()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.protectedRoot, options: .init())
        await fixture.store.confirmProtectedScan(options: .init())
        #expect(fixture.scanner.requestCount == 1)

        fixture.store.exit()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.protectedRoot, options: .init())

        #expect(fixture.store.pendingProtectedRoot == fixture.protectedRoot)
        #expect(fixture.scanner.requestCount == 1)
    }

    @Test func protectedScanRequiresDistinctCleanupAcknowledgementAndExitResetsIt() async throws {
        let fixture = try StorageStoreFixture.protectedVerifiedDuplicateGroup()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.protectedRoot, options: .init())
        await fixture.store.confirmProtectedScan(options: .init())
        let members = fixture.fixtureEntries
        let groupID = try #require(fixture.store.duplicateGroups.first?.id)

        #expect(fixture.store.cleanupAcknowledgementRequired)
        #expect(!fixture.store.canPerformCleanupActions)
        fixture.store.setTrashMarked(true, id: members[1].id, in: groupID)
        #expect(fixture.store.duplicateGroups[0].trashIDs.isEmpty)

        fixture.store.confirmProtectedCleanupAcknowledgement()
        #expect(fixture.store.canPerformCleanupActions)
        fixture.store.setTrashMarked(true, id: members[1].id, in: groupID)
        #expect(fixture.store.duplicateGroups[0].trashIDs == [members[1].id])

        fixture.store.exit()
        #expect(!fixture.store.cleanupAcknowledgementRequired)
        #expect(!fixture.store.hasAcknowledgedProtectedCleanup)
    }

    @Test(
        arguments: [
            VerificationReplacementStage.partial,
            .full,
            .live
        ]
    )
    func rootReplacementDuringVerificationRejectsEventsAndNeverCompletes(
        stage: VerificationReplacementStage
    ) async throws {
        let fixture = try StorageStoreFixture.replacementDuringVerification(stage: stage)
        fixture.store.enter()
        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        #expect(await waitUntilStorage { fixture.store.phase == .verifying })

        fixture.scanner.replaceRootIdentity()
        fixture.duplicates.releaseConfiguredEvent()
        #expect(await waitUntilStorage { fixture.store.phase == .paused })
        fixture.duplicates.finishConfiguredStream()
        #expect(await waitForStorageTaskCompletion(scan))

        #expect(fixture.store.phase == .paused)
        #expect(fixture.store.duplicateGroups.isEmpty)
        #expect(fixture.store.verificationStates.values.allSatisfy { $0 != .complete })
    }

    @Test func progressiveProjectionsUseCurrentThresholdsAndSaturatingTotals() async throws {
        let fixture = try StorageStoreFixture.projectionBatch()
        fixture.store.enter()
        fixture.store.thresholds = StorageAnalysisThresholds(
            largeFileBytes: Int64.max,
            longUnmodifiedDays: 30
        )

        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        #expect(await fixture.scanner.waitForRequestCount(1))
        fixture.scanner.releaseFirstBatch()
        await waitUntil { fixture.store.entries.count == fixture.firstBatchCount }

        #expect(fixture.store.phase == .scanning)
        #expect(fixture.store.totalBytes == Int64.max)
        #expect(fixture.store.largeFiles.map(\.id) == [fixture.fixtureEntries[0].id])
        #expect(fixture.store.longUnmodifiedFiles.count == 2)
        #expect(fixture.store.entriesByCategory[.document]?.count == 1)
        #expect(fixture.store.entriesByCategory[.video]?.count == 1)
        #expect(fixture.store.overviewMetrics == StorageOverviewMetrics(
            fileCount: 2,
            directoryCount: 1,
            inaccessibleCount: 1,
            reclaimableBytes: 0
        ))
        #expect(fixture.store.fileTypeGroups.map(\.category) == [
            .document,
            .video,
            .other
        ])
        #expect(fixture.store.fileTypeGroups.map(\.entryCount) == [1, 1, 1])

        fixture.scanner.finish()
        await scan.value
    }

    @Test func cleanupMutationsPreserveOneCopyAndRemoveOnlySucceededItems() async throws {
        let fixture = try StorageStoreFixture.verifiedDuplicateGroup()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.root, options: .init())
        let members = fixture.fixtureEntries
        let groupID = fixture.store.duplicateGroups[0].id

        fixture.store.setTrashMarked(true, id: members[1].id, in: groupID)
        fixture.store.setTrashMarked(true, id: members[2].id, in: groupID)
        fixture.store.setTrashMarked(true, id: members[0].id, in: groupID)

        #expect(fixture.store.reclaimableBytes == 200)
        #expect(!fixture.store.duplicateGroups[0].trashIDs.contains(members[0].id))

        fixture.store.setKeep(members[1].id, in: groupID)
        #expect(fixture.store.duplicateGroups[0].keepID == members[1].id)
        #expect(!fixture.store.duplicateGroups[0].trashIDs.contains(members[1].id))
        #expect(fixture.store.reclaimableBytes == 100)

        fixture.store.applyCleanupResult(FileOperationResult(outcomes: [
            .succeeded(source: members[2].url, destination: nil),
            .failed(source: members[0].url, message: "Not trashed")
        ]))

        #expect(fixture.store.entries.map(\.id) == [members[0].id, members[1].id])
        #expect(fixture.store.duplicateGroups[0].members.map(\.id)
            == [members[0].id, members[1].id])
        #expect(fixture.store.totalBytes == 200)
        #expect(fixture.store.reclaimableBytes == 0)
    }

    @Test func cleanupMutationsAreNoOpsWhileDuplicateVerificationIsRunning() async throws {
        let fixture = try StorageStoreFixture.pendingDuplicateVerification()
        fixture.store.enter()
        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        await waitUntil {
            fixture.store.phase == .verifying
                && fixture.store.duplicateGroups.count == 1
        }
        let members = fixture.fixtureEntries
        let originalEntries = fixture.store.entries
        let originalGroups = fixture.store.duplicateGroups
        let groupID = originalGroups[0].id

        fixture.store.setKeep(members[1].id, in: groupID)
        fixture.store.setTrashMarked(false, id: members[2].id, in: groupID)
        fixture.store.applyCleanupResult(FileOperationResult(outcomes: [
            .succeeded(source: members[2].url, destination: nil)
        ]))

        #expect(fixture.store.entries == originalEntries)
        #expect(fixture.store.duplicateGroups == originalGroups)

        fixture.store.cancel()
        await scan.value
    }

    @Test func cleanupMutationsAreNoOpsAfterCancellation() async throws {
        let fixture = try StorageStoreFixture.pendingDuplicateVerification()
        fixture.store.enter()
        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        await waitUntil {
            fixture.store.phase == .verifying
                && fixture.store.duplicateGroups.count == 1
        }
        fixture.store.cancel()
        await scan.value
        let members = fixture.fixtureEntries
        let originalEntries = fixture.store.entries
        let originalGroups = fixture.store.duplicateGroups
        let groupID = originalGroups[0].id

        fixture.store.setKeep(members[1].id, in: groupID)
        fixture.store.setTrashMarked(false, id: members[2].id, in: groupID)
        fixture.store.applyCleanupResult(FileOperationResult(outcomes: [
            .succeeded(source: members[2].url, destination: nil)
        ]))

        #expect(fixture.store.phase == .cancelled)
        #expect(fixture.store.entries == originalEntries)
        #expect(fixture.store.duplicateGroups == originalGroups)
    }

    @Test func cleanupRemovesOnlySelectedTrashShapedSuccesses() async throws {
        let fixture = try StorageStoreFixture.verifiedDuplicateGroup()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.root, options: .init())
        let members = fixture.fixtureEntries
        let originalEntries = fixture.store.entries
        let originalGroups = fixture.store.duplicateGroups
        let groupID = originalGroups[0].id
        fixture.store.setTrashMarked(true, id: members[2].id, in: groupID)
        let selectedGroups = fixture.store.duplicateGroups

        fixture.store.applyCleanupResult(FileOperationResult(outcomes: [
            .succeeded(
                source: members[2].url,
                destination: URL(filePath: "/copied/copy-2.txt")
            ),
            .succeeded(source: members[1].url, destination: nil)
        ]))

        #expect(fixture.store.entries == originalEntries)
        #expect(fixture.store.duplicateGroups == selectedGroups)

        fixture.store.applyCleanupResult(FileOperationResult(outcomes: [
            .succeeded(source: members[2].url, destination: nil)
        ]))

        #expect(fixture.store.entries.map(\.id) == [members[0].id, members[1].id])
        #expect(fixture.store.duplicateGroups.first?.members.map(\.id)
            == [members[0].id, members[1].id])
    }

    @Test func successfulCleanupRecomputesGroupsAndReclaimableBytes() async throws {
        let fixture = try StorageStoreFixture.verifiedDuplicateGroup()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.root, options: .init())
        let members = fixture.fixtureEntries
        let groupID = fixture.store.duplicateGroups[0].id
        fixture.store.setTrashMarked(true, id: members[1].id, in: groupID)
        fixture.store.setTrashMarked(true, id: members[2].id, in: groupID)
        #expect(fixture.store.reclaimableBytes == 200)

        fixture.store.applyCleanupResult(FileOperationResult(outcomes: [
            .succeeded(source: members[1].url, destination: nil)
        ]))

        #expect(fixture.store.entries.map(\.id) == [members[0].id, members[2].id])
        #expect(fixture.store.duplicateGroups.count == 1)
        #expect(fixture.store.duplicateGroups[0].members.map(\.id)
            == [members[0].id, members[2].id])
        #expect(fixture.store.duplicateGroups[0].trashIDs == [members[2].id])
        #expect(fixture.store.totalBytes == 200)
        #expect(fixture.store.reclaimableBytes == 100)
    }

    @Test func scanAgainRevalidatesAFormerlyAllowedRoot() async throws {
        let root = URL(filePath: "/storage-store/policy-changed", directoryHint: .isDirectory)
        let stream = ControlledStorageBatchStream()
        stream.finish()
        let scanner = ControlledStorageScanner(
            identities: [root: FileIdentity(
                entryIdentifier: "policy",
                resolvedIdentifier: "policy"
            )],
            streams: [root: stream]
        )
        let duplicates = ControlledStorageDuplicateDetector()
        let policy = MutableStorageLocationPolicy(
            decision: .allowed(admission(
                root,
                identity: FileIdentity(
                    entryIdentifier: "policy",
                    resolvedIdentifier: "policy"
                )
            ))
        )
        let store = StorageAnalysisStore(
            scanner: scanner,
            duplicates: duplicates,
            locationPolicy: policy
        )
        store.enter()
        await store.requestScan(at: root, options: .init())
        #expect(scanner.requestCount == 1)
        policy.decision = .rejected(reason: "Now cloud-backed")

        await store.scanAgain()

        #expect(scanner.requestCount == 1)
        #expect(store.phase == .paused)
    }

    @Test func cleanupAdmissionRejectsRootReplacementAfterCompletedScan() async throws {
        let fixture = try StorageStoreFixture.verifiedDuplicateGroup()
        fixture.store.enter()
        await fixture.store.requestScan(at: fixture.root, options: .init())
        let admission = try #require(fixture.store.currentAdmission)
        fixture.scanner.replaceRootIdentity()

        let accepted = await fixture.store.revalidateCleanupAdmission(admission)
        #expect(!accepted)
        #expect(fixture.store.phase == .paused)
        #expect(fixture.store.duplicateGroups.isEmpty)
    }

    @Test func protectedConfirmationReclassifiesBeforeOpeningListing() async {
        let root = URL(
            filePath: "/storage-store/protected-reclassified",
            directoryHint: .isDirectory
        )
        let identity = FileIdentity(
            entryIdentifier: "protected-reclassified",
            resolvedIdentifier: "protected-reclassified"
        )
        let stream = ControlledStorageBatchStream()
        stream.finish()
        let scanner = ControlledStorageScanner(
            identities: [root: identity],
            streams: [root: stream]
        )
        let policy = MutableStorageLocationPolicy(decision: .protected(
            reason: "Protected",
            admission: admission(root, identity: identity, isProtected: true)
        ))
        let store = StorageAnalysisStore(
            scanner: scanner,
            duplicates: ControlledStorageDuplicateDetector(),
            locationPolicy: policy
        )
        store.enter()
        await store.requestScan(at: root, options: .init())
        policy.decision = .rejected(reason: "Now provider-backed")

        await store.confirmProtectedScan(options: .init())

        #expect(scanner.requestCount == 0)
        #expect(store.phase == .paused)
        #expect(store.entries.isEmpty)
    }
}

@MainActor
private struct StorageStoreFixture {
    let store: StorageAnalysisStore
    let scanner: ControlledStorageScanner
    let duplicates: ControlledStorageDuplicateDetector
    let root: URL
    let firstBatchCount: Int
    let fixtureEntries: [StorageEntry]
    let oldRoot: URL
    let newRoot: URL
    let protectedRoot: URL
    let cloudRoot: URL

    static func twoControlledBatches() throws -> Self {
        let root = URL(filePath: "/storage-store/two-batches", directoryHint: .isDirectory)
        let stream = ControlledStorageBatchStream()
        let scanner = ControlledStorageScanner(
            identities: [root: identity("two-batches")],
            streams: [root: stream]
        )
        let first = try entry(root: root, name: "first.txt", byteSize: 10)
        let second = try entry(root: root, name: "second.txt", byteSize: 20)
        scanner.firstBatch = StorageScanBatch(records: [.entry(first)])
        scanner.finalBatch = StorageScanBatch(records: [.entry(second)])
        return fixture(
            scanner: scanner,
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .allowed(admission(root, identity: identity("two-batches")))
            ]),
            root: root,
            firstBatchCount: 1,
            fixtureEntries: [first, second]
        )
    }

    static func overlappingScans() throws -> Self {
        let oldRoot = URL(filePath: "/storage-store/old", directoryHint: .isDirectory)
        let newRoot = URL(filePath: "/storage-store/new", directoryHint: .isDirectory)
        let oldStream = ControlledStorageBatchStream()
        let newStream = ControlledStorageBatchStream()
        newStream.yield(StorageScanBatch(records: [
            .entry(try entry(root: newRoot, name: "current.txt", byteSize: 30))
        ]))
        newStream.finish()
        let scanner = ControlledStorageScanner(
            identities: [
                oldRoot: identity("old"),
                newRoot: identity("new")
            ],
            streams: [
                oldRoot: oldStream,
                newRoot: newStream
            ],
            oldRoot: oldRoot,
            oldEntry: try entry(root: oldRoot, name: "stale.txt", byteSize: 40)
        )
        return fixture(
            scanner: scanner,
            policy: LiteralStorageLocationPolicy(decisions: [
                oldRoot: .allowed(admission(oldRoot, identity: identity("old"))),
                newRoot: .allowed(admission(newRoot, identity: identity("new")))
            ]),
            oldRoot: oldRoot,
            newRoot: newRoot
        )
    }

    static func locationDecisions() throws -> Self {
        let protectedRoot = URL(
            filePath: "/storage-store/protected",
            directoryHint: .isDirectory
        )
        let cloudRoot = URL(filePath: "/storage-store/cloud", directoryHint: .isDirectory)
        let stream = ControlledStorageBatchStream()
        stream.finish()
        let scanner = ControlledStorageScanner(
            identities: [protectedRoot: identity("protected")],
            streams: [protectedRoot: stream]
        )
        return fixture(
            scanner: scanner,
            policy: LiteralStorageLocationPolicy(decisions: [
                protectedRoot: .protected(
                    reason: "Protected",
                    admission: admission(
                        protectedRoot,
                        identity: identity("protected"),
                        isProtected: true
                    )
                ),
                cloudRoot: .rejected(reason: "Cloud")
            ]),
            protectedRoot: protectedRoot,
            cloudRoot: cloudRoot
        )
    }

    static func changedRootIdentity() throws -> Self {
        let root = URL(filePath: "/storage-store/replaced", directoryHint: .isDirectory)
        let stream = ControlledStorageBatchStream()
        let onlyEntry = try entry(root: root, name: "before-replacement.txt", byteSize: 10)
        stream.yield(StorageScanBatch(records: [.entry(onlyEntry)]))
        stream.finish()
        let scanner = ControlledStorageScanner(
            identities: [root: identity("captured")],
            streams: [root: stream],
            refreshedIdentities: [root: identity("replacement")],
            refreshAfterIdentityRequestCount: 3
        )
        return fixture(
            scanner: scanner,
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .allowed(admission(root, identity: identity("captured")))
            ]),
            root: root,
            fixtureEntries: [onlyEntry]
        )
    }

    static func identityChangeBetweenBatches() throws -> Self {
        let root = URL(
            filePath: "/storage-store/replaced-between-batches",
            directoryHint: .isDirectory
        )
        let stream = ControlledStorageBatchStream()
        let first = try entry(root: root, name: "original.txt", byteSize: 10)
        let replacement = try entry(root: root, name: "replacement.txt", byteSize: 20)
        let scanner = ControlledStorageScanner(
            identities: [root: identity("captured")],
            streams: [root: stream],
            refreshedIdentities: [root: identity("replacement")],
            refreshAutomatically: false
        )
        scanner.firstBatch = StorageScanBatch(records: [.entry(first)])
        scanner.finalBatch = StorageScanBatch(records: [.entry(replacement)])
        return fixture(
            scanner: scanner,
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .allowed(admission(root, identity: identity("captured")))
            ]),
            root: root,
            firstBatchCount: 1,
            fixtureEntries: [first, replacement]
        )
    }

    static func projectionBatch() throws -> Self {
        let root = URL(filePath: "/storage-store/projections", directoryHint: .isDirectory)
        let stream = ControlledStorageBatchStream()
        let first = try entry(
            root: root,
            name: "huge.bin",
            byteSize: Int64.max,
            category: .document
        )
        let second = try entry(
            root: root,
            name: "overflow.mov",
            byteSize: 1,
            category: .video
        )
        let directory = try entry(
            root: root,
            name: "Old Folder",
            byteSize: 0,
            category: .other,
            kind: .directory
        )
        let failurePath = try StorageRelativePath(components: ["Unreadable"])
        let scanner = ControlledStorageScanner(
            identities: [root: identity("projections")],
            streams: [root: stream]
        )
        scanner.firstBatch = StorageScanBatch(records: [
            .entry(first),
            .entry(second),
            .entry(directory),
            .failure(path: failurePath, message: "Unreadable")
        ])
        return fixture(
            scanner: scanner,
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .allowed(admission(root, identity: identity("projections")))
            ]),
            root: root,
            firstBatchCount: 3,
            fixtureEntries: [first, second, directory]
        )
    }

    static func verifiedDuplicateGroup() throws -> Self {
        let root = URL(filePath: "/storage-store/duplicates", directoryHint: .isDirectory)
        let protectedRoot = URL(
            filePath: "/storage-store/protected-after-complete",
            directoryHint: .isDirectory
        )
        let scanStream = ControlledStorageBatchStream()
        let members = try (0 ..< 3).map {
            try entry(root: root, name: "copy-\($0).txt", byteSize: 100)
        }
        scanStream.yield(StorageScanBatch(records: members.map(StorageScanRecord.entry)))
        scanStream.finish()
        var group = StorageDuplicateGroup(
            id: StorageDuplicateGroupID(byteSize: 100, completeDigest: Data([0x44])),
            members: members,
            keepID: members[0].id,
            trashIDs: [],
            reclaimableBytes: 0
        )
        group.recalculateReclaimableBytes()
        let duplicateStream = ControlledStorageDuplicateStream()
        duplicateStream.yield(.group(group))
        duplicateStream.finish()
        let duplicates = ControlledStorageDuplicateDetector(streams: [root: duplicateStream])
        let scanner = ControlledStorageScanner(
            identities: [root: identity("duplicates")],
            streams: [root: scanStream],
            refreshedIdentities: [root: identity("replacement")],
            refreshAutomatically: false
        )
        return fixture(
            scanner: scanner,
            duplicates: duplicates,
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .allowed(admission(root, identity: identity("duplicates"))),
                protectedRoot: .protected(
                    reason: "Protected",
                    admission: admission(
                        protectedRoot,
                        identity: identity("unused-protected"),
                        isProtected: true
                    )
                )
            ]),
            root: root,
            fixtureEntries: members,
            protectedRoot: protectedRoot
        )
    }

    static func protectedVerifiedDuplicateGroup() throws -> Self {
        let root = URL(
            filePath: "/storage-store/protected-duplicates",
            directoryHint: .isDirectory
        )
        let scanStream = ControlledStorageBatchStream()
        let members = try (0 ..< 2).map {
            try entry(root: root, name: "protected-copy-\($0).txt", byteSize: 100)
        }
        scanStream.yield(StorageScanBatch(records: members.map(StorageScanRecord.entry)))
        scanStream.finish()
        let group = StorageDuplicateGroup(
            id: StorageDuplicateGroupID(byteSize: 100, completeDigest: Data([0x66])),
            members: members,
            keepID: members[0].id,
            trashIDs: [],
            reclaimableBytes: 0
        )
        let duplicateStream = ControlledStorageDuplicateStream()
        duplicateStream.yield(.group(group))
        duplicateStream.finish()
        return fixture(
            scanner: ControlledStorageScanner(
                identities: [root: identity("protected-duplicates")],
                streams: [root: scanStream]
            ),
            duplicates: ControlledStorageDuplicateDetector(streams: [root: duplicateStream]),
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .protected(
                    reason: "Protected",
                    admission: admission(
                        root,
                        identity: identity("protected-duplicates"),
                        isProtected: true
                    )
                )
            ]),
            root: root,
            fixtureEntries: members,
            protectedRoot: root
        )
    }

    static func replacementDuringVerification(
        stage: VerificationReplacementStage
    ) throws -> Self {
        let root = URL(
            filePath: "/storage-store/replaced-during-\(stage.rawValue)",
            directoryHint: .isDirectory
        )
        let scanStream = ControlledStorageBatchStream()
        let members = try (0 ..< 2).map {
            try entry(root: root, name: "\(stage.rawValue)-copy-\($0).txt", byteSize: 100)
        }
        scanStream.yield(StorageScanBatch(records: members.map(StorageScanRecord.entry)))
        scanStream.finish()
        let duplicateStream = ControlledStorageDuplicateStream()
        let event: StorageDuplicateDetectionEvent = switch stage {
        case .partial:
            .state(members[0].id, .partial(nil))
        case .full:
            .state(members[0].id, .partial(1))
        case .live:
            .state(members[0].id, .complete)
        }
        let duplicates = ControlledStorageDuplicateDetector(
            streams: [root: duplicateStream],
            configuredEvent: event
        )
        return fixture(
            scanner: ControlledStorageScanner(
                identities: [root: identity("captured")],
                streams: [root: scanStream],
                refreshedIdentities: [root: identity("replacement")],
                refreshAutomatically: false
            ),
            duplicates: duplicates,
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .allowed(admission(root, identity: identity("captured")))
            ]),
            root: root,
            fixtureEntries: members
        )
    }

    static func pendingDuplicateVerification() throws -> Self {
        let root = URL(
            filePath: "/storage-store/pending-duplicates",
            directoryHint: .isDirectory
        )
        let scanStream = ControlledStorageBatchStream()
        let members = try (0 ..< 3).map {
            try entry(root: root, name: "pending-copy-\($0).txt", byteSize: 100)
        }
        scanStream.yield(StorageScanBatch(records: members.map(StorageScanRecord.entry)))
        scanStream.finish()
        var group = StorageDuplicateGroup(
            id: StorageDuplicateGroupID(byteSize: 100, completeDigest: Data([0x55])),
            members: members,
            keepID: members[0].id,
            trashIDs: [members[2].id],
            reclaimableBytes: 0
        )
        group.recalculateReclaimableBytes()
        let duplicateStream = ControlledStorageDuplicateStream()
        duplicateStream.yield(.group(group))
        let duplicates = ControlledStorageDuplicateDetector(streams: [root: duplicateStream])
        let scanner = ControlledStorageScanner(
            identities: [root: identity("pending-duplicates")],
            streams: [root: scanStream]
        )
        return fixture(
            scanner: scanner,
            duplicates: duplicates,
            policy: LiteralStorageLocationPolicy(decisions: [
                root: .allowed(admission(root, identity: identity("pending-duplicates")))
            ]),
            root: root,
            fixtureEntries: members
        )
    }

    private static func fixture(
        scanner: ControlledStorageScanner,
        duplicates: ControlledStorageDuplicateDetector =
            ControlledStorageDuplicateDetector(),
        policy: LiteralStorageLocationPolicy,
        root: URL = URL(filePath: "/storage-store/unused"),
        firstBatchCount: Int = 0,
        fixtureEntries: [StorageEntry] = [],
        oldRoot: URL = URL(filePath: "/storage-store/unused-old"),
        newRoot: URL = URL(filePath: "/storage-store/unused-new"),
        protectedRoot: URL = URL(filePath: "/storage-store/unused-protected"),
        cloudRoot: URL = URL(filePath: "/storage-store/unused-cloud")
    ) -> Self {
        Self(
            store: StorageAnalysisStore(
                scanner: scanner,
                duplicates: duplicates,
                locationPolicy: policy
            ),
            scanner: scanner,
            duplicates: duplicates,
            root: root,
            firstBatchCount: firstBatchCount,
            fixtureEntries: fixtureEntries,
            oldRoot: oldRoot,
            newRoot: newRoot,
            protectedRoot: protectedRoot,
            cloudRoot: cloudRoot
        )
    }

    private static func identity(_ value: String) -> FileIdentity {
        FileIdentity(entryIdentifier: value, resolvedIdentifier: value)
    }

    private static func entry(
        root: URL,
        name: String,
        byteSize: Int64,
        category: StorageFileCategory = .document,
        kind: StorageEntryKind = .regularFile
    ) throws -> StorageEntry {
        let path = try StorageRelativePath(components: [name])
        return StorageEntry(
            relativePath: path,
            url: root.appending(path: name),
            kind: kind,
            category: category,
            fingerprint: ComparisonFingerprint(
                identity: identity(name),
                byteSize: byteSize,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            typeDescription: "Document"
        )
    }
}

private final class ControlledStorageScanner: StorageScanning, @unchecked Sendable {
    private struct State {
        var identityRequestCount = 0
        var requests: [StorageScanRequest] = []
    }

    private let state = LockedStorageState(State())
    private let identities: [URL: FileIdentity]
    private let refreshedIdentities: [URL: FileIdentity]
    private let streams: [URL: ControlledStorageBatchStream]
    private let oldRoot: URL?
    private let oldEntry: StorageEntry?
    private let refreshAutomatically: Bool
    private let refreshAfterIdentityRequestCount: Int
    var firstBatch: StorageScanBatch?
    var finalBatch: StorageScanBatch?
    private let useRefreshedIdentity = LockedStorageState(false)

    init(
        identities: [URL: FileIdentity],
        streams: [URL: ControlledStorageBatchStream],
        refreshedIdentities: [URL: FileIdentity] = [:],
        oldRoot: URL? = nil,
        oldEntry: StorageEntry? = nil,
        refreshAutomatically: Bool = true,
        refreshAfterIdentityRequestCount: Int = 2
    ) {
        self.identities = identities
        self.refreshedIdentities = refreshedIdentities
        self.streams = streams
        self.oldRoot = oldRoot
        self.oldEntry = oldEntry
        self.refreshAutomatically = refreshAutomatically
        self.refreshAfterIdentityRequestCount = refreshAfterIdentityRequestCount
    }

    var requestCount: Int {
        state.withValue { $0.requests.count }
    }

    var identityRequestCount: Int {
        state.withValue { $0.identityRequestCount }
    }

    var requests: [StorageScanRequest] {
        state.withValue { $0.requests }
    }

    func identity(of root: URL) async throws -> FileIdentity {
        let requestNumber = state.withValue { state in
            state.identityRequestCount += 1
            return state.identityRequestCount
        }
        if (refreshAutomatically && requestNumber >= refreshAfterIdentityRequestCount
                || useRefreshedIdentity.withValue({ $0 })),
           let refreshedIdentity = refreshedIdentities[root] {
            return refreshedIdentity
        }
        guard let identity = identities[root] else {
            throw ControlledStorageError.missingIdentity
        }
        return identity
    }

    func batches(
        for request: StorageScanRequest
    ) -> AsyncThrowingStream<StorageScanBatch, Error> {
        state.withValue { $0.requests.append(request) }
        return streams[request.root]?.stream ?? AsyncThrowingStream { $0.finish() }
    }

    func waitForRequestCount(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if requestCount >= expected { return true }
            await Task.yield()
        }
        return requestCount >= expected
    }

    func releaseFirstBatch() {
        guard let firstBatch else { return }
        streams.values.first?.yield(firstBatch)
    }

    func finish() {
        guard let stream = streams.values.first else { return }
        if let finalBatch {
            stream.yield(finalBatch)
        }
        stream.finish()
    }

    func replaceRootIdentity() {
        useRefreshedIdentity.withValue { $0 = true }
    }

    func releaseOldResult() {
        guard let oldRoot, let oldEntry, let stream = streams[oldRoot] else { return }
        stream.yield(StorageScanBatch(records: [.entry(oldEntry)]))
        stream.finish()
    }
}

private final class ControlledStorageBatchStream: @unchecked Sendable {
    let stream: AsyncThrowingStream<StorageScanBatch, Error>
    private let continuation: AsyncThrowingStream<StorageScanBatch, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<StorageScanBatch, Error>.Continuation?
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured!
    }

    func yield(_ batch: StorageScanBatch) {
        continuation.yield(batch)
    }

    func finish() {
        continuation.finish()
    }
}

private final class ControlledStorageDuplicateDetector:
    StorageDuplicateDetecting,
    @unchecked Sendable
{
    private let streams: [URL: ControlledStorageDuplicateStream]
    private let requests = LockedStorageState(0)
    private let configuredStream: ControlledStorageDuplicateStream?
    private let configuredEvent: StorageDuplicateDetectionEvent?

    init(
        streams: [URL: ControlledStorageDuplicateStream] = [:],
        configuredEvent: StorageDuplicateDetectionEvent? = nil
    ) {
        self.streams = streams
        configuredStream = streams.values.first
        self.configuredEvent = configuredEvent
    }

    var requestCount: Int {
        requests.withValue { $0 }
    }

    func events(
        for entries: [StorageEntry]
    ) -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error> {
        requests.withValue { $0 += 1 }
        if let root = streams.keys.first(where: { root in
            entries.first?.url.path.hasPrefix(root.path) == true
        }), let stream = streams[root] {
            return stream.stream
        }
        return AsyncThrowingStream { $0.finish() }
    }

    func releaseConfiguredEvent() {
        guard let configuredEvent else { return }
        configuredStream?.yield(configuredEvent)
    }

    func finishConfiguredStream() {
        configuredStream?.finish()
    }
}

private final class ControlledStorageDuplicateStream: @unchecked Sendable {
    let stream: AsyncThrowingStream<StorageDuplicateDetectionEvent, Error>
    private let continuation:
        AsyncThrowingStream<StorageDuplicateDetectionEvent, Error>.Continuation

    init() {
        var captured:
            AsyncThrowingStream<StorageDuplicateDetectionEvent, Error>.Continuation?
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured!
    }

    func yield(_ event: StorageDuplicateDetectionEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

}

@MainActor
private struct LiteralStorageLocationPolicy: StorageScanLocationValidating {
    let decisions: [URL: StorageScanLocationDecision]

    func decision(for url: URL) -> StorageScanLocationDecision {
        decisions[url] ?? .rejected(reason: "Unexpected root")
    }
}

@MainActor
private final class MutableStorageLocationPolicy: StorageScanLocationValidating {
    var decision: StorageScanLocationDecision

    init(decision: StorageScanLocationDecision) {
        self.decision = decision
    }

    func decision(for url: URL) -> StorageScanLocationDecision {
        decision
    }
}

private final class LockedStorageState<Value>: @unchecked Sendable {
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

private enum ControlledStorageError: Error {
    case missingIdentity
}

private func admission(
    _ root: URL,
    identity: FileIdentity,
    isProtected: Bool = false
) -> StorageScanAdmissionToken {
    StorageScanAdmissionToken(
        root: root.standardizedFileURL,
        rootIdentity: identity,
        rootKind: .directory,
        volumeClassification: .local,
        authorization: .init(
            isProtectedLocation: isProtected,
            protectedScanAuthorized: !isProtected,
            cleanupAuthorized: !isProtected
        )
    )
}

enum VerificationReplacementStage: String, CaseIterable, Sendable {
    case partial
    case full
    case live
}

@MainActor
private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
) async {
    _ = await waitUntilStorage(predicate)
}

@MainActor
private func waitUntilStorage(
    timeout: Duration = .seconds(10),
    _ predicate: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

@MainActor
private func waitForStorageTaskCompletion(
    _ task: Task<Void, Never>,
    timeout: Duration = .seconds(10)
) async -> Bool {
    let completed = LockedStorageState(false)
    Task {
        await task.value
        completed.withValue { $0 = true }
    }
    return await waitUntilStorage(timeout: timeout) {
        completed.withValue { $0 }
    }
}
