import Foundation

protocol ArchiveCommandRunning: Sendable {
    func run(
        kind: ArchiveOperationKind,
        sources: [URL],
        destination: URL
    ) async throws
}

struct LiveArchiveCommandRunner: ArchiveCommandRunning {
    private static let standardErrorLimit = 16_384

    func run(
        kind: ArchiveOperationKind,
        sources: [URL],
        destination: URL
    ) async throws {
        let arguments = try Self.arguments(
            kind: kind,
            sources: sources,
            destination: destination
        )
        guard !Task.isCancelled else {
            throw ArchiveOperationError.cancelled
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = arguments

        let standardErrorPipe = Pipe()
        process.standardError = standardErrorPipe

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
        let processWaiter = Task.detached(priority: .utility) {
            process.waitUntilExit()
            return process.terminationStatus
        }

        let status = await withTaskCancellationHandler {
            await processWaiter.value
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
        sources: [URL],
        destination: URL
    ) throws -> [String] {
        guard !sources.isEmpty else {
            throw ArchiveOperationError.invalidRequest
        }

        switch kind {
        case .compress:
            return [
                "-c",
                "-k",
                "--keepParent",
                "--sequesterRsrc"
            ] + sources.map(\.path) + [destination.path]
        case .extract:
            guard sources.count == 1 else {
                throw ArchiveOperationError.invalidRequest
            }
            return ["-x", "-k", sources[0].path, destination.path]
        }
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
