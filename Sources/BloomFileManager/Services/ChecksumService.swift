import CryptoKit
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
    private let chunkSize: Int
    private let permits = AsyncPermitPool(limit: 2)

    init(
        materializer: any CloudMaterializing = LiveCloudMaterializationService(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        chunkSize: Int = 1_048_576
    ) {
        self.materializer = materializer
        self.accessCoordinator = accessCoordinator
        self.chunkSize = max(4_096, chunkSize)
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
            let chunkSize = chunkSize
            let worker = Task.detached(priority: .utility) {
                try await streamChecksum(
                    for: preparedRequest,
                    chunkSize: chunkSize,
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

private func streamChecksum(
    for request: ChecksumRequest,
    chunkSize: Int,
    progress: @escaping @Sendable (Double) async -> Void
) async throws -> ChecksumResult {
    let descriptor = try openForChecksum(request.url)
    defer { Darwin.close(descriptor) }

    try validate(descriptor, request.fingerprint)
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var consumed: Int64 = 0

    while true {
        try Task.checkCancellation()
        let count = try readChunk(descriptor, into: &buffer)
        if count == 0 { break }
        hasher.update(data: Data(buffer[..<count]))
        consumed += Int64(count)
        let total = max(Int64(1), request.fingerprint.byteSize ?? 1)
        let fraction = min(1, max(0, Double(consumed) / Double(total)))
        await progress(fraction)
    }

    if consumed == 0 {
        await progress(1)
    }
    try validate(descriptor, request.fingerprint)
    try validateCurrentPath(request)
    return ChecksumResult(digest: Data(hasher.finalize()))
}

private func openForChecksum(_ url: URL) throws -> Int32 {
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
        if errno == ELOOP { throw ChecksumError.typeChanged }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}

private func readChunk(_ descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count >= 0 { return count }
        if errno != EINTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private func validateCurrentPath(_ request: ChecksumRequest) throws {
    let descriptor = try openForChecksum(request.url)
    defer { Darwin.close(descriptor) }
    try validate(descriptor, request.fingerprint)
}

private func validate(_ descriptor: Int32, _ fingerprint: ComparisonFingerprint) throws {
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
    guard let expectedSize = fingerprint.byteSize,
          Int64(information.st_size) == expectedSize else {
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
