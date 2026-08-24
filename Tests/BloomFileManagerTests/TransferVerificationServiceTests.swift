import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite(.serialized)
struct TransferVerificationServiceTests {
    @Test func disabledPolicyDoesNotCreateAVerificationSession() {
        let factory = LiveTransferVerificationSessionFactory()
        #expect(factory.makeSession(policy: .disabled) == nil)
        #expect(factory.makeSession(policy: .sha256(maxConcurrentPairs: 0)) != nil)
        #expect(factory.makeSession(policy: .sha256(maxConcurrentPairs: -1)) != nil)
    }

    @Test func equalRealFilesVerifyAndReturnOnlyBoundedSummary() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("equal".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }

        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 2)
            )
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }

        #expect(completion.summary == TransferVerificationSummary(
            verifiedFileCount: 1,
            verifiedLogicalByteCount: 5,
            noByteTransferItemCount: 0
        ))
        #expect(completion.receipt.source.regularFileCount == 1)
        #expect(completion.receipt.staged.regularFileCount == 1)
        #expect(completion.receipt.source.regularFiles.first?.comparisonKey == ["payload.bin"])
        #expect(completion.receipt.borrowedAuthorityTokens == Set([source.authorityToken]))
        #expect(!completion.receipt.borrowedAuthorityTokens.contains(
            completion.receipt.source.authorityToken
        ))
    }

    @Test func unequalRealFilesFailWithBoundedContentMismatch() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("source".utf8))
        defer { fixture.temporary.remove() }
        try Data("staged".utf8).write(to: fixture.staged.appending(path: "payload.bin"))
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )

        await #expect(throws: TransferVerificationFailure(
            category: .contentMismatch,
            safeName: "payload.bin"
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
    }

    @Test func structureMismatchIsReportedBeforeHashing() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        try Data("extra".utf8).write(to: fixture.staged.appending(path: "extra.bin"))
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let probe = HashProbe()
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                hasher: ProbeHasher(probe: probe)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 2))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .structureMismatch
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        #expect(await probe.callCount == 0)
    }

    @Test func postHashMutationIsCaughtByReceiptRevalidation() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        try Data("changed".utf8).write(to: fixture.staged.appending(path: "payload.bin"))

        await #expect(throws: TransferVerificationFailure(
            category: .stagedOutputChanged,
            safeName: nil
        )) {
            try await session.revalidate(completion.receipt)
        }
    }

    @Test func sourceMutationDuringHashMapsToSourceChanged() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let hasher = MutatingPairHasher {
            try? Data("changed".utf8).write(
                to: fixture.source.appending(path: "payload.bin")
            )
        }
        let session = try #require(
            LiveTransferVerificationSessionFactory(hasher: hasher)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .sourceChanged,
            safeName: nil
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
    }

    @Test func stagedMutationDuringHashMapsToStagedOutputChanged() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let hasher = MutatingPairHasher {
            try? Data("changed".utf8).write(
                to: fixture.staged.appending(path: "payload.bin")
            )
        }
        let session = try #require(
            LiveTransferVerificationSessionFactory(hasher: hasher)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .stagedOutputChanged,
            safeName: nil
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
    }

    @Test func zeroByteTreePublishesEveryPhaseBoundaryAndCompletes() async throws {
        let fixture = try VerificationFixture.emptyTree()
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let progress = ProgressRecorder()
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 2)
            )
        )

        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { await progress.record($0) }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }

        #expect(completion.summary == TransferVerificationSummary(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0
        ))
        let values = await progress.values
        #expect(values.contains { $0.phase == .preparingManifest && $0.fractionCompleted == 0 })
        #expect(values.contains { $0.phase == .preparingManifest && $0.fractionCompleted == 1 })
        #expect(values.contains { $0.phase == .hashing && $0.fractionCompleted == 0 })
        #expect(values.contains { $0.phase == .hashing && $0.fractionCompleted == 1 })
        #expect(values.contains { $0.phase == .finalValidation && $0.fractionCompleted == 0 })
        #expect(values.contains { $0.phase == .finalValidation && $0.fractionCompleted == 1 })
        #expect(values.last?.fractionCompleted == 1)
        for phase in [
            TransferVerificationPhase.preparingManifest,
            .hashing,
            .finalValidation
        ] {
            let fractions = values.filter { $0.phase == phase }.map(\.fractionCompleted)
            #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    @Test func emptyRegularFileUsesFileCompletionForHashingProgress() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data())
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let progress = ProgressRecorder()
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )

        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { await progress.record($0) }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }

        let hashing = await progress.values.filter { $0.phase == .hashing }
        #expect(hashing.contains {
            $0.fractionCompleted == 1
                && $0.completedFileCount == 1
                && $0.totalFileCount == 1
                && $0.completedLogicalByteCount == 0
        })
    }

    @Test func pairLimitNeverExceedsTwoAndZeroOrNegativeClampToOne() async throws {
        let fixture = try VerificationFixture.files(count: 4, bytes: 8)
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }

        let probe = HashProbe(delay: .milliseconds(20))
        let limitTwo = try #require(
            LiveTransferVerificationSessionFactory(
                hasher: ProbeHasher(probe: probe)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 99))
        )
        let completion = try await limitTwo.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        completion.receipt.source.close()
        completion.receipt.staged.close()
        #expect(await probe.highWater <= 2)

        for limit in [0, -1] {
            let oneProbe = HashProbe(delay: .milliseconds(20))
            let session = try #require(
                LiveTransferVerificationSessionFactory(
                    hasher: ProbeHasher(probe: oneProbe)
                ).makeSession(policy: .sha256(maxConcurrentPairs: limit))
            )
            let nextSource = try await capture(
                fixture.source,
                identity: fixture.sourceIdentity
            )
            let next = try await session.verify(
                source: nextSource,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
            nextSource.close()
            next.receipt.source.close()
            next.receipt.staged.close()
            #expect(await oneProbe.highWater == 1)
        }
    }

    @Test func concurrentVerifiesShareOneSessionPermitPool() async throws {
        let first = try VerificationFixture.singleFile(contents: Data("one".utf8))
        let second = try VerificationFixture.singleFile(contents: Data("two".utf8))
        defer {
            first.temporary.remove()
            second.temporary.remove()
        }
        let firstSource = try await capture(first.source, identity: first.sourceIdentity)
        let secondSource = try await capture(second.source, identity: second.sourceIdentity)
        let probe = HashProbe(delay: .milliseconds(30))
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                hasher: ProbeHasher(probe: probe)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        async let firstCompletion = session.verify(
            source: firstSource,
            stagedURL: first.staged,
            stagedIdentity: first.stagedIdentity,
            progress: { _ in }
        )
        async let secondCompletion = session.verify(
            source: secondSource,
            stagedURL: second.staged,
            stagedIdentity: second.stagedIdentity,
            progress: { _ in }
        )
        let completions = try await [firstCompletion, secondCompletion]
        firstSource.close()
        secondSource.close()
        for completion in completions {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        #expect(await probe.highWater == 1)
    }

    @Test func failedHashReleasesPermitForLaterVerification() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let probe = FailingOnceHasher()
        let session = try #require(
            LiveTransferVerificationSessionFactory(hasher: probe)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        do {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
            Issue.record("expected the first hash to fail")
        } catch let failure as TransferVerificationFailure {
            #expect(failure.category == .readFailed)
        }
        let retrySource = try await capture(fixture.source, identity: fixture.sourceIdentity)
        let completion = try await session.verify(
            source: retrySource,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        retrySource.close()
        completion.receipt.source.close()
        completion.receipt.staged.close()
        #expect(await probe.state.callCount == 2)
    }

    @Test func cancelledHashReleasesPermitForLaterVerification() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let hasher = CancellingOnceHasher()
        let session = try #require(
            LiveTransferVerificationSessionFactory(hasher: hasher)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        do {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
            Issue.record("expected the first hash to be cancelled")
        } catch let failure as TransferVerificationFailure {
            #expect(failure.category == .cancelled)
        }
        let retrySource = try await capture(fixture.source, identity: fixture.sourceIdentity)
        let completion = try await session.verify(
            source: retrySource,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        retrySource.close()
        completion.receipt.source.close()
        completion.receipt.staged.close()
        #expect(await hasher.state.callCount == 2)
    }

    @Test func workerCountIsBoundedByPairLimit() async throws {
        let fixture = try VerificationFixture.files(count: 512, bytes: 0)
        defer { fixture.temporary.remove() }
        let workerCounter = LockedCounter()
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                hasher: ProbeHasher(probe: HashProbe()),
                onWorkerStarted: { workerCounter.increment() }
            ).makeSession(policy: .sha256(maxConcurrentPairs: 2))
        )
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)

        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        source.close()
        #expect(completion.summary.verifiedFileCount == 512)
        #expect(workerCounter.value == 2)
        completion.receipt.source.close()
        completion.receipt.staged.close()
    }

    #if DEBUG
    @Test func successfulVerifyClosesIntermediateGenerationsBeforeReturn() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let ledger = DescriptorLedger()
        let builder = LiveTransferVerificationManifestBuilder(
            testHooks: TransferVerificationManifestTestHooks(
                onDescriptorEvent: { ledger.record($0) }
            )
        )
        let source = try await builder.capture(
            at: fixture.source,
            identifiedBy: fixture.sourceIdentity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        let sourceOpenCount = ledger.openCount
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        let openBeforeReceiptClose = ledger.openCount
        // The receipt retains exactly the final source and staged generation,
        // each with its root-parent and root-directory descriptor leases.
        let expectedReceiptGenerationLeaseCount = 4
        #expect(openBeforeReceiptClose == sourceOpenCount + expectedReceiptGenerationLeaseCount)

        source.close()
        completion.receipt.source.close()
        completion.receipt.staged.close()
        #expect(ledger.unbalancedLeaseIDs.isEmpty)
    }

    @Test func cancelledVerifyClosesAllServiceOwnedGenerations() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        let ledger = DescriptorLedger()
        let builder = LiveTransferVerificationManifestBuilder(
            testHooks: TransferVerificationManifestTestHooks(
                onDescriptorEvent: { ledger.record($0) }
            )
        )
        let source = try await builder.capture(
            at: fixture.source,
            identifiedBy: fixture.sourceIdentity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        let sourceOpenCount = ledger.openCount
        let lease = TestResourceLease(source: source, temporary: fixture.temporary)
        defer { lease.releaseNormally() }
        let hasher = BlockingPairHasher()
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: builder,
                hasher: hasher
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )
        let verificationTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        defer {
            scheduleLateTaskCleanup(
                verificationTask,
                lease: lease,
                onTimeout: { await hasher.state.release() }
            )
        }
        try await waitForTestSignal(hasher.state.entered)
        verificationTask.cancel()
        await hasher.state.release()
        let outcome = await awaitBoundedTaskResult(
            verificationTask,
            lease: lease,
            onTimeout: { await hasher.state.release() }
        )
        guard case .failure = outcome else {
            Issue.record("cancelled verification unexpectedly returned a receipt")
            return
        }
        #expect(ledger.openCount == sourceOpenCount)
        lease.releaseNormally()
        #expect(ledger.unbalancedLeaseIDs.isEmpty)
    }
    #endif

    @Test func progressCallbacksAreSerializedAndDrainedBeforeVerifyReturns() async throws {
        let fixture = try VerificationFixture.files(count: 2, bytes: 16)
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let callbacks = ProgressCallbackProbe()
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 2)
            )
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { await callbacks.record($0) }
        )
        let callbackCountAtReturn = await callbacks.count
        try await Task.sleep(for: .milliseconds(20))
        #expect(await callbacks.count == callbackCountAtReturn)
        #expect(await callbacks.highWater == 1)
        completion.receipt.source.close()
        completion.receipt.staged.close()
    }

    @Test func failuresDoNotExposeDigestOrFullPaths() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("source".utf8))
        defer { fixture.temporary.remove() }
        try Data("staged".utf8).write(to: fixture.staged.appending(path: "payload.bin"))
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )
        do {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { progress in
                    #expect(!progress.currentName.contains("/"))
                    #expect(!progress.currentName.contains(fixture.temporary.url.path))
                }
            )
            Issue.record("expected verification to fail")
        } catch {
            let description = String(describing: error)
            #expect(!description.contains(fixture.temporary.url.path))
            #expect(!description.contains("source"))
            #expect(!description.contains("staged"))
            #expect(!description.contains("SHA256"))
            #expect(!description.contains("e3b0c44298fc1c149afbf4c8996fb924"))
        }
    }

    @Test func cancellationAtTerminalProgressFailsBeforeReceiptPublication() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        #if DEBUG
        let ledger = DescriptorLedger()
        let builder = LiveTransferVerificationManifestBuilder(
            testHooks: TransferVerificationManifestTestHooks(
                onDescriptorEvent: { ledger.record($0) }
            )
        )
        let source = try await builder.capture(
            at: fixture.source,
            identifiedBy: fixture.sourceIdentity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        let sourceOpenCount = ledger.openCount
        #else
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        #endif
        let lease = TestResourceLease(source: source, temporary: fixture.temporary)
        defer { lease.releaseNormally() }
        let terminalGate = TestGate()
        #if DEBUG
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder).makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )
        #else
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )
        #endif

        let verificationTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { value in
                    guard value.phase == .finalValidation,
                          value.fractionCompleted == 1
                    else { return }
                    if await terminalGate.enterIfFirst() {
                        await terminalGate.waitForRelease()
                    }
                }
            )
        }
        defer {
            scheduleLateTaskCleanup(
                verificationTask,
                lease: lease,
                onTimeout: { await terminalGate.release() }
            )
        }
        try await waitForTestSignal(terminalGate.entered)
        verificationTask.cancel()
        await terminalGate.release()

        let outcome = await awaitBoundedTaskResult(
            verificationTask,
            lease: lease,
            onTimeout: { await terminalGate.release() }
        )
        guard case let .failure(error) = outcome else {
            Issue.record("terminal cancellation unexpectedly returned a receipt")
            return
        }
        #expect((error as? TransferVerificationFailure)?.category == .cancelled)
        #if DEBUG
        // Cancellation after the terminal callback must close every
        // intermediate generation before the retry starts.
        #expect(ledger.openCount == sourceOpenCount)
        #endif

        let retryTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        let retryOutcome = await awaitBoundedTaskResult(
            retryTask,
            lease: lease,
            onTimeout: { await terminalGate.release() }
        )
        guard case let .success(retry) = retryOutcome else {
            Issue.record("same-session retry did not finish after terminal cancellation")
            return
        }
        retry.receipt.source.close()
        retry.receipt.staged.close()
#if DEBUG
        #expect(ledger.openCount == sourceOpenCount)
        lease.releaseNormally()
        #expect(ledger.unbalancedLeaseIDs.isEmpty)
#endif
    }

    @Test func cancellationDuringHashReleasesPermitForTheSameSession() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        let lease = TestResourceLease(source: source, temporary: fixture.temporary)
        defer { lease.releaseNormally() }
        let hasher = BlockingPairHasher()
        let session = try #require(
            LiveTransferVerificationSessionFactory(hasher: hasher)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        let verificationTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        defer {
            scheduleLateTaskCleanup(
                verificationTask,
                lease: lease,
                onTimeout: { await hasher.state.release() }
            )
        }
        try await waitForTestSignal(hasher.state.entered)
        verificationTask.cancel()
        await hasher.state.release()

        let outcome = await awaitBoundedTaskResult(
            verificationTask,
            lease: lease,
            onTimeout: { await hasher.state.release() }
        )
        guard case let .failure(error) = outcome else {
            Issue.record("hash cancellation unexpectedly returned a receipt")
            return
        }
        #expect((error as? TransferVerificationFailure)?.category == .cancelled)

        let retryTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        let retryOutcome = await awaitBoundedTaskResult(
            retryTask,
            lease: lease,
            onTimeout: { await hasher.state.release() }
        )
        guard case let .success(retry) = retryOutcome else {
            Issue.record("same-session retry did not finish after hash cancellation")
            return
        }
        retry.receipt.source.close()
        retry.receipt.staged.close()
        #expect(await hasher.state.callCount == 2)
    }

    @Test func slowProgressHandlerBackpressuresConcurrentProducers() async throws {
        let fixture = try VerificationFixture.files(count: 2, bytes: 0)
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        let lease = TestResourceLease(source: source, temporary: fixture.temporary)
        defer { lease.releaseNormally() }
        let hasher = BurstProgressHasher()
        let progressProbe = ProgressBackpressureProbe()
        let progressGate = TestGate()
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                hasher: hasher,
                onWorkerStarted: nil,
                onProgressProducerWaiting: { _, pendingDepth in
                    progressProbe.record(pendingDepth)
                }
            )
                .makeSession(policy: .sha256(maxConcurrentPairs: 2))
        )

        let verificationTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { value in
                    guard value.phase == .hashing,
                          value.currentName != "Item"
                    else { return }
                    if await progressGate.enterIfFirst() {
                        await progressGate.waitForRelease()
                    }
                }
            )
        }
        defer {
            scheduleLateTaskCleanup(
                verificationTask,
                lease: lease,
                onTimeout: {
                    await progressGate.release()
                    await hasher.state.allowSecondFirstProgress()
                }
            )
        }
        try await waitForTestSignal(hasher.state.secondStarted)
        try await waitForTestSignal(progressGate.entered)
        await hasher.state.allowSecondFirstProgress()
        try await waitForTestSignal(hasher.state.secondAboutToPublish)
        try await progressProbe.waitForPublication()
        // The delivery actor has appended the second event to its pending
        // queue while the first handler is still blocked. The producer must
        // remain suspended at that exact backpressure boundary.
        #expect(progressProbe.pendingDepth == 1)
        #expect(await !hasher.state.secondFirstReturned.isSignaled())

        await progressGate.release()
        let outcome = await awaitBoundedTaskResult(
            verificationTask,
            lease: lease,
            onTimeout: { await progressGate.release() }
        )
        guard case let .success(completion) = outcome else {
            Issue.record("verification did not finish after progress gate release")
            return
        }
        completion.receipt.source.close()
        completion.receipt.staged.close()
    }

    @Test func workerFailureCancelsSiblingBeforeHashFailureDiagnosis() async throws {
        let fixture = try VerificationFixture.files(count: 2, bytes: 0)
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        let lease = TestResourceLease(source: source, temporary: fixture.temporary)
        defer { lease.releaseNormally() }
        let diagnosisGate = TestGate()
        let builder = GatedRecaptureBuilder(diagnosisGate: diagnosisGate)
        let hasher = FailureSiblingHasher()
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: builder,
                hasher: hasher
            ).makeSession(policy: .sha256(maxConcurrentPairs: 2))
        )

        let outcomeTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        defer {
            scheduleLateTaskCleanup(
                outcomeTask,
                lease: lease,
                onTimeout: {
                    await diagnosisGate.release()
                    await hasher.state.releaseSibling()
                }
            )
        }
        try await waitForTestSignal(diagnosisGate.entered)
        do {
            try await waitForTestSignal(
                hasher.state.siblingCancelled,
                timeout: .milliseconds(200)
            )
        } catch is VerificationTestTimeout {
            Issue.record("sibling hashing was not cancelled before failure diagnosis completed")
        }
        await diagnosisGate.release()
        await hasher.state.releaseSibling()
        let outcome = await awaitBoundedTaskResult(
            outcomeTask,
            lease: lease,
            onTimeout: {
                await diagnosisGate.release()
                await hasher.state.releaseSibling()
            }
        )
        guard case let .failure(error) = outcome else {
            Issue.record("worker failure unexpectedly returned a receipt")
            return
        }
        #expect((error as? TransferVerificationFailure)?.category == .readFailed)

        let retryTask = Task {
            try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        let retryOutcome = await awaitBoundedTaskResult(
            retryTask,
            lease: lease,
            onTimeout: {
                await diagnosisGate.release()
                await hasher.state.releaseSibling()
            }
        )
        guard case let .success(retry) = retryOutcome else {
            Issue.record("same-session retry did not finish after worker failure")
            return
        }
        retry.receipt.source.close()
        retry.receipt.staged.close()
    }

    @Test func factoryClampsChunkSizeToSafeBounds() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let cases = [
            (requested: -1, expected: 4_096),
            (requested: 0, expected: 4_096),
            (requested: 4_096, expected: 4_096),
            (requested: 4_194_304, expected: 4_194_304),
            (requested: 9_999_999, expected: 4_194_304)
        ]

        for item in cases {
            do {
                let probe = ChunkSizeProbe()
                let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
                defer { source.close() }
                let session = try #require(
                    LiveTransferVerificationSessionFactory(
                        hasher: ChunkSizeRecordingHasher(probe: probe),
                        chunkSize: item.requested
                    ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
                )
                let completion = try await session.verify(
                    source: source,
                    stagedURL: fixture.staged,
                    stagedIdentity: fixture.stagedIdentity,
                    progress: { _ in }
                )
                defer {
                    completion.receipt.source.close()
                    completion.receipt.staged.close()
                }
                #expect(await probe.value == item.expected)
            }
        }
    }

    @Test func rawFailureDiagnosisClassifiesSourceMutationBeforeStaged() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                hasher: MutatingFailingPairHasher {
                    try? Data("changed".utf8).write(
                        to: fixture.source.appending(path: "payload.bin")
                    )
                }
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .sourceChanged,
            safeName: "payload.bin"
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
    }

    @Test func rawFailureDiagnosisClassifiesStagedMutationAfterSourceCheck() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                hasher: MutatingFailingPairHasher {
                    try? Data("changed".utf8).write(
                        to: fixture.staged.appending(path: "payload.bin")
                    )
                }
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .stagedOutputChanged,
            safeName: "payload.bin"
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
    }

    @Test func sourceMutationBeforeStagedHashIsRejectedWithoutHasherCall() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let probe = HashProbe()
        let builder = MutatingCaptureBuilder(
            stagedRoot: fixture.staged,
            mutate: {
                try? Data("changed".utf8).write(
                    to: fixture.source.appending(path: "payload.bin")
                )
            }
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: builder,
                hasher: ProbeHasher(probe: probe)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .sourceChanged,
            safeName: "payload.bin"
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        #expect(await probe.callCount == 0)
    }

    @Test func sourceMutationBeforeVerifySkipsStagedCaptureAndHashing() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        try Data("changed".utf8).write(
            to: fixture.source.appending(path: "payload.bin")
        )
        let captureProbe = CaptureProbe()
        let hashProbe = HashProbe()
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: CaptureProbeBuilder(
                    stagedRoot: fixture.staged,
                    probe: captureProbe
                ),
                hasher: ProbeHasher(probe: hashProbe)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .sourceChanged
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        #expect(await captureProbe.stagedCaptureCount == 0)
        #expect(await hashProbe.callCount == 0)
    }

    @Test func initialRecaptureAuthorityAliasingFailsWithoutClosingCallerManifest() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: AliasRecaptureBuilder(aliasOnCall: 1)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func finalRecaptureAuthorityAliasingFailsWithoutPublishingReceipt() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: AliasRecaptureBuilder(aliasOnCall: 2)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func revalidateAuthorityAliasingFailsAndLeavesReceiptUsable() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = AliasRecaptureBuilder(aliasOnCall: 4)
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            try await session.revalidate(completion.receipt)
        }
        try await completion.receipt.source.regularFiles[0].withReaderDescriptor { _ in () }
        try await completion.receipt.staged.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func finalSourceRecaptureReturningCallerAuthorityFailsWithoutClosingCaller() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = CrossAuthorityRecaptureBuilder(
            caller: source,
            mode: .finalSourceToCaller
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        #expect(await builder.aliasHitCount == 1)
        #expect(await builder.recaptureCount == 2)
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func finalStagedRecaptureReturningCallerAuthorityFailsWithoutClosingCaller() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = CrossAuthorityRecaptureBuilder(
            caller: source,
            mode: .finalStagedToCaller
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        #expect(await builder.aliasHitCount == 1)
        #expect(await builder.recaptureCount == 3)
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func revalidateSourceReturningReceiptStagedAuthorityFailsWithoutClosingReceipt() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = CrossAuthorityRecaptureBuilder(
            caller: source,
            mode: .revalidateSourceToStaged
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        await builder.setReceipt(completion.receipt)

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            try await session.revalidate(completion.receipt)
        }
        #expect(await builder.aliasHitCount == 1)
        #expect(await builder.recaptureCount == 4)
        try await completion.receipt.source.regularFiles[0].withReaderDescriptor { _ in () }
        try await completion.receipt.staged.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func revalidateStagedReturningReceiptSourceAuthorityFailsWithoutClosingReceipt() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = CrossAuthorityRecaptureBuilder(
            caller: source,
            mode: .revalidateStagedToSource
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        await builder.setReceipt(completion.receipt)

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            try await session.revalidate(completion.receipt)
        }
        #expect(await builder.aliasHitCount == 1)
        #expect(await builder.recaptureCount == 5)
        try await completion.receipt.source.regularFiles[0].withReaderDescriptor { _ in () }
        try await completion.receipt.staged.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func revalidateSourceReturningOriginalCallerAuthorityFailsWithoutClosingReceipt() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = CrossAuthorityRecaptureBuilder(
            caller: source,
            mode: .revalidateSourceToCaller
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        await builder.setReceipt(completion.receipt)

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            try await session.revalidate(completion.receipt)
        }
        #expect(await builder.aliasHitCount == 1)
        #expect(await builder.recaptureCount == 4)
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
        try await completion.receipt.source.regularFiles[0].withReaderDescriptor { _ in () }
        try await completion.receipt.staged.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func revalidateStagedReturningOriginalCallerAuthorityFailsWithoutClosingReceipt() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = CrossAuthorityRecaptureBuilder(
            caller: source,
            mode: .revalidateStagedToCaller
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(manifestBuilder: builder)
                .makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        await builder.setReceipt(completion.receipt)

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            try await session.revalidate(completion.receipt)
        }
        #expect(await builder.aliasHitCount == 1)
        #expect(await builder.recaptureCount == 5)
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
        try await completion.receipt.source.regularFiles[0].withReaderDescriptor { _ in () }
        try await completion.receipt.staged.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func diagnosisReturningCallerAuthorityFailsWithoutClosingCaller() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let builder = CrossAuthorityRecaptureBuilder(
            caller: source,
            mode: .diagnosisSourceToCaller
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: builder,
                hasher: FailingOnceHasher()
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(
            category: .readFailed,
            safeName: "payload.bin"
        )) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        #expect(await builder.aliasHitCount == 1)
        #expect(await builder.recaptureCount == 2)
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func captureStagedReturningCallerAuthorityFailsWithoutClosingCaller() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let probe = HashProbe()
        let builder = CrossAuthorityCaptureBuilder(
            caller: source,
            stagedRoot: fixture.staged
        )
        let session = try #require(
            LiveTransferVerificationSessionFactory(
                manifestBuilder: builder,
                hasher: ProbeHasher(probe: probe)
            ).makeSession(policy: .sha256(maxConcurrentPairs: 1))
        )

        await #expect(throws: TransferVerificationFailure(category: .readFailed)) {
            _ = try await session.verify(
                source: source,
                stagedURL: fixture.staged,
                stagedIdentity: fixture.stagedIdentity,
                progress: { _ in }
            )
        }
        #expect(await probe.callCount == 0)
        try await source.regularFiles[0].withReaderDescriptor { _ in () }
    }

    @Test func sourceDescendantMutationIsCaughtByReceiptRevalidation() async throws {
        let fixture = try VerificationFixture.nestedFiles()
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        try Data("changed".utf8).write(
            to: fixture.source.appending(path: "nested/payload.bin")
        )

        await #expect(throws: TransferVerificationFailure(category: .sourceChanged)) {
            try await session.revalidate(completion.receipt)
        }
    }

    @Test func stagedDescendantMutationIsCaughtByReceiptRevalidation() async throws {
        let fixture = try VerificationFixture.nestedFiles()
        defer { fixture.temporary.remove() }
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        defer { source.close() }
        let session = try #require(
            LiveTransferVerificationSessionFactory().makeSession(
                policy: .sha256(maxConcurrentPairs: 1)
            )
        )
        let completion = try await session.verify(
            source: source,
            stagedURL: fixture.staged,
            stagedIdentity: fixture.stagedIdentity,
            progress: { _ in }
        )
        defer {
            completion.receipt.source.close()
            completion.receipt.staged.close()
        }
        try Data("changed".utf8).write(
            to: fixture.staged.appending(path: "nested/payload.bin")
        )

        await #expect(throws: TransferVerificationFailure(category: .stagedOutputChanged)) {
            try await session.revalidate(completion.receipt)
        }
    }

    @Test func boundedTaskTimeoutReturnsBeforeNonCooperativeOperationReleases() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        let lease = TestResourceLease(source: source, temporary: fixture.temporary)
        defer { lease.releaseNormally() }
        let operationGate = TestGate()
        let operationEntered = TestSignal()
        let operation = Task<Int, Error> {
            await operationEntered.signal()
            await operationGate.waitForRelease()
            try await source.regularFiles[0].withReaderDescriptor { _ in () }
            return 1
        }
        let timeoutStarted = TestSignal()
        let helperReturned = TestSignal()
        let helperTask = Task {
            let result = await awaitBoundedTaskResult(
                operation,
                timeout: .milliseconds(20),
                lease: lease,
                onTimeout: { await timeoutStarted.signal() }
            )
            await helperReturned.signal()
            return result
        }

        try await waitForTestSignal(operationEntered)
        try await waitForTestSignal(timeoutStarted)
        #expect(lease.didTransfer)
        #expect(lease.cleanupCount == 0)
        var returnedBeforeRelease = false
        do {
            try await waitForTestSignal(helperReturned, timeout: .milliseconds(100))
            returnedBeforeRelease = true
        } catch is VerificationTestTimeout {
            // The pre-fix helper awaited the non-cooperative task here.
        }
        #expect(returnedBeforeRelease)

        await operationGate.release()
        let result = await helperTask.value
        guard case .failure = result else {
            Issue.record("non-cooperative operation unexpectedly succeeded")
            return
        }
        try await lease.waitForCleanup()
        #expect(lease.cleanupCount == 1)
    }

    @Test func boundedTaskCallerCancellationTransfersLeaseBeforeReturning() async throws {
        let fixture = try VerificationFixture.singleFile(contents: Data("same".utf8))
        let source = try await capture(fixture.source, identity: fixture.sourceIdentity)
        let lease = TestResourceLease(source: source, temporary: fixture.temporary)
        defer { lease.releaseNormally() }
        let operationGate = TestGate()
        let operationEntered = TestSignal()
        let operation = Task<Int, Error> {
            await operationEntered.signal()
            await operationGate.waitForRelease()
            try await source.regularFiles[0].withReaderDescriptor { _ in () }
            return 1
        }
        let releaseStarted = TestSignal()
        let releasePermission = TestGate()
        let helperReturned = TestSignal()
        let helperTask = Task {
            let result = await awaitBoundedTaskResult(
                operation,
                lease: lease,
                onTimeout: {
                    await releaseStarted.signal()
                    await releasePermission.waitForRelease()
                    await operationGate.release()
                }
            )
            await helperReturned.signal()
            return result
        }
        defer {
            Task.detached {
                await releasePermission.release()
                await operationGate.release()
            }
        }

        try await waitForTestSignal(operationEntered)
        helperTask.cancel()
        do {
            try await waitForTestSignal(helperReturned, timeout: .milliseconds(100))
        } catch is VerificationTestTimeout {
            #expect(Bool(false), "caller cancellation did not return within the bound")
            if lease.transferToLateCleanup() {
                let lateCleanup = Task.detached {
                    let result = await operation.result
                    closeTimedOutVerificationReceipt(result)
                    lease.releaseAfterOperation()
                }
                _ = lateCleanup
            }
            return
        }
        let result = await helperTask.value
        guard case .failure = result else {
            Issue.record("caller cancellation unexpectedly succeeded")
            return
        }
        try await waitForTestSignal(releaseStarted)
        #expect(lease.didTransfer)
        #expect(lease.cleanupCount == 0)

        await releasePermission.release()
        try await lease.waitForCleanup()
        #expect(lease.cleanupCount == 1)
    }
}

private struct VerificationTestTimeout: Error {}

private final class TestResourceLease: @unchecked Sendable {
    private enum State: Equatable {
        case owned
        case transferred
        case released
    }

    private let lock = NSLock()
    private var state: State = .owned
    private var source: TransferVerificationManifest?
    private var temporary: TemporaryDirectory?
    private var cleanupCountStorage = 0
    private var cleanupWaiters: [CheckedContinuation<Void, any Error>] = []

    init(
        source: TransferVerificationManifest? = nil,
        temporary: TemporaryDirectory? = nil
    ) {
        self.source = source
        self.temporary = temporary
    }

    var cleanupCount: Int {
        lock.withLock { cleanupCountStorage }
    }

    var didTransfer: Bool {
        lock.withLock { state == .transferred }
    }

    @discardableResult
    func transferToLateCleanup() -> Bool {
        lock.withLock {
            guard state == .owned else { return false }
            state = .transferred
            return true
        }
    }

    func releaseNormally() {
        release(if: .owned)
    }

    func releaseAfterOperation() {
        release(if: .transferred)
    }

    private func release(if expectedState: State) {
        let resources: (
            source: TransferVerificationManifest?,
            temporary: TemporaryDirectory?
        )? = lock.withLock {
            guard state == expectedState else { return nil }
            state = .released
            let resources = (source, temporary)
            source = nil
            temporary = nil
            return resources
        }
        guard let resources else { return }
        resources.source?.close()
        resources.temporary?.remove()
        let waiters: [CheckedContinuation<Void, any Error>] = lock.withLock {
            cleanupCountStorage += 1
            let waiters = cleanupWaiters
            cleanupWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForCleanup(timeout: Duration = .seconds(2)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForCleanup()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VerificationTestTimeout()
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    private func waitForCleanup() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, Error>? = lock.withLock {
                    if cleanupCountStorage > 0 {
                        return .success(())
                    }
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    cleanupWaiters.append(continuation)
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let waiters: [CheckedContinuation<Void, any Error>] = lock.withLock {
                let waiters = cleanupWaiters
                cleanupWaiters.removeAll(keepingCapacity: false)
                return waiters
            }
            for waiter in waiters {
                waiter.resume(throwing: CancellationError())
            }
        }
    }
}

private func waitForTestSignal(
    _ signal: TestSignal,
    timeout: Duration = .seconds(2)
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await signal.wait()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw VerificationTestTimeout()
        }
        defer { group.cancelAll() }
        try await group.next()!
    }
}

private func awaitBoundedTaskResult<Success: Sendable>(
    _ task: Task<Success, Error>,
    timeout: Duration = .seconds(2),
    lease: TestResourceLease,
    onTimeout: @escaping @Sendable () async -> Void
) async -> Result<Success, Error> {
    let race = BoundedTaskResultRace()
    let (stream, continuation) = AsyncStream<Result<Success, Error>>.makeStream()
    let finishTimeout: @Sendable () -> Void = {
        guard race.claim() else { return }
        task.cancel()
        if lease.transferToLateCleanup() {
            launchLateTaskCleanup(
                task,
                lease: lease,
                onTimeout: onTimeout
            )
        }
        continuation.yield(.failure(VerificationTestTimeout()))
    }
    let relayTask = Task {
        let result = await task.result
        guard race.claim() else { return }
        continuation.yield(result)
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        finishTimeout()
    }

    let result = await withTaskCancellationHandler {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    } onCancel: {
        finishTimeout()
    }
    continuation.finish()
    relayTask.cancel()
    timeoutTask.cancel()
    return result ?? .failure(VerificationTestTimeout())
}

private func scheduleLateTaskCleanup<Success: Sendable>(
    _ task: Task<Success, Error>,
    lease: TestResourceLease,
    onTimeout: @escaping @Sendable () async -> Void
) {
    task.cancel()
    guard lease.transferToLateCleanup() else { return }
    launchLateTaskCleanup(task, lease: lease, onTimeout: onTimeout)
}

private func launchLateTaskCleanup<Success: Sendable>(
    _ task: Task<Success, Error>,
    lease: TestResourceLease,
    onTimeout: @escaping @Sendable () async -> Void
) {
    let cleanupTask = Task.detached {
        await onTimeout()
        let result = await task.result
        closeTimedOutVerificationReceipt(result)
        lease.releaseAfterOperation()
    }
    _ = cleanupTask
}

private func closeTimedOutVerificationReceipt<Success>(
    _ result: Result<Success, Error>
) {
    guard case let .success(value) = result,
          let completion = value as? TransferVerificationCompletion
    else { return }
    completion.receipt.source.close()
    completion.receipt.staged.close()
}

private final class BoundedTaskResultRace: @unchecked Sendable {
    private let lock = NSLock()
    private var didClaim = false

    func claim() -> Bool {
        lock.withLock {
            guard !didClaim else { return false }
            didClaim = true
            return true
        }
    }
}

private actor TestSignal {
    private var signaled = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func signal() {
        signaled = true
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    func isSignaled() -> Bool {
        signaled
    }

    func wait() async throws {
        if signaled { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if signaled {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}

private actor TestGate {
    let entered = TestSignal()
    private var didEnter = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enterIfFirst() async -> Bool {
        guard !didEnter else { return false }
        didEnter = true
        await entered.signal()
        return true
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor BlockingHasherState {
    let entered = TestSignal()
    private let gate = TestGate()
    private(set) var callCount = 0

    func begin() async {
        callCount += 1
        await entered.signal()
    }

    func waitForRelease() async {
        await gate.waitForRelease()
    }

    func release() async {
        await gate.release()
    }
}

private struct BlockingPairHasher: RawFileHashing {
    let state = BlockingHasherState()

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        await state.begin()
        await state.waitForRelease()
        try Task.checkCancellation()
        return (Data([0]), Data([0]))
    }
}

private actor BurstProgressState {
    let secondStarted = TestSignal()
    let secondAboutToPublish = TestSignal()
    let secondFirstReturned = TestSignal()
    private let secondProgressPermission = TestGate()
    private var callCount = 0

    func begin() async -> Int {
        callCount += 1
        if callCount == 2 {
            await secondStarted.signal()
        }
        return callCount
    }

    func allowSecondFirstProgress() async {
        await secondProgressPermission.release()
    }

    func signalSecondAboutToPublish() async {
        await secondAboutToPublish.signal()
    }

    func waitForSecondProgressPermission() async {
        await secondProgressPermission.waitForRelease()
    }

    func markSecondFirstReturned() async {
        await secondFirstReturned.signal()
    }
}

private struct BurstProgressHasher: RawFileHashing {
    let state = BurstProgressState()

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        let ordinal = await state.begin()
        if ordinal == 1 {
            await progress(1)
        } else {
            await state.waitForSecondProgressPermission()
            await state.signalSecondAboutToPublish()
            await progress(1)
            await state.markSecondFirstReturned()
            for _ in 0 ..< 64 {
                await progress(1)
            }
        }
        return (Data([0]), Data([0]))
    }
}

private actor FailureSiblingState {
    let secondStarted = TestSignal()
    let siblingCancelled = TestSignal()
    private let siblingRelease = TestGate()
    private var callCount = 0

    func next() -> Int {
        callCount += 1
        return callCount
    }

    func waitForSecondStarted() async throws {
        try await secondStarted.wait()
    }

    func markSecondStarted() async {
        await secondStarted.signal()
    }

    func waitForSiblingCancellation() async throws {
        try await withTaskCancellationHandler {
            await siblingRelease.waitForRelease()
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    func releaseSibling() async {
        await siblingRelease.release()
    }

    private func noteCancellation() async {
        await siblingCancelled.signal()
        await siblingRelease.release()
    }
}

private struct FailureSiblingHasher: RawFileHashing {
    let state = FailureSiblingState()

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        let ordinal = await state.next()
        if ordinal == 1 {
            try await state.waitForSecondStarted()
            throw RawFileHashingError.readFailed(.EIO)
        }
        await state.markSecondStarted()
        try await state.waitForSiblingCancellation()
        return (Data([0]), Data([0]))
    }
}

private actor ChunkSizeProbe {
    private(set) var value: Int?

    func record(_ value: Int) {
        self.value = value
    }
}

private struct ChunkSizeRecordingHasher: RawFileHashing {
    let probe: ChunkSizeProbe

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        await probe.record(chunkSize)
        return Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        await probe.record(chunkSize)
        return (Data([0]), Data([0]))
    }
}

private actor RecaptureGateState {
    private var recaptureCount = 0

    func shouldBlock() -> Bool {
        recaptureCount += 1
        return recaptureCount == 2
    }
}

private struct GatedRecaptureBuilder: TransferVerificationManifestBuilding {
    private let base = LiveTransferVerificationManifestBuilder()
    private let state = RecaptureGateState()
    private let diagnosisGate: TestGate

    init(diagnosisGate: TestGate) {
        self.diagnosisGate = diagnosisGate
    }

    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        try await base.capture(
            at: rootURL,
            identifiedBy: expectedIdentity,
            comparisonPolicy: comparisonPolicy
        )
    }

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest {
        if await state.shouldBlock() {
            _ = await diagnosisGate.enterIfFirst()
            await diagnosisGate.waitForRelease()
        }
        return try await base.recapture(manifest)
    }

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws {
        try base.requireStable(current, against: captured)
    }

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws {
        try base.requireEquivalentContentShape(source: source, staged: staged)
    }
}

private struct VerificationFixture {
    let temporary: TemporaryDirectory
    let source: URL
    let staged: URL
    let sourceIdentity: FileIdentity
    let stagedIdentity: FileIdentity

    static func singleFile(contents: Data) throws -> Self {
        let temporary = try TemporaryDirectory()
        let source = temporary.url.appending(path: "source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "staged", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        try contents.write(to: source.appending(path: "payload.bin"))
        try contents.write(to: staged.appending(path: "payload.bin"))
        return Self(
            temporary: temporary,
            source: source,
            staged: staged,
            sourceIdentity: try identity(for: source),
            stagedIdentity: try identity(for: staged)
        )
    }

    static func emptyTree() throws -> Self {
        let temporary = try TemporaryDirectory()
        let source = temporary.url.appending(path: "source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "staged", directoryHint: .isDirectory)
        for root in [source, staged] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: root.appending(path: "empty-folder", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }
        return Self(
            temporary: temporary,
            source: source,
            staged: staged,
            sourceIdentity: try identity(for: source),
            stagedIdentity: try identity(for: staged)
        )
    }

    static func nestedFiles() throws -> Self {
        let temporary = try TemporaryDirectory()
        let source = temporary.url.appending(path: "source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "staged", directoryHint: .isDirectory)
        for root in [source, staged] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let nested = root.appending(path: "nested", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data("same".utf8).write(to: nested.appending(path: "payload.bin"))
        }
        return Self(
            temporary: temporary,
            source: source,
            staged: staged,
            sourceIdentity: try identity(for: source),
            stagedIdentity: try identity(for: staged)
        )
    }

    static func files(count: Int, bytes: Int) throws -> Self {
        let temporary = try TemporaryDirectory()
        let source = temporary.url.appending(path: "source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "staged", directoryHint: .isDirectory)
        for root in [source, staged] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for index in 0 ..< count {
                try Data(repeating: UInt8(index % 251), count: bytes)
                    .write(to: root.appending(path: "file-\(index).bin"))
            }
        }
        return Self(
            temporary: temporary,
            source: source,
            staged: staged,
            sourceIdentity: try identity(for: source),
            stagedIdentity: try identity(for: staged)
        )
    }
}

private func capture(_ url: URL, identity: FileIdentity) async throws -> TransferVerificationManifest {
    try await LiveTransferVerificationManifestBuilder().capture(
        at: url,
        identifiedBy: identity,
        comparisonPolicy: .caseSensitiveCanonical
    )
}

private func identity(for url: URL) throws -> FileIdentity {
    var information = stat()
    let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let token = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    return FileIdentity(entryIdentifier: token, resolvedIdentifier: token)
}

private actor ProgressRecorder {
    private(set) var values: [TransferVerificationProgress] = []

    func record(_ value: TransferVerificationProgress) {
        values.append(value)
    }
}

private final class ProgressBackpressureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDepth: Int?
    private var waiter: CheckedContinuation<Void, any Error>?

    var pendingDepth: Int? {
        lock.withLock { recordedDepth }
    }

    func record(_ depth: Int) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            recordedDepth = depth
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }

    func waitForPublication(timeout: Duration = .seconds(2)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForPublication()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VerificationTestTimeout()
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    private func waitForPublication() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, Error>? = lock.withLock {
                    if recordedDepth != nil {
                        return .success(())
                    }
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    waiter = continuation
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard waiter != nil else { return nil }
                let continuation = waiter
                waiter = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private actor ProgressCallbackProbe {
    private(set) var count = 0
    private(set) var highWater = 0
    private var active = 0

    func record(_: TransferVerificationProgress) async {
        active += 1
        highWater = max(highWater, active)
        count += 1
        try? await Task.sleep(for: .milliseconds(1))
        active -= 1
    }
}

private actor HashProbe {
    let delay: Duration
    private(set) var active = 0
    private(set) var highWater = 0
    private(set) var callCount = 0

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func enter() async {
        active += 1
        highWater = max(highWater, active)
        callCount += 1
        if delay != .zero {
            try? await Task.sleep(for: delay)
        }
    }

    func leave() {
        active -= 1
    }
}

private struct ProbeHasher: RawFileHashing {
    let probe: HashProbe

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected: RawFileFingerprint,
        chunkSize _: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        await probe.enter()
        await progress(min(sourceExpected.logicalByteCount, 16))
        await probe.leave()
        return (Data([0]), Data([0]))
    }
}

private struct MutatingPairHasher: RawFileHashing {
    let mutate: @Sendable () -> Void

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected: RawFileFingerprint,
        chunkSize _: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        await progress(min(sourceExpected.logicalByteCount, stagedExpected.logicalByteCount))
        mutate()
        return (Data([0]), Data([0]))
    }
}

private struct MutatingFailingPairHasher: RawFileHashing {
    let mutate: @Sendable () -> Void

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        mutate()
        throw RawFileHashingError.stabilityChanged
    }
}

private struct MutatingCaptureBuilder: TransferVerificationManifestBuilding {
    private let base = LiveTransferVerificationManifestBuilder()
    private let stagedRoot: URL
    private let mutate: @Sendable () -> Void

    init(stagedRoot: URL, mutate: @escaping @Sendable () -> Void) {
        self.stagedRoot = stagedRoot
        self.mutate = mutate
    }

    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        if rootURL == stagedRoot {
            mutate()
        }
        return try await base.capture(
            at: rootURL,
            identifiedBy: expectedIdentity,
            comparisonPolicy: comparisonPolicy
        )
    }

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest {
        try await base.recapture(manifest)
    }

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws {
        try base.requireStable(current, against: captured)
    }

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws {
        try base.requireEquivalentContentShape(source: source, staged: staged)
    }
}

private actor CaptureProbe {
    private(set) var stagedCaptureCount = 0

    func recordStagedCapture() {
        stagedCaptureCount += 1
    }
}

private struct CaptureProbeBuilder: TransferVerificationManifestBuilding {
    private let base = LiveTransferVerificationManifestBuilder()
    private let stagedRoot: URL
    private let probe: CaptureProbe

    init(stagedRoot: URL? = nil, probe: CaptureProbe) {
        self.stagedRoot = stagedRoot ?? URL(filePath: "/__unconfigured-staged-root__")
        self.probe = probe
    }

    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        if rootURL == stagedRoot {
            await probe.recordStagedCapture()
        }
        return try await base.capture(
            at: rootURL,
            identifiedBy: expectedIdentity,
            comparisonPolicy: comparisonPolicy
        )
    }

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest {
        try await base.recapture(manifest)
    }

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws {
        try base.requireStable(current, against: captured)
    }

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws {
        try base.requireEquivalentContentShape(source: source, staged: staged)
    }
}

private actor AliasRecaptureState {
    private let aliasOnCall: Int
    private var recaptureCount = 0

    init(aliasOnCall: Int) {
        self.aliasOnCall = aliasOnCall
    }

    func shouldAlias() -> Bool {
        recaptureCount += 1
        return recaptureCount == aliasOnCall
    }
}

private struct AliasRecaptureBuilder: TransferVerificationManifestBuilding {
    private let base = LiveTransferVerificationManifestBuilder()
    private let state: AliasRecaptureState

    init(aliasOnCall: Int) {
        state = AliasRecaptureState(aliasOnCall: aliasOnCall)
    }

    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        try await base.capture(
            at: rootURL,
            identifiedBy: expectedIdentity,
            comparisonPolicy: comparisonPolicy
        )
    }

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest {
        if await state.shouldAlias() {
            return manifest
        }
        return try await base.recapture(manifest)
    }

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws {
        try base.requireStable(current, against: captured)
    }

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws {
        try base.requireEquivalentContentShape(source: source, staged: staged)
    }
}

private enum CrossAuthorityRecaptureMode: Sendable {
    case finalSourceToCaller
    case finalStagedToCaller
    case revalidateSourceToStaged
    case revalidateStagedToSource
    case revalidateSourceToCaller
    case revalidateStagedToCaller
    case diagnosisSourceToCaller
}

private actor CrossAuthorityRecaptureState {
    private let mode: CrossAuthorityRecaptureMode
    private var recaptureCount = 0
    private var aliasHitCount = 0
    private var receipt: TransferVerificationReceipt?

    init(mode: CrossAuthorityRecaptureMode) {
        self.mode = mode
    }

    func setReceipt(_ receipt: TransferVerificationReceipt) {
        self.receipt = receipt
    }

    func alias(caller: TransferVerificationManifest) -> TransferVerificationManifest? {
        recaptureCount += 1
        let result: TransferVerificationManifest?
        switch mode {
        case .finalSourceToCaller where recaptureCount == 2,
                .finalStagedToCaller where recaptureCount == 3,
                .revalidateSourceToCaller where recaptureCount == 4,
                .revalidateStagedToCaller where recaptureCount == 5,
                .diagnosisSourceToCaller where recaptureCount == 2:
            result = caller
        case .revalidateSourceToStaged where recaptureCount == 4:
            result = receipt?.staged
        case .revalidateStagedToSource where recaptureCount == 5:
            result = receipt?.source
        default:
            result = nil
        }
        if result != nil { aliasHitCount += 1 }
        return result
    }

    func aliasHits() -> Int {
        aliasHitCount
    }

    func recaptureCalls() -> Int {
        recaptureCount
    }
}

private struct CrossAuthorityRecaptureBuilder: TransferVerificationManifestBuilding {
    private let base = LiveTransferVerificationManifestBuilder()
    private let caller: TransferVerificationManifest
    private let state: CrossAuthorityRecaptureState

    init(
        caller: TransferVerificationManifest,
        mode: CrossAuthorityRecaptureMode
    ) {
        self.caller = caller
        state = CrossAuthorityRecaptureState(mode: mode)
    }

    func setReceipt(_ receipt: TransferVerificationReceipt) async {
        await state.setReceipt(receipt)
    }

    var aliasHitCount: Int {
        get async { await state.aliasHits() }
    }

    var recaptureCount: Int {
        get async { await state.recaptureCalls() }
    }

    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        try await base.capture(
            at: rootURL,
            identifiedBy: expectedIdentity,
            comparisonPolicy: comparisonPolicy
        )
    }

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest {
        if let alias = await state.alias(caller: caller) {
            return alias
        }
        return try await base.recapture(manifest)
    }

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws {
        try base.requireStable(current, against: captured)
    }

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws {
        try base.requireEquivalentContentShape(source: source, staged: staged)
    }
}

private struct CrossAuthorityCaptureBuilder: TransferVerificationManifestBuilding {
    private let base = LiveTransferVerificationManifestBuilder()
    private let caller: TransferVerificationManifest
    private let stagedRoot: URL

    init(caller: TransferVerificationManifest, stagedRoot: URL) {
        self.caller = caller
        self.stagedRoot = stagedRoot
    }

    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        if rootURL == stagedRoot {
            return caller
        }
        return try await base.capture(
            at: rootURL,
            identifiedBy: expectedIdentity,
            comparisonPolicy: comparisonPolicy
        )
    }

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest {
        try await base.recapture(manifest)
    }

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws {
        try base.requireStable(current, against: captured)
    }

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws {
        try base.requireEquivalentContentShape(source: source, staged: staged)
    }
}

private struct FailingOnceHasher: RawFileHashing {
    let state = FailureState()

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        await state.recordCall()
        if await state.consumeFailure() {
            throw RawFileHashingError.readFailed(.EIO)
        }
        return (Data([0]), Data([0]))
    }
}

private struct CancellingOnceHasher: RawFileHashing {
    let state = FailureState()

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        Data([0])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        await state.recordCall()
        if await state.consumeFailure() {
            throw CancellationError()
        }
        return (Data([0]), Data([0]))
    }
}

private actor FailureState {
    private var shouldFail = true
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }

    func consumeFailure() -> Bool {
        defer { shouldFail = false }
        return shouldFail
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

#if DEBUG
private struct DescriptorEventKey: Hashable {
    let leaseID: UInt64
    let descriptor: Int32
    let role: TransferVerificationDescriptorRole
}

private final class DescriptorLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferVerificationDescriptorEvent] = []

    func record(_ event: TransferVerificationDescriptorEvent) {
        lock.withLock {
            events.append(event)
        }
    }

    var openCount: Int {
        lock.withLock {
            var counts: [DescriptorEventKey: Int] = [:]
            for event in events {
                let key = DescriptorEventKey(
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

    var unbalancedLeaseIDs: Set<UInt64> {
        lock.withLock {
            var counts: [DescriptorEventKey: Int] = [:]
            for event in events {
                let key = DescriptorEventKey(
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
            return Set(
                counts.compactMap { key, count in
                    count == 0 ? nil : key.leaseID
                }
            )
        }
    }
}
#endif
