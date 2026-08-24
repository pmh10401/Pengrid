import Foundation
import Darwin
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

    @Test func nonemptyChecksumsDoNotDuplicateTerminalProgress() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "three-bytes.bin")
        try Data([1, 2, 3]).write(to: file)
        let progress = ChecksumProgressRecorder()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            rawHasher: ProgressScriptRawHasher(deltas: [1, 1, 1])
        )

        _ = try await service.checksum(for: checksumRequest(for: file)) { value in
            await progress.record(value)
        }

        #expect(await progress.values == [1.0 / 3.0, 2.0 / 3.0, 1.0])
    }

    @Test func emptyFilesStillReportCompletionProgress() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "empty.bin")
        try Data().write(to: file)
        let progress = ChecksumProgressRecorder()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            rawHasher: RecordingRawHasher()
        )

        _ = try await service.checksum(
            for: checksumRequest(for: file),
            progress: { value in await progress.record(value) }
        )

        let values = await progress.values
        #expect(values == [1])
    }

    @Test func cancellationDuringEmptyTerminalProgressIsObservedBeforeReturningDigest() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "empty.bin")
        try Data().write(to: file)
        let gate = TerminalProgressGate()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            rawHasher: RecordingRawHasher()
        )
        let worker = Task {
            try await service.checksum(for: checksumRequest(for: file)) { value in
                #expect(value == 1)
                await gate.waitForRelease()
            }
        }

        while !(await gate.didEnter) {
            await Task.yield()
        }
        worker.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
    }

    @Test func rawHasherReceivesTheCompleteCapturedFingerprint() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let rawHasher = RecordingRawHasher()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            chunkSize: 4_096,
            rawHasher: rawHasher
        )

        _ = try await service.checksum(for: pair.leftRequest, progress: { _ in })

        let captured = try #require(rawHasher.lastExpected)
        let descriptor = pair.leftRequest.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        let current = try RawFileFingerprint(descriptor: descriptor)
        #expect(captured == current)
    }

    @Test func rawTypeErrorsMapToTheExistingChecksumCategory() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            rawHasher: ThrowingRawHasher(error: .notRegularFile)
        )

        await #expect(throws: ChecksumError.typeChanged) {
            try await service.checksum(for: pair.leftRequest, progress: { _ in })
        }
    }

    @Test func rawReadFailuresPreserveThePOSIXChecksumContract() async throws {
        let pair = try ChecksumFixture.equalFiles()
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            rawHasher: ThrowingRawHasher(error: .readFailed(.EIO))
        )

        await #expect(throws: POSIXError(.EIO)) {
            try await service.checksum(for: pair.leftRequest, progress: { _ in })
        }
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

private func checksumRequest(for url: URL) throws -> ChecksumRequest {
    var information = stat()
    let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let identity = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    return ChecksumRequest(
        url: url,
        fingerprint: ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: identity,
                resolvedIdentifier: identity
            ),
            byteSize: Int64(information.st_size),
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec)
                    + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            rawModifiedAt: ComparisonModificationTimestamp(
                seconds: Int64(information.st_mtimespec.tv_sec),
                nanoseconds: Int64(information.st_mtimespec.tv_nsec)
            )
        )
    )
}

private final class RecordingRawHasher: RawFileHashing, @unchecked Sendable {
    private let lock = NSLock()
    private let underlying = LiveRawFileHasher()
    private var expectedFingerprints: [RawFileFingerprint] = []

    var lastExpected: RawFileFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        return expectedFingerprints.last
    }

    func checksum(
        descriptor: Int32,
        expected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        record(expected)
        return try await underlying.checksum(
            descriptor: descriptor,
            expected: expected,
            chunkSize: chunkSize,
            progress: progress
        )
    }

    private func record(_ expected: RawFileFingerprint) {
        lock.lock()
        expectedFingerprints.append(expected)
        lock.unlock()
    }

    func checksumPair(
        sourceDescriptor: Int32,
        sourceExpected: RawFileFingerprint,
        stagedDescriptor: Int32,
        stagedExpected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        try await underlying.checksumPair(
            sourceDescriptor: sourceDescriptor,
            sourceExpected: sourceExpected,
            stagedDescriptor: stagedDescriptor,
            stagedExpected: stagedExpected,
            chunkSize: chunkSize,
            progress: progress
        )
    }
}

private struct ThrowingRawHasher: RawFileHashing {
    let error: RawFileHashingError

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        throw error
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        throw error
    }
}

private struct ProgressScriptRawHasher: RawFileHashing {
    let deltas: [Int64]

    func checksum(
        descriptor _: Int32,
        expected _: RawFileFingerprint,
        chunkSize _: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        for delta in deltas {
            await progress(delta)
        }
        return Data([0xAA])
    }

    func checksumPair(
        sourceDescriptor _: Int32,
        sourceExpected _: RawFileFingerprint,
        stagedDescriptor _: Int32,
        stagedExpected _: RawFileFingerprint,
        chunkSize _: Int,
        progress _: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        return (Data([0xAA]), Data([0xBB]))
    }
}

private actor TerminalProgressGate {
    private(set) var didEnter = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        didEnter = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
