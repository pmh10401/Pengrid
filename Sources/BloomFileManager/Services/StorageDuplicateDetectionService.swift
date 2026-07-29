import CryptoKit
import Darwin
import Foundation

struct StoragePartialFingerprint: Hashable, Sendable {
    let digest: Data
}

protocol StoragePartialFingerprinting: Sendable {
    func fingerprint(
        for entry: StorageEntry,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> StoragePartialFingerprint
}

actor LiveStoragePartialFingerprintService: StoragePartialFingerprinting {
    private let sampleSize: Int
    private let permits: AsyncPermitPool

    init(sampleSize: Int = 65_536, concurrencyLimit: Int = 2) {
        self.sampleSize = max(1, sampleSize)
        permits = AsyncPermitPool(limit: concurrencyLimit)
    }

    func fingerprint(
        for entry: StorageEntry,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> StoragePartialFingerprint {
        try await permits.acquire()
        do {
            let sampleSize = sampleSize
            let worker = Task.detached(priority: .utility) {
                try await storagePartialFingerprint(
                    for: entry,
                    sampleSize: sampleSize,
                    progress: progress
                )
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            await permits.release()
            return result
        } catch {
            await permits.release()
            throw error
        }
    }
}

enum StorageDuplicateDetectionEvent: Sendable {
    case state(StorageRelativePath, StorageVerificationState)
    case group(StorageDuplicateGroup)
    case excluded(StorageRelativePath, StorageVerificationState)
}

protocol StorageDuplicateDetecting: Sendable {
    func events(for entries: [StorageEntry])
        -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error>
}

enum StorageDuplicateWorkerStage: Hashable, Sendable {
    case partial
    case full
    case live
}

protocol StorageDuplicateWorkerObserving: Sendable {
    func workerStarted(stage: StorageDuplicateWorkerStage) async
    func workerFinished(stage: StorageDuplicateWorkerStage) async
}

protocol StorageDuplicateEventBufferObserving: Sendable {
    func eventEnqueued(remainingCapacity: Int) async
    func eventBackpressured(isCritical: Bool) async
}

private struct NoopStorageDuplicateWorkerObserver: StorageDuplicateWorkerObserving {
    func workerStarted(stage _: StorageDuplicateWorkerStage) async {}
    func workerFinished(stage _: StorageDuplicateWorkerStage) async {}
}

private struct NoopStorageDuplicateEventBufferObserver:
    StorageDuplicateEventBufferObserving {
    func eventEnqueued(remainingCapacity _: Int) async {}
    func eventBackpressured(isCritical _: Bool) async {}
}

actor LiveStorageDuplicateDetectionService: StorageDuplicateDetecting {
    private let partials: any StoragePartialFingerprinting
    private let checksums: any ChecksumService
    private let fingerprints: any StorageEntryFingerprintReading
    private let workerObserver: any StorageDuplicateWorkerObserving
    private let eventBufferCapacity: Int
    private let eventBufferObserver: any StorageDuplicateEventBufferObserving

    init(
        partials: any StoragePartialFingerprinting = LiveStoragePartialFingerprintService(),
        checksums: any ChecksumService = LiveChecksumService(),
        fingerprints: any StorageEntryFingerprintReading =
            LiveStorageEntryFingerprintReader(),
        workerObserver: any StorageDuplicateWorkerObserving =
            NoopStorageDuplicateWorkerObserver(),
        eventBufferCapacity: Int = 32,
        eventBufferObserver: any StorageDuplicateEventBufferObserving =
            NoopStorageDuplicateEventBufferObserver()
    ) {
        self.partials = partials
        self.checksums = checksums
        self.fingerprints = fingerprints
        self.workerObserver = workerObserver
        self.eventBufferCapacity = max(1, eventBufferCapacity)
        self.eventBufferObserver = eventBufferObserver
    }

    nonisolated func events(for entries: [StorageEntry])
        -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error> {
        let partials = partials
        let checksums = checksums
        let fingerprints = fingerprints
        let workerObserver = workerObserver
        let eventBufferCapacity = eventBufferCapacity
        let eventBufferObserver = eventBufferObserver
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(eventBufferCapacity)
        ) { continuation in
            let task = Task {
                do {
                    try await detectStorageDuplicates(
                        entries: entries,
                        partials: partials,
                        checksums: checksums,
                        fingerprints: fingerprints,
                        workerObserver: workerObserver,
                        eventBufferObserver: eventBufferObserver,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private enum StorageDuplicateEventDelivery {
    case transient
    case critical
}

private func yieldStorageDuplicateEvent(
    _ event: StorageDuplicateDetectionEvent,
    delivery: StorageDuplicateEventDelivery,
    observer: any StorageDuplicateEventBufferObserving,
    continuation: AsyncThrowingStream<StorageDuplicateDetectionEvent, Error>.Continuation
) async throws {
    let isCritical = delivery == .critical
    while true {
        try Task.checkCancellation()
        switch continuation.yield(event) {
        case let .enqueued(remainingCapacity):
            await observer.eventEnqueued(remainingCapacity: remainingCapacity)
            return
        case .dropped:
            await observer.eventBackpressured(isCritical: isCritical)
            guard isCritical else { return }
            try await Task.sleep(for: .milliseconds(1))
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw CancellationError()
        }
    }
}

private struct StoragePartialGroupKey: Hashable, Sendable {
    let byteSize: Int64
    let digest: Data
}

private enum StoragePartialOutcome: Sendable {
    case success(StorageEntry, StoragePartialFingerprint)
    case excluded(StorageEntry, StorageVerificationState)
    case cancelled
}

private enum StorageChecksumOutcome: Sendable {
    case success(StorageEntry, ChecksumResult)
    case excluded(StorageEntry, StorageVerificationState)
    case cancelled
}

private enum StorageLiveFingerprintOutcome: Sendable {
    case current(StorageEntry)
    case excluded(StorageEntry, StorageVerificationState)
    case cancelled
}

private actor StorageDuplicateCandidateQueue<Element: Sendable> {
    private let candidates: [Element]
    private var index = 0

    init(_ candidates: [Element]) {
        self.candidates = candidates
    }

    func next() -> Element? {
        guard index < candidates.count else { return nil }
        defer { index += 1 }
        return candidates[index]
    }
}

private func runStorageDuplicateWorkers<Input: Sendable, Output: Sendable>(
    candidates: [Input],
    stage: StorageDuplicateWorkerStage,
    observer: any StorageDuplicateWorkerObserving,
    operation: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    guard !candidates.isEmpty else { return [] }
    let queue = StorageDuplicateCandidateQueue(candidates)
    return await withTaskGroup(of: [Output].self) { group in
        for _ in 0 ..< min(2, candidates.count) {
            group.addTask {
                await observer.workerStarted(stage: stage)
                var outcomes: [Output] = []
                while !Task.isCancelled, let candidate = await queue.next() {
                    outcomes.append(await operation(candidate))
                }
                await observer.workerFinished(stage: stage)
                return outcomes
            }
        }

        var outcomes: [Output] = []
        for await workerOutcomes in group {
            outcomes.append(contentsOf: workerOutcomes)
        }
        return outcomes
    }
}

private func detectStorageDuplicates(
    entries: [StorageEntry],
    partials: any StoragePartialFingerprinting,
    checksums: any ChecksumService,
    fingerprints: any StorageEntryFingerprintReading,
    workerObserver: any StorageDuplicateWorkerObserving,
    eventBufferObserver: any StorageDuplicateEventBufferObserving,
    continuation: AsyncThrowingStream<StorageDuplicateDetectionEvent, Error>.Continuation
) async throws {
    let sizeCandidates = Dictionary(grouping: entries.filter {
        $0.kind == .regularFile && ($0.fingerprint.byteSize ?? -1) >= 0
    }) {
        $0.fingerprint.byteSize!
    }
    let partialCandidates = sizeCandidates.values
        .filter { $0.count >= 2 }
        .flatMap { $0 }
        .sorted { $0.relativePath < $1.relativePath }

    for entry in partialCandidates {
        try await yieldStorageDuplicateEvent(
            .state(entry.id, .partial(nil)),
            delivery: .transient,
            observer: eventBufferObserver,
            continuation: continuation
        )
    }

    let partialOutcomes = await runStorageDuplicateWorkers(
        candidates: partialCandidates,
        stage: .partial,
        observer: workerObserver
    ) { entry -> StoragePartialOutcome in
        do {
            let fingerprint = try await partials.fingerprint(for: entry) { value in
                guard !Task.isCancelled else { return }
                try? await yieldStorageDuplicateEvent(
                    .state(entry.id, .partial(value)),
                    delivery: .transient,
                    observer: eventBufferObserver,
                    continuation: continuation
                )
            }
            try Task.checkCancellation()
            return .success(entry, fingerprint)
        } catch {
            if error is CancellationError {
                return .cancelled
            }
            return .excluded(entry, storageVerificationState(for: error))
        }
    }
    try Task.checkCancellation()

    var partialMatches: [(StorageEntry, StoragePartialFingerprint)] = []
    for outcome in partialOutcomes {
        switch outcome {
        case let .success(entry, fingerprint):
            partialMatches.append((entry, fingerprint))
        case let .excluded(entry, state):
            try await yieldStorageDuplicateEvent(
                .excluded(entry.id, state),
                delivery: .critical,
                observer: eventBufferObserver,
                continuation: continuation
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    let partialGroups = Dictionary(grouping: partialMatches) { value in
        StoragePartialGroupKey(
            byteSize: value.0.fingerprint.byteSize!,
            digest: value.1.digest
        )
    }
    let checksumCandidates = partialGroups.values
        .filter { $0.count >= 2 }
        .flatMap { $0.map(\.0) }
        .sorted { $0.relativePath < $1.relativePath }

    let checksumOutcomes = await runStorageDuplicateWorkers(
        candidates: checksumCandidates,
        stage: .full,
        observer: workerObserver
    ) { entry -> StorageChecksumOutcome in
        do {
            let checksum = try await checksums.checksum(
                for: ChecksumRequest(
                    url: entry.url,
                    fingerprint: entry.fingerprint
                )
            ) { value in
                guard !Task.isCancelled else { return }
                try? await yieldStorageDuplicateEvent(
                    .state(entry.id, .partial(value)),
                    delivery: .transient,
                    observer: eventBufferObserver,
                    continuation: continuation
                )
            }
            try Task.checkCancellation()
            return .success(entry, checksum)
        } catch {
            if error is CancellationError {
                return .cancelled
            }
            return .excluded(entry, storageVerificationState(for: error))
        }
    }
    try Task.checkCancellation()

    var completeMatches: [(StorageEntry, ChecksumResult)] = []
    for outcome in checksumOutcomes {
        switch outcome {
        case let .success(entry, checksum):
            completeMatches.append((entry, checksum))
        case let .excluded(entry, state):
            try await yieldStorageDuplicateEvent(
                .excluded(entry.id, state),
                delivery: .critical,
                observer: eventBufferObserver,
                continuation: continuation
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    let completeGroups = Dictionary(grouping: completeMatches) { value in
        StorageDuplicateGroupID(
            byteSize: value.0.fingerprint.byteSize!,
            completeDigest: value.1.digest
        )
    }
    let duplicateCandidates = completeGroups
        .filter { $0.value.count >= 2 }
        .map { id, values in (id, values.map(\.0)) }

    var verifiedGroups: [(StorageDuplicateGroupID, [StorageEntry])] = []
    for (id, candidates) in duplicateCandidates {
        try Task.checkCancellation()
        let outcomes = await runStorageDuplicateWorkers(
            candidates: candidates,
            stage: .live,
            observer: workerObserver
        ) { entry -> StorageLiveFingerprintOutcome in
            do {
                let current = try await fingerprints.fingerprint(of: entry.url)
                try Task.checkCancellation()
                guard storageFingerprintIsCurrent(
                    captured: entry.fingerprint,
                    live: current
                ) else {
                    return .excluded(entry, .unstable)
                }
                return .current(entry)
            } catch {
                if error is CancellationError {
                    return .cancelled
                }
                return .excluded(entry, storageVerificationState(for: error))
            }
        }
        try Task.checkCancellation()

        var currentEntries: [StorageEntry] = []
        for outcome in outcomes {
            switch outcome {
            case let .current(entry):
                currentEntries.append(entry)
                try await yieldStorageDuplicateEvent(
                    .state(entry.id, .complete),
                    delivery: .critical,
                    observer: eventBufferObserver,
                    continuation: continuation
                )
            case let .excluded(entry, state):
                try await yieldStorageDuplicateEvent(
                    .excluded(entry.id, state),
                    delivery: .critical,
                    observer: eventBufferObserver,
                    continuation: continuation
                )
            case .cancelled:
                throw CancellationError()
            }
        }
        if currentEntries.count >= 2 {
            verifiedGroups.append((id, currentEntries))
        }
    }

    verifiedGroups.sort { lhs, rhs in
        lhs.1.map(\.relativePath).min()! < rhs.1.map(\.relativePath).min()!
    }
    for (id, entries) in verifiedGroups {
        try Task.checkCancellation()
        let members = entries.sorted { $0.relativePath < $1.relativePath }
        guard let keepID = StorageKeepRecommender.recommendedKeep(
            in: members,
            explicitKeep: nil,
            preferredFolder: nil
        ) else {
            continue
        }
        try await yieldStorageDuplicateEvent(
            .group(StorageDuplicateGroup(
                id: id,
                members: members,
                keepID: keepID,
                trashIDs: [],
                reclaimableBytes: 0
            )),
            delivery: .critical,
            observer: eventBufferObserver,
            continuation: continuation
        )
    }
}

private func storageVerificationState(for error: any Error) -> StorageVerificationState {
    if error is ChecksumError {
        return .unstable
    }
    return .unreadable(error.localizedDescription)
}

private func storageFingerprintIsCurrent(
    captured: ComparisonFingerprint,
    live: ComparisonFingerprint
) -> Bool {
    captured.identity == live.identity
        && captured.byteSize == live.byteSize
        && captured.rawModifiedAt == live.rawModifiedAt
}

private struct StorageSampleRange: Hashable, Sendable {
    let offset: Int64
    let count: Int
}

private func storagePartialFingerprint(
    for entry: StorageEntry,
    sampleSize: Int,
    progress: @escaping @Sendable (Double) async -> Void
) async throws -> StoragePartialFingerprint {
    let descriptor = try openStoragePartialFile(entry.url)
    defer { Darwin.close(descriptor) }

    try validateStoragePartialDescriptor(descriptor, fingerprint: entry.fingerprint)
    guard let byteSize = entry.fingerprint.byteSize, byteSize >= 0 else {
        throw ChecksumError.sizeChanged
    }

    var hasher = SHA256()
    var encodedByteSize = byteSize.bigEndian
    withUnsafeBytes(of: &encodedByteSize) {
        hasher.update(data: Data($0))
    }

    let ranges = storageSampleRanges(byteSize: byteSize, sampleSize: sampleSize)
    let totalSampleBytes = ranges.reduce(0) { $0 + $1.count }
    var sampledBytes = 0
    for range in ranges {
        try Task.checkCancellation()
        let data = try readStoragePartialRange(descriptor, range: range)
        hasher.update(data: data)
        sampledBytes += data.count
        await progress(min(
            1,
            Double(sampledBytes) / Double(max(1, totalSampleBytes))
        ))
    }
    if ranges.isEmpty {
        await progress(1)
    }

    try validateStoragePartialDescriptor(descriptor, fingerprint: entry.fingerprint)
    return StoragePartialFingerprint(digest: Data(hasher.finalize()))
}

private func openStoragePartialFile(_ url: URL) throws -> Int32 {
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
        if errno == ELOOP {
            throw ChecksumError.typeChanged
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}

private func validateStoragePartialDescriptor(
    _ descriptor: Int32,
    fingerprint: ComparisonFingerprint
) throws {
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard information.st_mode & S_IFMT == S_IFREG else {
        throw ChecksumError.typeChanged
    }

    let identity = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    guard identity == fingerprint.identity.entryIdentifier else {
        throw ChecksumError.identityChanged
    }
    guard let byteSize = fingerprint.byteSize,
          Int64(information.st_size) == byteSize else {
        throw ChecksumError.sizeChanged
    }

    let rawModifiedAt = ComparisonModificationTimestamp(
        seconds: Int64(information.st_mtimespec.tv_sec),
        nanoseconds: Int64(information.st_mtimespec.tv_nsec)
    )
    guard let expectedRawModifiedAt = fingerprint.rawModifiedAt,
          rawModifiedAt == expectedRawModifiedAt else {
        throw ChecksumError.identityChanged
    }
}

private func storageSampleRanges(
    byteSize: Int64,
    sampleSize: Int
) -> [StorageSampleRange] {
    guard byteSize > 0 else { return [] }
    let count = Int(min(byteSize, Int64(sampleSize)))
    let count64 = Int64(count)
    let offsets = [
        Int64(0),
        max(0, (byteSize - count64) / 2),
        max(0, byteSize - count64)
    ]
    var seen: Set<StorageSampleRange> = []
    return offsets.compactMap { offset in
        let range = StorageSampleRange(offset: offset, count: count)
        return seen.insert(range).inserted ? range : nil
    }
}

private func readStoragePartialRange(
    _ descriptor: Int32,
    range: StorageSampleRange
) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: range.count)
    var consumed = 0
    while consumed < range.count {
        try Task.checkCancellation()
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.pread(
                descriptor,
                bytes.baseAddress?.advanced(by: consumed),
                range.count - consumed,
                off_t(range.offset + Int64(consumed))
            )
        }
        if readCount > 0 {
            consumed += readCount
        } else if readCount == 0 {
            throw ChecksumError.sizeChanged
        } else if errno != EINTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    return Data(buffer)
}
