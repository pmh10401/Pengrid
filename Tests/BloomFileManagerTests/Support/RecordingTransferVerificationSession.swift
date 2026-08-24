import Foundation
@testable import BloomFileManager

/// A protocol-bound verification double for transfer integration tests.
///
/// The double deliberately keeps the manifest implementation behind the real
/// `TransferVerificationSession` boundary.  It records the filesystem event
/// snapshot observed at each callback so callers can assert that verification
/// happens after staging and before publication without changing the shared
/// `RecordingFileSystem` fixture.
enum RecordingTransferVerificationEvent: Sendable, Equatable {
    case capture(
        url: URL,
        identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy,
        filesystemEvents: [String]
    )
    case verify(
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        filesystemEvents: [String]
    )
    case revalidate(filesystemEvents: [String])
}

enum RecordingTransferVerificationPhase: Sendable {
    case capture
    case verify
    case revalidate
}

struct RecordingTransferVerificationConfiguration: @unchecked Sendable {
    var captureFailuresByCall: [Int: TransferVerificationFailureCategory] = [:]
    var verifyFailuresByCall: [Int: TransferVerificationFailureCategory] = [:]
    var revalidateFailuresByCall: [Int: TransferVerificationFailureCategory] = [:]
    var summariesByVerifyCall: [Int: TransferVerificationSummary] = [:]
    var cancellingVerifyCalls: Set<Int> = []
    var onPhase: (@Sendable (RecordingTransferVerificationPhase) async -> Void)?
}

actor RecordingTransferVerificationEventRecorder {
    private(set) var events: [RecordingTransferVerificationEvent] = []

    func append(_ event: RecordingTransferVerificationEvent) {
        events.append(event)
    }
}

/// A deterministic session factory that records every enabled-session request.
/// It intentionally returns a session even for `.disabled`, making an
/// accidental factory call observable in compatibility-path tests.
final class RecordingTransferVerificationSessionFactory:
    TransferVerificationSessionFactory,
    @unchecked Sendable
{
    let recorder: RecordingTransferVerificationEventRecorder
    let session: RecordingTransferVerificationSession

    private let lock = NSLock()
    private var recordedPolicies: [TransferVerificationPolicy] = []

    init(
        eventSource: @escaping @Sendable () async -> [String],
        recorder: RecordingTransferVerificationEventRecorder =
            RecordingTransferVerificationEventRecorder(),
        configuration: RecordingTransferVerificationConfiguration = .init()
    ) {
        self.recorder = recorder
        session = RecordingTransferVerificationSession(
            eventSource: eventSource,
            recorder: recorder,
            configuration: configuration
        )
    }

    var policies: [TransferVerificationPolicy] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPolicies
    }

    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)? {
        lock.lock()
        recordedPolicies.append(policy)
        lock.unlock()
        return session
    }
}

/// A small, real-protocol session used by transfer-operation RED tests.
/// Synthetic manifests keep the test independent of the virtual filesystem;
/// production code still has to pass the captured identity and comparison
/// policy through the session boundary.
actor RecordingTransferVerificationSession: TransferVerificationSession {
    private let eventSource: @Sendable () async -> [String]
    private let recorder: RecordingTransferVerificationEventRecorder
    private let configuration: RecordingTransferVerificationConfiguration
    private var stagedBySourceAuthority:
        [TransferVerificationRootAuthorityToken: TransferVerificationManifest] = [:]
    private var ownedManifests: [TransferVerificationManifest] = []
    private var captureCallCount = 0
    private var verifyCallCount = 0
    private var revalidateCallCount = 0

    init(
        eventSource: @escaping @Sendable () async -> [String],
        recorder: RecordingTransferVerificationEventRecorder,
        configuration: RecordingTransferVerificationConfiguration
    ) {
        self.eventSource = eventSource
        self.recorder = recorder
        self.configuration = configuration
    }

    func captureSource(
        at url: URL,
        identifiedBy identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        captureCallCount += 1
        let call = captureCallCount
        await configuration.onPhase?(.capture)
        await recorder.append(.capture(
            url: url,
            identity: identity,
            comparisonPolicy: comparisonPolicy,
            filesystemEvents: await eventSource()
        ))
        if let category = configuration.captureFailuresByCall[call] {
            throw TransferVerificationFailure(category: category)
        }
        #if DEBUG
        let pair = try TransferVerificationManifest.makeSyntheticPairForTesting(
            descendantCount: 1,
            regularFileDepth: 1
        )
        #else
        throw TransferVerificationFailure(category: .unsupportedItem)
        #endif
        stagedBySourceAuthority[pair.source.authorityToken] = pair.staged
        ownedManifests.append(pair.source)
        ownedManifests.append(pair.staged)
        return pair.source
    }

    func verify(
        source: TransferVerificationManifest,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        progress: @escaping @Sendable (TransferVerificationProgress) async -> Void
    ) async throws -> TransferVerificationCompletion {
        verifyCallCount += 1
        let call = verifyCallCount
        guard let staged = stagedBySourceAuthority[source.authorityToken] else {
            throw TransferVerificationFailure(category: .stagedOutputChanged)
        }
        await recorder.append(.verify(
            stagedURL: stagedURL,
            stagedIdentity: stagedIdentity,
            filesystemEvents: await eventSource()
        ))
        await configuration.onPhase?(.verify)
        if configuration.cancellingVerifyCalls.contains(call) {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if let category = configuration.verifyFailuresByCall[call] {
            stagedBySourceAuthority.removeValue(forKey: source.authorityToken)?.close()
            throw TransferVerificationFailure(category: category)
        }
        await progress(TransferVerificationProgress(
            phase: .finalValidation,
            fractionCompleted: 1,
            completedFileCount: source.regularFileCount,
            totalFileCount: source.regularFileCount,
            completedLogicalByteCount: source.logicalByteCount,
            totalLogicalByteCount: source.logicalByteCount,
            currentName: stagedURL.lastPathComponent
        ))
        let summary = configuration.summariesByVerifyCall[call]
            ?? TransferVerificationSummary(
                verifiedFileCount: source.regularFileCount,
                verifiedLogicalByteCount: source.logicalByteCount,
                noByteTransferItemCount: 0
            )
        return TransferVerificationCompletion(
            receipt: TransferVerificationReceipt(
                source: source,
                staged: staged,
                borrowedAuthorityTokens: [source.authorityToken]
            ),
            summary: summary
        )
    }

    func revalidate(_ receipt: TransferVerificationReceipt) async throws {
        revalidateCallCount += 1
        let call = revalidateCallCount
        await recorder.append(.revalidate(filesystemEvents: await eventSource()))
        await configuration.onPhase?(.revalidate)
        if let category = configuration.revalidateFailuresByCall[call] {
            throw TransferVerificationFailure(category: category)
        }
    }

    deinit {
        ownedManifests.forEach { $0.close() }
    }
}
