import Foundation

private func clampedTransferVerificationChunkSize(_ value: Int) -> Int {
    min(max(4_096, value), 4_194_304)
}

struct TransferVerificationReceipt: @unchecked Sendable {
    let source: TransferVerificationManifest
    let staged: TransferVerificationManifest
}

struct TransferVerificationCompletion: @unchecked Sendable {
    let receipt: TransferVerificationReceipt
    let summary: TransferVerificationSummary
}

protocol TransferVerificationSessionFactory: Sendable {
    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)?
}

protocol TransferVerificationSession: Sendable {
    func captureSource(
        at url: URL,
        identifiedBy identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest

    func verify(
        source: TransferVerificationManifest,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        progress: @escaping @Sendable (TransferVerificationProgress) async -> Void
    ) async throws -> TransferVerificationCompletion

    func revalidate(_ receipt: TransferVerificationReceipt) async throws
}

struct LiveTransferVerificationSessionFactory: TransferVerificationSessionFactory {
    private let manifestBuilder: any TransferVerificationManifestBuilding
    private let hasher: any RawFileHashing
    private let chunkSize: Int
    private let onWorkerStarted: (@Sendable () -> Void)?

    init(
        manifestBuilder: any TransferVerificationManifestBuilding =
            LiveTransferVerificationManifestBuilder(),
        hasher: any RawFileHashing = LiveRawFileHasher(),
        chunkSize: Int = 1_048_576
    ) {
        self.manifestBuilder = manifestBuilder
        self.hasher = hasher
        self.chunkSize = clampedTransferVerificationChunkSize(chunkSize)
        onWorkerStarted = nil
    }

    #if DEBUG
    init(
        manifestBuilder: any TransferVerificationManifestBuilding =
            LiveTransferVerificationManifestBuilder(),
        hasher: any RawFileHashing = LiveRawFileHasher(),
        chunkSize: Int = 1_048_576,
        onWorkerStarted: (@Sendable () -> Void)?
    ) {
        self.manifestBuilder = manifestBuilder
        self.hasher = hasher
        self.chunkSize = clampedTransferVerificationChunkSize(chunkSize)
        self.onWorkerStarted = onWorkerStarted
    }
    #endif

    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)? {
        guard let pairLimit = policy.effectivePairLimit else { return nil }
        return LiveTransferVerificationSession(
            manifestBuilder: manifestBuilder,
            hasher: hasher,
            pairLimit: pairLimit,
            chunkSize: chunkSize,
            onWorkerStarted: onWorkerStarted
        )
    }
}

private struct LiveTransferVerificationSession: TransferVerificationSession {
    private let manifestBuilder: any TransferVerificationManifestBuilding
    private let hasher: any RawFileHashing
    private let pairLimit: Int
    private let chunkSize: Int
    private let permits: AsyncPermitPool
    private let onWorkerStarted: (@Sendable () -> Void)?

    init(
        manifestBuilder: any TransferVerificationManifestBuilding,
        hasher: any RawFileHashing,
        pairLimit: Int,
        chunkSize: Int,
        onWorkerStarted: (@Sendable () -> Void)?
    ) {
        self.manifestBuilder = manifestBuilder
        self.hasher = hasher
        self.pairLimit = min(max(pairLimit, 1), 2)
        self.chunkSize = clampedTransferVerificationChunkSize(chunkSize)
        permits = AsyncPermitPool(limit: min(max(pairLimit, 1), 2))
        self.onWorkerStarted = onWorkerStarted
    }

    func captureSource(
        at url: URL,
        identifiedBy identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        do {
            return try await manifestBuilder.capture(
                at: url,
                identifiedBy: identity,
                comparisonPolicy: comparisonPolicy
            )
        } catch {
            throw mapFailure(error, side: .source, safeName: nil)
        }
    }

    func verify(
        source: TransferVerificationManifest,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        progress: @escaping @Sendable (TransferVerificationProgress) async -> Void
    ) async throws -> TransferVerificationCompletion {
        let delivery = TransferVerificationProgressDelivery(handler: progress)
        await delivery.publish(
            phase: .preparingManifest,
            fraction: 0,
            completedFileCount: 0,
            totalFileCount: 0,
            completedLogicalByteCount: 0,
            totalLogicalByteCount: 0,
            currentName: ""
        )

        var hashingSource: TransferVerificationManifest?
        var initialStaged: TransferVerificationManifest?
        var finalSource: TransferVerificationManifest?
        var finalStaged: TransferVerificationManifest?
        var publishedReceipt = false
        defer {
            hashingSource?.close()
            initialStaged?.close()
            if !publishedReceipt {
                finalSource?.close()
                finalStaged?.close()
            }
        }

        do {
            try Task.checkCancellation()
            hashingSource = try await recaptureAndRequireStable(
                source,
                side: .source
            )
            guard let hashingSource else {
                throw TransferVerificationFailure(
                    category: .sourceChanged
                )
            }

            initialStaged = try await captureStaged(
                at: stagedURL,
                identity: stagedIdentity,
                comparisonPolicy: source.comparisonPolicy
            )
            guard let initialStaged else {
                throw TransferVerificationFailure(
                    category: .stagedOutputChanged
                )
            }
            try Task.checkCancellation()
            do {
                try manifestBuilder.requireEquivalentContentShape(
                    source: hashingSource,
                    staged: initialStaged
                )
            } catch {
                throw mapFailure(error, side: nil, safeName: nil)
            }

            let pairs: [TransferVerificationRegularFilePair]
            do {
                // The manifest owns the comparison and pair materialization.  In
                // particular, do not rebuild this relation through a dictionary.
                pairs = try hashingSource.regularFilePairs(matching: initialStaged)
            } catch {
                throw mapFailure(error, side: nil, safeName: nil)
            }

            await delivery.publish(
                phase: .preparingManifest,
                fraction: 1,
                completedFileCount: 0,
                totalFileCount: pairs.count,
                completedLogicalByteCount: 0,
                totalLogicalByteCount: hashingSource.logicalByteCount,
                currentName: ""
            )
            await delivery.publish(
                phase: .hashing,
                fraction: 0,
                completedFileCount: 0,
                totalFileCount: pairs.count,
                completedLogicalByteCount: 0,
                totalLogicalByteCount: hashingSource.logicalByteCount,
                currentName: ""
            )

            try await hash(
                pairs: pairs,
                source: hashingSource,
                staged: initialStaged,
                delivery: delivery
            )
            await delivery.publish(
                phase: .hashing,
                fraction: 1,
                completedFileCount: await delivery.completedFileCount,
                totalFileCount: pairs.count,
                completedLogicalByteCount: await delivery.completedLogicalByteCount,
                totalLogicalByteCount: hashingSource.logicalByteCount,
                currentName: ""
            )

            await delivery.publish(
                phase: .finalValidation,
                fraction: 0,
                completedFileCount: await delivery.completedFileCount,
                totalFileCount: pairs.count,
                completedLogicalByteCount: await delivery.completedLogicalByteCount,
                totalLogicalByteCount: hashingSource.logicalByteCount,
                currentName: ""
            )
            try Task.checkCancellation()

            finalSource = try await recaptureAndRequireStable(
                hashingSource,
                side: .source
            )
            finalStaged = try await recaptureAndRequireStable(
                initialStaged,
                side: .staged
            )
            guard let finalSource, let finalStaged else {
                throw TransferVerificationFailure(category: .structureMismatch)
            }
            do {
                try manifestBuilder.requireEquivalentContentShape(
                    source: finalSource,
                    staged: finalStaged
                )
            } catch {
                throw mapFailure(error, side: nil, safeName: nil)
            }
            try Task.checkCancellation()
            await delivery.publish(
                phase: .finalValidation,
                fraction: 1,
                completedFileCount: await delivery.completedFileCount,
                totalFileCount: pairs.count,
                completedLogicalByteCount: await delivery.completedLogicalByteCount,
                totalLogicalByteCount: finalSource.logicalByteCount,
                currentName: ""
            )
            await delivery.flush()
            try Task.checkCancellation()

            let receipt = TransferVerificationReceipt(
                source: finalSource,
                staged: finalStaged
            )
            let summary = TransferVerificationSummary(
                verifiedFileCount: pairs.count,
                verifiedLogicalByteCount: finalSource.logicalByteCount,
                noByteTransferItemCount: 0
            )
            publishedReceipt = true
            self.closeIfDistinct(hashingSource, from: finalSource)
            self.closeIfDistinct(initialStaged, from: finalStaged)
            return TransferVerificationCompletion(receipt: receipt, summary: summary)
        } catch {
            await delivery.flush()
            if let failure = error as? TransferVerificationFailure {
                throw failure
            }
            throw mapFailure(error, side: nil, safeName: nil)
        }
    }

    func revalidate(_ receipt: TransferVerificationReceipt) async throws {
        var currentSource: TransferVerificationManifest?
        var currentStaged: TransferVerificationManifest?
        defer {
            currentSource?.close()
            currentStaged?.close()
        }

        do {
            try Task.checkCancellation()
            currentSource = try await recaptureAndRequireStable(
                receipt.source,
                side: .source
            )
            currentStaged = try await recaptureAndRequireStable(
                receipt.staged,
                side: .staged
            )
            guard let currentSource, let currentStaged else {
                throw TransferVerificationFailure(category: .structureMismatch)
            }
            do {
                try manifestBuilder.requireEquivalentContentShape(
                    source: currentSource,
                    staged: currentStaged
                )
            } catch {
                throw mapFailure(error, side: nil, safeName: nil)
            }
            try Task.checkCancellation()
        } catch {
            if let failure = error as? TransferVerificationFailure {
                throw failure
            }
            throw mapFailure(error, side: nil, safeName: nil)
        }
    }

    private func captureStaged(
        at url: URL,
        identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        do {
            return try await manifestBuilder.capture(
                at: url,
                identifiedBy: identity,
                comparisonPolicy: comparisonPolicy
            )
        } catch {
            throw mapFailure(error, side: .staged, safeName: nil)
        }
    }

    private func recaptureAndRequireStable(
        _ manifest: TransferVerificationManifest,
        side: TransferVerificationFailureSide,
        safeName: String? = nil
    ) async throws -> TransferVerificationManifest {
        let resolvedSafeName = safeName
        var current: TransferVerificationManifest?
        do {
            let candidate = try await manifestBuilder.recapture(manifest)
            // A recapture is a new ownership generation.  Check this before
            // assigning it to the service-owned slot, requiring stability, or
            // closing it on an error.  A violating builder may have returned a
            // borrowed manifest that the caller still owns.
            guard !candidate.hasSameAuthority(as: manifest) else {
                throw TransferVerificationFailure(
                    category: .readFailed,
                    safeName: resolvedSafeName
                )
            }
            current = candidate
            do {
                try manifestBuilder.requireStable(candidate, against: manifest)
            } catch {
                current?.close()
                current = nil
                throw error
            }
            return candidate
        } catch {
            current?.close()
            current = nil
            if let failure = error as? TransferVerificationFailure {
                throw failure
            }
            throw mapFailure(error, side: side, safeName: resolvedSafeName)
        }
    }

    private func hash(
        pairs: [TransferVerificationRegularFilePair],
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest,
        delivery: TransferVerificationProgressDelivery
    ) async throws {
        guard !pairs.isEmpty else { return }
        let queue = TransferVerificationPairIndexQueue(count: pairs.count)
        let failureGate = TransferVerificationFailureGate()
        var rawFailures: [TransferVerificationRawWorkerFailure] = []
        let workerCount = min(pairLimit, pairs.count)
        var cancelledWorkers = false

        await withTaskGroup(of: TransferVerificationRawWorkerFailure?.self) { group in
            for _ in 0..<workerCount {
                #if DEBUG
                onWorkerStarted?()
                #endif
                group.addTask {
                    while !Task.isCancelled, !(await failureGate.hasFailed()) {
                        guard let index = await queue.next() else { return nil }
                        guard !(await failureGate.hasFailed()) else { return nil }
                        let safeName = pairs[index].source.comparisonKey.last
                        do {
                            try Task.checkCancellation()
                            try await self.hashPair(
                                pairs[index],
                                source: source,
                                staged: staged,
                                delivery: delivery,
                                safeName: safeName
                            )
                        } catch {
                            await failureGate.markFailed()
                            return TransferVerificationRawWorkerFailure(
                                index: index,
                                error: error,
                                safeName: safeName
                            )
                        }
                    }
                    return nil
                }
            }

            for await result in group {
                if let result {
                    rawFailures.append(result)
                    if !cancelledWorkers {
                        cancelledWorkers = true
                        group.cancelAll()
                    }
                }
            }
        }

        var failures: [TransferVerificationWorkerFailure] = []
        failures.reserveCapacity(rawFailures.count)
        for rawFailure in rawFailures {
            let failure = await self.mapPairFailure(
                rawFailure.error,
                safeName: rawFailure.safeName,
                source: source,
                staged: staged
            )
            failures.append(
                TransferVerificationWorkerFailure(
                    index: rawFailure.index,
                    failure: failure
                )
            )
        }

        let nonCancellationFailures = failures.filter {
            $0.failure.category != .cancelled
        }
        if let failure = (nonCancellationFailures.isEmpty ? failures : nonCancellationFailures)
            .min(by: { $0.index < $1.index }) {
            throw failure.failure
        }
        try Task.checkCancellation()
    }

    private func hashPair(
        _ pair: TransferVerificationRegularFilePair,
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest,
        delivery: TransferVerificationProgressDelivery,
        safeName: String?
    ) async throws {
        try await withPermit {
            do {
                try await pair.source.withReaderDescriptor { sourceDescriptor in
                    do {
                        try await pair.staged.withReaderDescriptor { stagedDescriptor in
                            do {
                                let digests = try await self.hasher.checksumPair(
                                    sourceDescriptor: sourceDescriptor,
                                    sourceExpected: RawFileFingerprint(
                                        device: pair.source.device,
                                        inode: pair.source.inode,
                                        mode: pair.source.mode,
                                        logicalByteCount: pair.source.logicalByteCount,
                                        modificationSeconds: pair.source.modificationSeconds,
                                        modificationNanoseconds: pair.source.modificationNanoseconds,
                                        changeSeconds: pair.source.changeSeconds,
                                        changeNanoseconds: pair.source.changeNanoseconds
                                    ),
                                    stagedDescriptor: stagedDescriptor,
                                    stagedExpected: RawFileFingerprint(
                                        device: pair.staged.device,
                                        inode: pair.staged.inode,
                                        mode: pair.staged.mode,
                                        logicalByteCount: pair.staged.logicalByteCount,
                                        modificationSeconds: pair.staged.modificationSeconds,
                                        modificationNanoseconds: pair.staged.modificationNanoseconds,
                                        changeSeconds: pair.staged.changeSeconds,
                                        changeNanoseconds: pair.staged.changeNanoseconds
                                    ),
                                    chunkSize: self.chunkSize,
                                    progress: { delta in
                                        await delivery.recordHashBytes(
                                            delta,
                                            currentName: safeName ?? ""
                                        )
                                    }
                                )
                                guard digests.source == digests.staged else {
                                    throw TransferVerificationPairContentMismatch()
                                }
                            } catch let error as TransferVerificationPairContentMismatch {
                                throw error
                            } catch {
                                throw TransferVerificationPairHashFailure(underlying: error)
                            }
                        }
                    } catch let error as TransferVerificationPairHashFailure {
                        throw error
                    } catch let error as TransferVerificationPairContentMismatch {
                        throw error
                    } catch {
                        throw TransferVerificationPairSideFailure(
                            side: .staged,
                            underlying: error
                        )
                    }
                }
            } catch let error as TransferVerificationPairHashFailure {
                throw error
            } catch let error as TransferVerificationPairContentMismatch {
                throw error
            } catch let error as TransferVerificationPairSideFailure {
                throw error
            } catch {
                throw TransferVerificationPairSideFailure(
                    side: .source,
                    underlying: error
                )
            }
        }
        await delivery.recordHashFile(currentName: safeName ?? "")
    }

    private func withPermit<T: Sendable>(
        _ body: () async throws -> T
    ) async throws -> T {
        try await permits.acquire()
        do {
            let value = try await body()
            await permits.release()
            return value
        } catch {
            await permits.release()
            throw error
        }
    }

    private func mapPairFailure(
        _ error: Error,
        safeName: String?,
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) async -> TransferVerificationFailure {
        if error is TransferVerificationPairContentMismatch {
            return TransferVerificationFailure(
                category: .contentMismatch,
                safeName: safeName
            )
        }
        if let sideFailure = error as? TransferVerificationPairSideFailure {
            return mapFailure(
                sideFailure.underlying,
                side: sideFailure.side,
                safeName: safeName
            )
        }
        if let hashFailure = error as? TransferVerificationPairHashFailure {
            return await diagnoseHashFailure(
                hashFailure.underlying,
                source: source,
                staged: staged,
                safeName: safeName
            )
        }
        return mapFailure(error, side: nil, safeName: safeName)
    }

    private func diagnoseHashFailure(
        _ error: Error,
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest,
        safeName: String?
    ) async -> TransferVerificationFailure {
        if isCancellation(error) {
            return TransferVerificationFailure(category: .cancelled)
        }

        do {
            let currentSource = try await recaptureAndRequireStable(
                source,
                side: .source,
                safeName: safeName
            )
            currentSource.close()
        } catch let sourceFailure {
            return mapFailure(sourceFailure, side: .source, safeName: safeName)
        }

        do {
            let currentStaged = try await recaptureAndRequireStable(
                staged,
                side: .staged,
                safeName: safeName
            )
            currentStaged.close()
        } catch let stagedFailure {
            return mapFailure(stagedFailure, side: .staged, safeName: safeName)
        }
        return mapFailure(error, side: nil, safeName: safeName)
    }

    private func mapFailure(
        _ error: Error,
        side: TransferVerificationFailureSide?,
        safeName: String?
    ) -> TransferVerificationFailure {
        if let failure = error as? TransferVerificationFailure {
            return failure
        }
        if isCancellation(error) {
            return TransferVerificationFailure(category: .cancelled)
        }
        if let manifestError = error as? TransferVerificationManifestError {
            switch manifestError {
            case .changed:
                return TransferVerificationFailure(
                    category: side == .staged ? .stagedOutputChanged : .sourceChanged,
                    safeName: safeName
                )
            case .structureMismatch:
                return TransferVerificationFailure(
                    category: .structureMismatch,
                    safeName: safeName
                )
            case .unsupportedItem:
                return TransferVerificationFailure(
                    category: .unsupportedItem,
                    safeName: safeName
                )
            case .unsupportedName:
                return TransferVerificationFailure(
                    category: .unsupportedName,
                    safeName: safeName
                )
            case .readFailed:
                return TransferVerificationFailure(
                    category: .readFailed,
                    safeName: safeName
                )
            case .scopeTooLarge:
                return TransferVerificationFailure(
                    category: .scopeTooLarge,
                    safeName: safeName
                )
            case .cancelled:
                return TransferVerificationFailure(category: .cancelled)
            }
        }
        if let rawError = error as? RawFileHashingError {
            switch rawError {
            case .notRegularFile, .descriptorIdentityChanged, .logicalSizeChanged,
                    .stabilityChanged, .invalidChunkSize, .invalidReadResult,
                    .readFailed:
                return TransferVerificationFailure(
                    category: .readFailed,
                    safeName: safeName
                )
            }
        }
        return TransferVerificationFailure(category: .readFailed, safeName: safeName)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError {
            return true
        }
        return (error as? TransferVerificationManifestError) == .cancelled
    }

    private func closeIfDistinct(
        _ first: TransferVerificationManifest?,
        from second: TransferVerificationManifest
    ) {
        guard let first else { return }
        guard !first.hasSameAuthority(as: second) else { return }
        first.close()
    }
}

private enum TransferVerificationFailureSide: Sendable {
    case source
    case staged
}

private struct TransferVerificationRawWorkerFailure: @unchecked Sendable {
    let index: Int
    let error: Error
    let safeName: String?
}

private struct TransferVerificationWorkerFailure: Sendable {
    let index: Int
    let failure: TransferVerificationFailure
}

private struct TransferVerificationPairHashFailure: Error, @unchecked Sendable {
    let underlying: Error
}

private struct TransferVerificationPairSideFailure: Error, @unchecked Sendable {
    let side: TransferVerificationFailureSide
    let underlying: Error
}

private struct TransferVerificationPairContentMismatch: Error, Sendable {}

private struct TransferVerificationPendingProgress {
    let progress: TransferVerificationProgress
    let continuation: CheckedContinuation<Void, Never>
}

private actor TransferVerificationPairIndexQueue {
    private let count: Int
    private var nextIndex = 0

    init(count: Int) {
        self.count = count
    }

    func next() -> Int? {
        guard nextIndex < count else { return nil }
        defer { nextIndex += 1 }
        return nextIndex
    }
}

private actor TransferVerificationFailureGate {
    private var failed = false

    func hasFailed() -> Bool { failed }

    func markFailed() {
        failed = true
    }
}

private actor TransferVerificationProgressDelivery {
    private let handler: @Sendable (TransferVerificationProgress) async -> Void
    private var pending: [TransferVerificationPendingProgress] = []
    private var pendingHead = 0
    private var isDelivering = false
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentPhase: TransferVerificationPhase?
    private var lastFraction = 0.0
    private(set) var completedFileCount = 0
    private(set) var completedLogicalByteCount: Int64 = 0
    private var totalFileCount = 0
    private var totalLogicalByteCount: Int64 = 0
    private var lastName = ""

    init(handler: @escaping @Sendable (TransferVerificationProgress) async -> Void) {
        self.handler = handler
    }

    func publish(
        phase: TransferVerificationPhase,
        fraction: Double,
        completedFileCount: Int,
        totalFileCount: Int,
        completedLogicalByteCount: Int64,
        totalLogicalByteCount: Int64,
        currentName: String
    ) async {
        if currentPhase != phase {
            currentPhase = phase
            lastFraction = 0
        }
        self.totalFileCount = max(totalFileCount, 0)
        self.totalLogicalByteCount = max(totalLogicalByteCount, 0)
        self.completedFileCount = max(completedFileCount, self.completedFileCount)
        self.completedLogicalByteCount = max(
            completedLogicalByteCount,
            self.completedLogicalByteCount
        )
        if !currentName.isEmpty { lastName = currentName }
        let progress = TransferVerificationProgress(
            phase: phase,
            fractionCompleted: max(lastFraction, fraction),
            completedFileCount: self.completedFileCount,
            totalFileCount: self.totalFileCount,
            completedLogicalByteCount: self.completedLogicalByteCount,
            totalLogicalByteCount: self.totalLogicalByteCount,
            currentName: currentName.isEmpty ? lastName : currentName
        )
        lastFraction = max(lastFraction, progress.fractionCompleted)
        await enqueue(progress)
    }

    func recordHashBytes(_ delta: Int64, currentName: String) async {
        guard delta > 0 else { return }
        let (sum, overflow) = completedLogicalByteCount.addingReportingOverflow(delta)
        completedLogicalByteCount = overflow
            ? max(totalLogicalByteCount, 0)
            : min(max(totalLogicalByteCount, 0), max(0, sum))
        let fraction: Double
        if totalLogicalByteCount > 0 {
            fraction = min(
                1,
                Double(completedLogicalByteCount) / Double(totalLogicalByteCount)
            )
        } else if totalFileCount > 0 {
            fraction = Double(completedFileCount) / Double(totalFileCount)
        } else {
            fraction = 1
        }
        await publish(
            phase: .hashing,
            fraction: fraction,
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount,
            completedLogicalByteCount: completedLogicalByteCount,
            totalLogicalByteCount: totalLogicalByteCount,
            currentName: currentName
        )
    }

    func recordHashFile(currentName: String) async {
        completedFileCount = min(totalFileCount, completedFileCount + 1)
        let fraction: Double = totalLogicalByteCount > 0
            ? min(
                1,
                Double(completedLogicalByteCount) / Double(totalLogicalByteCount)
            )
            : (totalFileCount > 0
                ? Double(completedFileCount) / Double(totalFileCount)
                : 1)
        await publish(
            phase: .hashing,
            fraction: fraction,
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount,
            completedLogicalByteCount: completedLogicalByteCount,
            totalLogicalByteCount: totalLogicalByteCount,
            currentName: currentName
        )
    }

    func flush() async {
        guard isDelivering || !pending.isEmpty else { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append(continuation)
        }
    }

    private func enqueue(_ progress: TransferVerificationProgress) async {
        guard isDelivering else {
            isDelivering = true
            await handler(progress)
            await drainPending()
            return
        }

        await withCheckedContinuation { continuation in
            pending.append(
                TransferVerificationPendingProgress(
                    progress: progress,
                    continuation: continuation
                )
            )
        }
    }

    private func drainPending() async {
        while pendingHead < pending.count {
            let next = pending[pendingHead]
            pendingHead += 1
            await handler(next.progress)
            next.continuation.resume()
        }
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        isDelivering = false
        let waiters = flushWaiters
        flushWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
