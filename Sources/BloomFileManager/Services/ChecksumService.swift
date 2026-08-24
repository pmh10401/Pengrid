import Darwin
import Foundation

struct ChecksumRequest: Hashable, Sendable {
    let url: URL
    let fingerprint: ComparisonFingerprint
}

struct ChecksumResult: Hashable, Sendable {
    let digest: Data
}

enum ChecksumError: Error, Equatable {
    case identityChanged
    case typeChanged
    case sizeChanged
}

protocol ChecksumService: Sendable {
    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult
}

actor LiveChecksumService: ChecksumService {
    private let materializer: any CloudMaterializing
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let rawHasher: any RawFileHashing
    private let chunkSize: Int
    private let permits = AsyncPermitPool(limit: 2)

    init(
        materializer: any CloudMaterializing = LiveCloudMaterializationService(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        chunkSize: Int = 1_048_576,
        rawHasher: any RawFileHashing = LiveRawFileHasher()
    ) {
        self.materializer = materializer
        self.accessCoordinator = accessCoordinator
        self.rawHasher = rawHasher
        self.chunkSize = max(4_096, chunkSize)
    }

    init(
        materializer: any CloudMaterializing = LiveCloudMaterializationService(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        chunkSize: Int = 1_048_576,
        hasher: any RawFileHashing
    ) {
        self.init(
            materializer: materializer,
            accessCoordinator: accessCoordinator,
            chunkSize: chunkSize,
            rawHasher: hasher
        )
    }

    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        let accessLease = try accessCoordinator.acquireAccess(for: request.url)
        defer { accessLease?.finish() }
        if try request.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ChecksumError.typeChanged
        }
        let identifiedRequest = IdentifiedFileRequest(
            url: request.url,
            identity: request.fingerprint.identity
        )
        let preparation = await materializer.materialize(
            [identifiedRequest],
            purpose: .checksum,
            progress: { _ in }
        )
        guard !Task.isCancelled, !preparation.wasCancelled else {
            throw CancellationError()
        }
        guard preparation.failures.isEmpty,
              let prepared = CloudOperationRequestGate.identityPreservingPreparedRequests(
                  original: [identifiedRequest],
                  prepared: preparation.preparedRequests
              )?.first
        else {
            throw ChecksumError.identityChanged
        }
        let preparedRequest = ChecksumRequest(
            url: prepared.url,
            fingerprint: ComparisonFingerprint(
                identity: prepared.identity,
                byteSize: request.fingerprint.byteSize,
                modifiedAt: request.fingerprint.modifiedAt,
                rawModifiedAt: request.fingerprint.rawModifiedAt
            )
        )

        try await permits.acquire()
        do {
            try Task.checkCancellation()
            let descriptor = try openForChecksum(preparedRequest.url)
            defer { Darwin.close(descriptor) }

            let expected: RawFileFingerprint
            do {
                expected = try validate(
                    descriptor,
                    preparedRequest.fingerprint
                )
            } catch {
                throw mapRawHashingError(error)
            }

            let progressAccumulator = ChecksumProgressAccumulator(
                totalByteCount: expected.logicalByteCount
            )
            let digest: Data
            do {
                digest = try await rawHasher.checksum(
                    descriptor: descriptor,
                    expected: expected,
                    chunkSize: chunkSize,
                    progress: { delta in
                        let fraction = progressAccumulator.advance(by: delta)
                        guard fraction > 0 else { return }
                        await progress(fraction)
                    }
                )
            } catch {
                throw mapRawHashingError(error)
            }

            try Task.checkCancellation()
            do {
                _ = try validate(
                    descriptor,
                    preparedRequest.fingerprint,
                    matching: expected
                )
                try validateCurrentPath(
                    preparedRequest,
                    matching: expected
                )
            } catch {
                throw mapRawHashingError(error)
            }

            await progress(progressAccumulator.finish())
            await permits.release()
            return ChecksumResult(digest: digest)
        } catch {
            await permits.release()
            throw error
        }
    }
}

private final class ChecksumProgressAccumulator: @unchecked Sendable {
    private let totalByteCount: Int64
    private let lock = NSLock()
    private var completedByteCount: Int64 = 0

    init(totalByteCount: Int64) {
        self.totalByteCount = max(0, totalByteCount)
    }

    func advance(by delta: Int64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard delta > 0 else { return 0 }
        let (sum, overflowed) = completedByteCount.addingReportingOverflow(delta)
        completedByteCount = min(
            totalByteCount,
            overflowed ? Int64.max : sum
        )
        guard totalByteCount > 0 else { return 0 }
        return min(1, max(0, Double(completedByteCount) / Double(totalByteCount)))
    }

    func finish() -> Double {
        lock.lock()
        completedByteCount = totalByteCount
        lock.unlock()
        return 1
    }
}

actor AsyncPermitPool {
    private let limit: Int
    private var available: Int
    private var waiterIDs: [UUID] = []
    private var waiterHead = 0
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(limit: Int) {
        let limit = max(1, limit)
        self.limit = limit
        available = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiterIDs.append(id)
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        while waiterHead < waiterIDs.count {
            let id = waiterIDs[waiterHead]
            waiterHead += 1
            guard let continuation = continuations.removeValue(forKey: id) else { continue }
            compactWaiterIDsIfNeeded()
            continuation.resume()
            return
        }
        waiterIDs.removeAll(keepingCapacity: true)
        waiterHead = 0
        available = min(limit, available + 1)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        discardLeadingTombstones()
        continuation.resume(throwing: CancellationError())
    }

    private func discardLeadingTombstones() {
        while waiterHead < waiterIDs.count,
              continuations[waiterIDs[waiterHead]] == nil {
            waiterHead += 1
        }
        compactWaiterIDsIfNeeded()
    }

    private func compactWaiterIDsIfNeeded() {
        guard waiterHead > 0 else { return }
        if waiterHead == waiterIDs.count {
            waiterIDs.removeAll(keepingCapacity: true)
            waiterHead = 0
        } else if waiterHead >= 256, waiterHead * 2 >= waiterIDs.count {
            waiterIDs = Array(waiterIDs[waiterHead...])
            waiterHead = 0
        }
    }
}

actor ChecksumCache {
    private let limit: Int
    private var values: [ChecksumRequest: ChecksumResult] = [:]
    private var insertionOrder: [ChecksumRequest] = []

    init(limit: Int = 4_096) {
        self.limit = max(1, limit)
    }

    func value(for request: ChecksumRequest) -> ChecksumResult? {
        values[request]
    }

    func insert(_ value: ChecksumResult, for request: ChecksumRequest) {
        if values[request] == nil {
            insertionOrder.append(request)
        }
        values[request] = value
        while values.count > limit, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        values.removeAll()
        insertionOrder.removeAll()
    }

    var count: Int { values.count }
}

private func openForChecksum(_ url: URL) throws -> Int32 {
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
        if errno == ELOOP { throw ChecksumError.typeChanged }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}

private func validateCurrentPath(
    _ request: ChecksumRequest,
    matching expected: RawFileFingerprint
) throws {
    let descriptor = try openForChecksum(request.url)
    defer { Darwin.close(descriptor) }
    _ = try validate(descriptor, request.fingerprint, matching: expected)
}

private func validate(
    _ descriptor: Int32,
    _ fingerprint: ComparisonFingerprint,
    matching expected: RawFileFingerprint? = nil
) throws -> RawFileFingerprint {
    let actual = try RawFileFingerprint(descriptor: descriptor)
    guard actual.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
        throw ChecksumError.typeChanged
    }

    let identity = "\(actual.device):\(actual.inode)"
    guard identity == fingerprint.identity.entryIdentifier else {
        throw ChecksumError.identityChanged
    }
    guard let expectedSize = fingerprint.byteSize,
          actual.logicalByteCount == expectedSize else {
        throw ChecksumError.sizeChanged
    }

    let rawModifiedAt = ComparisonModificationTimestamp(
        seconds: actual.modificationSeconds,
        nanoseconds: actual.modificationNanoseconds
    )
    guard let expectedRawModifiedAt = fingerprint.rawModifiedAt,
          rawModifiedAt == expectedRawModifiedAt else {
        throw ChecksumError.identityChanged
    }

    if let expected, actual != expected {
        if actual.mode & UInt32(S_IFMT) != expected.mode & UInt32(S_IFMT) {
            throw ChecksumError.typeChanged
        }
        if actual.device != expected.device || actual.inode != expected.inode {
            throw ChecksumError.identityChanged
        }
        if actual.logicalByteCount != expected.logicalByteCount {
            throw ChecksumError.sizeChanged
        }
        throw ChecksumError.identityChanged
    }
    return actual
}

private func mapRawHashingError(_ error: Error) -> Error {
    guard let error = error as? RawFileHashingError else { return error }
    switch error {
    case .notRegularFile:
        return ChecksumError.typeChanged
    case .descriptorIdentityChanged:
        return ChecksumError.identityChanged
    case .logicalSizeChanged:
        return ChecksumError.sizeChanged
    case .stabilityChanged:
        return ChecksumError.identityChanged
    case .invalidChunkSize, .invalidReadResult, .readFailed:
        return error
    }
}
