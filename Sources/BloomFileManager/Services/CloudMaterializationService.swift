import Darwin
import Foundation

struct CloudMaterializationProgress: Sendable, Equatable {
    let completedCount: Int
    let totalCount: Int
    let currentName: String
}

protocol CloudMaterializing: Sendable {
    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult
}

struct CloudMaterializationResult: Sendable, Equatable {
    let preparedRequests: [IdentifiedFileRequest]
    let failures: [CloudMaterializationFailure]
    let wasCancelled: Bool

    var isReady: Bool {
        !wasCancelled && failures.isEmpty && !preparedRequests.isEmpty
    }
}

struct CloudMaterializationFailure: Sendable, Equatable {
    let name: String
    let reason: CloudAvailabilityFailure
}

protocol CloudReadCoordinating: Sendable {
    func coordinateReading(
        at url: URL,
        expectedIdentity: FileIdentity,
        kind: CloudCoordinatedReadKind
    ) async throws
}

actor LiveCloudReadCoordinator: CloudReadCoordinating {
    private let beforeAccessor: @Sendable (URL) -> Void

    init(beforeAccessor: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.beforeAccessor = beforeAccessor
    }

    func coordinateReading(
        at url: URL,
        expectedIdentity: FileIdentity,
        kind: CloudCoordinatedReadKind
    ) async throws {
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let coordinatorBox = CloudFileCoordinatorBox(coordinator)
        let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                coordinator.coordinate(with: [intent], queue: queue) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        do {
                            try coordinatorBox.checkCancellation()
                            self.beforeAccessor(intent.url)
                            try Self.readAllBytes(
                                at: intent.url,
                                expectedIdentity: expectedIdentity,
                                kind: kind,
                                cancellation: coordinatorBox
                            )
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            coordinatorBox.cancel()
        }
        try Task.checkCancellation()
    }

    private static func readAllBytes(
        at url: URL,
        expectedIdentity: FileIdentity,
        kind: CloudCoordinatedReadKind,
        cancellation: CloudFileCoordinatorBox
    ) throws {
        let flags = O_RDONLY | O_NOFOLLOW | (kind == .regularFile ? 0 : O_DIRECTORY)
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let identity = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
        let type = information.st_mode & S_IFMT
        let expectedType: mode_t = kind == .regularFile ? S_IFREG : S_IFDIR
        guard identity == expectedIdentity.entryIdentifier, type == expectedType else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        guard kind == .regularFile else { return }

        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try cancellation.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 { continue }
            if count == 0 { return }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum CloudCoordinatedReadKind: Sendable, Equatable {
    case regularFile
    case directory
}

private final class CloudFileCoordinatorBox: @unchecked Sendable {
    private let coordinator: NSFileCoordinator
    private let lock = NSLock()
    private var isCancelled = false

    init(_ coordinator: NSFileCoordinator) {
        self.coordinator = coordinator
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        coordinator.cancel()
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
    }
}

struct LiveCloudMaterializationService: CloudMaterializing {
    private let fileSystem: any FileSystemAccess
    private let availabilityReader: any CloudItemAvailabilityReading
    private let coordinator: any CloudReadCoordinating
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let maximumPollAttempts: Int
    private let pollInterval: Duration

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        coordinator: any CloudReadCoordinating = LiveCloudReadCoordinator(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        maximumPollAttempts: Int = 600,
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.fileSystem = fileSystem
        self.availabilityReader = availabilityReader
        self.coordinator = coordinator
        self.accessCoordinator = accessCoordinator
        self.maximumPollAttempts = max(maximumPollAttempts, 1)
        self.pollInterval = pollInterval
    }

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        var prepared: [IdentifiedFileRequest] = []
        var failures: [CloudMaterializationFailure] = []

        for (index, request) in requests.enumerated() {
            if Task.isCancelled {
                return cancelledResult()
            }

            do {
                prepared.append(try await prepareWithScopedAccess(request, purpose: purpose))
            } catch is CancellationError {
                return cancelledResult()
            } catch let error as CloudPreparationError {
                failures.append(CloudMaterializationFailure(
                    name: displayName(for: request.url),
                    reason: error.reason
                ))
            } catch {
                failures.append(CloudMaterializationFailure(
                    name: displayName(for: request.url),
                    reason: categorize(error)
                ))
            }

            if Task.isCancelled {
                return cancelledResult()
            }
            await progress(CloudMaterializationProgress(
                completedCount: index + 1,
                totalCount: requests.count,
                currentName: displayName(for: request.url)
            ))
            if Task.isCancelled {
                return cancelledResult()
            }
        }

        return CloudMaterializationResult(
            preparedRequests: prepared,
            failures: failures,
            wasCancelled: false
        )
    }

    private func prepareWithScopedAccess(
        _ request: IdentifiedFileRequest,
        purpose: CloudPreparationPurpose
    ) async throws -> IdentifiedFileRequest {
        let lease = try accessCoordinator.acquireAccess(for: request.url)
        defer { lease?.finish() }
        return try await prepare(request, purpose: purpose)
    }

    private func prepare(
        _ request: IdentifiedFileRequest,
        purpose: CloudPreparationPurpose
    ) async throws -> IdentifiedFileRequest {
        try Task.checkCancellation()
        _ = try await requireIdentity(request.identity, at: request.url)
        let values = try request.url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey
        ])

        if case .transfer = purpose {
            if values.isDirectory == true,
               values.isPackage != true,
               values.isSymbolicLink != true {
                return try await prepareDirectory(request)
            }
        }

        let kind: CloudCoordinatedReadKind = values.isDirectory == true ? .directory : .regularFile
        try await materializeLeaf(
            request.url,
            expectedIdentity: request.identity,
            expectedKind: values.isPackage == true ? .package
                : (values.isDirectory == true ? .directory : .regularFile),
            coordinatedKind: kind
        )
        let finalIdentity = try await requireIdentity(request.identity, at: request.url)
        return IdentifiedFileRequest(url: request.url, identity: finalIdentity)
    }

    private func prepareDirectory(
        _ request: IdentifiedFileRequest
    ) async throws -> IdentifiedFileRequest {
        try await materializeLeaf(
            request.url,
            expectedIdentity: request.identity,
            expectedKind: .directory,
            coordinatedKind: .directory
        )
        _ = try await requireIdentity(request.identity, at: request.url)

        let initial = try await directoryManifest(at: request.url)
        for target in initial.materializationTargets {
            try Task.checkCancellation()
            try await materializeLeaf(
                target.url,
                expectedIdentity: target.identity,
                expectedKind: target.kind,
                coordinatedKind: target.kind == .regularFile ? .regularFile : .directory
            )
        }

        let finalIdentity = try await requireIdentity(request.identity, at: request.url)
        let final = try await directoryManifest(at: request.url)
        guard initial.entries == final.entries else {
            throw CloudPreparationError(.itemChanged)
        }
        return IdentifiedFileRequest(url: request.url, identity: finalIdentity)
    }

    private func materializeLeaf(
        _ url: URL,
        expectedIdentity: FileIdentity? = nil,
        expectedKind: CloudDirectoryManifest.Entry.Kind? = nil,
        coordinatedKind: CloudCoordinatedReadKind = .regularFile
    ) async throws {
        try Task.checkCancellation()
        try await requireTarget(
            at: url,
            expectedIdentity: expectedIdentity,
            expectedKind: expectedKind
        )
        let initialAvailability = await availabilityReader.availability(of: url)
        switch initialAvailability {
        case .availableLocally:
            return
        case let .unavailable(reason):
            throw CloudPreparationError(reason)
        case .onlineOnly, .downloading, .unknown:
            break
        }

        try Task.checkCancellation()
        try await requireTarget(
            at: url,
            expectedIdentity: expectedIdentity,
            expectedKind: expectedKind
        )
        do {
            guard let expectedIdentity else {
                throw CloudPreparationError(.itemChanged)
            }
            try await coordinator.coordinateReading(
                at: url,
                expectedIdentity: expectedIdentity,
                kind: coordinatedKind
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudPreparationError(categorize(error))
        }
        try await requireTarget(
            at: url,
            expectedIdentity: expectedIdentity,
            expectedKind: expectedKind
        )
        if case .unknown = initialAvailability {
            return
        }

        for attempt in 0..<maximumPollAttempts {
            try Task.checkCancellation()
            switch await availabilityReader.availability(of: url) {
            case .availableLocally:
                try await requireTarget(
                    at: url,
                    expectedIdentity: expectedIdentity,
                    expectedKind: expectedKind
                )
                return
            case let .unavailable(reason):
                throw CloudPreparationError(reason)
            case .onlineOnly, .downloading, .unknown:
                break
            }

            if attempt + 1 < maximumPollAttempts, pollInterval > .zero {
                try await Task.sleep(for: pollInterval)
            }
        }
        throw CloudPreparationError(.providerFailure)
    }

    private func requireTarget(
        at url: URL,
        expectedIdentity: FileIdentity?,
        expectedKind: CloudDirectoryManifest.Entry.Kind?
    ) async throws {
        if let expectedIdentity {
            _ = try await requireIdentity(expectedIdentity, at: url)
        }
        if let expectedKind {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isPackageKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            let actualKind: CloudDirectoryManifest.Entry.Kind
            if values.isSymbolicLink == true {
                actualKind = .symbolicLink
            } else if values.isPackage == true {
                actualKind = .package
            } else if values.isDirectory == true {
                actualKind = .directory
            } else if values.isRegularFile == true {
                actualKind = .regularFile
            } else {
                actualKind = .other
            }
            guard actualKind == expectedKind else {
                throw CloudPreparationError(.itemChanged)
            }
        }
    }

    private func requireIdentity(
        _ expected: FileIdentity,
        at url: URL
    ) async throws -> FileIdentity {
        guard let actual = try await fileSystem.identity(of: url), actual == expected else {
            throw CloudPreparationError(.itemChanged)
        }
        return actual
    }

    private func directoryManifest(at root: URL) async throws -> CloudDirectoryManifest {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        var pendingDirectories = [root]
        var entries: [CloudDirectoryManifest.Entry] = []
        var targets: [CloudDirectoryManifest.MaterializationTarget] = []

        while let directory = pendingDirectories.popLast() {
            try Task.checkCancellation()
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children {
                try Task.checkCancellation()
                let normalizedChild = child.standardizedFileURL
                let values = try normalizedChild.resourceValues(forKeys: keys)
                let kind: CloudDirectoryManifest.Entry.Kind
                if values.isSymbolicLink == true {
                    kind = .symbolicLink
                } else if values.isPackage == true {
                    kind = .package
                } else if values.isDirectory == true {
                    kind = .directory
                    pendingDirectories.append(normalizedChild)
                } else if values.isRegularFile == true {
                    kind = .regularFile
                } else {
                    kind = .other
                }
                guard var identity = try await fileSystem.identity(of: normalizedChild) else {
                    throw CloudPreparationError(.itemChanged)
                }
                if kind == .symbolicLink {
                    identity = FileIdentity(
                        entryIdentifier: identity.entryIdentifier,
                        resolvedIdentifier: identity.entryIdentifier
                    )
                }
                entries.append(.init(
                    relativePath: try relativePath(of: normalizedChild, under: root),
                    identity: identity,
                    kind: kind
                ))
                if kind == .regularFile || kind == .package {
                    targets.append(.init(
                        url: normalizedChild,
                        identity: identity,
                        kind: kind
                    ))
                }
            }
        }

        return CloudDirectoryManifest(
            entries: entries.sorted { $0.relativePath < $1.relativePath },
            materializationTargets: targets.sorted { $0.url.path < $1.url.path }
        )
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidate = url.standardizedFileURL.pathComponents
        guard candidate.count > rootComponents.count,
              candidate.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            throw CloudPreparationError(.itemChanged)
        }
        return candidate.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func categorize(_ error: any Error) -> CloudAvailabilityFailure {
        if let preparationError = error as? CloudPreparationError {
            return preparationError.reason
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.Code.fileWriteOutOfSpace.rawValue:
                return .insufficientLocalStorage
            case CocoaError.Code.fileReadNoPermission.rawValue,
                 CocoaError.Code.fileWriteNoPermission.rawValue:
                return .permissionDenied
            default:
                break
            }
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case URLError.notConnectedToInternet.rawValue,
                 URLError.networkConnectionLost.rawValue,
                 URLError.dataNotAllowed.rawValue:
                return .offline
            default:
                break
            }
        }
        if error is FileSystemAccessError {
            return .itemChanged
        }
        return .providerFailure
    }

    private func displayName(for url: URL) -> String {
        url.lastPathComponent.isEmpty ? "Item" : url.lastPathComponent
    }

    private func cancelledResult() -> CloudMaterializationResult {
        CloudMaterializationResult(
            preparedRequests: [],
            failures: [],
            wasCancelled: true
        )
    }
}

private struct CloudPreparationError: Error {
    let reason: CloudAvailabilityFailure

    init(_ reason: CloudAvailabilityFailure) {
        self.reason = reason
    }
}

private struct CloudDirectoryManifest {
    struct Entry: Equatable {
        enum Kind: Equatable {
            case directory
            case regularFile
            case symbolicLink
            case package
            case other
        }

        let relativePath: String
        let identity: FileIdentity
        let kind: Kind
    }

    struct MaterializationTarget {
        let url: URL
        let identity: FileIdentity
        let kind: Entry.Kind
    }

    let entries: [Entry]
    let materializationTargets: [MaterializationTarget]
}
