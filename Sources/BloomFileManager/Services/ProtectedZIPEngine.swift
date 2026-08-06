import Darwin
import EncryptedZIPCore
import Foundation

protocol ProtectedZIPEngine: Sendable {
    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws
}

actor LiveProtectedZIPEngine: ProtectedZIPEngine {
    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { () throws -> ProtectedZIPInspection in
            try archive.withUnsafeDescriptor { descriptor in
                var nativeInspection = pengrid_zip_inspection_t()
                let status = pengrid_zip_inspect_fd(descriptor, &nativeInspection)
                guard status == PENGRID_ZIP_STATUS_OK else {
                    throw LiveProtectedZIPEngine.error(for: status)
                }
                guard nativeInspection.entry_count <= UInt64(Int.max),
                      nativeInspection.total_uncompressed_bytes <= UInt64(Int64.max) else {
                    throw ProtectedZIPError.entryCountOverflow
                }
                return ProtectedZIPInspection(
                    entryCount: Int(nativeInspection.entry_count),
                    totalUncompressedByteCount: Int64(nativeInspection.total_uncompressed_bytes),
                    hasEncryptedEntries: nativeInspection.has_encrypted_entries != 0,
                    hasUnsupportedEncryption: nativeInspection.has_unsupported_encryption != 0,
                    hasUnsupportedCompression: nativeInspection.has_unsupported_compression != 0,
                    strongestAESStrength: LiveProtectedZIPEngine.aesBits(
                        nativeInspection.strongest_aes_strength
                    )
                )
            }
        }
        let result = try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
        try Task.checkCancellation()
        return result
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        try Task.checkCancellation()
        let nativeLimits = try Self.nativeLimits(from: limits)
        let task = Task.detached(priority: .utility) { () throws -> ProtectedZIPInspection in
            try archive.withUnsafeDescriptor { archiveDescriptor in
                var inspection = pengrid_zip_inspection_t()
                let status = pengrid_zip_preflight_fd(
                    archiveDescriptor,
                    destinationProbeRoot.descriptor,
                    nativeLimits,
                    &inspection
                )
                guard status == PENGRID_ZIP_STATUS_OK else {
                    throw LiveProtectedZIPEngine.error(for: status)
                }
                return try LiveProtectedZIPEngine.inspection(from: inspection)
            }
        }
        let result = try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
        try Task.checkCancellation()
        return result
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        defer { password.invalidate() }
        try Task.checkCancellation()

        let bridge = ProtectedZIPProgressBridge(progress: progress)
        let deliveryTask = Task {
            await bridge.consume()
        }
        let task = Task.detached(priority: .utility) { () -> ProtectedZIPNativeOutcome in
            defer { bridge.finish() }
            do {
                try sourceRoot.withUnsafeDescriptor { sourceDescriptor in
                    try password.withUnsafeBytes { secretBytes in
                        guard let baseAddress = secretBytes.baseAddress else {
                            throw ProtectedZIPError.invalidPasswordInput
                        }
                        let context = Unmanaged.passUnretained(bridge).toOpaque()
                        let status = pengrid_zip_create_aes256(
                            sourceDescriptor,
                            destination.descriptor,
                            baseAddress.assumingMemoryBound(to: UInt8.self),
                            secretBytes.count,
                            protectedZIPProgressCallback,
                            context
                        )
                        guard status == PENGRID_ZIP_STATUS_OK else {
                            throw LiveProtectedZIPEngine.error(for: status)
                        }
                    }
                }
                return .success
            } catch let error as ProtectedZIPError {
                return .failure(error)
            } catch {
                return .failure(.engineSetupFailed)
            }
        }

        let outcome = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            bridge.cancel()
            task.cancel()
        })
        _ = await deliveryTask.value
        switch outcome {
        case .success:
            break
        case .failure(let error):
            throw error
        }
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        defer { password.invalidate() }
        try Task.checkCancellation()
        let nativeLimits = try Self.nativeLimits(from: limits)
        let bridge = ProtectedZIPProgressBridge(progress: progress)
        let deliveryTask = Task {
            await bridge.consume()
        }
        let task = Task.detached(priority: .utility) { () -> ProtectedZIPNativeOutcome in
            defer { bridge.finish() }
            do {
                try archive.withUnsafeDescriptor { archiveDescriptor in
                    try password.withUnsafeBytes { secretBytes in
                        guard let baseAddress = secretBytes.baseAddress else {
                            throw ProtectedZIPError.invalidPasswordInput
                        }
                        let status = pengrid_zip_extract(
                            archiveDescriptor,
                            destinationRoot.descriptor,
                            baseAddress.assumingMemoryBound(to: UInt8.self),
                            secretBytes.count,
                            nativeLimits,
                            protectedZIPProgressCallback,
                            Unmanaged.passUnretained(bridge).toOpaque()
                        )
                        guard status == PENGRID_ZIP_STATUS_OK else {
                            throw LiveProtectedZIPEngine.error(for: status)
                        }
                    }
                }
                return .success
            } catch let error as ProtectedZIPError {
                return .failure(error)
            } catch {
                return .failure(.engineSetupFailed)
            }
        }
        let outcome = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            bridge.cancel()
            task.cancel()
        })
        _ = await deliveryTask.value
        switch outcome {
        case .success:
            break
        case .failure(let error):
            throw error
        }
    }

    private static func nativeLimits(from limits: ProtectedZIPLimits) throws -> pengrid_zip_limits_t {
        guard limits.maximumOutputByteCount >= 0 else {
            throw ProtectedZIPError.outputBudgetOverflow
        }
        guard limits.capacityReserveByteCount >= 0 else {
            throw ProtectedZIPError.insufficientCapacity
        }
        guard let maximumOutput = UInt64(exactly: limits.maximumOutputByteCount),
              let capacityReserve = UInt64(exactly: limits.capacityReserveByteCount) else {
            throw ProtectedZIPError.outputBudgetOverflow
        }
        return pengrid_zip_limits_t(
            maximum_entry_count: UInt64(ProtectedZIPLimits.maximumEntryCount),
            maximum_output_bytes: maximumOutput,
            capacity_reserve_bytes: capacityReserve
        )
    }

    private static func inspection(from native: pengrid_zip_inspection_t) throws -> ProtectedZIPInspection {
        guard native.entry_count <= UInt64(Int.max),
              native.total_uncompressed_bytes <= UInt64(Int64.max) else {
            throw ProtectedZIPError.entryCountOverflow
        }
        return ProtectedZIPInspection(
            entryCount: Int(native.entry_count),
            totalUncompressedByteCount: Int64(native.total_uncompressed_bytes),
            hasEncryptedEntries: native.has_encrypted_entries != 0,
            hasUnsupportedEncryption: native.has_unsupported_encryption != 0,
            hasUnsupportedCompression: native.has_unsupported_compression != 0,
            strongestAESStrength: LiveProtectedZIPEngine.aesBits(native.strongest_aes_strength)
        )
    }

    private static func aesBits(_ strength: UInt8) -> Int {
        switch strength {
        case 1: return 128
        case 2: return 192
        case 3: return 256
        default: return 0
        }
    }

    fileprivate static func error(for status: Int32) -> ProtectedZIPError {
        switch status {
        case PENGRID_ZIP_STATUS_INVALID_ARGUMENT:
            return .invalidPasswordInput
        case PENGRID_ZIP_STATUS_IO_ERROR:
            return .engineSetupFailed
        case PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE:
            return .malformedArchive
        case PENGRID_ZIP_STATUS_OVERFLOW:
            return .entryCountOverflow
        case PENGRID_ZIP_STATUS_CANCELLED:
            return .cancelled
        case PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY:
            return .unsafeEntry
        case PENGRID_ZIP_STATUS_UNSUPPORTED_COMPRESSION:
            return .unsupportedCompression
        case PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE:
            return .incorrectPasswordOrDamagedData
        case PENGRID_ZIP_STATUS_CAPACITY:
            return .insufficientCapacity
        case PENGRID_ZIP_STATUS_OUTPUT_BUDGET:
            return .outputBudgetOverflow
        case PENGRID_ZIP_STATUS_IDENTITY_CHANGED:
            return .identityChanged
        case PENGRID_ZIP_STATUS_UNSUPPORTED_ENCRYPTION:
            return .unsupportedEncryption
        case PENGRID_ZIP_STATUS_RECOVERY_REQUIRED:
            return .recoveryRequired
        default:
            return .engineSetupFailed
        }
    }
}

private func MZUnused<T>(_ value: T) {
    _ = value
}

private enum ProtectedZIPNativeOutcome: Sendable {
    case success
    case failure(ProtectedZIPError)
}

private struct ProtectedZIPProgressEvent: Sendable {
    let completed: UInt64
    let total: UInt64
}

private final class ProtectedZIPProgressBridge: @unchecked Sendable {
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private let wakeStream: AsyncStream<Void>
    private let progress: @Sendable (ProtectedZIPProgress) async -> Void
    private let lock = NSLock()
    private let initialDeliveryGate = DispatchSemaphore(value: 0)
    private var cancelled = false
    private var finished = false
    private var initialGateSignaled = false
    private var initialPending: ProtectedZIPProgressEvent?
    private var initialDelivered = false
    private var latestIntermediate: ProtectedZIPProgressEvent?
    private var finalPending: ProtectedZIPProgressEvent?

    init(progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void) {
        var wakeContinuation: AsyncStream<Void>.Continuation?
        wakeStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { wakeContinuation = $0 }
        self.wakeContinuation = wakeContinuation!
        self.progress = progress
    }

    func callback(completed: UInt64, total: UInt64) -> Int32 {
        var shouldAwaitInitial = false
        lock.lock()
        if !cancelled {
            let event = ProtectedZIPProgressEvent(completed: completed, total: total)
            if completed == 0 {
                if !initialDelivered, initialPending == nil {
                    initialPending = event
                    shouldAwaitInitial = true
                }
            } else if total > 0, completed >= total {
                finalPending = event
            } else {
                latestIntermediate = event
            }
        }
        let cancelled = self.cancelled
        lock.unlock()
        guard !cancelled else { return 1 }
        wakeContinuation.yield(())
        if shouldAwaitInitial {
            initialDeliveryGate.wait()
            lock.lock()
            let cancelledAfterDelivery = self.cancelled
            lock.unlock()
            return cancelledAfterDelivery ? 1 : 0
        }
        return 0
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        signalInitialGateIfNeeded()
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        wakeContinuation.yield(())
        wakeContinuation.finish()
        lock.unlock()
        // If native returned before the initial event could be delivered (for
        // example an overflow/error callback), never leave its gate blocked.
        signalInitialGateIfNeeded()
    }

    func consume() async {
        var lastDelivery: ContinuousClock.Instant?
        var lastDeliveredEvent: ProtectedZIPProgressEvent?
        var wakeIterator = wakeStream.makeAsyncIterator()
        while true {
            guard let event = nextEvent(lastDelivery: &lastDelivery, lastDeliveredEvent: &lastDeliveredEvent) else {
                if isDone() { return }
                if shouldWaitForFinalGate() {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                _ = await wakeIterator.next()
                continue
            }
            let isInitial = event.completed == 0
            guard event.completed <= UInt64(Int64.max), event.total <= UInt64(Int64.max) else {
                if isInitial {
                    // An unrepresentable initial event is dropped, but native
                    // still needs its one-shot acknowledgement immediately.
                    signalInitialGateIfNeeded()
                }
                continue
            }
            await progress(
                ProtectedZIPProgress(
                    completedByteCount: Int64(event.completed),
                    totalByteCount: Int64(event.total)
                )
            )
            if isInitial {
                // Preserve the cancellation boundary: native may continue
                // only after the caller has observed the initial callback.
                signalInitialGateIfNeeded()
            }
            lastDelivery = ContinuousClock.now
            lastDeliveredEvent = event
        }
    }

    private func signalInitialGateIfNeeded() {
        lock.lock()
        guard !initialGateSignaled else {
            lock.unlock()
            return
        }
        initialGateSignaled = true
        lock.unlock()
        initialDeliveryGate.signal()
    }

    private func nextEvent(
        lastDelivery: inout ContinuousClock.Instant?,
        lastDeliveredEvent: inout ProtectedZIPProgressEvent?
    ) -> ProtectedZIPProgressEvent? {
        lock.lock()
        defer { lock.unlock() }
        if let initialPending {
            self.initialPending = nil
            initialDelivered = true
            return initialPending
        }
        if finished {
            latestIntermediate = nil
            if let finalPending {
                if lastDeliveredEvent?.completed == finalPending.completed,
                   lastDeliveredEvent?.total == finalPending.total {
                    self.finalPending = nil
                    return nil
                }
                if let lastDelivery,
                   lastDelivery.duration(to: ContinuousClock.now) < .milliseconds(100) {
                    return nil
                }
                self.finalPending = nil
                return finalPending
            }
            return nil
        }
        guard let latestIntermediate else { return nil }
        self.latestIntermediate = nil
        if let lastDelivery,
           lastDelivery.duration(to: ContinuousClock.now) < .milliseconds(100) {
            return nil
        }
        return latestIntermediate
    }

    private func shouldWaitForFinalGate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished && finalPending != nil
    }

    private func isDone() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished && initialPending == nil && finalPending == nil && latestIntermediate == nil
    }
}

private func protectedZIPProgressCallback(
    _ completed: UInt64,
    _ total: UInt64,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 1 }
    let bridge = Unmanaged<ProtectedZIPProgressBridge>.fromOpaque(context).takeUnretainedValue()
    return bridge.callback(completed: completed, total: total)
}
