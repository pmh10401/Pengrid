import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite
struct StorageCleanupControllerTests {
    @Test func reviewRejectsAGroupWhoseEveryMemberIsSelected() throws {
        let fixture = try StorageCleanupFixture.allMembersMarked()

        #expect(throws: StorageCleanupValidationError.missingKeepCopy(fixture.group.id)) {
            try fixture.controller.prepareReview(
                generation: 1,
                admission: fixture.admission,
                groups: [fixture.group],
                cleanupAuthorized: true
            )
        }
    }

    @Test func reviewRequiresTheDistinctProtectedCleanupAcknowledgement() throws {
        let fixture = try StorageCleanupFixture.verifiedSelection()

        #expect(throws: StorageCleanupValidationError.cleanupAcknowledgementRequired) {
            try fixture.controller.prepareReview(
                generation: 1,
                admission: fixture.admission,
                groups: [fixture.group],
                cleanupAuthorized: false
            )
        }
        #expect(fixture.controller.pendingReview == nil)
    }

    @Test func confirmRevalidatesAndDispatchesOnlyCurrentSelectedFiles() async throws {
        let fixture = try StorageCleanupFixture.oneReplacementBeforeConfirm()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        let started = await fixture.controller.confirm(
            currentGeneration: 1,
            currentAdmission: fixture.admission,
            groups: [fixture.group],
            operationController: fixture.operationController,
            workspace: fixture.workspace,
            validateAdmission: { _ in true },
            onCompletion: fixture.record
        )
        #expect(await fixture.waitUntilIdle())

        #expect(started)
        #expect(await fixture.fileSystem.trashedURLs() == [fixture.unchangedSelectedURL])
        #expect(fixture.controller.excludedIDs == [fixture.replacedID])
    }

    @Test func replacedKeepCopySkipsEverySelectedSiblingWithoutDispatch() async throws {
        let fixture = try StorageCleanupFixture.replacedKeepBeforeConfirm()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        let started = await fixture.controller.confirm(
            currentGeneration: 1,
            currentAdmission: fixture.admission,
            groups: [fixture.group],
            operationController: fixture.operationController,
            workspace: fixture.workspace,
            validateAdmission: { _ in true },
            onCompletion: fixture.record
        )

        #expect(started)
        #expect(await fixture.waitUntilIdle())
        #expect(await fixture.fileSystem.attemptedTrashURLs().isEmpty)
        #expect(fixture.controller.excludedIDs == fixture.group.trashIDs)
    }

    @Test func unreadableKeepCopyFailsEverySelectedSiblingWithoutDispatch() async throws {
        let fixture = try StorageCleanupFixture.unreadableKeepBeforeConfirm()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        let started = await fixture.controller.confirm(
            currentGeneration: 1,
            currentAdmission: fixture.admission,
            groups: [fixture.group],
            operationController: fixture.operationController,
            workspace: fixture.workspace,
            validateAdmission: { _ in true },
            onCompletion: fixture.record
        )

        #expect(started)
        #expect(await fixture.waitUntilIdle())
        #expect(await fixture.fileSystem.attemptedTrashURLs().isEmpty)
        #expect(fixture.controller.excludedIDs.isEmpty)
        #expect(fixture.completions.last?.outcomes == fixture.selectedURLs.map {
            .failed(source: $0, message: "cleanup-trash-failed")
        })
    }

    @Test func cleanupNeverCallsPathOnlyTrashOrRemove() async throws {
        let fixture = try StorageCleanupFixture.verifiedSelection()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        _ = await fixture.confirm()

        #expect(await fixture.fileSystem.identifiedTrashCount() == 1)
        #expect(await fixture.fileSystem.pathOnlyTrashCount() == 0)
        #expect(await fixture.fileSystem.removeCount() == 0)
    }

    @Test func individualTrashFailureDoesNotPreventSiblingSuccess() async throws {
        let fixture = try StorageCleanupFixture.oneTrashFailureAndSiblingSuccess()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        let started = await fixture.confirm()

        #expect(started)
        #expect(await fixture.fileSystem.attemptedTrashURLs() == fixture.selectedURLs)
        #expect(await fixture.fileSystem.existsAt(fixture.selectedURLs[0]))
        #expect(fixture.completions.map(\.outcomes) == [[
            .failed(
                source: fixture.selectedURLs[0],
                message: "cleanup-trash-failed"
            ),
            .succeeded(source: fixture.selectedURLs[1], destination: nil)
        ]])
    }

    @Test func rollbackCollisionStaysDistinctFromOrdinaryCleanupFailure() async throws {
        let fixture = try StorageCleanupFixture.recoveryAndOrdinaryFailure()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        let started = await fixture.confirm()

        #expect(started)
        #expect(fixture.completions.map(\.outcomes) == [[
            .recoveryNeeded(source: fixture.selectedURLs[0]),
            .failed(
                source: fixture.selectedURLs[1],
                message: "cleanup-trash-failed"
            )
        ]])
        #expect(fixture.controller.lastResult == fixture.completions.last)
    }

    @Test func preflightSkipsAndTrashOutcomesStayInStableReviewOrder() async throws {
        let fixture = try StorageCleanupFixture.mixedPreflightAndTrashOutcomes()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        let started = await fixture.confirm()

        #expect(started)
        #expect(fixture.completions.map(\.outcomes) == [[
            .failed(
                source: fixture.selectedURLs[0],
                message: "cleanup-trash-failed"
            ),
            .skipped(source: fixture.selectedURLs[1]),
            .succeeded(source: fixture.selectedURLs[2], destination: nil)
        ]])
        #expect(fixture.controller.lastResult == fixture.completions.last)
        #expect(fixture.controller.pendingReview != nil)
    }

    @Test func cleanupProgressErrorsLogsAndAccessibilityStayMetadataFree() async throws {
        let fixture = try StorageCleanupFixture.privacySensitiveSelection()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        _ = await fixture.confirm()

        let result = try #require(fixture.completions.last)
        let values = [
            fixture.operationController.progress?.currentName ?? "",
            OperationStatusSummary(result: result).accessibilityLabel
        ] + (await fixture.logger.values)
        for value in values {
            #expect(!value.contains(fixture.root.path))
            #expect(!value.contains(fixture.filename))
            #expect(!value.contains(fixture.digestBase64))
        }
    }

    @Test func changedRootAdmissionStopsBeforeOperationDispatch() async throws {
        let fixture = try StorageCleanupFixture.verifiedSelection()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        let started = await fixture.controller.confirm(
            currentGeneration: 1,
            currentAdmission: fixture.admission,
            groups: [fixture.group],
            operationController: fixture.operationController,
            workspace: fixture.workspace,
            validateAdmission: { _ in false },
            onCompletion: fixture.record
        )

        #expect(!started)
        #expect(await fixture.fileSystem.attemptedTrashURLs().isEmpty)
        #expect(fixture.controller.lastResult?.outcomes == fixture.selectedURLs.map {
            .skipped(source: $0)
        })
    }

    @Test func keepCopyFingerprintFailureFailsOnlyRemainingMutation() async throws {
        let fixture = try StorageCleanupFixture.keepDisappearsBetweenSelectedItems()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        #expect(await fixture.confirm())
        #expect(await fixture.fileSystem.trashedURLs() == [fixture.selectedURLs[0]])
        #expect(fixture.completions.last?.outcomes == [
            .succeeded(source: fixture.selectedURLs[0], destination: nil),
            .failed(
                source: fixture.selectedURLs[1],
                message: "cleanup-trash-failed"
            )
        ])
    }

    @Test func replacementAtQuarantineBoundaryReportsFailedWithoutTrash() async throws {
        let fixture = try StorageCleanupFixture.replacementAtQuarantineBoundary()
        try fixture.controller.prepareReview(
            generation: 1,
            admission: fixture.admission,
            groups: [fixture.group],
            cleanupAuthorized: true
        )

        #expect(await fixture.confirm())
        #expect(await fixture.fileSystem.trashedURLs().isEmpty)
        #expect(await fixture.fileSystem.attemptedTrashURLs().isEmpty)
        #expect(fixture.completions.last?.outcomes == [
            .failed(
                source: fixture.selectedURLs[0],
                message: "cleanup-trash-failed"
            )
        ])
    }
}

@MainActor
private final class StorageCleanupFixture {
    let group: StorageDuplicateGroup
    let controller: StorageCleanupController
    let operationController: FileOperationController
    let workspace: WorkspaceState
    let fileSystem: CleanupRecordingFileSystem
    let fingerprints: ScriptedCleanupFingerprintReader
    let logger: RecordingCleanupLogger
    let unchangedSelectedURL: URL
    let replacedID: StorageRelativePath
    let selectedURLs: [URL]
    let root: URL
    let filename: String
    let digestBase64: String
    private(set) var completions: [FileOperationResult] = []

    var admission: StorageScanAdmissionToken {
        StorageScanAdmissionToken(
            root: root,
            rootIdentity: FileIdentity(
                entryIdentifier: "cleanup-root",
                resolvedIdentifier: "cleanup-root"
            ),
            rootKind: .directory,
            volumeClassification: .local,
            authorization: .init(
                isProtectedLocation: false,
                protectedScanAuthorized: true,
                cleanupAuthorized: true
            )
        )
    }

    private init(
        group: StorageDuplicateGroup,
        currentFingerprints: [URL: ComparisonFingerprint],
        unchangedSelectedURL: URL,
        replacedID: StorageRelativePath,
        failingURLs: Set<URL> = [],
        recoveryOnRollbackURLs: Set<URL> = [],
        readableCounts: [URL: Int] = [:],
        replaceAtQuarantineURLs: Set<URL> = [],
        filename: String = "",
        digest: Data = Data()
    ) {
        self.group = group
        self.unchangedSelectedURL = unchangedSelectedURL
        self.replacedID = replacedID
        selectedURLs = group.members.filter {
            group.trashIDs.contains($0.id)
        }.map(\.url)
        root = URL(filePath: "/cleanup", directoryHint: .isDirectory)
        self.filename = filename
        digestBase64 = digest.base64EncodedString()
        fingerprints = ScriptedCleanupFingerprintReader(
            currentFingerprints,
            readableCounts: readableCounts
        )
        controller = StorageCleanupController(fingerprints: fingerprints)
        fileSystem = CleanupRecordingFileSystem(identities: Dictionary(
            uniqueKeysWithValues: group.members.map {
                ($0.url, $0.fingerprint.identity)
            }
        ),
        failingTrashURLs: failingURLs,
        recoveryOnRollbackURLs: recoveryOnRollbackURLs,
        replaceAtQuarantineURLs: replaceAtQuarantineURLs)
        logger = RecordingCleanupLogger()
        operationController = FileOperationController(
            service: FileOperationService(
                fileSystem: fileSystem,
                logger: logger,
                storageFingerprints: fingerprints
            )
        )
        workspace = WorkspaceState(
            leftURL: URL(filePath: "/cleanup"),
            rightURL: URL(filePath: "/elsewhere"),
            listingService: StubDirectoryListingService(values: [:])
        )
    }

    static func allMembersMarked() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let selected = try entry(name: "selected", identity: "selected", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, selected],
            keepID: keep.id,
            trashIDs: [keep.id, selected.id],
            reclaimableBytes: 20
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: keep.fingerprint,
                selected.url: selected.fingerprint
            ],
            unchangedSelectedURL: selected.url,
            replacedID: selected.id
        )
    }

    static func oneReplacementBeforeConfirm() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let replaced = try entry(name: "replaced", identity: "original", size: 10)
        let unchanged = try entry(name: "unchanged", identity: "unchanged", size: 10)
        let replacement = fingerprint(identity: "replacement", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, replaced, unchanged],
            keepID: keep.id,
            trashIDs: [replaced.id, unchanged.id],
            reclaimableBytes: 20
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: keep.fingerprint,
                replaced.url: replacement,
                unchanged.url: unchanged.fingerprint
            ],
            unchangedSelectedURL: unchanged.url,
            replacedID: replaced.id
        )
    }

    static func replacedKeepBeforeConfirm() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let first = try entry(name: "first", identity: "first", size: 10)
        let second = try entry(name: "second", identity: "second", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, first, second],
            keepID: keep.id,
            trashIDs: [first.id, second.id],
            reclaimableBytes: 20
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: fingerprint(identity: "replacement", size: 10),
                first.url: first.fingerprint,
                second.url: second.fingerprint
            ],
            unchangedSelectedURL: first.url,
            replacedID: keep.id
        )
    }

    static func unreadableKeepBeforeConfirm() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let first = try entry(name: "first", identity: "first", size: 10)
        let second = try entry(name: "second", identity: "second", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, first, second],
            keepID: keep.id,
            trashIDs: [first.id, second.id],
            reclaimableBytes: 20
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                first.url: first.fingerprint,
                second.url: second.fingerprint
            ],
            unchangedSelectedURL: first.url,
            replacedID: keep.id
        )
    }

    static func verifiedSelection() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let selected = try entry(name: "selected", identity: "selected", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, selected],
            keepID: keep.id,
            trashIDs: [selected.id],
            reclaimableBytes: 10
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: keep.fingerprint,
                selected.url: selected.fingerprint
            ],
            unchangedSelectedURL: selected.url,
            replacedID: selected.id
        )
    }

    static func keepDisappearsBetweenSelectedItems() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep-live", identity: "keep-live", size: 10)
        let first = try entry(name: "first-live", identity: "first-live", size: 10)
        let second = try entry(name: "second-live", identity: "second-live", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, first, second],
            keepID: keep.id,
            trashIDs: [first.id, second.id],
            reclaimableBytes: 20
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: keep.fingerprint,
                first.url: first.fingerprint,
                second.url: second.fingerprint
            ],
            unchangedSelectedURL: first.url,
            replacedID: second.id,
            readableCounts: [keep.url: 1]
        )
    }

    static func replacementAtQuarantineBoundary() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep-race", identity: "keep-race", size: 10)
        let selected = try entry(name: "selected-race", identity: "original", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, selected],
            keepID: keep.id,
            trashIDs: [selected.id],
            reclaimableBytes: 10
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: keep.fingerprint,
                selected.url: selected.fingerprint
            ],
            unchangedSelectedURL: selected.url,
            replacedID: selected.id,
            replaceAtQuarantineURLs: [selected.url]
        )
    }

    static func oneTrashFailureAndSiblingSuccess() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let failed = try entry(name: "failed", identity: "failed", size: 10)
        let succeeded = try entry(name: "succeeded", identity: "succeeded", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, failed, succeeded],
            keepID: keep.id,
            trashIDs: [failed.id, succeeded.id],
            reclaimableBytes: 20
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: Dictionary(uniqueKeysWithValues: group.members.map {
                ($0.url, $0.fingerprint)
            }),
            unchangedSelectedURL: succeeded.url,
            replacedID: failed.id,
            failingURLs: [failed.url]
        )
    }

    static func recoveryAndOrdinaryFailure() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let recovery = try entry(name: "recovery", identity: "recovery", size: 10)
        let failed = try entry(name: "failed", identity: "failed", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, recovery, failed],
            keepID: keep.id,
            trashIDs: [recovery.id, failed.id],
            reclaimableBytes: 20
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: Dictionary(uniqueKeysWithValues: group.members.map {
                ($0.url, $0.fingerprint)
            }),
            unchangedSelectedURL: failed.url,
            replacedID: recovery.id,
            failingURLs: [recovery.url, failed.url],
            recoveryOnRollbackURLs: [recovery.url]
        )
    }

    static func mixedPreflightAndTrashOutcomes() throws -> StorageCleanupFixture {
        let keep = try entry(name: "keep", identity: "keep", size: 10)
        let failed = try entry(name: "failed", identity: "failed", size: 10)
        let skipped = try entry(name: "skipped", identity: "skipped", size: 10)
        let succeeded = try entry(name: "succeeded", identity: "succeeded", size: 10)
        let group = StorageDuplicateGroup(
            id: groupID(size: 10),
            members: [keep, failed, skipped, succeeded],
            keepID: keep.id,
            trashIDs: [failed.id, skipped.id, succeeded.id],
            reclaimableBytes: 30
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: keep.fingerprint,
                failed.url: failed.fingerprint,
                skipped.url: fingerprint(identity: "replacement", size: 10),
                succeeded.url: succeeded.fingerprint
            ],
            unchangedSelectedURL: succeeded.url,
            replacedID: skipped.id,
            failingURLs: [failed.url]
        )
    }

    static func privacySensitiveSelection() throws -> StorageCleanupFixture {
        let filename = "private-storage-\(UUID().uuidString).bin"
        let digest = Data("digest-\(UUID().uuidString)".utf8)
        let keep = try entry(name: "keep", identity: "private-keep", size: 10)
        let selected = try entry(
            name: filename,
            identity: "private-selected",
            size: 10
        )
        let group = StorageDuplicateGroup(
            id: StorageDuplicateGroupID(byteSize: 10, completeDigest: digest),
            members: [keep, selected],
            keepID: keep.id,
            trashIDs: [selected.id],
            reclaimableBytes: 10
        )
        return StorageCleanupFixture(
            group: group,
            currentFingerprints: [
                keep.url: keep.fingerprint,
                selected.url: selected.fingerprint
            ],
            unchangedSelectedURL: selected.url,
            replacedID: selected.id,
            filename: filename,
            digest: digest
        )
    }

    func confirm() async -> Bool {
        let started = await controller.confirm(
            currentGeneration: 1,
            currentAdmission: admission,
            groups: [group],
            operationController: operationController,
            workspace: workspace,
            validateAdmission: { _ in true },
            onCompletion: record
        )
        #expect(await waitUntilIdle())
        return started
    }

    func record(_ result: FileOperationResult) {
        completions.append(result)
    }

    func waitUntilIdle(
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !operationController.isRunning { return true }
            await Task.yield()
        }
        return !operationController.isRunning
    }

    private static func entry(
        name: String,
        identity: String,
        size: Int64
    ) throws -> StorageEntry {
        StorageEntry(
            relativePath: try StorageRelativePath(components: [name]),
            url: URL(filePath: "/cleanup/\(name)"),
            kind: .regularFile,
            category: .other,
            fingerprint: fingerprint(identity: identity, size: size),
            typeDescription: "File"
        )
    }

    private static func fingerprint(
        identity: String,
        size: Int64
    ) -> ComparisonFingerprint {
        ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: identity,
                resolvedIdentifier: identity
            ),
            byteSize: size,
            modifiedAt: Date(timeIntervalSince1970: 100),
            rawModifiedAt: ComparisonModificationTimestamp(
                seconds: 100,
                nanoseconds: 123
            )
        )
    }

    private static func groupID(size: Int64) -> StorageDuplicateGroupID {
        StorageDuplicateGroupID(
            byteSize: size,
            completeDigest: Data([0xCA, 0xFE])
        )
    }
}

private actor ScriptedCleanupFingerprintReader: StorageEntryFingerprintReading {
    private let fingerprints: [URL: ComparisonFingerprint]
    private let readableCounts: [URL: Int]
    private var reads: [URL: Int] = [:]

    init(
        _ fingerprints: [URL: ComparisonFingerprint],
        readableCounts: [URL: Int] = [:]
    ) {
        self.fingerprints = fingerprints
        self.readableCounts = readableCounts
    }

    func fingerprint(of url: URL) async throws -> ComparisonFingerprint {
        reads[url, default: 0] += 1
        if let limit = readableCounts[url], reads[url, default: 0] > limit {
            throw CleanupFixtureError.unreadable
        }
        guard let fingerprint = fingerprints[url] else {
            throw CleanupFixtureError.unreadable
        }
        return fingerprint
    }
}

private enum CleanupFixtureError: LocalizedError {
    case unreadable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "This item could not be moved to Trash."
        case .unsupported:
            "The fixture does not support this operation."
        }
    }
}

private actor CleanupRecordingFileSystem: FileSystemAccess {
    private var identities: [URL: FileIdentity]
    private let failingTrashURLs: Set<URL>
    private let recoveryOnRollbackURLs: Set<URL>
    private let replaceAtQuarantineURLs: Set<URL>
    private var trashed: [URL] = []
    private var attemptedTrash: [URL] = []
    private var pathOnlyTrashCalls = 0
    private var identifiedTrashCalls = 0
    private var removeCalls = 0
    private var quarantinedOriginals: [URL: URL] = [:]

    init(
        identities: [URL: FileIdentity],
        failingTrashURLs: Set<URL> = [],
        recoveryOnRollbackURLs: Set<URL> = [],
        replaceAtQuarantineURLs: Set<URL> = []
    ) {
        self.identities = identities
        self.failingTrashURLs = failingTrashURLs
        self.recoveryOnRollbackURLs = recoveryOnRollbackURLs
        self.replaceAtQuarantineURLs = replaceAtQuarantineURLs
    }

    func trashedURLs() -> [URL] { trashed }
    func attemptedTrashURLs() -> [URL] { attemptedTrash }
    func pathOnlyTrashCount() -> Int { pathOnlyTrashCalls }
    func identifiedTrashCount() -> Int { identifiedTrashCalls }
    func removeCount() -> Int { removeCalls }
    func existsAt(_ url: URL) -> Bool { identities[url] != nil }

    func exists(_ url: URL) async -> Bool { identities[url] != nil }
    func createDirectory(_ url: URL) async throws { throw CleanupFixtureError.unsupported }
    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity {
        throw CleanupFixtureError.unsupported
    }
    func move(_ source: URL, to destination: URL) async throws {
        throw CleanupFixtureError.unsupported
    }
    func remove(_ url: URL) async throws {
        removeCalls += 1
        identities.removeValue(forKey: url)
    }
    func replace(_ destination: URL, with stagedItem: URL) async throws {
        throw CleanupFixtureError.unsupported
    }
    func identity(of url: URL) async throws -> FileIdentity? { identities[url] }
    func move(
        _ source: URL,
        identifiedBy identity: FileIdentity,
        to destination: URL
    ) async throws {
        throw CleanupFixtureError.unsupported
    }
    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        removeCalls += 1
        identities.removeValue(forKey: url)
    }
    func replace(
        _ destination: URL,
        identifiedBy destinationIdentity: FileIdentity,
        with stagedItem: URL,
        identifiedBy stagedIdentity: FileIdentity
    ) async throws {
        throw CleanupFixtureError.unsupported
    }
    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation {
        throw CleanupFixtureError.unsupported
    }
    func removeStagingDirectory(_ reservation: StagingReservation) async throws {
        // Quarantine directories are virtual in this fixture.
    }
    func fingerprint(of source: URL) async throws -> SourceFingerprint {
        throw CleanupFixtureError.unsupported
    }
    func trash(_ url: URL) async throws {
        pathOnlyTrashCalls += 1
        trashed.append(url)
        identities.removeValue(forKey: url)
    }
    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        identifiedTrashCalls += 1
        let reportedURL = quarantinedOriginals[url] ?? url
        attemptedTrash.append(reportedURL)
        guard identities[url] == identity else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        guard !failingTrashURLs.contains(reportedURL) else {
            throw CleanupFixtureError.unreadable
        }
        trashed.append(reportedURL)
        identities.removeValue(forKey: url)
        quarantinedOriginals.removeValue(forKey: url)
    }
    func quarantineForTrash(
        _ url: URL,
        identifiedBy identity: FileIdentity
    ) async throws -> StorageTrashQuarantine {
        if replaceAtQuarantineURLs.contains(url) {
            identities[url] = FileIdentity(
                entryIdentifier: "replacement",
                resolvedIdentifier: "replacement"
            )
        }
        guard identities[url] == identity else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        let directory = url.deletingLastPathComponent().appending(
            path: ".cleanup-quarantine-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let item = directory.appending(path: "payload")
        let reservation = StagingReservation(
            directory: directory,
            directoryIdentity: FileIdentity(
                entryIdentifier: directory.path,
                resolvedIdentifier: directory.path
            ),
            item: item
        )
        identities.removeValue(forKey: url)
        identities[item] = identity
        quarantinedOriginals[item] = url
        return StorageTrashQuarantine(
            originalURL: url,
            quarantinedURL: item,
            identity: identity,
            reservation: reservation
        )
    }
    func rollbackTrashQuarantine(_ quarantine: StorageTrashQuarantine) async throws {
        if recoveryOnRollbackURLs.contains(quarantine.originalURL) {
            throw StorageTrashAccessError.recoveryRequired
        }
        guard identities[quarantine.originalURL] == nil,
              identities[quarantine.quarantinedURL] == quarantine.identity
        else {
            throw FileSystemAccessError.identityMismatch(quarantine.originalURL)
        }
        identities.removeValue(forKey: quarantine.quarantinedURL)
        identities[quarantine.originalURL] = quarantine.identity
        quarantinedOriginals.removeValue(forKey: quarantine.quarantinedURL)
    }
    func moveTrashQuarantineAtomically(
        _ quarantine: StorageTrashQuarantine
    ) async throws -> URL {
        do {
            try await trash(
                quarantine.quarantinedURL,
                identifiedBy: quarantine.identity
            )
            return quarantine.quarantinedURL
        } catch {
            do {
                try await rollbackTrashQuarantine(quarantine)
            } catch {
                throw StorageTrashAccessError.recoveryRequired
            }
            throw StorageTrashAccessError.failedButRestored
        }
    }
    func names(in directory: URL) async throws -> Set<String> { [] }
    func volumeIdentifier(for url: URL) async throws -> String { "cleanup-volume" }
    func byteSize(of url: URL) async throws -> Int64? { nil }
    func availableCapacity(at url: URL) async throws -> Int64? { nil }
    func prepareDirectoryHierarchy(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        relativeComponents: [String]
    ) async throws -> PreparedDirectoryHierarchy {
        throw CleanupFixtureError.unsupported
    }
    func removeEmptyOwnedDirectories(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        directories: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) async throws {
        throw CleanupFixtureError.unsupported
    }
}

private actor RecordingCleanupLogger: OperationLogging {
    private(set) var values: [String] = []

    func record(
        kind: FileOperationKind,
        duration _: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int
    ) {
        values.append(
            "operation=\(kind.rawValue) succeeded=\(succeeded) "
                + "failed=\(failed) skipped=\(skipped)"
        )
    }
}
