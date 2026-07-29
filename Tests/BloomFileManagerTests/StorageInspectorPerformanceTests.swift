import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite(.serialized)
struct StorageInspectorPerformanceTests {
    @Test(.timeLimit(.minutes(1)))
    func oneHundredThousandEntriesCompleteWithinBoundedTime() async throws {
        let fixture = try StoragePerformanceFixture(
            entryCount: 100_000,
            batchSize: 256,
            stallAfterBatchCount: nil
        )
        fixture.store.enter()

        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }

        #expect(await waitForPerformanceTaskCompletion(scan))
        #expect(fixture.generatedEntryCount == 100_000)
        #expect(fixture.store.entries.count == 100_000)
        #expect(fixture.store.phase == .complete)
        #expect(fixture.publishedBatchSizes.count == 391)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeScanCancellationAfterProgressiveBatchesIsPrompt() async throws {
        let fixture = try StoragePerformanceFixture(
            entryCount: 100_000,
            batchSize: 256,
            stallAfterBatchCount: 2
        )
        fixture.store.enter()
        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        #expect(await fixture.waitForPublishedBatchCount(2))
        #expect(await fixture.waitForEntryCount(atLeast: 512))

        let clock = ContinuousClock()
        let started = clock.now
        fixture.store.cancel()
        #expect(started.duration(to: clock.now) < .milliseconds(250))

        #expect(await waitForPerformanceTaskCompletion(scan))
        #expect(fixture.store.phase == .cancelled)
        #expect(await fixture.waitForCancellation())
        #expect(fixture.publishedBatchSizes == [256, 256])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationAfterPartialFingerprintStartRejectsLateHashOutput() async throws {
        let fixture = try StorageHashCancellationFixture(blockedStage: .partial)
        fixture.store.enter()
        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        #expect(await fixture.waitForBlockedStageStart())
        let statesBeforeCancellation = fixture.store.verificationStates

        fixture.store.cancel()
        await fixture.releaseBlockedStage()

        #expect(await waitForPerformanceTaskCompletion(scan))
        #expect(await fixture.waitForBlockedStageReturn())
        #expect(fixture.store.phase == .cancelled)
        #expect(fixture.store.verificationStates == statesBeforeCancellation)
        #expect(fixture.store.duplicateGroups.isEmpty)
        #expect(await fixture.checksumStartCount == 0)
        #expect(await fixture.liveFingerprintReadCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationAfterFullChecksumStartRejectsLateHashOutput() async throws {
        let fixture = try StorageHashCancellationFixture(blockedStage: .full)
        fixture.store.enter()
        let scan = Task {
            await fixture.store.requestScan(at: fixture.root, options: .init())
        }
        #expect(await fixture.waitForBlockedStageStart())
        let statesBeforeCancellation = fixture.store.verificationStates

        fixture.store.cancel()
        await fixture.releaseBlockedStage()

        #expect(await waitForPerformanceTaskCompletion(scan))
        #expect(await fixture.waitForBlockedStageReturn())
        #expect(fixture.store.phase == .cancelled)
        #expect(fixture.store.verificationStates == statesBeforeCancellation)
        #expect(fixture.store.duplicateGroups.isEmpty)
        #expect(await fixture.partialStartCount >= 2)
        #expect(await fixture.liveFingerprintReadCount == 0)
    }
}

@MainActor
private struct StoragePerformanceFixture {
    let store: StorageAnalysisStore
    let root: URL
    private let scanner: GeneratedStorageScanner

    init(
        entryCount: Int,
        batchSize: Int,
        stallAfterBatchCount: Int?
    ) throws {
        root = URL(
            filePath: "/generated-storage-performance",
            directoryHint: .isDirectory
        )
        scanner = try GeneratedStorageScanner(
            root: root,
            entryCount: entryCount,
            batchSize: batchSize,
            stallAfterBatchCount: stallAfterBatchCount
        )
        store = StorageAnalysisStore(
            scanner: scanner,
            duplicates: EmptyPerformanceDuplicateDetector(),
            locationPolicy: PerformanceLocationPolicy()
        )
    }

    var generatedEntryCount: Int {
        scanner.generatedEntryCount
    }

    var publishedBatchSizes: [Int] {
        scanner.publishedBatchSizes
    }

    func waitForEntryCount(atLeast count: Int) async -> Bool {
        await waitForPerformanceCondition {
            store.entries.count >= count
        }
    }

    func waitForPublishedBatchCount(_ count: Int) async -> Bool {
        await waitForPerformanceCondition {
            scanner.publishedBatchSizes.count >= count
        }
    }

    func waitForCancellation() async -> Bool {
        await waitForPerformanceCondition {
            scanner.didCancel
        }
    }
}

private final class GeneratedStorageScanner: StorageScanning, @unchecked Sendable {
    private struct State {
        var publishedBatchSizes: [Int] = []
        var didCancel = false
    }

    private let root: URL
    private let entries: [StorageEntry]
    private let batchSize: Int
    private let stallAfterBatchCount: Int?
    private let gate = PerformanceReleaseGate()
    private let state = PerformanceLockedState(State())

    init(
        root: URL,
        entryCount: Int,
        batchSize: Int,
        stallAfterBatchCount: Int?
    ) throws {
        self.root = root
        self.batchSize = batchSize
        self.stallAfterBatchCount = stallAfterBatchCount
        entries = try (0 ..< entryCount).map { index in
            let name = "generated-\(index).bin"
            return StorageEntry(
                relativePath: try StorageRelativePath(components: [name]),
                url: root.appending(path: name, directoryHint: .notDirectory),
                kind: .regularFile,
                category: .other,
                fingerprint: ComparisonFingerprint(
                    identity: FileIdentity(
                        entryIdentifier: "generated-entry-\(index)",
                        resolvedIdentifier: "generated-resolved-\(index)"
                    ),
                    byteSize: Int64(index + 1),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
                    rawModifiedAt: ComparisonModificationTimestamp(
                        seconds: 1,
                        nanoseconds: Int64(index)
                    )
                ),
                typeDescription: "Data"
            )
        }
    }

    var generatedEntryCount: Int {
        entries.count
    }

    var publishedBatchSizes: [Int] {
        state.withValue { $0.publishedBatchSizes }
    }

    var didCancel: Bool {
        state.withValue { $0.didCancel }
    }

    func identity(of requestedRoot: URL) async throws -> FileIdentity {
        guard requestedRoot == root else {
            throw PerformanceFixtureError.unexpectedRoot
        }
        return FileIdentity(
            entryIdentifier: "generated-root",
            resolvedIdentifier: "generated-root"
        )
    }

    func batches(
        for request: StorageScanRequest
    ) -> AsyncThrowingStream<StorageScanBatch, Error> {
        let entries = entries
        let batchSize = batchSize
        let stallAfterBatchCount = stallAfterBatchCount
        let gate = gate
        let state = state
        return AsyncThrowingStream { continuation in
            let producer = Task {
                for offset in stride(
                    from: 0,
                    to: entries.count,
                    by: batchSize
                ) {
                    let end = min(offset + batchSize, entries.count)
                    let records = entries[offset ..< end].map(StorageScanRecord.entry)
                    state.withValue {
                        $0.publishedBatchSizes.append(records.count)
                    }
                    continuation.yield(StorageScanBatch(records: records))
                    if let stallAfterBatchCount,
                       state.withValue({ $0.publishedBatchSizes.count })
                            >= stallAfterBatchCount {
                        await gate.wait()
                        if Task.isCancelled {
                            state.withValue { $0.didCancel = true }
                        }
                        continuation.finish()
                        return
                    }
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
                Task {
                    await gate.release()
                }
            }
        }
    }
}

private actor PerformanceReleaseGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiting = continuations
        continuations = []
        waiting.forEach { $0.resume() }
    }
}

private struct EmptyPerformanceDuplicateDetector: StorageDuplicateDetecting {
    func events(
        for _: [StorageEntry]
    ) -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private struct PerformanceLocationPolicy: StorageScanLocationValidating {
    func decision(for root: URL) -> StorageScanLocationDecision {
        let identity = root.path.contains("hash-cancellation")
            ? "hash-root"
            : "generated-root"
        return .allowed(StorageScanAdmissionToken(
            root: root.standardizedFileURL,
            rootIdentity: FileIdentity(
                entryIdentifier: identity,
                resolvedIdentifier: identity
            ),
            rootKind: .directory,
            volumeClassification: .local,
            authorization: .init(
                isProtectedLocation: false,
                protectedScanAuthorized: true,
                cleanupAuthorized: true
            )
        ))
    }
}

private final class PerformanceLockedState<Value>: @unchecked Sendable {
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

private enum PerformanceFixtureError: Error {
    case unexpectedRoot
}

@MainActor
private struct StorageHashCancellationFixture {
    enum Stage {
        case partial
        case full
    }

    let store: StorageAnalysisStore
    let root: URL
    private let blockedStage: Stage
    private let partials: BlockingPerformancePartialFingerprinter
    private let checksums: BlockingPerformanceChecksumService
    private let fingerprints: RecordingPerformanceFingerprintReader

    init(blockedStage: Stage) throws {
        self.blockedStage = blockedStage
        let fixtureRoot = URL(
            filePath: "/generated-storage-hash-cancellation",
            directoryHint: .isDirectory
        )
        root = fixtureRoot
        let entries = try (0 ..< 2).map { index in
            let name = "candidate-\(index).bin"
            return StorageEntry(
                relativePath: try StorageRelativePath(components: [name]),
                url: fixtureRoot.appending(path: name, directoryHint: .notDirectory),
                kind: .regularFile,
                category: .other,
                fingerprint: ComparisonFingerprint(
                    identity: FileIdentity(
                        entryIdentifier: "hash-entry-\(index)",
                        resolvedIdentifier: "hash-resolved-\(index)"
                    ),
                    byteSize: 4_096,
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
                    rawModifiedAt: ComparisonModificationTimestamp(
                        seconds: 10,
                        nanoseconds: Int64(index)
                    )
                ),
                typeDescription: "Data"
            )
        }
        partials = BlockingPerformancePartialFingerprinter(
            blocks: blockedStage == .partial
        )
        checksums = BlockingPerformanceChecksumService(
            entries: entries,
            blocks: blockedStage == .full
        )
        fingerprints = RecordingPerformanceFingerprintReader(entries: entries)
        let detector = LiveStorageDuplicateDetectionService(
            partials: partials,
            checksums: checksums,
            fingerprints: fingerprints
        )
        store = StorageAnalysisStore(
            scanner: LiteralPerformanceScanner(root: root, entries: entries),
            duplicates: detector,
            locationPolicy: PerformanceLocationPolicy()
        )
    }

    var partialStartCount: Int {
        get async { await partials.startCount }
    }

    var checksumStartCount: Int {
        get async { await checksums.startCount }
    }

    var liveFingerprintReadCount: Int {
        get async { await fingerprints.readCount }
    }

    func waitForBlockedStageStart() async -> Bool {
        await waitForPerformanceAsyncCondition {
            switch blockedStage {
            case .partial:
                await partials.startCount >= 1
            case .full:
                await checksums.startCount >= 1
            }
        }
    }

    func waitForBlockedStageReturn() async -> Bool {
        await waitForPerformanceAsyncCondition {
            switch blockedStage {
            case .partial:
                await partials.returnCount >= 1
            case .full:
                await checksums.returnCount >= 1
            }
        }
    }

    func releaseBlockedStage() async {
        switch blockedStage {
        case .partial:
            await partials.release()
        case .full:
            await checksums.release()
        }
    }
}

private actor BlockingPerformancePartialFingerprinter: StoragePartialFingerprinting {
    private let blocks: Bool
    private let gate = PerformanceReleaseGate()
    private(set) var startCount = 0
    private(set) var returnCount = 0

    init(blocks: Bool) {
        self.blocks = blocks
    }

    func fingerprint(
        for _: StorageEntry,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> StoragePartialFingerprint {
        startCount += 1
        if blocks {
            await gate.wait()
        }
        await progress(1)
        returnCount += 1
        return StoragePartialFingerprint(digest: Data([0x11]))
    }

    func release() async {
        await gate.release()
    }
}

private actor BlockingPerformanceChecksumService: ChecksumService {
    private let paths: Set<URL>
    private let blocks: Bool
    private let gate = PerformanceReleaseGate()
    private(set) var startCount = 0
    private(set) var returnCount = 0

    init(entries: [StorageEntry], blocks: Bool) {
        paths = Set(entries.map(\.url))
        self.blocks = blocks
    }

    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        guard paths.contains(request.url) else {
            throw PerformanceFixtureError.unexpectedRoot
        }
        startCount += 1
        if blocks {
            await gate.wait()
        }
        await progress(1)
        returnCount += 1
        return ChecksumResult(digest: Data([0x22]))
    }

    func release() async {
        await gate.release()
    }
}

private actor RecordingPerformanceFingerprintReader: StorageEntryFingerprintReading {
    private let fingerprints: [URL: ComparisonFingerprint]
    private(set) var readCount = 0

    init(entries: [StorageEntry]) {
        fingerprints = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.url, $0.fingerprint)
        })
    }

    func fingerprint(of url: URL) async throws -> ComparisonFingerprint {
        readCount += 1
        guard let fingerprint = fingerprints[url] else {
            throw PerformanceFixtureError.unexpectedRoot
        }
        return fingerprint
    }
}

private struct LiteralPerformanceScanner: StorageScanning {
    let root: URL
    let entries: [StorageEntry]

    func identity(of requestedRoot: URL) async throws -> FileIdentity {
        guard requestedRoot == root else {
            throw PerformanceFixtureError.unexpectedRoot
        }
        return FileIdentity(
            entryIdentifier: "hash-root",
            resolvedIdentifier: "hash-root"
        )
    }

    func batches(
        for request: StorageScanRequest
    ) -> AsyncThrowingStream<StorageScanBatch, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StorageScanBatch(
                records: entries.map(StorageScanRecord.entry)
            ))
            continuation.finish()
        }
    }
}

@MainActor
private func waitForPerformanceCondition(
    timeout: Duration = .seconds(10),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func waitForPerformanceAsyncCondition(
    timeout: Duration = .seconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

private func waitForPerformanceTaskCompletion(
    _ task: Task<Void, Never>,
    timeout: Duration = .seconds(10)
) async -> Bool {
    let completed = PerformanceLockedState(false)
    Task {
        await task.value
        completed.withValue { $0 = true }
    }
    return await waitForPerformanceAsyncCondition(timeout: timeout) {
        completed.withValue { $0 }
    }
}
