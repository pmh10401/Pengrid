import Darwin
import Foundation
import Testing
@testable import BloomFileManager

private let transferVerificationAPFSIsEnabled =
    ProcessInfo.processInfo.environment["PENGRID_TRANSFER_APFS_ROOT"] != nil

@Suite("TransferVerificationAPFSTests", .serialized)
struct TransferVerificationAPFSTests {
    @Test(.enabled(if: transferVerificationAPFSIsEnabled))
    func copiesAndVerifiesANestedDirectoryOnMountedAPFSFilesystem() async throws {
        let fixture = try TransferVerificationAPFSFixture(label: "nested-copy")
        defer { fixture.remove() }
        let source = fixture.localRoot.appending(
            path: "Tree",
            directoryHint: .isDirectory
        )
        let nested = source.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        let first = Data("first APFS payload".utf8)
        let second = Data("second nested APFS payload".utf8)
        try first.write(to: source.appending(path: "First.txt"))
        try second.write(to: nested.appending(path: "Second.txt"))

        let result = await transfer(
            source,
            to: fixture.mountedRoot,
            mode: .copy
        )
        let destination = fixture.mountedRoot.appending(path: "Tree")

        #expect(result.outcomes == [
            .succeeded(source: source, destination: destination)
        ])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 2,
            verifiedLogicalByteCount: Int64(first.count + second.count),
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(try Data(contentsOf: destination.appending(path: "First.txt")) == first)
        #expect(try Data(
            contentsOf: destination.appending(path: "Nested/Second.txt")
        ) == second)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test(.enabled(if: transferVerificationAPFSIsEnabled))
    func crossVolumeMoveKeepsSourceUntilVerificationSucceeds() async throws {
        let fixture = try TransferVerificationAPFSFixture(label: "cross-volume-move")
        defer { fixture.remove() }
        let source = fixture.localRoot.appending(
            path: "MoveFolder",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: false
        )
        let payload = Data(repeating: 0x5a, count: 512 * 1_024)
        try payload.write(to: source.appending(path: "Move.bin"))
        let destination = fixture.mountedRoot.appending(path: "MoveFolder")
        let gate = TransferVerificationAPFSPhaseGate()
        let task = Task {
            await transfer(
                source,
                to: fixture.mountedRoot,
                mode: .move,
                verificationProgress: { progress in
                    guard progress.phase == .preparingManifest else { return }
                    await gate.pauseOnce()
                }
            )
        }

        do {
            try await waitForAPFSPhaseGate(gate)
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            await gate.release()
        } catch {
            task.cancel()
            await gate.release()
            _ = await task.value
            throw error
        }

        let result = await task.value
        #expect(result.outcomes == [
            .succeeded(source: source, destination: destination)
        ])
        #expect(result.verificationReport?.verifiedFileCount == 1)
        #expect(result.verificationReport?.failedVerificationItemCount == 0)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination.appending(path: "Move.bin")) == payload)
    }

    @Test(.enabled(if: transferVerificationAPFSIsEnabled))
    func verifiesSingleSymlinkRootWithoutFollowingItsTarget() async throws {
        let fixture = try TransferVerificationAPFSFixture(label: "symlink-root")
        defer { fixture.remove() }
        let target = fixture.localRoot.appending(path: "Target.bin")
        let source = fixture.localRoot.appending(path: "Target Link")
        try Data(repeating: 0x7c, count: 256 * 1_024).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: source,
            withDestinationURL: target
        )

        let result = await transfer(
            source,
            to: fixture.mountedRoot,
            mode: .copy
        )
        let destination = fixture.mountedRoot.appending(path: "Target Link")

        #expect(result.outcomes == [
            .succeeded(source: source, destination: destination)
        ])
        #expect(result.verificationReport == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path
        ) == FileManager.default.destinationOfSymbolicLink(atPath: source.path))
    }

    @Test(.enabled(if: transferVerificationAPFSIsEnabled))
    func cancellationDuringVerificationPreservesSourceAndCleansOwnedStaging() async throws {
        let fixture = try TransferVerificationAPFSFixture(label: "cancel-verification")
        defer { fixture.remove() }
        let source = fixture.localRoot.appending(
            path: "CancelFolder",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: false
        )
        try Data(repeating: 0x31, count: 512 * 1_024).write(
            to: source.appending(path: "Cancel.bin")
        )
        let destination = fixture.mountedRoot.appending(path: "CancelFolder")
        let gate = TransferVerificationAPFSPhaseGate()
        let task = Task {
            await transfer(
                source,
                to: fixture.mountedRoot,
                mode: .move,
                verificationProgress: { progress in
                    guard progress.phase == .preparingManifest else { return }
                    await gate.pauseOnce()
                }
            )
        }

        do {
            try await waitForAPFSPhaseGate(gate)
            task.cancel()
            await gate.release()
        } catch {
            task.cancel()
            await gate.release()
            _ = await task.value
            throw error
        }

        let result = await task.value
        #expect(result.outcomes == [.cancelled(source: source)])
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try expectNoOwnedTransferStaging(in: fixture.mountedRoot)
    }

    @Test(.enabled(if: transferVerificationAPFSIsEnabled))
    func receiptMutationPreventsReplacementAndCleansOnlyOwnedStaging() async throws {
        let fixture = try TransferVerificationAPFSFixture(label: "receipt-mutation")
        defer { fixture.remove() }
        let source = fixture.localRoot.appending(
            path: "ReplaceFolder",
            directoryHint: .isDirectory
        )
        let destination = fixture.mountedRoot.appending(
            path: "ReplaceFolder",
            directoryHint: .isDirectory
        )
        let oldDestination = Data("existing destination bytes".utf8)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        try Data("source content to verify".utf8).write(
            to: source.appending(path: "Payload.bin")
        )
        try oldDestination.write(to: destination.appending(path: "Payload.bin"))
        let unrelatedStaging = fixture.mountedRoot.appending(
            path: ".bloom-staging-unrelated",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: unrelatedStaging,
            withIntermediateDirectories: false
        )
        let sentinel = unrelatedStaging.appending(path: "sentinel")
        try Data("do not remove".utf8).write(to: sentinel)
        let factory = ReceiptMutatingTransferVerificationSessionFactory { stagedURL in
            let stagedPayload = stagedURL.appending(path: "Payload.bin")
            let descriptor = Darwin.open(
                stagedPayload.path,
                O_WRONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(descriptor) }
            var byte: UInt8 = 0xff
            guard Darwin.pwrite(descriptor, &byte, 1, 0) == 1,
                  Darwin.fsync(descriptor) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let fileSystem = LiveFileSystemAccess()
        let service = FileOperationService(
            fileSystem: fileSystem,
            verificationSessionFactory: factory
        )
        let request = try await identifiedRequest(
            source: source,
            destinationRoot: fixture.mountedRoot,
            fileSystem: fileSystem
        )

        let result = await service.transfer(
            [request],
            mode: .copy,
            resolveConflict: { _ in .replace },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(result.verificationReport?.verifiedFileCount == 0)
        #expect(result.verificationReport?.failedVerificationItemCount == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(
            contentsOf: destination.appending(path: "Payload.bin")
        ) == oldDestination)
        #expect(try Data(contentsOf: sentinel) == Data("do not remove".utf8))
        try expectNoOwnedTransferStaging(
            in: fixture.mountedRoot,
            excluding: unrelatedStaging
        )
    }
}

private func transfer(
    _ source: URL,
    to destinationRoot: URL,
    mode: TransferMode,
    verificationProgress: @escaping TransferVerificationProgressHandler = { _ in }
) async -> FileOperationResult {
    let fileSystem = LiveFileSystemAccess()
    let service = FileOperationService(fileSystem: fileSystem)
    do {
        let request = try await identifiedRequest(
            source: source,
            destinationRoot: destinationRoot,
            fileSystem: fileSystem
        )
        return await service.transfer(
            [request],
            mode: mode,
            resolveConflict: { _ in .cancel },
            verificationPolicy: .sha256(maxConcurrentPairs: 2),
            progress: { _ in },
            verificationProgress: verificationProgress
        )
    } catch {
        return FileOperationResult(outcomes: [
            .failed(source: source, message: String(reflecting: type(of: error)))
        ])
    }
}

private func identifiedRequest(
    source: URL,
    destinationRoot: URL,
    fileSystem: LiveFileSystemAccess
) async throws -> IdentifiedTransferRequest {
    IdentifiedTransferRequest(
        source: source,
        sourceIdentity: try #require(await fileSystem.identity(of: source)),
        destinationRoot: destinationRoot,
        destinationRootIdentity: try #require(
            await fileSystem.identity(of: destinationRoot)
        ),
        relativeParentComponents: []
    )
}

private struct TransferVerificationAPFSFixture {
    let local: TemporaryDirectory
    let localRoot: URL
    let mountedRoot: URL
    private let harnessRoot: URL

    init(label: String) throws {
        harnessRoot = try validatedTransferVerificationAPFSRoot()
        local = try TemporaryDirectory()
        localRoot = local.url.appending(path: label, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: localRoot,
            withIntermediateDirectories: false
        )
        mountedRoot = harnessRoot.appending(
            path: ".pengrid-apfs-test-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        guard isStrictChild(mountedRoot, of: harnessRoot) else {
            throw TransferVerificationAPFSTestFailure.unsafeRoot
        }
        try FileManager.default.createDirectory(
            at: mountedRoot,
            withIntermediateDirectories: false
        )

        let localVolume = try localRoot.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ).volumeIdentifier
        let mountedVolume = try mountedRoot.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ).volumeIdentifier
        guard let localVolume, let mountedVolume,
              try VolumeIdentifierNormalizer.normalize(localVolume)
                != VolumeIdentifierNormalizer.normalize(mountedVolume)
        else {
            remove()
            throw TransferVerificationAPFSTestFailure.notCrossVolume
        }
    }

    func remove() {
        if isStrictChild(mountedRoot, of: harnessRoot) {
            try? FileManager.default.removeItem(at: mountedRoot)
        }
        local.remove()
    }
}

private func validatedTransferVerificationAPFSRoot() throws -> URL {
    guard let raw = ProcessInfo.processInfo.environment["PENGRID_TRANSFER_APFS_ROOT"],
          !raw.isEmpty
    else {
        throw TransferVerificationAPFSTestFailure.missingRoot
    }
    let supplied = URL(filePath: raw, directoryHint: .isDirectory).standardizedFileURL
    let resolved = supplied.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard supplied.path == resolved.path,
          supplied.path != "/",
          supplied.path != FileManager.default.homeDirectoryForCurrentUser.path,
          FileManager.default.fileExists(
            atPath: supplied.path,
            isDirectory: &isDirectory
          ),
          isDirectory.boolValue
    else {
        throw TransferVerificationAPFSTestFailure.unsafeRoot
    }
    return supplied
}

private func isStrictChild(_ candidate: URL, of root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return candidatePath.hasPrefix(rootPath + "/") && candidatePath != rootPath
}

private func expectNoOwnedTransferStaging(
    in root: URL,
    excluding excluded: URL? = nil
) throws {
    let excludedPath = excluded?.standardizedFileURL.path
    let staging = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).filter {
        $0.lastPathComponent.hasPrefix(".bloom-staging-")
            && $0.standardizedFileURL.path != excludedPath
    }
    #expect(staging.isEmpty)
}

private actor TransferVerificationAPFSPhaseGate {
    private(set) var hasEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !hasEntered else { return }
        hasEntered = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func waitForAPFSPhaseGate(
    _ gate: TransferVerificationAPFSPhaseGate,
    timeout: Duration = .seconds(10)
) async throws {
    let start = ContinuousClock.now
    while !(await gate.hasEntered) {
        if start.duration(to: ContinuousClock.now) >= timeout {
            throw TransferVerificationAPFSTestFailure.timedOut
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct ReceiptMutatingTransferVerificationSessionFactory:
    TransferVerificationSessionFactory
{
    let mutate: @Sendable (URL) throws -> Void

    init(mutate: @escaping @Sendable (URL) throws -> Void) {
        self.mutate = mutate
    }

    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)? {
        guard let base = LiveTransferVerificationSessionFactory().makeSession(
            policy: policy
        ) else {
            return nil
        }
        return ReceiptMutatingTransferVerificationSession(
            base: base,
            mutate: mutate
        )
    }
}

private struct ReceiptMutatingTransferVerificationSession:
    TransferVerificationSession
{
    let base: any TransferVerificationSession
    let mutate: @Sendable (URL) throws -> Void

    func captureSource(
        at url: URL,
        identifiedBy identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        try await base.captureSource(
            at: url,
            identifiedBy: identity,
            comparisonPolicy: comparisonPolicy
        )
    }

    func verify(
        source: TransferVerificationManifest,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        progress: @escaping @Sendable (TransferVerificationProgress) async -> Void
    ) async throws -> TransferVerificationCompletion {
        let completion = try await base.verify(
            source: source,
            stagedURL: stagedURL,
            stagedIdentity: stagedIdentity,
            progress: progress
        )
        do {
            try mutate(stagedURL)
        } catch {
            completion.receipt.source.close()
            completion.receipt.staged.close()
            throw error
        }
        return completion
    }

    func revalidate(_ receipt: TransferVerificationReceipt) async throws {
        try await base.revalidate(receipt)
    }
}

private enum TransferVerificationAPFSTestFailure: Error {
    case missingRoot
    case unsafeRoot
    case notCrossVolume
    case timedOut
}
