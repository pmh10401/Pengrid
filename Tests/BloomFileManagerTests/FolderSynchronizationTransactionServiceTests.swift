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

    @Test func disabledCompatibilityPathCreatesNoVerificationSessionReportOrLog() async throws {
        let fixture = try await TransactionCopyFixture()
        let factory = RecordingTransferVerificationSessionFactory {
            await fixture.fileSystem.events
        }
        let logger = TransactionVerificationLogger()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory,
            logger: logger
        )

        let result = await service.execute(fixture.plan)

        #expect(result.verificationReport == nil)
        #expect(factory.policies.isEmpty)
        #expect(await logger.verificationEvents.isEmpty)
    }

    @Test func enabledPolicyFailsClosedWhenVerificationSessionCannotBeCreated() async throws {
        let fixture = try await TransactionCopyFixture()
        let logger = TransactionVerificationLogger()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: NilSynchronizationVerificationFactory(),
            logger: logger
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )

        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1
        ))
        #expect(await logger.verificationEvents == [TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1,
            failureCategory: .identityUnavailable
        )])
        #expect((await fixture.fileSystem.events).contains {
            $0.hasPrefix("createDirectory:") || $0.hasPrefix("copy:")
        } == false)
        #expect(await !fixture.fileSystem.exists(fixture.destination))
    }

    @Test func fileOperationServiceMakerSharesFactoryAndLoggerButCreatesASessionPerExecution() async throws {
        let fixture = try await TransactionCopyFixture()
        let factory = FreshSynchronizationVerificationFactory {
            await fixture.fileSystem.events
        }
        let logger = TransactionVerificationLogger()
        let operationService = FileOperationService(
            fileSystem: fixture.fileSystem,
            logger: logger,
            verificationSessionFactory: factory
        )
        let service = operationService.makeFolderSynchronizationTransactionService()

        let first = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )
        let second = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )

        #expect(first.verificationReport?.verifiedFileCount == 1)
        #expect(second.verificationReport == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(factory.sessionIDs.count == 2)
        #expect(Set(factory.sessionIDs).count == 2)
        #expect(await logger.verificationEvents.count == 2)
    }

    @Test func enabledVerificationCapturesBeforeReservationAndRevalidatesImmediatelyBeforePublish() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fixture.fileSystem.events },
            configuration: .init(summariesByVerifyCall: [
                1: .init(
                    verifiedFileCount: 3,
                    verifiedLogicalByteCount: 128,
                    noByteTransferItemCount: 0
                )
            ])
        )
        let logger = TransactionVerificationLogger()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory,
            logger: logger
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )

        #expect(factory.policies == [.sha256(maxConcurrentPairs: 2)])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 3,
            verifiedLogicalByteCount: 128,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        let verificationEvents = await factory.recorder.events
        guard case let .capture(_, _, policy, captureFileSystemEvents) = verificationEvents.first else {
            Issue.record("missing source capture")
            return
        }
        #expect(policy == fixture.plan.destinationFilenameComparisonPolicy)
        #expect(captureFileSystemEvents.contains { $0.hasPrefix("createDirectory:") } == false)
        guard let verifyEvent = verificationEvents.first(where: {
            if case .verify = $0 { return true }
            return false
        }), case let .verify(_, _, verifyFileSystemEvents) = verifyEvent else {
            Issue.record("missing staging verification")
            return
        }
        #expect(verifyFileSystemEvents.contains { $0.hasPrefix("copy:") })
        #expect(verifyFileSystemEvents.contains { $0.hasPrefix("moveChecked:") } == false)
        guard let revalidateEvent = verificationEvents.first(where: {
            if case .revalidate = $0 { return true }
            return false
        }), case let .revalidate(revalidateFileSystemEvents) = revalidateEvent else {
            Issue.record("missing receipt revalidation")
            return
        }
        #expect(revalidateFileSystemEvents.contains { $0.hasPrefix("moveExclusiveChecked:") } == false)
        let finalEvents = await fixture.fileSystem.events
        #expect(finalEvents.dropFirst(revalidateFileSystemEvents.count).first?.hasPrefix(
            "moveExclusiveChecked:"
        ) == true)
        #expect(await logger.verificationEvents == [TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: 3,
            verifiedLogicalByteCount: 128,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0,
            failureCategory: nil
        )])
    }

    @Test func verificationMismatchFailsBeforeQuarantineAndPreservesBothUserItems() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fixture.fileSystem.events },
            configuration: .init(verifyFailuresByCall: [1: .contentMismatch])
        )
        let logger = TransactionVerificationLogger()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory,
            logger: logger
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )

        #expect(await fixture.fileSystem.exists(fixture.source))
        #expect(try await fixture.fileSystem.identity(of: fixture.destination) == fixture.destinationIdentity)
        let events = await fixture.fileSystem.events
        #expect(events.contains { $0.hasPrefix("moveChecked:") } == false)
        #expect(events.contains { $0.hasPrefix("moveExclusiveChecked:") } == false)
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1
        ))
        #expect(await logger.verificationEvents.count == 1)
        #expect(await logger.verificationEvents.first?.failureCategory == .contentMismatch)
    }

    @Test func secondReceiptFailureRollsBackTheFirstPublication() async throws {
        let fixture = try await TransactionMultiCopyFixture(count: 2)
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fixture.fileSystem.events },
            configuration: .init(revalidateFailuresByCall: [2: .stagedOutputChanged])
        )
        let logger = TransactionVerificationLogger()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory,
            logger: logger
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )

        for source in fixture.sources {
            #expect(await fixture.fileSystem.exists(source))
        }
        for destination in fixture.destinations {
            #expect(await !fixture.fileSystem.exists(destination))
        }
        #expect((await fixture.fileSystem.events).filter {
            $0.hasPrefix("moveExclusiveChecked:")
        }.count == 1)
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 2,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1
        ))
        #expect(await logger.verificationEvents.first?.failureCategory == .stagedOutputChanged)
    }

    @Test func verificationCleanupFailureBecomesRecoveryNeeded() async throws {
        let fixture = try await TransactionCopyFixture(
            stagingCleanupError: CocoaError(.fileWriteUnknown)
        )
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fixture.fileSystem.events },
            configuration: .init(verifyFailuresByCall: [1: .readFailed])
        )
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )

        #expect(result.outcomes == [.recoveryNeeded(source: fixture.source)])
        #expect(await fixture.fileSystem.exists(fixture.source))
        #expect(await !fixture.fileSystem.exists(fixture.destination))
    }

    @Test func cancellationDuringVerificationCleansStagingWithoutQuarantineOrUserMutation() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let factory = RecordingTransferVerificationSessionFactory(
            eventSource: { await fixture.fileSystem.events },
            configuration: .init(cancellingVerifyCalls: [1])
        )
        let logger = TransactionVerificationLogger()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory,
            logger: logger
        )

        let result = await Task.detached {
            await service.execute(
                fixture.plan,
                verificationPolicy: .sha256(maxConcurrentPairs: 2),
                progress: { _ in },
                verificationProgress: { _ in }
            )
        }.value

        #expect(result.outcomes == [.cancelled(source: fixture.source)])
        #expect(await fixture.fileSystem.exists(fixture.source))
        #expect(try await fixture.fileSystem.identity(of: fixture.destination) == fixture.destinationIdentity)
        let events = await fixture.fileSystem.events
        #expect(events.contains { $0.hasPrefix("moveChecked:") } == false)
        #expect(events.contains { $0.hasPrefix("moveExclusiveChecked:") } == false)
        #expect(events.contains { $0.hasPrefix("removeStaging:") })
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect(await logger.verificationEvents.first?.failureCategory == .cancelled)
    }

    #if DEBUG
    @Test func originalManifestDescriptorsCloseAfterReceiptInstallAndBeforeQuarantine() async throws {
        let fixture = try await TransactionReplacementFixture(kind: .replace)
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let realSource = temporary.url.appending(path: "source.bin")
        let realStaged = temporary.url.appending(path: "staged.bin")
        let contents = Data("verified folder synchronization".utf8)
        try contents.write(to: realSource)
        try contents.write(to: realStaged)
        let liveFileSystem = LiveFileSystemAccess()
        let sourceIdentity = try #require(try await liveFileSystem.identity(of: realSource))
        let stagedIdentity = try #require(try await liveFileSystem.identity(of: realStaged))
        let ledger = SynchronizationDescriptorLedger()
        let factory = ManifestOwnershipVerificationFactory(
            sourceURL: realSource,
            sourceIdentity: sourceIdentity,
            stagedURL: realStaged,
            stagedIdentity: stagedIdentity,
            logicalByteCount: Int64(contents.count),
            ledger: ledger
        )
        let quarantineSnapshot = DescriptorCountSnapshot()
        let backingStorageSnapshot = BooleanSnapshot()
        let byteProgress = SynchronizationVerificationProgressRecorder()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 1),
            progress: { value in
                if value.phase == .quarantining {
                    await quarantineSnapshot.record(ledger.openCount)
                    await backingStorageSnapshot.record(
                        factory.session.sourceManifestBackingStorageIsReleased
                    )
                }
            },
            verificationProgress: { value in
                await byteProgress.append(value)
            }
        )

        let receiptLeaseCount = factory.session.receiptLeaseCount
        #expect(receiptLeaseCount > 0)
        #expect(await quarantineSnapshot.value == receiptLeaseCount)
        #expect(await backingStorageSnapshot.value == true)
        #expect(factory.session.sourceManifestBackingStorageIsReleased)
        #expect(ledger.openCount == 0)
        #expect(await byteProgress.values.last?.completedLogicalByteCount == Int64(contents.count))
        #expect(await byteProgress.values.last?.totalLogicalByteCount == Int64(contents.count))
        #expect(await byteProgress.values.last?.fractionCompleted == 1)
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 1,
            verifiedLogicalByteCount: Int64(contents.count),
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
    }
    #endif

    @Test func enabledLargeBatchUsesTwoRootWorkersAndCompletesAllVerificationBeforeQuarantine() async throws {
        let fixture = try await TransactionMultiCopyFixture(count: 20, includeTrash: true)
        let factory = ConcurrentSynchronizationVerificationFactory()
        let audit = SynchronizationVerificationProgressAudit()
        let verificationProgress = SynchronizationVerificationProgressRecorder()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { value in
                let completedVerifications = await factory.session.completedVerificationCount
                await audit.record(
                    value,
                    completedVerificationCount: completedVerifications
                )
            },
            verificationProgress: { value in
                await verificationProgress.append(value)
            }
        )

        #expect(result.outcomes.count == 21)
        #expect(result.outcomes.allSatisfy {
            if case .succeeded = $0 { return true }
            return false
        })
        #expect(factory.policies == [.sha256(maxConcurrentPairs: 2)])
        #expect(await factory.session.startedVerificationCount == 20)
        #expect(await factory.session.maximumActiveVerificationCount == 2)
        #expect(await factory.session.revalidationCount == 20)
        #expect(await audit.completedBeforeFirstQuarantine == 20)
        #expect(await audit.verifyingProgressViolations.isEmpty)
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 20,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        let verificationValues = await verificationProgress.values
        #expect(verificationValues.contains { $0.phase == .hashing })
        #expect(verificationValues.last?.phase == .finalValidation)
        #expect(verificationValues.last?.fractionCompleted == 1)
        #expect(verificationValues.last?.completedFileCount == 20)
        #expect(verificationValues.last?.totalFileCount == 20)
        for phase in [
            TransferVerificationPhase.preparingManifest,
            .hashing,
            .finalValidation
        ] {
            let fractions = verificationValues
                .filter { $0.phase == phase }
                .map(\.fractionCompleted)
            #expect(zip(fractions, fractions.dropFirst()).allSatisfy(<=))
        }
    }

    @Test func concurrentMismatchRemainsTheTerminalCategoryWhenSiblingIsCancelled() async throws {
        let fixture = try await TransactionMultiCopyFixture(count: 2, includeTrash: true)
        let factory = ConcurrentSynchronizationVerificationFactory(
            failureOnVerificationCall: 1
        )
        let logger = TransactionVerificationLogger()
        let service = FolderSynchronizationTransactionService(
            fileSystem: fixture.fileSystem,
            scopedAccess: TransactionTestScopedAccess(),
            availabilityReader: TransactionTestAvailability(),
            verificationSessionFactory: factory,
            logger: logger
        )

        let result = await service.execute(
            fixture.plan,
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: { _ in }
        )

        #expect(await logger.verificationEvents.first?.failureCategory == .contentMismatch)
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect((await fixture.fileSystem.events).contains {
            $0.hasPrefix("moveChecked:")
        } == false)
        for source in fixture.sources {
            #expect(await fixture.fileSystem.exists(source))
        }
        for destination in fixture.destinations {
            #expect(await !fixture.fileSystem.exists(destination))
        }
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
        failPublicationCleanupAfterSideEffect: Bool = false,
        stagingCleanupError: CocoaError? = nil
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
            stagingCleanupError: stagingCleanupError,
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

private struct TransactionMultiCopyFixture {
    let sources: [URL]
    let destinations: [URL]
    let preexistingTrashDestination: URL?
    let fileSystem: RecordingFileSystem
    let plan: PreparedFolderSynchronizationPlan

    init(count: Int, includeTrash: Bool = false) async throws {
        let sourceRoot = URL(filePath: "/transaction/source", directoryHint: .isDirectory)
        let destinationRoot = URL(filePath: "/transaction/destination", directoryHint: .isDirectory)
        let sourceRootIdentity = FileIdentity(
            entryIdentifier: "source-root",
            resolvedIdentifier: "source-root"
        )
        let destinationRootIdentity = FileIdentity(
            entryIdentifier: "destination-root",
            resolvedIdentifier: "destination-root"
        )
        sources = (0..<count).map { sourceRoot.appending(path: "item-\($0).txt") }
        destinations = (0..<count).map { destinationRoot.appending(path: "item-\($0).txt") }
        preexistingTrashDestination = includeTrash
            ? destinationRoot.appending(path: "obsolete.txt")
            : nil
        var existingURLs: Set<URL> = [sourceRoot, destinationRoot]
        existingURLs.formUnion(sources)
        var identities: [URL: FileIdentity] = [
            sourceRoot: sourceRootIdentity,
            destinationRoot: destinationRootIdentity
        ]
        for (index, source) in sources.enumerated() {
            identities[source] = FileIdentity(
                entryIdentifier: "source-\(index)",
                resolvedIdentifier: "source-\(index)"
            )
        }
        if let preexistingTrashDestination {
            existingURLs.insert(preexistingTrashDestination)
            identities[preexistingTrashDestination] = FileIdentity(
                entryIdentifier: "obsolete",
                resolvedIdentifier: "obsolete"
            )
        }
        fileSystem = RecordingFileSystem(
            existingURLs: existingURLs,
            availableCapacities: [destinationRoot: 1],
            identities: identities
        )

        var actions: [FolderSynchronizationAction] = []
        var sourceFingerprints: [ComparisonRelativePath: SourceFingerprint] = [:]
        var destinationFingerprints: [ComparisonRelativePath: SourceFingerprint] = [:]
        var expectedAbsent: Set<ComparisonRelativePath> = []
        var parentIdentities: [ComparisonRelativePath: FileIdentity] = [:]
        for (index, source) in sources.enumerated() {
            let path = try ComparisonRelativePath(components: ["item-\(index).txt"])
            let identity = try #require(identities[source])
            let entry = ComparisonEntry(
                relativePath: path,
                url: source,
                kind: .regularFile,
                fingerprint: .init(identity: identity, byteSize: nil, modifiedAt: nil),
                symbolicLinkTarget: nil,
                typeDescription: "regularFile"
            )
            actions.append(try .init(
                relativePath: path,
                kind: .copy,
                source: entry,
                destination: nil
            ))
            sourceFingerprints[path] = try await fileSystem.fingerprint(of: source)
            expectedAbsent.insert(path)
            parentIdentities[path] = destinationRootIdentity
        }
        if let preexistingTrashDestination {
            let path = try ComparisonRelativePath(components: ["obsolete.txt"])
            let identity = try #require(identities[preexistingTrashDestination])
            let entry = ComparisonEntry(
                relativePath: path,
                url: preexistingTrashDestination,
                kind: .regularFile,
                fingerprint: .init(identity: identity, byteSize: nil, modifiedAt: nil),
                symbolicLinkTarget: nil,
                typeDescription: "regularFile"
            )
            actions.append(try .init(
                relativePath: path,
                kind: .moveDestinationToTrash,
                source: nil,
                destination: entry
            ))
            destinationFingerprints[path] = try await fileSystem.fingerprint(
                of: preexistingTrashDestination
            )
            parentIdentities[path] = destinationRootIdentity
        }
        let draft = try FolderSynchronizationPlanDraft(
            direction: .leftToRight,
            comparisonGeneration: UUID(),
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity,
            actions: actions,
            skipCount: 0,
            estimatedRegularFileCopyBytes: 0
        )
        plan = .init(
            draft: draft,
            sourceFingerprints: sourceFingerprints,
            destinationFingerprints: destinationFingerprints,
            expectedAbsentDestinations: expectedAbsent,
            requiredCapacityBytes: 0,
            destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
            rootAuthority: .init(
                source: .init(
                    identity: sourceRootIdentity,
                    canonicalURL: sourceRoot,
                    volumeIdentifier: "transaction",
                    mountIdentifier: "transaction"
                ),
                destination: .init(
                    identity: destinationRootIdentity,
                    canonicalURL: destinationRoot,
                    volumeIdentifier: "transaction",
                    mountIdentifier: "transaction"
                )
            ),
            destinationParentIdentities: parentIdentities
        )
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

private actor TransactionVerificationLogger: OperationLogging {
    private(set) var verificationEvents: [TransferVerificationLogEvent] = []

    func record(
        kind: FileOperationKind,
        duration: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int
    ) async {}

    func recordTransferVerification(
        _ event: TransferVerificationLogEvent
    ) async {
        verificationEvents.append(event)
    }
}

private final class FreshSynchronizationVerificationFactory:
    TransferVerificationSessionFactory,
    @unchecked Sendable
{
    private let eventSource: @Sendable () async -> [String]
    private let lock = NSLock()
    private var storedSessionIDs: [UUID] = []

    init(eventSource: @escaping @Sendable () async -> [String]) {
        self.eventSource = eventSource
    }

    var sessionIDs: [UUID] {
        lock.withLock { storedSessionIDs }
    }

    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)? {
        lock.withLock { storedSessionIDs.append(UUID()) }
        return RecordingTransferVerificationSession(
            eventSource: eventSource,
            recorder: RecordingTransferVerificationEventRecorder(),
            configuration: .init()
        )
    }
}

private struct NilSynchronizationVerificationFactory:
    TransferVerificationSessionFactory,
    Sendable
{
    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)? {
        nil
    }
}

private final class ConcurrentSynchronizationVerificationFactory:
    TransferVerificationSessionFactory,
    @unchecked Sendable
{
    let session: ConcurrentSynchronizationVerificationSession

    private let lock = NSLock()
    private var recordedPolicies: [TransferVerificationPolicy] = []

    init(failureOnVerificationCall: Int? = nil) {
        session = ConcurrentSynchronizationVerificationSession(
            failureOnVerificationCall: failureOnVerificationCall
        )
    }

    var policies: [TransferVerificationPolicy] {
        lock.withLock { recordedPolicies }
    }

    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)? {
        lock.withLock { recordedPolicies.append(policy) }
        return session
    }
}

private final class ConcurrentSynchronizationVerificationSession:
    TransferVerificationSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let probe = ConcurrentSynchronizationVerificationProbe()
    private let failureOnVerificationCall: Int?
    private var stagedBySourceAuthority:
        [TransferVerificationRootAuthorityToken: TransferVerificationManifest] = [:]
    private var ownedManifests: [TransferVerificationManifest] = []

    init(failureOnVerificationCall: Int?) {
        self.failureOnVerificationCall = failureOnVerificationCall
    }

    var startedVerificationCount: Int {
        get async { await probe.startedCount }
    }

    var completedVerificationCount: Int {
        get async { await probe.completedCount }
    }

    var maximumActiveVerificationCount: Int {
        get async { await probe.maximumActiveCount }
    }

    var revalidationCount: Int {
        get async { await probe.revalidatedCount }
    }

    func captureSource(
        at url: URL,
        identifiedBy identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        #if DEBUG
        let pair = try TransferVerificationManifest.makeSyntheticPairForTesting(
            descendantCount: 1,
            regularFileDepth: 1
        )
        #else
        throw TransferVerificationFailure(category: .unsupportedItem)
        #endif
        lock.withLock {
            stagedBySourceAuthority[pair.source.authorityToken] = pair.staged
            ownedManifests.append(pair.source)
            ownedManifests.append(pair.staged)
        }
        return pair.source
    }

    func verify(
        source: TransferVerificationManifest,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        progress: @escaping @Sendable (TransferVerificationProgress) async -> Void
    ) async throws -> TransferVerificationCompletion {
        let staged = try lock.withLock {
            guard let staged = stagedBySourceAuthority[source.authorityToken] else {
                throw TransferVerificationFailure(category: .stagedOutputChanged)
            }
            return staged
        }
        let call = await probe.begin()
        if call == failureOnVerificationCall {
            await probe.finish()
            throw TransferVerificationFailure(category: .contentMismatch)
        }
        await progress(.init(
            phase: .preparingManifest,
            fractionCompleted: 1,
            completedFileCount: 0,
            totalFileCount: 1,
            completedLogicalByteCount: 0,
            totalLogicalByteCount: 0,
            currentName: stagedURL.lastPathComponent
        ))
        await progress(.init(
            phase: .hashing,
            fractionCompleted: 1,
            completedFileCount: 1,
            totalFileCount: 1,
            completedLogicalByteCount: 0,
            totalLogicalByteCount: 0,
            currentName: stagedURL.lastPathComponent
        ))
        await progress(.init(
            phase: .finalValidation,
            fractionCompleted: 1,
            completedFileCount: 1,
            totalFileCount: 1,
            completedLogicalByteCount: 0,
            totalLogicalByteCount: 0,
            currentName: stagedURL.lastPathComponent
        ))
        await probe.finish()
        return TransferVerificationCompletion(
            receipt: .init(
                source: source,
                staged: staged,
                borrowedAuthorityTokens: [source.authorityToken]
            ),
            summary: .init(
                verifiedFileCount: 1,
                verifiedLogicalByteCount: 0,
                noByteTransferItemCount: 0
            )
        )
    }

    func revalidate(_ receipt: TransferVerificationReceipt) async throws {
        await probe.recordRevalidation()
    }

    deinit {
        lock.withLock { ownedManifests.forEach { $0.close() } }
    }
}

private actor ConcurrentSynchronizationVerificationProbe {
    private(set) var startedCount = 0
    private(set) var completedCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var revalidatedCount = 0
    private var activeCount = 0
    private var firstWorkerWaiter: CheckedContinuation<Void, Never>?

    func begin() async -> Int {
        startedCount += 1
        let call = startedCount
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        if startedCount == 1 {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                releaseFirstWorkerIfNeeded()
            }
            await withCheckedContinuation { firstWorkerWaiter = $0 }
        } else if startedCount == 2 {
            releaseFirstWorkerIfNeeded()
        }
        return call
    }

    func finish() {
        completedCount += 1
        activeCount -= 1
    }

    func recordRevalidation() {
        revalidatedCount += 1
    }

    private func releaseFirstWorkerIfNeeded() {
        firstWorkerWaiter?.resume()
        firstWorkerWaiter = nil
    }
}

private actor SynchronizationVerificationProgressAudit {
    private(set) var completedBeforeFirstQuarantine: Int?
    private(set) var verifyingProgressViolations: [FolderSynchronizationProgress] = []

    func record(
        _ progress: FolderSynchronizationProgress,
        completedVerificationCount: Int
    ) {
        if progress.phase == .verifyingStaging,
           progress.completedCount > completedVerificationCount {
            verifyingProgressViolations.append(progress)
        }
        if progress.phase == .quarantining,
           completedBeforeFirstQuarantine == nil {
            completedBeforeFirstQuarantine = completedVerificationCount
        }
    }
}

private actor SynchronizationVerificationProgressRecorder {
    private(set) var values: [TransferVerificationProgress] = []

    func append(_ value: TransferVerificationProgress) {
        values.append(value)
    }
}

#if DEBUG
private struct SynchronizationDescriptorEventKey: Hashable {
    let leaseID: UInt64
    let descriptor: Int32
    let role: TransferVerificationDescriptorRole
}

private final class SynchronizationDescriptorLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferVerificationDescriptorEvent] = []

    func record(_ event: TransferVerificationDescriptorEvent) {
        lock.withLock { events.append(event) }
    }

    var openCount: Int {
        lock.withLock {
            var counts: [SynchronizationDescriptorEventKey: Int] = [:]
            for event in events {
                let key = SynchronizationDescriptorEventKey(
                    leaseID: event.leaseID,
                    descriptor: event.descriptor,
                    role: event.role
                )
                switch event.action {
                case .acquired:
                    counts[key, default: 0] += 1
                case .closed:
                    counts[key, default: 0] -= 1
                }
            }
            return counts.values.filter { $0 > 0 }.reduce(0, +)
        }
    }
}

private final class ManifestOwnershipVerificationFactory:
    TransferVerificationSessionFactory,
    @unchecked Sendable
{
    let session: ManifestOwnershipVerificationSession

    init(
        sourceURL: URL,
        sourceIdentity: FileIdentity,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        logicalByteCount: Int64,
        ledger: SynchronizationDescriptorLedger
    ) {
        session = ManifestOwnershipVerificationSession(
            sourceURL: sourceURL,
            sourceIdentity: sourceIdentity,
            stagedURL: stagedURL,
            stagedIdentity: stagedIdentity,
            logicalByteCount: logicalByteCount,
            ledger: ledger
        )
    }

    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)? {
        session
    }
}

private final class ManifestOwnershipVerificationSession:
    TransferVerificationSession,
    @unchecked Sendable
{
    private let sourceURL: URL
    private let sourceIdentity: FileIdentity
    private let stagedURL: URL
    private let stagedIdentity: FileIdentity
    private let logicalByteCount: Int64
    private let builder: LiveTransferVerificationManifestBuilder
    private let ledger: SynchronizationDescriptorLedger
    private let lock = NSLock()
    private var storedReceiptLeaseCount = 0
    private var sourceManifestBackingStorageProbe: WeakObjectProbe?

    init(
        sourceURL: URL,
        sourceIdentity: FileIdentity,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        logicalByteCount: Int64,
        ledger: SynchronizationDescriptorLedger
    ) {
        self.sourceURL = sourceURL
        self.sourceIdentity = sourceIdentity
        self.stagedURL = stagedURL
        self.stagedIdentity = stagedIdentity
        self.logicalByteCount = logicalByteCount
        self.ledger = ledger
        builder = LiveTransferVerificationManifestBuilder(
            testHooks: .init(onDescriptorEvent: { ledger.record($0) })
        )
    }

    var receiptLeaseCount: Int {
        lock.withLock { storedReceiptLeaseCount }
    }

    var sourceManifestBackingStorageIsReleased: Bool {
        let probe = lock.withLock { sourceManifestBackingStorageProbe }
        return probe?.isReleased == true
    }

    func captureSource(
        at url: URL,
        identifiedBy identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        let manifest = try await builder.capture(
            at: sourceURL,
            identifiedBy: sourceIdentity,
            comparisonPolicy: comparisonPolicy
        )
        let probe = WeakObjectProbe(manifest.backingStorageObjectForTesting)
        lock.withLock { sourceManifestBackingStorageProbe = probe }
        return manifest
    }

    func verify(
        source: TransferVerificationManifest,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        progress: @escaping @Sendable (TransferVerificationProgress) async -> Void
    ) async throws -> TransferVerificationCompletion {
        let openBeforeReceipt = ledger.openCount
        var receiptSource: TransferVerificationManifest?
        var receiptStaged: TransferVerificationManifest?
        var published = false
        defer {
            if !published {
                receiptSource?.close()
                receiptStaged?.close()
            }
        }
        receiptSource = try await builder.capture(
            at: sourceURL,
            identifiedBy: sourceIdentity,
            comparisonPolicy: source.comparisonPolicy
        )
        receiptStaged = try await builder.capture(
            at: self.stagedURL,
            identifiedBy: self.stagedIdentity,
            comparisonPolicy: source.comparisonPolicy
        )
        lock.withLock {
            storedReceiptLeaseCount = ledger.openCount - openBeforeReceipt
        }
        await progress(.init(
            phase: .finalValidation,
            fractionCompleted: 1,
            completedFileCount: 1,
            totalFileCount: 1,
            completedLogicalByteCount: logicalByteCount,
            totalLogicalByteCount: logicalByteCount,
            currentName: stagedURL.lastPathComponent
        ))
        let finalSource = try #require(receiptSource)
        let finalStaged = try #require(receiptStaged)
        published = true
        return .init(
            receipt: .init(
                source: finalSource,
                staged: finalStaged,
                borrowedAuthorityTokens: []
            ),
            summary: .init(
                verifiedFileCount: 1,
                verifiedLogicalByteCount: logicalByteCount,
                noByteTransferItemCount: 0
            )
        )
    }

    func revalidate(_ receipt: TransferVerificationReceipt) async throws {}
}

private actor DescriptorCountSnapshot {
    private(set) var value: Int?

    func record(_ count: Int) {
        if value == nil {
            value = count
        }
    }
}

private actor BooleanSnapshot {
    private(set) var value: Bool?

    func record(_ value: Bool) {
        if self.value == nil {
            self.value = value
        }
    }
}

private final class WeakObjectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var object: AnyObject?

    init(_ object: AnyObject) {
        self.object = object
    }

    var isReleased: Bool {
        lock.withLock { object == nil }
    }
}
#endif
