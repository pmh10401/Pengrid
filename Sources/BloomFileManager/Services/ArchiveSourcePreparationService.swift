import Foundation

protocol ArchiveSourcePreparing: Sendable {
    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources

    func cleanup(_ prepared: PreparedArchiveSources) async throws
}

struct PreparedArchiveSources: Sendable {
    let root: URL
    let reservation: StagingReservation
    let copiedEntries: [PreparedArchiveSourceEntry]
}

struct PreparedArchiveSourceEntry: Sendable {
    let url: URL
    let identity: FileIdentity
}

struct LiveArchiveSourcePreparationService: ArchiveSourcePreparing {
    private let fileSystem: any FileSystemAccess

    init(fileSystem: any FileSystemAccess = LiveFileSystemAccess()) {
        self.fileSystem = fileSystem
    }

    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources {
        guard !sources.isEmpty else {
            throw ArchiveOperationError.invalidRequest
        }

        var selectedNames: Set<String> = []
        for source in sources {
            let name = source.url.lastPathComponent
            guard !name.isEmpty, selectedNames.insert(name).inserted else {
                throw ArchiveOperationError.invalidRequest
            }
        }

        let reservation = try await fileSystem.reserveStagingDirectory(
            beside: destination,
            parentIdentifiedBy: parentIdentity
        )
        let copied = PreparedArchiveSourceCopyState()
        do {
            try await prepareAggregateSource(
                sources: sources,
                aggregateRoot: reservation.directory,
                copied: copied,
                progress: progress
            )
            try Task.checkCancellation()
        } catch {
            let prepared = PreparedArchiveSources(
                root: reservation.directory,
                reservation: reservation,
                copiedEntries: await copied.entries
            )
            do {
                try await cleanup(prepared)
            } catch {
                throw ArchiveOperationError.recoveryRequired
            }
            throw error
        }

        return PreparedArchiveSources(
            root: reservation.directory,
            reservation: reservation,
            copiedEntries: await copied.entries
        )
    }

    func cleanup(_ prepared: PreparedArchiveSources) async throws {
        var firstError: (any Error)?
        for entry in prepared.copiedEntries.reversed() {
            do {
                try await fileSystem.remove(entry.url, identifiedBy: entry.identity)
            } catch {
                firstError = firstError ?? error
            }
        }
        do {
            try await fileSystem.removeStagingDirectory(prepared.reservation)
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
    }

    static func aggregatePreparationWorkerCount(
        sourceCount: Int,
        activeProcessorCount: Int
    ) -> Int {
        min(4, max(1, activeProcessorCount), sourceCount)
    }

    private func prepareAggregateSource(
        sources: [IdentifiedFileRequest],
        aggregateRoot: URL,
        copied: PreparedArchiveSourceCopyState,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws {
        let queue = ArchiveSourceCopyWorkQueue(count: sources.count)
        let reporter = ArchivePreparationProgressReporter(
            total: sources.count,
            handler: progress
        )
        let workerCount = Self.aggregatePreparationWorkerCount(
            sourceCount: sources.count,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        )

        await reporter.begin()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while true {
                        await reporter.checkpoint()
                        guard let index = await queue.nextIndex() else { return }
                        try Task.checkCancellation()
                        let source = sources[index]
                        guard try await fileSystem.identity(of: source.url) == source.identity else {
                            throw FileSystemAccessError.identityMismatch(source.url)
                        }
                        let before = try await fileSystem.fingerprint(of: source.url)
                        let destination = aggregateRoot.appending(
                            path: source.url.lastPathComponent
                        )
                        let copiedIdentity = try await fileSystem.copyAndCaptureIdentity(
                            source.url,
                            identifiedBy: source.identity,
                            to: destination
                        )
                        await copied.append(url: destination, identity: copiedIdentity)
                        guard try await fileSystem.identity(of: source.url) == source.identity,
                              try await fileSystem.fingerprint(of: source.url) == before else {
                            throw FileSystemAccessError.identityMismatch(source.url)
                        }
                        await reporter.completeOne()
                    }
                }
            }

            do {
                while try await group.next() != nil {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

private actor ArchivePreparationProgressReporter {
    private let total: Int
    private let handler: ArchiveCommandProgressHandler
    private var completed = 0
    private var lastEnqueuedCompletedCount: Int?
    private var pending: [ArchiveOperationPhase] = []
    private var isDelivering = false

    init(total: Int, handler: @escaping ArchiveCommandProgressHandler) {
        self.total = max(total, 0)
        self.handler = handler
    }

    func begin() async {
        await enqueueProgress()
    }

    func completeOne() async {
        completed = min(completed + 1, total)
        await enqueueProgress()
    }

    func checkpoint() async {
        await enqueueProgress()
    }

    private func enqueueProgress() async {
        guard lastEnqueuedCompletedCount != completed else { return }
        lastEnqueuedCompletedCount = completed
        let phase = ArchiveOperationPhase.preparingSources(
            completedCount: completed,
            totalCount: total
        )
        pending.append(phase)
        guard !isDelivering else { return }
        isDelivering = true
        while !pending.isEmpty {
            let next = pending.removeFirst()
            await handler(next)
        }
        isDelivering = false
    }
}

private actor ArchiveSourceCopyWorkQueue {
    private let count: Int
    private var next = 0

    init(count: Int) {
        self.count = count
    }

    func nextIndex() -> Int? {
        guard next < count else { return nil }
        defer { next += 1 }
        return next
    }
}

private actor PreparedArchiveSourceCopyState {
    private(set) var entries: [PreparedArchiveSourceEntry] = []

    func append(url: URL, identity: FileIdentity) {
        entries.append(PreparedArchiveSourceEntry(url: url, identity: identity))
    }
}
