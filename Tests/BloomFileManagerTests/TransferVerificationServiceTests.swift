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
        let fixture = try VerificationFixture.files(count: 64, bytes: 0)
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
        #expect(completion.summary.verifiedFileCount == 64)
        #expect(workerCounter.value == 2)
        completion.receipt.source.close()
        completion.receipt.staged.close()
    }

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
