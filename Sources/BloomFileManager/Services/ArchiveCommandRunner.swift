import Foundation

protocol ArchiveCommandRunning: Sendable {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL
    ) async throws
}

struct LiveArchiveCommandRunner: ArchiveCommandRunning {
    private static let standardErrorLimit = 16_384

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL
    ) async throws {
        let preparedCommand = try Self.prepareCommand(
            kind: kind,
            format: format,
            sources: sources,
            destination: destination
        )
        defer { preparedCommand.cleanup() }
        guard !Task.isCancelled else {
            throw ArchiveOperationError.cancelled
        }

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

    private static func prepareCommand(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL
    ) throws -> PreparedArchiveCommand {
        guard kind == .compress else {
            let arguments = try arguments(
                kind: kind,
                format: format,
                sources: sources,
                destination: destination
            )
            if format != .zip {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            }
            return PreparedArchiveCommand(
                arguments: arguments
            )
        }
        guard !sources.isEmpty else {
            throw ArchiveOperationError.invalidRequest
        }

        let aggregateRoot = destination
            .deletingLastPathComponent()
            .appending(
                path: ".archive-source-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        do {
            try FileManager.default.createDirectory(
                at: aggregateRoot,
                withIntermediateDirectories: false
            )
            var selectedNames: Set<String> = []
            for source in sources {
                try Task.checkCancellation()
                let name = source.lastPathComponent
                guard !name.isEmpty, selectedNames.insert(name).inserted else {
                    throw ArchiveOperationError.invalidRequest
                }
                try FileManager.default.copyItem(
                    at: source,
                    to: aggregateRoot.appending(path: name)
                )
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: aggregateRoot)
            throw error
        }

        return PreparedArchiveCommand(
            arguments: compressionArguments(
                sourcePaths: [aggregateRoot.path],
                destination: destination,
                keepParent: false,
                format: format
            ),
            aggregateRoot: aggregateRoot
        )
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

private struct PreparedArchiveCommand {
    let arguments: [String]
    let aggregateRoot: URL?

    init(arguments: [String], aggregateRoot: URL? = nil) {
        self.arguments = arguments
        self.aggregateRoot = aggregateRoot
    }

    func cleanup() {
        guard let aggregateRoot else { return }
        try? FileManager.default.removeItem(at: aggregateRoot)
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
