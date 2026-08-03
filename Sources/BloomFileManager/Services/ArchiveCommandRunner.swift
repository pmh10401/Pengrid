import Foundation

typealias ArchiveCommandProgressHandler = @Sendable (ArchiveOperationPhase) async -> Void

protocol ArchiveCommandRunning: Sendable {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL
    ) async throws

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws
}

extension ArchiveCommandRunning {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws {
        await progress(.encoding)
        try await run(
            kind: kind,
            format: format,
            sources: sources,
            destination: destination
        )
    }
}

struct LiveArchiveCommandRunner: ArchiveCommandRunning {
    private static let standardErrorLimit = 16_384
    private let fileSystem: any FileSystemAccess

    init(fileSystem: any FileSystemAccess = LiveFileSystemAccess()) {
        self.fileSystem = fileSystem
    }

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL
    ) async throws {
        try await run(
            kind: kind,
            format: format,
            sources: sources,
            destination: destination,
            progress: { _ in }
        )
    }

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws {
        let preparedCommand = try await prepareCommand(
            kind: kind,
            format: format,
            sources: sources,
            destination: destination,
            progress: progress
        )
        do {
            guard !Task.isCancelled else {
                throw ArchiveOperationError.cancelled
            }

            await progress(.encoding)
            try Task.checkCancellation()

            let process = Process()
            process.executableURL = format == .zip
                ? URL(filePath: "/usr/bin/ditto")
                : URL(filePath: "/usr/bin/tar")
            process.arguments = preparedCommand.arguments

            let standardErrorPipe = Pipe()
            process.standardError = standardErrorPipe

            let terminationLatch = ProcessTerminationLatch()
            process.terminationHandler = { process in
                terminationLatch.record(process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                throw ArchiveOperationError.commandLaunch(error.localizedDescription)
            }

            let runningProcess = RunningArchiveProcess(process)
            let standardErrorTask = Task.detached(priority: .utility) {
                captureStandardError(
                    from: standardErrorPipe.fileHandleForReading,
                    limit: Self.standardErrorLimit
                )
            }
            let status = await withTaskCancellationHandler {
                await terminationLatch.wait()
            } onCancel: {
                runningProcess.cancel()
            }
            let standardError = await standardErrorTask.value

            if Task.isCancelled || runningProcess.wasCancellationRequested {
                throw ArchiveOperationError.cancelled
            }
            guard status == 0 else {
                throw ArchiveOperationError.nonZeroTermination(
                    status: status,
                    standardError: standardError
                )
            }
        } catch {
            guard await preparedCommand.cleanup(using: fileSystem) == nil else {
                throw ArchiveOperationError.recoveryRequired
            }
            throw error
        }
        guard await preparedCommand.cleanup(using: fileSystem) == nil else {
            throw ArchiveOperationError.recoveryRequired
        }
    }

    static func arguments(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL
    ) throws -> [String] {
        guard !sources.isEmpty else {
            throw ArchiveOperationError.invalidRequest
        }

        switch (kind, format) {
        case (.compress, .zip):
            guard sources.count == 1 else {
                throw ArchiveOperationError.invalidRequest
            }
            return compressionArguments(
                sourcePaths: sources.map(\.path),
                destination: destination,
                keepParent: true
            )
        case (.extract, .zip):
            guard sources.count == 1 else {
                throw ArchiveOperationError.invalidRequest
            }
            return ["-x", "-k", sources[0].path, destination.path]
        case (.compress, let format):
            guard sources.count == 1 else {
                throw ArchiveOperationError.invalidRequest
            }
            return ["-c"] + tarCompressionArguments(for: format) + [
                "-f", destination.path,
                "-C", sources[0].path,
                "."
            ]
        case (.extract, let format):
            guard sources.count == 1 else {
                throw ArchiveOperationError.invalidRequest
            }
            return ["-x"] + tarCompressionArguments(for: format) + [
                "-k",
                "-f", sources[0].path,
                "-C", destination.path
            ]
        }
    }

    private func prepareCommand(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveCommand {
        guard kind == .compress else {
            let arguments = try Self.arguments(
                kind: kind,
                format: format,
                sources: sources.map(\.url),
                destination: destination
            )
            if format != .zip {
                try await fileSystem.createDirectory(destination)
            }
            return PreparedArchiveCommand(
                arguments: arguments
            )
        }
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

        let aggregateParent = destination.deletingLastPathComponent()
        guard let aggregateParentIdentity = try await fileSystem.identity(
            of: aggregateParent
        ) else {
            throw FileSystemAccessError.identityMismatch(aggregateParent)
        }
        let reservation = try await fileSystem.reserveStagingDirectory(
            beside: destination,
            parentIdentifiedBy: aggregateParentIdentity
        )
        let aggregateRoot = reservation.directory
        let copied = PreparedArchiveCopyState()
        do {
            try await prepareAggregateSource(
                sources: sources,
                aggregateRoot: aggregateRoot,
                copied: copied,
                progress: progress
            )
            try Task.checkCancellation()
        } catch {
            let prepared = PreparedArchiveCommand(
                arguments: [],
                reservation: reservation,
                copiedEntries: await copied.entries
            )
            guard await prepared.cleanup(using: fileSystem) == nil else {
                throw ArchiveOperationError.recoveryRequired
            }
            throw error
        }

        return PreparedArchiveCommand(
            arguments: Self.preparedCompressionArguments(
                format: format,
                aggregateRoot: aggregateRoot,
                destination: destination,
            ),
            reservation: reservation,
            copiedEntries: await copied.entries
        )
    }

    static func preparedCompressionArguments(
        format: ArchiveFormat,
        aggregateRoot: URL,
        destination: URL
    ) -> [String] {
        compressionArguments(
            sourcePaths: [aggregateRoot.path],
            destination: destination,
            keepParent: false,
            format: format
        )
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
        copied: PreparedArchiveCopyState,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws {
        let queue = ArchiveCopyWorkQueue(count: sources.count)
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

    private static func compressionArguments(
        sourcePaths: [String],
        destination: URL,
        keepParent: Bool,
        format: ArchiveFormat = .zip
    ) -> [String] {
        guard format == .zip else {
            return ["-c"] + tarCompressionArguments(for: format) + [
                "-f", destination.path,
                "-C", sourcePaths[0],
                "."
            ]
        }
        var arguments = ["-c", "-k"]
        if keepParent {
            arguments.append("--keepParent")
        }
        arguments.append("--sequesterRsrc")
        arguments.append(contentsOf: sourcePaths)
        arguments.append(destination.path)
        return arguments
    }

    private static func tarCompressionArguments(for format: ArchiveFormat) -> [String] {
        format.tarCompressionFlag.map { [$0] } ?? []
    }
}

private actor ArchivePreparationProgressReporter {
    private let total: Int
    private let handler: ArchiveCommandProgressHandler
    private var completed = 0
    private var pending: [ArchiveOperationPhase] = []
    private var isDelivering = false

    init(total: Int, handler: @escaping ArchiveCommandProgressHandler) {
        self.total = max(total, 0)
        self.handler = handler
    }

    func begin() async {
        await enqueue(.preparingSources(completedCount: 0, totalCount: total))
    }

    func completeOne() async {
        completed = min(completed + 1, total)
        await enqueue(.preparingSources(
            completedCount: completed,
            totalCount: total
        ))
    }

    func checkpoint() async {
        await handler(.preparingSources(
            completedCount: completed,
            totalCount: total
        ))
    }

    private func enqueue(_ phase: ArchiveOperationPhase) async {
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

private actor ArchiveCopyWorkQueue {
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

private struct PreparedArchiveCommand {
    let arguments: [String]
    let reservation: StagingReservation?
    let copiedEntries: [PreparedArchiveCopyEntry]

    init(
        arguments: [String],
        reservation: StagingReservation? = nil,
        copiedEntries: [PreparedArchiveCopyEntry] = []
    ) {
        self.arguments = arguments
        self.reservation = reservation
        self.copiedEntries = copiedEntries
    }

    func cleanup(using fileSystem: any FileSystemAccess) async -> (any Error)? {
        guard let reservation else { return nil }
        var firstError: (any Error)?
        for entry in copiedEntries.reversed() {
            do {
                try await fileSystem.remove(entry.url, identifiedBy: entry.identity)
            } catch {
                firstError = firstError ?? error
            }
        }
        do {
            try await fileSystem.removeStagingDirectory(reservation)
        } catch {
            firstError = firstError ?? error
        }
        return firstError
    }
}

private struct PreparedArchiveCopyEntry: Sendable {
    let url: URL
    let identity: FileIdentity
}

private actor PreparedArchiveCopyState {
    private(set) var entries: [PreparedArchiveCopyEntry] = []

    func append(url: URL, identity: FileIdentity) {
        entries.append(PreparedArchiveCopyEntry(url: url, identity: identity))
    }
}

private final class RunningArchiveProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancellationRequested = false

    init(_ process: Process) {
        self.process = process
    }

    var wasCancellationRequested: Bool {
        lock.withLock { cancellationRequested }
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class ProcessTerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func record(_ status: Int32) {
        let waiter = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            self.status = status
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = lock.withLock { () -> Int32? in
                if let recordedStatus = self.status { return recordedStatus }
                waiter = continuation
                return nil
            }
            if let status {
                continuation.resume(returning: status)
            }
        }
    }
}

private func captureStandardError(from handle: FileHandle, limit: Int) -> String {
    defer { try? handle.close() }

    var captured = Data()
    var wasTruncated = false
    while true {
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 4_096) ?? Data()
        } catch {
            break
        }
        guard !chunk.isEmpty else { break }

        let remainingCapacity = max(0, limit - captured.count)
        if remainingCapacity > 0 {
            captured.append(chunk.prefix(remainingCapacity))
        }
        if chunk.count > remainingCapacity {
            wasTruncated = true
        }
    }

    var text = String(decoding: captured, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if wasTruncated {
        text += "…"
    }
    return text
}
