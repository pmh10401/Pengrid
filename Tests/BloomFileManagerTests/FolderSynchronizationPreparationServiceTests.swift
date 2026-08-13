import Foundation
import Testing
@testable import BloomFileManager

@Suite struct FolderSynchronizationPreparationServiceTests {
    @Test func prepareCapturesIdentityBoundFingerprintsAbsencesAndCapacity() async throws {
        let fixture = try PreparationFixture()
        let prepared = try await fixture.service.prepare(fixture.copyDraft)

        #expect(prepared.draft == fixture.copyDraft)
        #expect(prepared.sourceFingerprints[fixture.reportPath] != nil)
        #expect(prepared.destinationFingerprints.isEmpty)
        #expect(prepared.expectedAbsentDestinations == [fixture.reportPath])
        #expect(prepared.requiredCapacityBytes == 42)
        #expect(prepared.rootAuthority.source.identity == fixture.sourceRootIdentity)
        #expect(prepared.rootAuthority.destination.identity == fixture.destinationRootIdentity)
        #expect(fixture.scopedAccess.balancedRoots == [fixture.sourceRoot, fixture.destinationRoot])
    }

    @Test func prepareRejectsAliasMediatedNestedRootsBeforePlanIsConfirmable() async throws {
        let fixture = try PreparationFixture(
            sourceCanonicalPath: "/canonical/source",
            destinationCanonicalPath: "/canonical/source/alias-destination"
        )

        await #expect(throws: FolderSynchronizationPreparationError.unsafeRootRelationship) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
        #expect(await fixture.fileSystem.fingerprintRequests.isEmpty)
        #expect(fixture.scopedAccess.balancedRoots == [fixture.sourceRoot, fixture.destinationRoot])
    }

    @Test func prepareRejectsRootReplacementDuringCapture() async throws {
        let fixture = try PreparationFixture(replaceSourceRootAfterFingerprintRequest: 1)

        await #expect(throws: FolderSynchronizationPreparationError.rootChanged(.source)) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
        #expect(fixture.scopedAccess.balancedRoots == [fixture.sourceRoot, fixture.destinationRoot])
    }

    @Test func prepareRejectsSameBackingStoreThroughDistinctMountInstances() async throws {
        let fixture = try PreparationFixture(
            sourceCanonicalPath: "/Volumes/Data/Project/Source",
            destinationCanonicalPath: "/Aliases/ProjectDestination",
            sourceMountIdentifier: "fsid:17:mount:/Volumes/Data",
            destinationMountIdentifier: "fsid:17:mount:/Aliases"
        )

        await #expect(throws: FolderSynchronizationPreparationError.unsafeRootRelationship) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
        #expect(await fixture.fileSystem.fingerprintRequests.isEmpty)
    }

    @Test func prepareRejectsCanonicallyNestedRootsAcrossVolumes() async throws {
        let fixture = try PreparationFixture(
            sourceCanonicalPath: "/physical-backing/Project",
            destinationCanonicalPath: "/physical-backing/Project/Child",
            sourceVolumeIdentifier: "volume-one",
            destinationVolumeIdentifier: "volume-two"
        )

        await #expect(throws: FolderSynchronizationPreparationError.unsafeRootRelationship) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }

    @Test func prepareAllowsCanonicallyDisjointRootsAcrossVolumes() async throws {
        let fixture = try PreparationFixture(
            sourceCanonicalPath: "/physical-backing-one/Project",
            destinationCanonicalPath: "/physical-backing-two/Project",
            sourceVolumeIdentifier: "volume-one",
            destinationVolumeIdentifier: "volume-two"
        )

        let prepared = try await fixture.service.prepare(fixture.copyDraft)
        #expect(prepared.rootAuthority.source.volumeIdentifier == "volume-one")
        #expect(prepared.rootAuthority.destination.volumeIdentifier == "volume-two")
    }

    @Test func prepareRejectsSourceFingerprintDrift() async throws {
        let fixture = try PreparationFixture(mutateSourceAfterFingerprintRequest: 1)

        await #expect(throws: FolderSynchronizationPreparationError.sourceChanged(fixture.reportPath)) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }

    @Test func prepareRejectsNewlyOccupiedExpectedDestinationAbsence() async throws {
        let fixture = try PreparationFixture(occupyDestinationAfterFingerprintRequest: 1)

        await #expect(throws: FolderSynchronizationPreparationError.expectedDestinationAbsenceOccupied(fixture.reportPath)) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }

    @Test func prepareRejectsInsufficientDestinationCapacity() async throws {
        let fixture = try PreparationFixture(availableCapacity: 41)

        await #expect(throws: FolderSynchronizationPreparationError.insufficientDestinationCapacity(required: 42, available: 41)) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }

    @Test func prepareBalancesAcquiredAccessWhenSecondRootAccessFails() async throws {
        let fixture = try PreparationFixture(denyDestinationAccess: true)

        await #expect(throws: FolderSynchronizationPreparationError.scopedAccessDenied) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
        #expect(fixture.scopedAccess.balancedRoots == [fixture.sourceRoot])
        #expect(await fixture.fileSystem.fingerprintRequests.isEmpty)
    }

    @Test func prepareBalancesLeasesWhenCancelled() async throws {
        let fixture = try PreparationFixture(suspendOnFirstFingerprint: true)
        let task = Task { try await fixture.service.prepare(fixture.copyDraft) }
        await fixture.fileSystem.waitForFingerprintSuspension()
        task.cancel()
        await fixture.fileSystem.releaseFingerprintSuspension()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(fixture.scopedAccess.balancedRoots == [fixture.sourceRoot, fixture.destinationRoot])
    }

    @Test func prepareCapturesAndRevalidatesDestinationFilenamePolicy() async throws {
        let fixture = try PreparationFixture(filenamePolicies: [.caseInsensitiveCanonical, .caseInsensitiveCanonical])

        let prepared = try await fixture.service.prepare(fixture.copyDraft)
        #expect(prepared.destinationFilenameComparisonPolicy == .caseInsensitiveCanonical)
    }

    @Test func prepareRejectsDestinationFilenamePolicyChangeDuringPreparation() async throws {
        let fixture = try PreparationFixture(filenamePolicies: [.caseSensitiveCanonical, .caseInsensitiveCanonical])

        await #expect(throws: FolderSynchronizationPreparationError.destinationFilenamePolicyChanged) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }

    @Test func prepareRejectsOnlineOnlySourceWithoutMaterializingIt() async throws {
        let fixture = try PreparationFixture(sourceAvailability: .onlineOnly)

        await #expect(throws: FolderSynchronizationPreparationError.itemUnavailable) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }

    @Test func prepareRejectsDirectoryCopyWithOnlineOnlyDescendantWithoutMaterializingIt() async throws {
        let fixture = try PreparationFixture(
            sourceDescendantAvailability: .onlineOnly,
            sourceFingerprintIncludesDescendant: true
        )

        await #expect(throws: FolderSynchronizationPreparationError.itemUnavailable) {
            try await fixture.service.prepare(try fixture.directoryCopyDraft())
        }
    }

    @Test func prepareAcceptsDirectoryCopyWhenEveryFingerprintDescendantIsLocal() async throws {
        let fixture = try PreparationFixture(
            sourceDescendantAvailability: .availableLocally,
            sourceFingerprintIncludesDescendant: true
        )

        let prepared = try await fixture.service.prepare(try fixture.directoryCopyDraft())
        #expect(prepared.requiredCapacityBytes == 42)
    }

    @Test func prepareRejectsEscapingFingerprintRelativePath() async throws {
        let fixture = try PreparationFixture(
            sourceFingerprintRelativePath: "../escape",
            sourceFingerprintIncludesDescendant: true
        )

        await #expect(throws: FolderSynchronizationPreparationError.itemUnavailable) {
            try await fixture.service.prepare(try fixture.directoryCopyDraft())
        }
    }

    @Test func prepareRejectsRootReplacementAfterSecondFingerprintBeforeReturn() async throws {
        let fixture = try PreparationFixture(replaceSourceRootAfterFingerprintRequest: 2)

        await #expect(throws: FolderSynchronizationPreparationError.rootChanged(.source)) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }

    @Test func prepareRejectsRootReplacementDuringLateCapacityEvidence() async throws {
        let fixture = try PreparationFixture(replaceSourceRootDuringCapacity: true)

        await #expect(throws: FolderSynchronizationPreparationError.rootChanged(.source)) {
            try await fixture.service.prepare(fixture.copyDraft)
        }
    }
}

private struct PreparationFixture {
    let sourceRoot = URL(filePath: "/fixtures/source", directoryHint: .isDirectory)
    let destinationRoot = URL(filePath: "/fixtures/destination", directoryHint: .isDirectory)
    let sourceRootIdentity = FileIdentity(entryIdentifier: "source-root", resolvedIdentifier: "source-root")
    let destinationRootIdentity = FileIdentity(entryIdentifier: "destination-root", resolvedIdentifier: "destination-root")
    let reportPath = try! ComparisonRelativePath(components: ["report.txt"])
    let fileSystem: PreparationFileSystem
    let scopedAccess: PreparationScopedAccess
    let service: FolderSynchronizationPreparationService
    let copyDraft: FolderSynchronizationPlanDraft

    init(
        sourceCanonicalPath: String = "/canonical/source",
        destinationCanonicalPath: String = "/canonical/destination",
        sourceVolumeIdentifier: String = "fixture-volume",
        destinationVolumeIdentifier: String = "fixture-volume",
        sourceMountIdentifier: String = "fsid:17:mount:/canonical",
        destinationMountIdentifier: String = "fsid:17:mount:/canonical",
        availableCapacity: Int64 = 42,
        replaceSourceRootAfterFingerprintRequest: Int? = nil,
        mutateSourceAfterFingerprintRequest: Int? = nil,
        occupyDestinationAfterFingerprintRequest: Int? = nil,
        filenamePolicies: [FilenameComparisonPolicy] = [.caseSensitiveCanonical, .caseSensitiveCanonical],
        sourceAvailability: CloudItemAvailability = .availableLocally,
        sourceDescendantAvailability: CloudItemAvailability? = nil,
        sourceFingerprintRelativePath: String = "nested.txt",
        sourceFingerprintIncludesDescendant: Bool = false,
        replaceSourceRootDuringCapacity: Bool = false,
        denyDestinationAccess: Bool = false,
        suspendOnFirstFingerprint: Bool = false
    ) throws {
        let source = sourceRoot.appending(path: reportPath.string)
        fileSystem = PreparationFileSystem(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity,
            source: source,
            sourceIdentity: .init(entryIdentifier: "source-report", resolvedIdentifier: "source-report"),
            sourceCanonicalPath: sourceCanonicalPath,
            destinationCanonicalPath: destinationCanonicalPath,
            sourceVolumeIdentifier: sourceVolumeIdentifier,
            destinationVolumeIdentifier: destinationVolumeIdentifier,
            sourceMountIdentifier: sourceMountIdentifier,
            destinationMountIdentifier: destinationMountIdentifier,
            availableCapacity: availableCapacity,
            replaceSourceRootAfterFingerprintRequest: replaceSourceRootAfterFingerprintRequest,
            mutateSourceAfterFingerprintRequest: mutateSourceAfterFingerprintRequest,
            occupyDestinationAfterFingerprintRequest: occupyDestinationAfterFingerprintRequest,
            filenamePolicies: filenamePolicies,
            replaceSourceRootDuringCapacity: replaceSourceRootDuringCapacity,
            sourceFingerprintRelativePath: sourceFingerprintRelativePath,
            sourceFingerprintIncludesDescendant: sourceFingerprintIncludesDescendant,
            suspendOnFirstFingerprint: suspendOnFirstFingerprint
        )
        scopedAccess = PreparationScopedAccess(denyDestination: denyDestinationAccess)
        service = FolderSynchronizationPreparationService(
            fileSystem: fileSystem,
            scopedAccess: scopedAccess,
            availabilityReader: PreparationAvailabilityReader(
                defaultValue: sourceAvailability,
                values: sourceDescendantAvailability.map { [source.appending(path: "nested.txt"): $0] } ?? [:]
            )
        )
        let entry = ComparisonEntry(
            relativePath: reportPath,
            url: source,
            kind: .regularFile,
            fingerprint: .init(
                identity: .init(entryIdentifier: "source-report", resolvedIdentifier: "source-report"),
                byteSize: 42,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "regularFile"
        )
        let action = try FolderSynchronizationAction(
            relativePath: reportPath,
            kind: .copy,
            source: entry,
            destination: nil
        )
        copyDraft = try FolderSynchronizationPlanDraft(
            direction: .leftToRight,
            comparisonGeneration: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity,
            actions: [action],
            skipCount: 0,
            estimatedRegularFileCopyBytes: 42
        )
    }

    func directoryCopyDraft() throws -> FolderSynchronizationPlanDraft {
        let directory = ComparisonEntry(
            relativePath: reportPath,
            url: sourceRoot.appending(path: reportPath.string),
            kind: .directory,
            fingerprint: .init(
                identity: .init(entryIdentifier: "source-report", resolvedIdentifier: "source-report"),
                byteSize: nil,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "directory"
        )
        return try .init(
            direction: .leftToRight,
            comparisonGeneration: copyDraft.comparisonGeneration,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity,
            actions: [try .init(relativePath: reportPath, kind: .copy, source: directory, destination: nil)],
            skipCount: 0,
            estimatedRegularFileCopyBytes: 0
        )
    }
}

private final class PreparationScopedAccess: FolderSynchronizationScopedAccessing, @unchecked Sendable {
    private let denyDestination: Bool
    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []

    init(denyDestination: Bool) { self.denyDestination = denyDestination }

    func acquireAccess(for roots: [URL]) throws -> [any FolderSynchronizationScopedAccessLease] {
        var leases: [any FolderSynchronizationScopedAccessLease] = []
        for root in roots {
            if denyDestination, root.path.contains("destination") {
                leases.forEach { $0.finish() }
                throw FolderSynchronizationPreparationError.scopedAccessDenied
            }
            lock.withLock { started.append(root) }
            leases.append(PreparationLease(root: root) { [weak self] root in
                self?.finish(root)
            })
        }
        return leases
    }

    private func finish(_ root: URL) { lock.withLock { stopped.append(root) } }

    var balancedRoots: [URL] {
        lock.withLock {
            started.filter { root in
                stopped.filter { $0 == root }.count == started.filter { $0 == root }.count
            }
        }
    }
}

private final class PreparationLease: FolderSynchronizationScopedAccessLease, @unchecked Sendable {
    private let root: URL
    private let onFinish: @Sendable (URL) -> Void
    private let lock = NSLock()
    private var finished = false

    init(root: URL, onFinish: @escaping @Sendable (URL) -> Void) {
        self.root = root
        self.onFinish = onFinish
    }

    func finish() {
        guard lock.withLock({ !finished }) else { return }
        lock.withLock { finished = true }
        onFinish(root)
    }
}

private actor PreparationFileSystem: FileSystemAccess, FolderSynchronizationRootAuthorityProviding {
    let sourceRoot: URL
    let destinationRoot: URL
    let source: URL
    let sourceIdentity: FileIdentity
    let sourceCanonicalPath: String
    let destinationCanonicalPath: String
    let sourceVolumeIdentifier: String
    let destinationVolumeIdentifier: String
    let sourceMountIdentifier: String
    let destinationMountIdentifier: String
    let availableCapacity: Int64
    let replaceSourceRootAfterFingerprintRequest: Int?
    let mutateSourceAfterFingerprintRequest: Int?
    let occupyDestinationAfterFingerprintRequest: Int?
    let filenamePolicies: [FilenameComparisonPolicy]
    let replaceSourceRootDuringCapacity: Bool
    let sourceFingerprintRelativePath: String
    let sourceFingerprintIncludesDescendant: Bool
    let suspendOnFirstFingerprint: Bool
    private var identities: [URL: FileIdentity]
    private var sourceFingerprintVersion = 1
    private var destinationOccupied = false
    private var fingerprintCount = 0
    private var filenamePolicyCount = 0
    private var fingerprintContinuation: CheckedContinuation<Void, Never>?
    private var fingerprintSuspended = false
    private(set) var fingerprintRequests: [URL] = []

    init(
        sourceRoot: URL,
        destinationRoot: URL,
        sourceRootIdentity: FileIdentity,
        destinationRootIdentity: FileIdentity,
        source: URL,
        sourceIdentity: FileIdentity,
        sourceCanonicalPath: String,
        destinationCanonicalPath: String,
        sourceVolumeIdentifier: String,
        destinationVolumeIdentifier: String,
        sourceMountIdentifier: String,
        destinationMountIdentifier: String,
        availableCapacity: Int64,
        replaceSourceRootAfterFingerprintRequest: Int?,
        mutateSourceAfterFingerprintRequest: Int?,
        occupyDestinationAfterFingerprintRequest: Int?,
        filenamePolicies: [FilenameComparisonPolicy],
        replaceSourceRootDuringCapacity: Bool,
        sourceFingerprintRelativePath: String,
        sourceFingerprintIncludesDescendant: Bool,
        suspendOnFirstFingerprint: Bool
    ) {
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.source = source
        self.sourceIdentity = sourceIdentity
        self.sourceCanonicalPath = sourceCanonicalPath
        self.destinationCanonicalPath = destinationCanonicalPath
        self.sourceVolumeIdentifier = sourceVolumeIdentifier
        self.destinationVolumeIdentifier = destinationVolumeIdentifier
        self.sourceMountIdentifier = sourceMountIdentifier
        self.destinationMountIdentifier = destinationMountIdentifier
        self.availableCapacity = availableCapacity
        self.replaceSourceRootAfterFingerprintRequest = replaceSourceRootAfterFingerprintRequest
        self.mutateSourceAfterFingerprintRequest = mutateSourceAfterFingerprintRequest
        self.occupyDestinationAfterFingerprintRequest = occupyDestinationAfterFingerprintRequest
        self.filenamePolicies = filenamePolicies
        self.replaceSourceRootDuringCapacity = replaceSourceRootDuringCapacity
        self.sourceFingerprintRelativePath = sourceFingerprintRelativePath
        self.sourceFingerprintIncludesDescendant = sourceFingerprintIncludesDescendant
        self.suspendOnFirstFingerprint = suspendOnFirstFingerprint
        identities = [sourceRoot: sourceRootIdentity, destinationRoot: destinationRootIdentity, source: sourceIdentity]
    }

    func captureFolderSynchronizationRootAuthority(
        at url: URL,
        expectedIdentity: FileIdentity
    ) async throws -> FolderSynchronizationRootEvidence {
        guard identities[url] == expectedIdentity else { throw FileSystemAccessError.identityMismatch(url) }
        return .init(
            identity: expectedIdentity,
            canonicalURL: URL(filePath: url == sourceRoot ? sourceCanonicalPath : destinationCanonicalPath),
            volumeIdentifier: url == sourceRoot ? sourceVolumeIdentifier : destinationVolumeIdentifier,
            mountIdentifier: url == sourceRoot ? sourceMountIdentifier : destinationMountIdentifier
        )
    }

    func exists(_ url: URL) async -> Bool { url == destinationRoot.appending(path: "report.txt") && destinationOccupied }
    func createDirectory(_ url: URL) async throws { throw FileSystemAccessError.unsupportedOperation(url) }
    func createEmptyItemAndCaptureIdentity(
        _ url: URL,
        kind: EmptyFileSystemItemKind,
        parentIdentifiedBy parentIdentity: FileIdentity
    ) async throws -> OpenedEmptyFileSystemItem { throw FileSystemAccessError.unsupportedOperation(url) }
    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity { throw FileSystemAccessError.unsupportedOperation(destination) }
    func move(_ source: URL, to destination: URL) async throws { throw FileSystemAccessError.unsupportedOperation(source) }
    func moveExclusively(_ source: URL, to destination: URL) async throws { throw FileSystemAccessError.unsupportedOperation(source) }
    func remove(_ url: URL) async throws { throw FileSystemAccessError.unsupportedOperation(url) }
    func replace(_ destination: URL, with stagedItem: URL) async throws { throw FileSystemAccessError.unsupportedOperation(destination) }
    func identity(of url: URL) async throws -> FileIdentity? { identities[url] }
    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws { throw FileSystemAccessError.unsupportedOperation(source) }
    func moveExclusively(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws { throw FileSystemAccessError.unsupportedOperation(source) }
    func moveExclusively(_ source: URL, identifiedBy sourceIdentity: FileIdentity, to destination: URL, destinationParentIdentifiedBy destinationParentIdentity: FileIdentity) async throws { throw FileSystemAccessError.unsupportedOperation(source) }
    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws { throw FileSystemAccessError.unsupportedOperation(url) }
    func replace(_ destination: URL, identifiedBy destinationIdentity: FileIdentity, with stagedItem: URL, identifiedBy stagedIdentity: FileIdentity) async throws { throw FileSystemAccessError.unsupportedOperation(destination) }
    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation { throw FileSystemAccessError.unsupportedOperation(destination) }
    func reserveStagingDirectory(beside destination: URL, parentIdentifiedBy parentIdentity: FileIdentity) async throws -> StagingReservation { throw FileSystemAccessError.unsupportedOperation(destination) }
    func removeStagingDirectory(_ reservation: StagingReservation) async throws { throw FileSystemAccessError.unsupportedOperation(reservation.directory) }
    func fingerprint(of url: URL) async throws -> SourceFingerprint {
        fingerprintRequests.append(url)
        fingerprintCount += 1
        if suspendOnFirstFingerprint, fingerprintCount == 1 {
            fingerprintSuspended = true
            await withCheckedContinuation { fingerprintContinuation = $0 }
            try Task.checkCancellation()
        }
        let root = url == source ? source : destinationRoot.appending(path: "report.txt")
        let version = sourceFingerprintVersion
        let entries: [SourceFingerprint.Entry]
        if sourceFingerprintIncludesDescendant {
            entries = [
                .init(relativePath: ".", device: 1, inode: 9, mode: 0o040755, size: 0, modificationSeconds: Int64(version), modificationNanoseconds: 0, changeSeconds: Int64(version), changeNanoseconds: 0),
                .init(relativePath: sourceFingerprintRelativePath, device: 1, inode: 10, mode: 0o100644, size: 42, modificationSeconds: Int64(version), modificationNanoseconds: 0, changeSeconds: Int64(version), changeNanoseconds: 0)
            ]
        } else {
            entries = [.init(relativePath: ".", device: 1, inode: 9, mode: 0o100644, size: 42, modificationSeconds: Int64(version), modificationNanoseconds: 0, changeSeconds: Int64(version), changeNanoseconds: 0)]
        }
        let fingerprint = SourceFingerprint(entries: entries)
        if fingerprintCount == replaceSourceRootAfterFingerprintRequest {
            identities[sourceRoot] = .init(entryIdentifier: "replacement-root", resolvedIdentifier: "replacement-root")
        }
        if fingerprintCount == mutateSourceAfterFingerprintRequest { sourceFingerprintVersion += 1 }
        if fingerprintCount == occupyDestinationAfterFingerprintRequest { destinationOccupied = true }
        _ = root
        return fingerprint
    }
    func trash(_ url: URL) async throws { throw FileSystemAccessError.unsupportedOperation(url) }
    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws { throw FileSystemAccessError.unsupportedOperation(url) }
    func trashAndReturnResultingURL(_ url: URL, identifiedBy identity: FileIdentity) async throws -> URL? { throw FileSystemAccessError.unsupportedOperation(url) }
    func quarantineForTrash(_ url: URL, identifiedBy identity: FileIdentity) async throws -> StorageTrashQuarantine { throw FileSystemAccessError.unsupportedOperation(url) }
    func rollbackTrashQuarantine(_ quarantine: StorageTrashQuarantine) async throws { throw FileSystemAccessError.unsupportedOperation(quarantine.originalURL) }
    func moveTrashQuarantineAtomically(_ quarantine: StorageTrashQuarantine) async throws -> URL { throw FileSystemAccessError.unsupportedOperation(quarantine.originalURL) }
    func names(in directory: URL) async throws -> Set<String> { [] }
    func filenameComparisonPolicy(in directory: URL) async throws -> FilenameComparisonPolicy {
        let index = min(filenamePolicyCount, filenamePolicies.count - 1)
        filenamePolicyCount += 1
        return filenamePolicies[index]
    }
    func volumeIdentifier(for url: URL) async throws -> String { destinationVolumeIdentifier }
    func byteSize(of url: URL) async throws -> Int64? { 42 }
    func availableCapacity(at url: URL) async throws -> Int64? {
        if replaceSourceRootDuringCapacity {
            identities[sourceRoot] = .init(entryIdentifier: "replacement-root", resolvedIdentifier: "replacement-root")
        }
        return availableCapacity
    }
    func captureFolderPreviewRequest(paneID: PaneID, url: URL) async throws -> FolderPreviewRequest? { nil }
    func snapshotFolder(_ request: FolderPreviewRequest, visibility: DirectoryVisibilityPolicy, progress: @escaping @Sendable (Int) -> Void) async throws -> FolderPreviewSnapshot { throw FileSystemAccessError.unsupportedOperation(request.url) }
    func prepareDirectoryHierarchy(root: URL, identifiedBy rootIdentity: FileIdentity, relativeComponents: [String]) async throws -> PreparedDirectoryHierarchy { throw FileSystemAccessError.unsupportedOperation(root) }
    func removeEmptyOwnedDirectories(root: URL, identifiedBy rootIdentity: FileIdentity, directories: [PreparedDirectoryHierarchy.OwnedDirectory]) async throws { throw FileSystemAccessError.unsupportedOperation(root) }

    func waitForFingerprintSuspension() async {
        while !fingerprintSuspended { await Task.yield() }
    }
    func releaseFingerprintSuspension() { fingerprintContinuation?.resume(); fingerprintContinuation = nil }
}

private actor PreparationAvailabilityReader: CloudItemAvailabilityReading {
    let defaultValue: CloudItemAvailability
    let values: [URL: CloudItemAvailability]

    init(defaultValue: CloudItemAvailability, values: [URL: CloudItemAvailability]) {
        self.defaultValue = defaultValue
        self.values = values
    }

    func availability(of url: URL) -> CloudItemAvailability { values[url] ?? defaultValue }
}
