import Darwin
import Foundation
import Testing
@testable import BloomFileManager

func archiveTestIdentity(for url: URL) -> FileIdentity {
    if let entryIdentifier = archiveTestNodeIdentifier(for: url, followsSymbolicLink: false) {
        let resolvedIdentifier = archiveTestNodeIdentifier(
            for: url,
            followsSymbolicLink: true
        ) ?? entryIdentifier
        return FileIdentity(
            entryIdentifier: entryIdentifier,
            resolvedIdentifier: resolvedIdentifier
        )
    }
    let token = "recording:\(url.standardizedFileURL.path)"
    return FileIdentity(entryIdentifier: token, resolvedIdentifier: token)
}

private func archiveTestNodeIdentifier(
    for url: URL,
    followsSymbolicLink: Bool
) -> String? {
    var information = stat()
    let inspectedURL = followsSymbolicLink ? url.resolvingSymlinksInPath() : url
    let status = inspectedURL.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else { return nil }
    return "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
}

func identifiedArchiveTestSources(_ urls: [URL]) -> [IdentifiedFileRequest] {
    urls.map { url in
        IdentifiedFileRequest(
            url: url,
            identity: archiveTestIdentity(for: url)
        )
    }
}

extension ArchiveRequest {
    init(
        kind: ArchiveOperationKind,
        verifiedSources: [URL],
        finalDestination: URL,
        progressDisplayName: String? = nil,
        format: ArchiveFormat = .zip
    ) {
        self.init(
            kind: kind,
            verifiedSources: identifiedArchiveTestSources(verifiedSources),
            finalDestination: finalDestination,
            destinationParentIdentity: archiveTestIdentity(
                for: finalDestination.deletingLastPathComponent()
            ),
            progressDisplayName: progressDisplayName,
            format: format
        )
    }
}

extension LiveArchiveCommandRunner {
    @discardableResult
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL
    ) async throws -> FileIdentity {
        try await run(
            kind: kind,
            format: format,
            sources: identifiedArchiveTestSources(sources),
            destination: destination,
            destinationParentIdentity: archiveTestIdentity(
                for: destination.deletingLastPathComponent()
            )
        )
    }

    @discardableResult
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> FileIdentity {
        try await run(
            kind: kind,
            format: format,
            sources: identifiedArchiveTestSources(sources),
            destination: destination,
            destinationParentIdentity: archiveTestIdentity(
                for: destination.deletingLastPathComponent()
            ),
            progress: progress
        )
    }
}

@MainActor
extension FileOperationController {
    /// Test-only projection of the public operation-center fields.
    ///
    /// Keep this intentionally narrow: titles, sanitized basenames, state
    /// labels, and progress detail are the only text exposed to assertions.
    var observableTextForTesting: String {
        ([activeJob].compactMap { $0 } + queuedJobs + operationHistory)
            .map {
                "\($0.title)|\($0.itemDisplayName)|\($0.state.label)|\($0.progress?.detail ?? "")"
            }
            .joined(separator: "\n")
    }
}

func archiveTestExpectNoStagingDirectories(in directory: URL) throws {
    #expect(try archiveTestStagingDirectories(in: directory).isEmpty)
}

func archiveTestStagingDirectories(in directory: URL) throws -> [URL] {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    return children.filter {
        $0.lastPathComponent.hasPrefix(".bloom-staging-")
    }
}

actor ArchiveTestEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
final class E2ERecordingArchivePasswordProvider: ArchivePasswordProviding {
    private var passwords: [String]
    private(set) var requests: [ArchivePasswordRequest] = []
    private(set) var retainedSecrets: [ArchiveSecret] = []
    private let events: ArchiveTestEventRecorder?

    init(
        passwords: [String],
        events: ArchiveTestEventRecorder? = nil
    ) {
        self.passwords = passwords
        self.events = events
    }

    var requestCount: Int { requests.count }

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        requests.append(request)
        await events?.append("prompt-\(requests.count)")
        let password = passwords.isEmpty ? "fallback-e2e-passphrase" : passwords.removeFirst()
        let secret: ArchiveSecret
        switch request.purpose {
        case .createAES256:
            secret = try ArchiveSecret.creation(password: password, confirmation: password)
        case .extract:
            secret = try ArchiveSecret.extraction(password: password)
        }
        retainedSecrets.append(secret)
        return secret
    }

    func retainedSecretAvailability() -> [Bool] {
        retainedSecrets.map { (try? $0.withUnsafeBytes { _ in }) != nil }
    }
}

@MainActor
final class E2EBlockingArchivePasswordProvider: ArchivePasswordProviding {
    private let gate: ArchiveTestPromptGate
    private let password: String
    private(set) var requests: [ArchivePasswordRequest] = []

    init(password: String, gate: ArchiveTestPromptGate) {
        self.password = password
        self.gate = gate
    }

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        requests.append(request)
        try await gate.wait()
        try Task.checkCancellation()
        return switch request.purpose {
        case .createAES256:
            try ArchiveSecret.creation(password: password, confirmation: password)
        case .extract:
            try ArchiveSecret.extraction(password: password)
        }
    }
}

actor ArchiveTestPromptGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        guard !released else { return }
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        guard !released else { return }
        released = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

struct E2ERecordingCloudMaterializer: CloudMaterializing {
    let inner: any CloudMaterializing
    let events: ArchiveTestEventRecorder

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        let result = await inner.materialize(requests, purpose: purpose, progress: progress)
        await events.append("materialization-finished")
        return result
    }
}

actor E2EFaultingArchiveSourcePreparer: ArchiveSourcePreparing {
    private let live: LiveArchiveSourcePreparationService
    private var failuresRemaining: Int

    init(fileSystem: any FileSystemAccess, failures: Int) {
        live = LiveArchiveSourcePreparationService(fileSystem: fileSystem)
        failuresRemaining = max(failures, 0)
    }

    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources {
        try await live.prepare(
            sources,
            beside: destination,
            parentIdentity: parentIdentity,
            progress: progress
        )
    }

    func cleanup(_ prepared: PreparedArchiveSources) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw E2EArchiveCleanupError.injected
        }
        try await live.cleanup(prepared)
    }
}

enum E2EArchiveCleanupError: Error {
    case injected
}
