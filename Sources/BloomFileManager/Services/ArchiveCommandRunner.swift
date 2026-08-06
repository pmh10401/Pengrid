import Darwin
import Foundation

typealias ArchiveCommandProgressHandler = @Sendable (ArchiveOperationPhase) async -> Void
typealias ArchiveNativeProcessHandler = @Sendable (
    ArchiveOperationKind,
    ArchiveFormat,
    [String],
    Int32
) async throws -> Void

protocol ArchiveCommandRunning: Sendable {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> FileIdentity

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> FileIdentity
}

extension ArchiveCommandRunning {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> FileIdentity {
        await progress(.encoding)
        return try await run(
            kind: kind,
            format: format,
            sources: sources,
            destination: destination,
            destinationParentIdentity: destinationParentIdentity
        )
    }
}

struct LiveArchiveCommandRunner: ArchiveCommandRunning {
    private static let standardErrorLimit = 16_384
    private let fileSystem: any FileSystemAccess
    private let sourcePreparer: any ArchiveSourcePreparing
    private let nativeProcess: ArchiveNativeProcessHandler?

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        sourcePreparer: (any ArchiveSourcePreparing)? = nil
    ) {
        self.fileSystem = fileSystem
        self.sourcePreparer = sourcePreparer
            ?? LiveArchiveSourcePreparationService(fileSystem: fileSystem)
        self.nativeProcess = nil
    }

    init(
        fileSystem: any FileSystemAccess,
        sourcePreparer: any ArchiveSourcePreparing,
        nativeProcess: @escaping ArchiveNativeProcessHandler
    ) {
        self.fileSystem = fileSystem
        self.sourcePreparer = sourcePreparer
        self.nativeProcess = nativeProcess
    }

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> FileIdentity {
        try await run(
            kind: kind,
            format: format,
            sources: sources,
            destination: destination,
            destinationParentIdentity: destinationParentIdentity,
            progress: { _ in }
        )
    }

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> FileIdentity {
        let preparedCommand = try await prepareCommand(
            kind: kind,
            format: format,
            sources: sources,
            destination: destination,
            destinationParentIdentity: destinationParentIdentity,
            progress: progress
        )
        let output: OpenedEmptyFileSystemItem
        do {
            output = try await fileSystem.createEmptyItemAndCaptureIdentity(
                destination,
                kind: kind == .compress ? .regularFile : .directory,
                parentIdentifiedBy: destinationParentIdentity
            )
        } catch {
            guard await preparedCommand.cleanup(
                using: fileSystem,
                sourcePreparer: sourcePreparer
            ) == nil else {
                throw ArchiveOperationError.recoveryRequired
            }
            throw error
        }
        defer {
            if output.descriptor >= 0 {
                Darwin.close(output.descriptor)
            }
        }
        do {
            guard !Task.isCancelled else {
                throw ArchiveOperationError.cancelled
            }

            await progress(.encoding)
            try Task.checkCancellation()

            if let nativeProcess {
                try await nativeProcess(
                    kind,
                    format,
                    preparedCommand.arguments,
                    output.descriptor
                )
            } else {
                try await runNativeProcess(
                    kind: kind,
                    format: format,
                    arguments: preparedCommand.arguments,
                    outputDescriptor: output.descriptor
                )
            }
        } catch {
            let outputCleanupError = await cleanupOutput(
                destination,
                identity: output.identity
            )
            let preparationCleanupError = await preparedCommand.cleanup(
                using: fileSystem,
                sourcePreparer: sourcePreparer
            )
            guard outputCleanupError == nil, preparationCleanupError == nil else {
                throw ArchiveOperationError.recoveryRequired
            }
            throw error
        }
        do {
            guard try await fileSystem.identity(of: destination) == output.identity else {
                throw ArchiveOperationError.recoveryRequired
            }
        } catch {
            let outputCleanupError = await cleanupOutput(
                destination,
                identity: output.identity
            )
            let preparationCleanupError = await preparedCommand.cleanup(
                using: fileSystem,
                sourcePreparer: sourcePreparer
            )
            guard outputCleanupError == nil, preparationCleanupError == nil else {
                throw ArchiveOperationError.recoveryRequired
            }
            throw error
        }
        guard await preparedCommand.cleanup(
            using: fileSystem,
            sourcePreparer: sourcePreparer
        ) == nil else {
            throw ArchiveOperationError.recoveryRequired
        }
        return output.identity
    }

    private func runNativeProcess(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        arguments: [String],
        outputDescriptor: Int32
    ) async throws {
        let executable = format == .zip
            ? URL(filePath: "/usr/bin/ditto")
            : URL(filePath: "/usr/bin/tar")
        let boundArguments = Self.argumentsBoundToOpenedOutput(
            arguments,
            kind: kind,
            format: format
        )

        if kind == .compress {
            try await runCompressionProcess(
                executable: executable,
                arguments: boundArguments,
                outputDescriptor: outputDescriptor
            )
        } else {
            try await runExtractionProcess(
                executable: executable,
                arguments: boundArguments,
                outputDescriptor: outputDescriptor
            )
        }
    }

    private func runCompressionProcess(
        executable: URL,
        arguments: [String],
        outputDescriptor: Int32
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle(
            fileDescriptor: outputDescriptor,
            closeOnDealloc: false
        )

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
        try Self.validateProcessResult(
            status: status,
            standardError: standardError,
            cancellationRequested: runningProcess.wasCancellationRequested
        )
    }

    private func runExtractionProcess(
        executable: URL,
        arguments: [String],
        outputDescriptor: Int32
    ) async throws {
        let process: SpawnedArchiveProcess
        do {
            process = try SpawnedArchiveProcess(
                executable: executable,
                arguments: arguments,
                currentDirectoryDescriptor: outputDescriptor
            )
        } catch {
            throw ArchiveOperationError.commandLaunch(error.localizedDescription)
        }
        let standardErrorTask = Task.detached(priority: .utility) {
            captureStandardError(
                from: process.standardErrorHandle,
                limit: Self.standardErrorLimit
            )
        }
        let status = await withTaskCancellationHandler {
            await process.wait()
        } onCancel: {
            process.cancel()
        }
        let standardError = await standardErrorTask.value
        try Self.validateProcessResult(
            status: status,
            standardError: standardError,
            cancellationRequested: process.wasCancellationRequested
        )
    }

    private static func validateProcessResult(
        status: Int32,
        standardError: String,
        cancellationRequested: Bool
    ) throws {
        if Task.isCancelled || cancellationRequested {
            throw ArchiveOperationError.cancelled
        }
        guard status == 0 else {
            throw ArchiveOperationError.nonZeroTermination(
                status: status,
                standardError: standardError
            )
        }
    }

    static func argumentsBoundToOpenedOutput(
        _ arguments: [String],
        kind: ArchiveOperationKind,
        format: ArchiveFormat
    ) -> [String] {
        var result = arguments
        switch (kind, format) {
        case (.compress, .zip), (.extract, .zip):
            if !result.isEmpty {
                result[result.count - 1] = kind == .compress ? "/dev/fd/1" : "."
            }
        case (.compress, _):
            if let flag = result.firstIndex(of: "-f"), result.indices.contains(flag + 1) {
                result[flag + 1] = "-"
            }
        case (.extract, _):
            if let flag = result.firstIndex(of: "-C"), result.indices.contains(flag + 1) {
                result[flag + 1] = "."
            }
        }
        return result
    }

    private func cleanupOutput(
        _ destination: URL,
        identity: FileIdentity
    ) async -> (any Error)? {
        do {
            try await fileSystem.remove(destination, identifiedBy: identity)
            return nil
        } catch {
            return error
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
        destinationParentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveCommand {
        guard kind == .compress else {
            return try await prepareExtractionCommand(
                format: format,
                sources: sources,
                destination: destination,
                destinationParentIdentity: destinationParentIdentity
            )
        }
        let preparedSources = try await sourcePreparer.prepare(
            sources,
            beside: destination,
            parentIdentity: destinationParentIdentity,
            progress: progress
        )
        return PreparedArchiveCommand(
            arguments: Self.preparedCompressionArguments(
                format: format,
                aggregateRoot: preparedSources.root,
                destination: destination,
            ),
            preparedSources: preparedSources
        )
    }

    private func prepareExtractionCommand(
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> PreparedArchiveCommand {
        guard sources.count == 1, let source = sources.first else {
            throw ArchiveOperationError.invalidRequest
        }
        let reservation = try await fileSystem.reserveStagingDirectory(
            beside: destination,
            parentIdentifiedBy: destinationParentIdentity
        )
        var copiedEntries: [PreparedArchiveCopyEntry] = []
        do {
            // The source identity gate in the copy primitive protects against a
            // replacement, while the fingerprint gate protects against an
            // in-place mutation that races the descriptor-backed copy.
            let sourceFingerprint = try await fileSystem.fingerprint(of: source.url)
            let copiedIdentity = try await fileSystem.copyAndCaptureIdentity(
                source.url,
                identifiedBy: source.identity,
                to: reservation.item
            )
            copiedEntries.append(PreparedArchiveCopyEntry(
                url: reservation.item,
                identity: copiedIdentity
            ))
            guard try await fileSystem.identity(of: source.url) == source.identity,
                  try await fileSystem.fingerprint(of: source.url) == sourceFingerprint else {
                throw FileSystemAccessError.identityMismatch(source.url)
            }
            let arguments = try Self.arguments(
                kind: .extract,
                format: format,
                sources: [reservation.item],
                destination: destination
            )
            return PreparedArchiveCommand(
                arguments: arguments,
                reservation: reservation,
                copiedEntries: copiedEntries
            )
        } catch {
            let prepared = PreparedArchiveCommand(
                arguments: [],
                reservation: reservation,
                copiedEntries: copiedEntries
            )
            guard await prepared.cleanup(using: fileSystem) == nil else {
                throw ArchiveOperationError.recoveryRequired
            }
            throw error
        }
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
        LiveArchiveSourcePreparationService.aggregatePreparationWorkerCount(
            sourceCount: sourceCount,
            activeProcessorCount: activeProcessorCount
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
    let preparedSources: PreparedArchiveSources?
    let reservation: StagingReservation?
    let copiedEntries: [PreparedArchiveCopyEntry]

    init(
        arguments: [String],
        preparedSources: PreparedArchiveSources? = nil,
        reservation: StagingReservation? = nil,
        copiedEntries: [PreparedArchiveCopyEntry] = []
    ) {
        self.arguments = arguments
        self.preparedSources = preparedSources
        self.reservation = reservation
        self.copiedEntries = copiedEntries
    }

    func cleanup(using fileSystem: any FileSystemAccess) async -> (any Error)? {
        guard preparedSources == nil else { return nil }
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

    func cleanup(
        using fileSystem: any FileSystemAccess,
        sourcePreparer: any ArchiveSourcePreparing
    ) async -> (any Error)? {
        if let preparedSources {
            do {
                try await sourcePreparer.cleanup(preparedSources)
                return nil
            } catch {
                return error
            }
        }
        return await cleanup(using: fileSystem)
    }
}

private struct PreparedArchiveCopyEntry: Sendable {
    let url: URL
    let identity: FileIdentity
}

private final class SpawnedArchiveProcess: @unchecked Sendable {
    let standardErrorHandle: FileHandle

    private let processIdentifier: pid_t
    private let lock = NSLock()
    private var cancellationRequested = false

    init(
        executable: URL,
        arguments: [String],
        currentDirectoryDescriptor: Int32
    ) throws {
        let pipe = Pipe()
        var actions: posix_spawn_file_actions_t? = nil
        var status = posix_spawn_file_actions_init(&actions)
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        if #available(macOS 26.0, *) {
            status = posix_spawn_file_actions_addfchdir(
                &actions,
                currentDirectoryDescriptor
            )
        } else {
            status = posix_spawn_file_actions_addfchdir_np(
                &actions,
                currentDirectoryDescriptor
            )
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        status = posix_spawn_file_actions_adddup2(
            &actions,
            pipe.fileHandleForWriting.fileDescriptor,
            STDERR_FILENO
        )
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        status = posix_spawn_file_actions_addclose(
            &actions,
            pipe.fileHandleForReading.fileDescriptor
        )
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        if pipe.fileHandleForWriting.fileDescriptor != STDERR_FILENO {
            status = posix_spawn_file_actions_addclose(
                &actions,
                pipe.fileHandleForWriting.fileDescriptor
            )
            guard status == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
            }
        }

        var processIdentifier: pid_t = 0
        var argumentPointers: [UnsafeMutablePointer<CChar>?] =
            ([executable.path] + arguments).map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers where pointer != nil {
                free(pointer)
            }
        }
        status = executable.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return argumentPointers.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processIdentifier,
                    path,
                    &actions,
                    nil,
                    buffer.baseAddress,
                    environ
                )
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }

        self.processIdentifier = processIdentifier
        self.standardErrorHandle = pipe.fileHandleForReading
        try? pipe.fileHandleForWriting.close()
    }

    var wasCancellationRequested: Bool {
        lock.withLock { cancellationRequested }
    }

    func wait() async -> Int32 {
        let processIdentifier = processIdentifier
        return await Task.detached(priority: .utility) {
            var waitStatus: Int32 = 0
            while Darwin.waitpid(processIdentifier, &waitStatus, 0) < 0 {
                guard errno == EINTR else { return Int32(-1) }
            }
            let signal = waitStatus & 0x7f
            if signal == 0 {
                return (waitStatus >> 8) & 0xff
            }
            return 128 + signal
        }.value
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
            _ = Darwin.kill(processIdentifier, SIGTERM)
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
