import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct RawFileHashingTests {
    @Test func equalContentsProduceTheStandardDigest() async throws {
        let fixture = try RawHashFixture(contents: Data([0x11, 0x22, 0x33, 0x44]))

        let digest = try await fixture.hasher.checksum(
            descriptor: fixture.descriptor,
            expected: fixture.fingerprint,
            chunkSize: 2,
            progress: { _ in }
        )

        #expect(digest == Data(SHA256.hash(data: fixture.contents)))
    }

    @Test func emptyFilesProduceTheStandardEmptyDigestWithoutProgress() async throws {
        let fixture = try RawHashFixture(contents: Data())
        let recorder = DeltaRecorder()

        let digest = try await fixture.hasher.checksum(
            descriptor: fixture.descriptor,
            expected: fixture.fingerprint,
            chunkSize: 4_096,
            progress: { await recorder.record($0) }
        )

        #expect(digest == Data(SHA256.hash(data: Data())))
        #expect(await recorder.values.isEmpty)
    }

    @Test func shortReadsAreConsumedUntilEndOfFile() async throws {
        let fixture = try RawHashFixture(contents: Data(0 ..< 10))
        let driver = ScriptedReadDriver(scripts: [
            fixture.descriptor: [
                .data(Array(0 ..< 4)),
                .data(Array(4 ..< 7)),
                .data(Array(7 ..< 10)),
                .end
            ]
        ])
        let hasher = LiveRawFileHasher(readDriver: driver)

        let digest = try await hasher.checksum(
            descriptor: fixture.descriptor,
            expected: fixture.fingerprint,
            chunkSize: 16,
            progress: { _ in }
        )

        #expect(digest == Data(SHA256.hash(data: fixture.contents)))
        #expect(driver.recordedCalls == Array(repeating: fixture.descriptor, count: 4))
    }

    @Test func interruptedReadsAreRetriedUntilTheyDeliverData() async throws {
        let fixture = try RawHashFixture(contents: Data([0x55]))
        let driver = ScriptedReadDriver(scripts: [
            fixture.descriptor: [.interrupt, .data([0x55]), .end]
        ])
        let hasher = LiveRawFileHasher(readDriver: driver)

        let digest = try await hasher.checksum(
            descriptor: fixture.descriptor,
            expected: fixture.fingerprint,
            chunkSize: 4,
            progress: { _ in }
        )

        #expect(digest == Data(SHA256.hash(data: fixture.contents)))
        #expect(driver.recordedCalls == Array(repeating: fixture.descriptor, count: 3))
    }

    @Test func cancellationDuringEINTRRetryStopsBeforeTheNextRead() async throws {
        let fixture = try RawHashFixture(contents: Data([0x56]))
        let driver = InterruptRetryGateDriver()
        let worker = Task {
            try await LiveRawFileHasher(readDriver: driver).checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 1,
                progress: { _ in }
            )
        }

        while !driver.didStartFirstRead {
            await Task.yield()
        }
        worker.cancel()
        driver.releaseFirstRead()
        try await Task.sleep(for: .milliseconds(20))
        driver.releaseRetryRead()

        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
        #expect(driver.readCallCount == 1)
    }

    @Test func driverFailuresBecomeTypedPOSIXReadErrors() async throws {
        let fixture = try RawHashFixture(contents: Data([0x66]))
        let driver = ScriptedReadDriver(scripts: [
            fixture.descriptor: [.failure(.EIO)]
        ])
        let hasher = LiveRawFileHasher(readDriver: driver)

        await #expect(throws: RawFileHashingError.readFailed(.EIO)) {
            try await hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 4,
                progress: { _ in }
            )
        }
    }

    @Test func impossibleDriverByteCountsAreRejectedWithoutDigest() async throws {
        let fixture = try RawHashFixture(contents: Data(repeating: 0x77, count: 8))
        let driver = ScriptedReadDriver(scripts: [
            fixture.descriptor: [.oversized(128)]
        ])
        let hasher = LiveRawFileHasher(readDriver: driver)

        await #expect(throws: RawFileHashingError.invalidReadResult) {
            try await hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 16,
                progress: { _ in }
            )
        }
    }

    @Test func nonpositiveChunkSizesAreRejectedBeforeAnyRead() async throws {
        let fixture = try RawHashFixture(contents: Data([0x88]))
        let hasher = LiveRawFileHasher(readDriver: ScriptedReadDriver(scripts: [:]))

        await #expect(throws: RawFileHashingError.invalidChunkSize) {
            try await hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 0,
                progress: { _ in }
            )
        }
    }

    @Test func nonRegularDescriptorsAreRejectedBeforeReading() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let descriptor = try RawHashSupport.open(directory.url)
        defer { Darwin.close(descriptor) }
        let fingerprint = try RawFileFingerprint(descriptor: descriptor)
        let hasher = LiveRawFileHasher(readDriver: ScriptedReadDriver(scripts: [:]))

        await #expect(throws: RawFileHashingError.notRegularFile) {
            try await hasher.checksum(
                descriptor: descriptor,
                expected: fingerprint,
                chunkSize: 4_096,
                progress: { _ in }
            )
        }
    }

    @Test func descriptorIdentityMismatchesAreRejectedBeforeReading() async throws {
        let left = try RawHashFixture(contents: Data([0x01]))
        let right = try RawHashFixture(contents: Data([0x02]))
        let hasher = LiveRawFileHasher(readDriver: ScriptedReadDriver(scripts: [:]))

        await #expect(throws: RawFileHashingError.descriptorIdentityChanged) {
            try await hasher.checksum(
                descriptor: left.descriptor,
                expected: right.fingerprint,
                chunkSize: 4_096,
                progress: { _ in }
            )
        }
    }

    @Test func sizeChangesDuringHashingAreRejectedAfterTheFinalRead() async throws {
        let fixture = try RawHashFixture(contents: Data([0x10, 0x20]), chunkSize: 1)
        fixture.mutateDuringProgress { [fixture] in fixture.appendByte(0x30) }

        await #expect(throws: RawFileHashingError.logicalSizeChanged) {
            try await fixture.hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 1,
                progress: { [fixture] _ in await fixture.runPendingMutation() }
            )
        }
    }

    @Test func modificationTimestampChangesDuringHashingAreRejected() async throws {
        let initial = ComparisonModificationTimestamp(seconds: 1_700_000_000, nanoseconds: 100_000_000)
        let changed = ComparisonModificationTimestamp(seconds: 1_700_000_000, nanoseconds: 200_000_000)
        let fixture = try RawHashFixture(
            contents: Data([0x40, 0x50]),
            chunkSize: 1,
            modificationTimestamp: initial
        )
        #expect(fixture.fingerprint.modificationNanoseconds == initial.nanoseconds)
        fixture.mutateDuringProgress { [fixture] in
            try fixture.setModificationTime(changed)
        }

        await #expect(throws: RawFileHashingError.stabilityChanged) {
            try await fixture.hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 1,
                progress: { [fixture] _ in fixture.runPendingMutationSync() }
            )
        }
    }

    @Test func modeChangesDuringHashingAreRejected() async throws {
        let fixture = try RawHashFixture(
            contents: Data([0x60, 0x70]),
            chunkSize: 1,
            permissions: 0o644
        )
        #expect(fixture.fingerprint.mode & 0o777 != 0o600)
        fixture.mutateDuringProgress { [fixture] in try fixture.setPermissions(0o600) }

        await #expect(throws: RawFileHashingError.stabilityChanged) {
            try await fixture.hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 1,
                progress: { [fixture] _ in fixture.runPendingMutationSync() }
            )
        }
    }

    @Test func cancellationAfterAReturnedReadStopsBeforeTheNextRead() async throws {
        let fixture = try RawHashFixture(contents: Data([0x80, 0x90]), chunkSize: 1)
        let driver = ScriptedReadDriver(scripts: [
            fixture.descriptor: [.data([0x80]), .data([0x90]), .end]
        ])
        let hasher = LiveRawFileHasher(readDriver: driver)

        await #expect(throws: CancellationError.self) {
            try await hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 1,
                progress: { _ in
                    withUnsafeCurrentTask { task in task?.cancel() }
                }
            )
        }
        #expect(driver.recordedCalls == [fixture.descriptor])
    }

    @Test func cancellationWhileAReadBlocksIsObservedBeforeReturningADigest() async throws {
        let fixture = try RawHashFixture(contents: Data())
        let gate = GatedReadDriver(gatedDescriptor: fixture.descriptor)
        let hasher = LiveRawFileHasher(readDriver: gate)

        let worker = Task {
            try await hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 4_096,
                progress: { _ in }
            )
        }

        while !gate.isFirstReadStarted {
            await Task.yield()
        }
        worker.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
        #expect(gate.readCallCount == 1)
    }

    @Test func pairedHashingAlternatesDescriptorsAndReportsMatchedPrefixGrowth() async throws {
        let source = try RawHashFixture(contents: Data([0x01, 0x02]))
        let staged = try RawHashFixture(contents: Data([0x03, 0x04]))
        let driver = ScriptedReadDriver(scripts: [
            source.descriptor: [.data([0x01]), .data([0x02]), .end],
            staged.descriptor: [.data([0x03]), .data([0x04]), .end]
        ])
        let hasher = LiveRawFileHasher(readDriver: driver)
        let recorder = DeltaRecorder()

        let digests = try await hasher.checksumPair(
            sourceDescriptor: source.descriptor,
            sourceExpected: source.fingerprint,
            stagedDescriptor: staged.descriptor,
            stagedExpected: staged.fingerprint,
            chunkSize: 1,
            progress: { await recorder.record($0) }
        )

        #expect(digests.source == Data(SHA256.hash(data: source.contents)))
        #expect(digests.staged == Data(SHA256.hash(data: staged.contents)))
        #expect(driver.recordedCalls == [
            source.descriptor,
            staged.descriptor,
            source.descriptor,
            staged.descriptor,
            source.descriptor,
            staged.descriptor
        ])
        #expect(await recorder.values == [1, 1])
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) != -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) != -1)
        source.closeDescriptor()
        staged.closeDescriptor()
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) == -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) == -1)
    }

    @Test func pairedProgressCountsOnlyCommonPrefixGrowth() async throws {
        let source = try RawHashFixture(contents: Data([0x0A, 0x0B, 0x0C]))
        let staged = try RawHashFixture(contents: Data([0x0D, 0x0E]))
        let driver = ScriptedReadDriver(scripts: [
            source.descriptor: [.data([0x0A]), .data([0x0B]), .data([0x0C]), .end],
            staged.descriptor: [.data([0x0D]), .data([0x0E]), .end]
        ])
        let hasher = LiveRawFileHasher(readDriver: driver)
        let recorder = DeltaRecorder()

        let digests = try await hasher.checksumPair(
            sourceDescriptor: source.descriptor,
            sourceExpected: source.fingerprint,
            stagedDescriptor: staged.descriptor,
            stagedExpected: staged.fingerprint,
            chunkSize: 1,
            progress: { await recorder.record($0) }
        )

        #expect(digests.source != digests.staged)
        #expect(await recorder.values == [1, 1])
        #expect(driver.recordedCalls == [
            source.descriptor,
            staged.descriptor,
            source.descriptor,
            staged.descriptor,
            source.descriptor,
            staged.descriptor,
            source.descriptor
        ])
    }

    @Test func pairedEmptyFilesFinishWithoutFalseProgress() async throws {
        let source = try RawHashFixture(contents: Data())
        let staged = try RawHashFixture(contents: Data())
        let hasher = LiveRawFileHasher(readDriver: ScriptedReadDriver(scripts: [:]))
        let recorder = DeltaRecorder()

        let digests = try await hasher.checksumPair(
            sourceDescriptor: source.descriptor,
            sourceExpected: source.fingerprint,
            stagedDescriptor: staged.descriptor,
            stagedExpected: staged.fingerprint,
            chunkSize: 4_096,
            progress: { await recorder.record($0) }
        )

        #expect(digests.source == Data(SHA256.hash(data: Data())))
        #expect(digests.staged == Data(SHA256.hash(data: Data())))
        #expect(await recorder.values.isEmpty)
    }

    @Test func pairedCancellationWhileSourceReadReturnsStopsBeforeStagedRead() async throws {
        let source = try RawHashFixture(contents: Data([0x01]))
        let staged = try RawHashFixture(contents: Data([0x02]))
        let driver = PairBlockingReadDriver(blockedDescriptor: source.descriptor)
        let recorder = DeltaRecorder()
        let worker = Task {
            try await LiveRawFileHasher(readDriver: driver).checksumPair(
                sourceDescriptor: source.descriptor,
                sourceExpected: source.fingerprint,
                stagedDescriptor: staged.descriptor,
                stagedExpected: staged.fingerprint,
                chunkSize: 1,
                progress: { await recorder.record($0) }
            )
        }

        while !driver.didStartBlockedRead {
            await Task.yield()
        }
        worker.cancel()
        driver.releaseBlockedRead()

        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
        #expect(driver.recordedCalls == [source.descriptor])
        #expect(await recorder.values.isEmpty)
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) != -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) != -1)
        source.closeDescriptor()
        staged.closeDescriptor()
    }

    @Test func pairedCancellationWhileStagedReadReturnsStopsBeforeHashingOrProgress() async throws {
        let source = try RawHashFixture(contents: Data([0x03]))
        let staged = try RawHashFixture(contents: Data([0x04]))
        let driver = PairBlockingReadDriver(blockedDescriptor: staged.descriptor)
        let recorder = DeltaRecorder()
        let worker = Task {
            try await LiveRawFileHasher(readDriver: driver).checksumPair(
                sourceDescriptor: source.descriptor,
                sourceExpected: source.fingerprint,
                stagedDescriptor: staged.descriptor,
                stagedExpected: staged.fingerprint,
                chunkSize: 1,
                progress: { await recorder.record($0) }
            )
        }

        while !driver.didStartBlockedRead {
            await Task.yield()
        }
        worker.cancel()
        driver.releaseBlockedRead()

        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
        #expect(driver.recordedCalls == [source.descriptor, staged.descriptor])
        #expect(await recorder.values.isEmpty)
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) != -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) != -1)
        source.closeDescriptor()
        staged.closeDescriptor()
    }

    @Test func pairedCancellationDuringEINTRRetryStopsBeforeTheNextRead() async throws {
        let source = try RawHashFixture(contents: Data())
        let staged = try RawHashFixture(contents: Data())
        let driver = InterruptRetryGateDriver()
        let worker = Task {
            try await LiveRawFileHasher(readDriver: driver).checksumPair(
                sourceDescriptor: source.descriptor,
                sourceExpected: source.fingerprint,
                stagedDescriptor: staged.descriptor,
                stagedExpected: staged.fingerprint,
                chunkSize: 1,
                progress: { _ in }
            )
        }

        while !driver.didStartFirstRead {
            await Task.yield()
        }
        worker.cancel()
        driver.releaseFirstRead()
        try await Task.sleep(for: .milliseconds(20))
        driver.releaseRetryRead()

        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
        #expect(driver.readCallCount == 1)
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) != -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) != -1)
        source.closeDescriptor()
        staged.closeDescriptor()
    }

    @Test func pairedSourceMutationAfterReadIsRejected() async throws {
        let source = try RawHashFixture(contents: Data([0x05, 0x06]))
        let staged = try RawHashFixture(contents: Data([0x07, 0x08]))
        let driver = ScriptedReadDriver(scripts: [
            source.descriptor: [.data([0x05]), .data([0x06]), .end],
            staged.descriptor: [.data([0x07]), .data([0x08]), .end]
        ])
        source.mutateDuringProgress { [source] in source.appendByte(0x09) }

        await #expect(throws: RawFileHashingError.logicalSizeChanged) {
            try await LiveRawFileHasher(readDriver: driver).checksumPair(
                sourceDescriptor: source.descriptor,
                sourceExpected: source.fingerprint,
                stagedDescriptor: staged.descriptor,
                stagedExpected: staged.fingerprint,
                chunkSize: 1,
                progress: { [source] _ in source.runPendingMutationSync() }
            )
        }
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) != -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) != -1)
        source.closeDescriptor()
        staged.closeDescriptor()
    }

    @Test func pairedStagedMutationAfterReadIsRejected() async throws {
        let source = try RawHashFixture(contents: Data([0x0A, 0x0B]))
        let staged = try RawHashFixture(contents: Data([0x0C, 0x0D]))
        let driver = ScriptedReadDriver(scripts: [
            source.descriptor: [.data([0x0A]), .data([0x0B]), .end],
            staged.descriptor: [.data([0x0C]), .data([0x0D]), .end]
        ])
        staged.mutateDuringProgress { [staged] in staged.appendByte(0x0E) }

        await #expect(throws: RawFileHashingError.logicalSizeChanged) {
            try await LiveRawFileHasher(readDriver: driver).checksumPair(
                sourceDescriptor: source.descriptor,
                sourceExpected: source.fingerprint,
                stagedDescriptor: staged.descriptor,
                stagedExpected: staged.fingerprint,
                chunkSize: 1,
                progress: { [staged] _ in staged.runPendingMutationSync() }
            )
        }
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) != -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) != -1)
        source.closeDescriptor()
        staged.closeDescriptor()
    }

    @Test func pairedReadFailuresPreserveCallerDescriptorOwnership() async throws {
        let source = try RawHashFixture(contents: Data([0x0F]))
        let staged = try RawHashFixture(contents: Data([0x10]))
        let driver = ScriptedReadDriver(scripts: [
            source.descriptor: [.failure(.EIO)],
            staged.descriptor: [.end]
        ])

        await #expect(throws: RawFileHashingError.readFailed(.EIO)) {
            try await LiveRawFileHasher(readDriver: driver).checksumPair(
                sourceDescriptor: source.descriptor,
                sourceExpected: source.fingerprint,
                stagedDescriptor: staged.descriptor,
                stagedExpected: staged.fingerprint,
                chunkSize: 1,
                progress: { _ in }
            )
        }
        #expect(Darwin.fcntl(source.descriptor, F_GETFD) != -1)
        #expect(Darwin.fcntl(staged.descriptor, F_GETFD) != -1)
        source.closeDescriptor()
        staged.closeDescriptor()
    }

    @Test func callersOwnTheirDescriptorsAfterHashingCompletes() async throws {
        let fixture = try RawHashFixture(contents: Data([0xAA, 0xBB]))

        _ = try await fixture.hasher.checksum(
            descriptor: fixture.descriptor,
            expected: fixture.fingerprint,
            chunkSize: 1,
            progress: { _ in }
        )

        #expect(Darwin.fcntl(fixture.descriptor, F_GETFD) != -1)
        fixture.closeDescriptor()
        #expect(Darwin.fcntl(fixture.descriptor, F_GETFD) == -1)
    }

    @Test func callersOwnTheirDescriptorsAfterHashingFails() async throws {
        let fixture = try RawHashFixture(contents: Data([0xAB]))
        let driver = ScriptedReadDriver(scripts: [
            fixture.descriptor: [.failure(.EIO)]
        ])

        await #expect(throws: RawFileHashingError.readFailed(.EIO)) {
            try await LiveRawFileHasher(readDriver: driver).checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 1,
                progress: { _ in }
            )
        }

        #expect(Darwin.fcntl(fixture.descriptor, F_GETFD) != -1)
        fixture.closeDescriptor()
        #expect(Darwin.fcntl(fixture.descriptor, F_GETFD) == -1)
    }

    @Test func callersOwnTheirDescriptorsAfterCancellation() async throws {
        let fixture = try RawHashFixture(contents: Data())
        let gate = GatedReadDriver(gatedDescriptor: fixture.descriptor)
        let hasher = LiveRawFileHasher(readDriver: gate)
        let worker = Task {
            try await hasher.checksum(
                descriptor: fixture.descriptor,
                expected: fixture.fingerprint,
                chunkSize: 1,
                progress: { _ in }
            )
        }

        while !gate.isFirstReadStarted {
            await Task.yield()
        }
        worker.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) {
            try await worker.value
        }
        #expect(Darwin.fcntl(fixture.descriptor, F_GETFD) != -1)
        fixture.closeDescriptor()
        #expect(Darwin.fcntl(fixture.descriptor, F_GETFD) == -1)
    }

    @Test func fieldWiseFingerprintInitializerPreservesEveryField() {
        let fingerprint = RawFileFingerprint(
            device: 1,
            inode: 2,
            mode: 3,
            logicalByteCount: 4,
            modificationSeconds: 5,
            modificationNanoseconds: 6,
            changeSeconds: 7,
            changeNanoseconds: 8
        )

        #expect(fingerprint == RawFileFingerprint(
            device: 1,
            inode: 2,
            mode: 3,
            logicalByteCount: 4,
            modificationSeconds: 5,
            modificationNanoseconds: 6,
            changeSeconds: 7,
            changeNanoseconds: 8
        ))
    }
}

private enum RawHashSupport {
    static func open(_ url: URL, flags: Int32 = O_RDONLY) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    static func setModificationTime(
        _ url: URL,
        to timestamp: ComparisonModificationTimestamp
    ) throws {
        var times = [
            timespec(tv_sec: Int(timestamp.seconds), tv_nsec: Int(timestamp.nanoseconds)),
            timespec(tv_sec: Int(timestamp.seconds), tv_nsec: Int(timestamp.nanoseconds))
        ]
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return times.withUnsafeMutableBufferPointer { buffer in
                Darwin.utimensat(AT_FDCWD, path, buffer.baseAddress, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class RawHashFixture: @unchecked Sendable {
    let directory: TemporaryDirectory
    let url: URL
    let contents: Data
    let descriptor: Int32
    let fingerprint: RawFileFingerprint
    let hasher: LiveRawFileHasher
    let scriptedDriver: ScriptedReadDriver?
    private let descriptorOwner: OwnedDescriptor
    private let mutation = OnceMutation()

    init(
        contents: Data,
        chunkSize: Int = 4_096,
        modificationTimestamp: ComparisonModificationTimestamp? = nil,
        permissions: Int? = nil
    ) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "raw.bin")
        try contents.write(to: url)
        if let modificationTimestamp {
            try RawHashSupport.setModificationTime(url, to: modificationTimestamp)
        }
        if let permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }
        let descriptor = try RawHashSupport.open(url)
        self.directory = directory
        self.url = url
        self.contents = contents
        self.descriptor = descriptor
        descriptorOwner = OwnedDescriptor(descriptor)
        fingerprint = try RawFileFingerprint(descriptor: descriptor)
        hasher = LiveRawFileHasher()
        scriptedDriver = nil
    }

    func mutateDuringProgress(_ mutation: @escaping @Sendable () throws -> Void) {
        self.mutation.set(mutation)
    }

    func runPendingMutation() async {
        do {
            try mutation.runOnce()
        } catch {
            Issue.record("Unexpected mutation failure: \(error)")
        }
    }

    func runPendingMutationSync() {
        do {
            try mutation.runOnce()
        } catch {
            Issue.record("Unexpected mutation failure: \(error)")
        }
    }

    func appendByte(_ byte: UInt8) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Issue.record("Unable to open fixture for appending")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([byte]))
        } catch {
            Issue.record("Unexpected append failure: \(error)")
        }
    }

    func setModificationTime(_ timestamp: ComparisonModificationTimestamp) throws {
        try RawHashSupport.setModificationTime(url, to: timestamp)
    }

    func setPermissions(_ permissions: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func closeDescriptor() {
        descriptorOwner.close()
    }

    deinit {
        descriptorOwner.close()
        directory.remove()
    }
}

private final class OwnedDescriptor: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        _ = Darwin.close(descriptor)
    }
}

private final class OnceMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () throws -> Void)?
    private var hasRun = false

    func set(_ operation: @escaping @Sendable () throws -> Void) {
        lock.lock()
        self.operation = operation
        lock.unlock()
    }

    func runOnce() throws {
        let operation: (@Sendable () throws -> Void)?
        lock.lock()
        guard !hasRun else {
            lock.unlock()
            return
        }
        hasRun = true
        operation = self.operation
        self.operation = nil
        lock.unlock()
        try operation?()
    }
}

private final class ScriptedReadDriver: RawFileReadDriving, @unchecked Sendable {
    enum Step: Sendable {
        case data([UInt8])
        case end
        case interrupt
        case failure(POSIXErrorCode)
        case oversized(Int)
    }

    private let lock = NSLock()
    private var scripts: [Int32: [Step]]
    private var calls: [Int32] = []

    init(scripts: [Int32: [Step]]) {
        self.scripts = scripts
    }

    var recordedCalls: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func read(
        descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> RawFileReadResult {
        lock.lock()
        calls.append(descriptor)
        guard var queue = scripts[descriptor], !queue.isEmpty else {
            lock.unlock()
            return .bytes(0)
        }
        let step = queue.removeFirst()
        scripts[descriptor] = queue
        lock.unlock()

        switch step {
        case .end:
            return .bytes(0)
        case .interrupt:
            return .interrupted
        case .failure(let code):
            return .failed(code)
        case .oversized(let count):
            return .bytes(count)
        case .data(let bytes):
            let count = min(bytes.count, buffer.count)
            bytes.prefix(count).copyBytes(to: buffer.bindMemory(to: UInt8.self))
            return .bytes(count)
        }
    }
}

private final class GatedReadDriver: RawFileReadDriving, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let gatedDescriptor: Int32
    private var started = false
    private var callCount = 0

    init(gatedDescriptor: Int32) {
        self.gatedDescriptor = gatedDescriptor
    }

    var isFirstReadStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var readCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func open() {
        gate.signal()
    }

    func read(
        descriptor: Int32,
        into _: UnsafeMutableRawBufferPointer
    ) -> RawFileReadResult {
        lock.lock()
        callCount += 1
        let shouldWait = descriptor == gatedDescriptor && !started
        started = true
        lock.unlock()

        if shouldWait {
            gate.wait()
        }
        return .bytes(0)
    }
}

private final class PairBlockingReadDriver: RawFileReadDriving, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blockedDescriptor: Int32
    private var calls: [Int32] = []
    private var callCounts: [Int32: Int] = [:]
    private var hasBlockedReadStarted = false

    init(blockedDescriptor: Int32) {
        self.blockedDescriptor = blockedDescriptor
    }

    var didStartBlockedRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasBlockedReadStarted
    }

    var recordedCalls: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func releaseBlockedRead() {
        gate.signal()
    }

    func read(
        descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> RawFileReadResult {
        lock.lock()
        calls.append(descriptor)
        let callCount = (callCounts[descriptor] ?? 0) + 1
        callCounts[descriptor] = callCount
        let isFirstRead = callCount == 1
        if descriptor == blockedDescriptor && isFirstRead {
            hasBlockedReadStarted = true
        }
        lock.unlock()

        if descriptor == blockedDescriptor && isFirstRead {
            gate.wait()
        }
        guard isFirstRead else { return .bytes(0) }
        buffer.storeBytes(
            of: descriptor == blockedDescriptor ? UInt8(0x11) : UInt8(0x22),
            as: UInt8.self
        )
        return .bytes(1)
    }
}

private final class InterruptRetryGateDriver: RawFileReadDriving, @unchecked Sendable {
    private let firstReadGate = DispatchSemaphore(value: 0)
    private let retryReadGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callCount = 0
    private var startedFirstRead = false

    var didStartFirstRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedFirstRead
    }

    var readCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func releaseFirstRead() {
        firstReadGate.signal()
    }

    func releaseRetryRead() {
        retryReadGate.signal()
    }

    func read(
        descriptor _: Int32,
        into _: UnsafeMutableRawBufferPointer
    ) -> RawFileReadResult {
        lock.lock()
        callCount += 1
        let isFirstCall = callCount == 1
        if isFirstCall {
            startedFirstRead = true
        }
        lock.unlock()

        if isFirstCall {
            firstReadGate.wait()
            return .interrupted
        }
        retryReadGate.wait()
        return .bytes(0)
    }
}

private actor DeltaRecorder {
    private(set) var values: [Int64] = []

    func record(_ value: Int64) {
        values.append(value)
    }
}
