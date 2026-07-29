import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ChecksumServiceTests {
    @Test func equalContentsProduceEqualDigest() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            chunkSize: 4_096
        )
        let left = try await service.checksum(for: pair.leftRequest, progress: { _ in })
        let right = try await service.checksum(for: pair.rightRequest, progress: { _ in })
        #expect(left.digest == right.digest)
    }

    @Test func replacementDuringReadIsRejected() async throws {
        let fixture = try ChecksumFixture.replacedAfterFirstChunk()
        await #expect(throws: ChecksumError.identityChanged) {
            try await fixture.service.checksum(for: fixture.request) { _ in
                await fixture.replaceAfterFirstChunk()
            }
        }
    }

    @Test func nanosecondOnlyModificationDuringReadIsRejected() async throws {
        let fixture = try ChecksumFixture.nanosecondMutationAfterFirstChunk()
        #expect(fixture.request.fingerprint.modifiedAt == fixture.changedModifiedAt)
        #expect(fixture.request.fingerprint.rawModifiedAt != fixture.changedRawModifiedAt)

        await #expect(throws: ChecksumError.identityChanged) {
            try await fixture.service.checksum(for: fixture.request) { _ in
                await fixture.mutateAfterFirstChunk()
            }
        }
    }

    @Test func liveListingPopulatesTheExactModificationTimestamp() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let service = LiveComparisonListingService(batchSize: 1)
        let records = try await service.collect(.init(
            root: pair.directory.url,
            seed: nil,
            subtree: nil,
            options: .init()
        ))
        let listedLeft = records.compactMap(\.entry).first {
            $0.url.lastPathComponent == pair.leftRequest.url.lastPathComponent
        }

        #expect(listedLeft?.fingerprint.rawModifiedAt == pair.leftRequest.fingerprint.rawModifiedAt)
        #expect(listedLeft?.fingerprint.rawModifiedAt != nil)
    }

    @Test func symbolicLinkRequestIsRefused() async throws {
        let fixture = try ChecksumFixture.symbolicLinkRequest()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            chunkSize: 4_096
        )

        await #expect(throws: ChecksumError.typeChanged) {
            try await service.checksum(for: fixture.leftRequest, progress: { _ in })
        }
    }

    @Test func sizeMutationDuringReadIsRejected() async throws {
        let fixture = try ChecksumFixture.sizeMutationAfterFirstChunk()

        await #expect(throws: ChecksumError.sizeChanged) {
            try await fixture.service.checksum(for: fixture.request) { _ in
                await fixture.mutateAfterFirstChunk()
            }
        }
    }

    @Test func schedulerNeverRunsMoreThanTwoReads() async throws {
        let probe = ChecksumConcurrencyProbe()
        let service = InMemoryChecksumService(probe: probe)
        await withTaskGroup(of: Void.self) { group in
            for request in ChecksumFixture.fiveRequests() {
                group.addTask { _ = try? await service.checksum(for: request, progress: { _ in }) }
            }
        }
        #expect(await probe.highWater == 2)
    }

    @Test func cancelledQueuedWaiterFinishesBeforeActiveReadsRelease() async throws {
        let permits = AsyncPermitPool(limit: 2)
        try await permits.acquire()
        try await permits.acquire()
        let probe = PermitWaiterCancellationProbe()
        let waiter = Task {
            await probe.markStarted()
            do {
                try await permits.acquire()
                await probe.markAcquired()
                await permits.release()
            } catch is CancellationError {
                await probe.markCancelled()
            } catch {
                await probe.markFailed()
            }
        }

        while !(await probe.started) {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await probe.outcome == .cancelled)

        await permits.release()
        await permits.release()
        await waiter.value
        try await permits.acquire()
        await permits.release()
    }

    @Test func errorsReleasePermitsForLaterReads() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            chunkSize: 4_096
        )
        let stale = ChecksumRequest(
            url: pair.leftRequest.url,
            fingerprint: .init(
                identity: .init(entryIdentifier: "0:0", resolvedIdentifier: "0:0"),
                byteSize: pair.leftRequest.fingerprint.byteSize,
                modifiedAt: pair.leftRequest.fingerprint.modifiedAt
            )
        )

        for _ in 0 ..< 3 {
            await #expect(throws: ChecksumError.identityChanged) {
                try await service.checksum(for: stale, progress: { _ in })
            }
        }
        _ = try await service.checksum(for: pair.leftRequest, progress: { _ in })
    }

    @Test func cancellationsReleasePermitsForLaterReads() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            chunkSize: 4_096
        )

        for _ in 0 ..< 3 {
            await #expect(throws: CancellationError.self) {
                try await service.checksum(for: pair.leftRequest) { _ in
                    withUnsafeCurrentTask { task in task?.cancel() }
                }
            }
        }
        _ = try await service.checksum(for: pair.leftRequest, progress: { _ in })
    }

    @Test func progressIsBoundedAndFinishesAtOne() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let progress = ChecksumProgressRecorder()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            chunkSize: 4_096
        )

        _ = try await service.checksum(for: pair.leftRequest) { value in
            await progress.record(value)
        }

        let values = await progress.values
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { (0 ... 1).contains($0) })
        #expect(values.last == 1)
    }

    @Test func cacheEvictsTheOldestRequestAtItsBound() async {
        let requests = ChecksumFixture.fiveRequests()
        let cache = ChecksumCache(limit: 2)
        await cache.insert(.init(digest: Data([1])), for: requests[0])
        await cache.insert(.init(digest: Data([2])), for: requests[1])
        await cache.insert(.init(digest: Data([3])), for: requests[2])

        #expect(await cache.value(for: requests[0]) == nil)
        #expect(await cache.value(for: requests[1])?.digest == Data([2]))
        #expect(await cache.value(for: requests[2])?.digest == Data([3]))
    }

    @Test func matcherAppliesDigestComparisonToTheRow() throws {
        let row = try ChecksumFixture.checkingRow()
        let same = ChecksumResult(digest: Data([1]))
        let different = ChecksumResult(digest: Data([2]))

        #expect(ComparisonMatcher.applying(left: same, right: same, to: row).status == .metadataChanged)
        #expect(ComparisonMatcher.applying(left: same, right: different, to: row).status == .contentChanged)
    }

    @Test func matcherPromotesQuickIdentityAfterEqualDigests() throws {
        var row = try ChecksumFixture.checkingRow()
        row.status = .identical(.quick)
        let same = ChecksumResult(digest: Data([1]))

        #expect(ComparisonMatcher.applying(left: same, right: same, to: row).status == .identical(.checksum))
    }
}
