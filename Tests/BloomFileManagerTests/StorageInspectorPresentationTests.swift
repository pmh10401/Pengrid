import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct StorageInspectorPresentationTests {
    @Test func enteringStorageInspectorExitsComparisonAndPreservesPaneState() async {
        let fixture = await StoragePresentationFixture.comparingWorkspace()
        let before = fixture.snapshot

        StorageInspectorCommandActions.toggle(
            workspace: fixture.workspace,
            comparison: fixture.comparison,
            storage: fixture.storage
        )

        #expect(!fixture.comparison.isActive)
        #expect(fixture.storage.isActive)
        #expect(fixture.snapshot == before)
    }

    @Test func enteringComparisonExitsStorageInspector() async {
        let fixture = await StoragePresentationFixture.ordinaryWorkspace()
        fixture.storage.enter()

        ComparisonCommandActions.toggle(
            workspace: fixture.workspace,
            comparison: fixture.comparison,
            storage: fixture.storage
        )

        #expect(!fixture.storage.isActive)
        #expect(await storagePresentationWait { fixture.comparison.isActive })
        fixture.comparison.stop()
    }

    @Test func exitingStorageInspectorRestoresCapturedPaneFocusOnNextTurn() async {
        let fixture = await StoragePresentationFixture.ordinaryWorkspace()
        fixture.workspace.activate(.right)
        fixture.storage.enter()

        StorageInspectorCommandActions.toggle(
            workspace: fixture.workspace,
            comparison: fixture.comparison,
            storage: fixture.storage
        )

        #expect(!fixture.storage.isActive)
        #expect(fixture.workspace.right.focusRequestID == nil)
        await Task.yield()
        #expect(fixture.workspace.right.focusRequestID != nil)
        #expect(fixture.workspace.left.focusRequestID == nil)
    }

    @Test func phasePresentationAlwaysHasVisibleAndSpokenStatus() {
        for phase in [
            StorageAnalysisPhase.inactive,
            .idle,
            .scanning,
            .verifying,
            .complete,
            .paused,
            .cancelled
        ] {
            #expect(!StorageInspectorPresentation.phaseTitle(phase).isEmpty)
            #expect(!StorageInspectorPresentation.phaseAccessibilityValue(phase).isEmpty)
        }
    }

    @Test func duplicateRowsExposeRelativeMetadataAndVerificationWithoutLogPaths() async throws {
        let fixture = try await StoragePresentationFixture.verifiedDuplicateGroup()
        let rows = StorageInspectorPresentation.rows(
            section: .duplicates,
            store: fixture.store
        )

        #expect(rows.count == 2)
        #expect(rows[0].name == "IMG_0001.mov")
        #expect(rows[0].relativeParent == "Photos/2025")
        #expect(rows[0].sizeText == "4 KB")
        #expect(rows[0].modifiedText == "Jan 2, 2025 at 3:04 AM")
        #expect(rows[0].categoryText == "Video")
        #expect(rows[0].verificationText == "Verified duplicate")
        #expect(rows[0].accessibilityLabel
            == "IMG_0001.mov, Photos/2025, 4 KB, Jan 2, 2025 at 3:04 AM, Video, Verified duplicate")
        #expect(rows[0].accessibilityLabel.contains(fixture.root.path) == false)
    }

    @Test func duplicatePresentationNavigatesGroupsInsteadOfFlatteningEveryMember() async throws {
        let fixture = try await StoragePresentationFixture.twoVerifiedDuplicateGroups()
        let summaries = StorageInspectorPresentation.duplicateGroupSummaries(
            store: fixture.store
        )

        #expect(summaries.count == 2)
        #expect(summaries.map(\.memberCount) == [2, 2])
        fixture.store.selectedDuplicateGroupID = summaries[1].id
        let rows = StorageInspectorPresentation.rows(
            section: .duplicates,
            store: fixture.store
        )
        #expect(rows.map(\.id) == summaries[1].memberIDs)
    }

    @Test func progressiveResultsPolicyShowsTheTableAsSoonAsEntriesExist() {
        #expect(StorageInspectorResultsPolicy.showsTable(
            phase: .scanning,
            entryCount: 1
        ))
        #expect(StorageInspectorResultsPolicy.showsTable(
            phase: .verifying,
            entryCount: 1
        ))
        #expect(!StorageInspectorResultsPolicy.showsTable(
            phase: .scanning,
            entryCount: 0
        ))
    }

    @Test func largeFileRowsPreserveDescendingSizeOrder() async throws {
        let fixture = try await StoragePresentationFixture.thresholdRows()
        fixture.store.thresholds.largeFileBytes = 0

        let rows = StorageInspectorPresentation.rows(
            section: .largeFiles,
            store: fixture.store
        )

        #expect(rows.map(\.name) == [
            "z-large.bin",
            "m-medium.bin",
            "a-small.bin"
        ])
    }

    @Test func reviewSummaryCountsOnlyExplicitTrashMarksAndNamesTheKeptCopies() throws {
        let fixture = try StoragePresentationFixture.cleanupReview()
        let summary = StorageInspectorPresentation.cleanupSummary(fixture.review)

        #expect(summary.contains("1 file"))
        #expect(summary.contains(fixture.reclaimableText))
        #expect(summary.contains("kept"))
        #expect(summary.contains(fixture.root.path) == false)
    }

    @Test func mixedCleanupResultSummaryKeepsEveryOutcomeVisible() {
        let root = URL(filePath: "/cleanup-summary", directoryHint: .isDirectory)
        let result = FileOperationResult(outcomes: [
            .succeeded(source: root.appending(path: "succeeded"), destination: nil),
            .recoveryNeeded(source: root.appending(path: "recoverable")),
            .failed(source: root.appending(path: "failed"), message: "Unavailable"),
            .skipped(source: root.appending(path: "skipped")),
            .cancelled(source: root.appending(path: "cancelled"))
        ])

        #expect(
            StorageInspectorPresentation.cleanupResultSummary(result)
                == "1 succeeded, 1 recovery needed, 1 failed, 1 skipped, 1 cancelled."
        )
    }

    @Test func recoveryPresentationIsStableAndMetadataFree() {
        let sensitive = URL(filePath: "/private/root/secret-name.bin")
        let outcome = FileOperationItemOutcome.recoveryNeeded(source: sensitive)
        let result = FileOperationResult(outcomes: [outcome])
        let summary = OperationStatusSummary(result: result)
        let details = OperationResultDetails(result: result)
        let messages = [
            StorageInspectorPresentation.cleanupOutcomeTitle(outcome),
            StorageInspectorPresentation.cleanupOutcomeGuidance(outcome) ?? "",
            StorageInspectorPresentation.cleanupResultSummary(result),
            summary.accessibilityLabel,
            details.accessibilityLabel
        ] + details.items.flatMap { [$0.name, $0.guidance] }

        #expect(StorageInspectorPresentation.cleanupOutcomeTitle(outcome) == "Recovery needed")
        #expect(
            StorageInspectorPresentation.cleanupOutcomeGuidance(outcome)
                == "A staged item was retained for safe manual recovery."
        )
        #expect(summary.recoveryNeeded == 1)
        #expect(details.items.map(\.status) == [.recoveryNeeded])
        #expect(messages.contains { $0.contains(sensitive.path) } == false)
        #expect(messages.contains { $0.contains(sensitive.lastPathComponent) } == false)
    }

    @Test func storageInspectorUsesTheSharedRuntimeInstances() async {
        let fixture = await StoragePresentationFixture.ordinaryWorkspace()
        let quickLook = QuickLookController()
        let materializer = InMemoryCloudMaterializer()
        let probeURL = URL(filePath: "/storage-runtime/probe")
        let fileSystem = RecordingFileSystem()
        let accessCoordinator = CloudLocationScopedAccessCoordinator()
        let operations = FileOperationController(
            service: FileOperationService(
                fileSystem: fileSystem,
                accessCoordinator: accessCoordinator
            ),
            materializer: materializer
        )
        let cleanup = StorageCleanupController(
            fingerprints: NoopStoragePresentationFingerprintReader()
        )
        let view = StorageInspectorView(
            workspace: fixture.workspace,
            storage: fixture.storage,
            cleanupController: cleanup,
            quickLookController: quickLook,
            materializer: materializer,
            fileSystem: fileSystem,
            workspaceActions: StoragePresentationWorkspaceActions(),
            operationController: operations,
            accessCoordinator: accessCoordinator
        )

        #expect(view.quickLookController === quickLook)
        #expect(view.operationController === operations)
        #expect(view.accessCoordinator === accessCoordinator)
        _ = await view.materializer.materialize(
            [],
            purpose: .quickLook,
            progress: { _ in }
        )
        _ = try? await view.fileSystem.identity(of: probeURL)
        #expect(await materializer.recordedCalls().count == 1)
        #expect(await fileSystem.events.contains("identity:\(probeURL.path)"))
    }

    @Test func cleanupDecisionPolicyLocksForReviewAndRunningOperation() {
        #expect(StorageInspectorDecisionPolicy.canMutate(
            phase: .complete,
            isOperationRunning: false,
            hasPendingReview: false,
            cleanupAuthorized: true
        ))
        #expect(!StorageInspectorDecisionPolicy.canMutate(
            phase: .complete,
            isOperationRunning: false,
            hasPendingReview: true,
            cleanupAuthorized: true
        ))
        #expect(!StorageInspectorDecisionPolicy.canMutate(
            phase: .complete,
            isOperationRunning: true,
            hasPendingReview: false,
            cleanupAuthorized: true
        ))
        #expect(!StorageInspectorDecisionPolicy.canMutate(
            phase: .verifying,
            isOperationRunning: false,
            hasPendingReview: false,
            cleanupAuthorized: true
        ))
        #expect(!StorageInspectorDecisionPolicy.canMutate(
            phase: .complete,
            isOperationRunning: false,
            hasPendingReview: false,
            cleanupAuthorized: false
        ))
    }

    @Test func genericProgressAndFailuresNeverExposeSensitiveMetadata() async throws {
        let fixture = try await StoragePrivacyFixture.make()

        for value in fixture.allUserIndependentMessages {
            #expect(!value.contains(fixture.root.path))
            #expect(!value.contains(fixture.filename))
            #expect(!value.contains(fixture.digestBase64))
        }
    }
}

@MainActor
private struct StoragePresentationFixture {
    let workspace: WorkspaceState
    let comparison: ComparisonCoordinator
    let storage: StorageAnalysisStore

    var snapshot: StorageWorkspaceSnapshot {
        StorageWorkspaceSnapshot(workspace: workspace)
    }

    static func ordinaryWorkspace() async -> Self {
        let left = URL(filePath: "/storage-presentation/left", directoryHint: .isDirectory)
        let right = URL(filePath: "/storage-presentation/right", directoryHint: .isDirectory)
        let leftChild = left.appending(path: "child", directoryHint: .isDirectory)
        let rightChild = right.appending(path: "child", directoryHint: .isDirectory)
        let workspace = WorkspaceState(
            leftURL: left,
            rightURL: right,
            leftSort: FileSort(key: .size, direction: .descending),
            rightSort: FileSort(key: .modifiedAt, direction: .ascending),
            listingService: StubDirectoryListingService(values: [:])
        )
        await workspace.left.navigate(to: leftChild)
        await workspace.left.goBack()
        await workspace.right.navigate(to: rightChild)
        workspace.left.selection = [left.appending(path: "selected-left.txt")]
        workspace.right.selection = [rightChild.appending(path: "selected-right.txt")]
        workspace.activate(.right)

        return Self(
            workspace: workspace,
            comparison: ComparisonCoordinator(
                listings: InMemoryComparisonListingService([:]),
                checksums: StoragePresentationChecksumService(),
                monitor: InMemoryComparisonTreeMonitor()
            ),
            storage: StorageAnalysisStore(
                scanner: EmptyStorageScanner(),
                duplicates: EmptyStorageDuplicateDetector(),
                locationPolicy: AllowStorageLocationPolicy()
            )
        )
    }

    static func comparingWorkspace() async -> Self {
        let fixture = await ordinaryWorkspace()
        fixture.comparison.start(workspace: fixture.workspace)
        _ = await storagePresentationWait { fixture.comparison.isActive }
        return fixture
    }

    static func verifiedDuplicateGroup() async throws -> StorageResultPresentationFixture {
        let root = URL(
            filePath: "/storage-presentation/private-library-root",
            directoryHint: .isDirectory
        )
        let entries = try [
            storageEntry(
                root: root,
                components: ["Photos", "2025", "IMG_0001.mov"],
                identity: "photo-copy",
                size: 4_096
            ),
            storageEntry(
                root: root,
                components: ["Reference", "IMG_0001.mov"],
                identity: "reference-copy",
                size: 4_096
            )
        ]
        let group = StorageDuplicateGroup(
            id: StorageDuplicateGroupID(
                byteSize: 4_096,
                completeDigest: Data([0xCA, 0xFE])
            ),
            members: entries,
            keepID: entries[0].id,
            trashIDs: [],
            reclaimableBytes: 0
        )
        let store = StorageAnalysisStore(
            scanner: LiteralStorageScanner(root: root, entries: entries),
            duplicates: LiteralStorageDuplicateDetector(group: group),
            locationPolicy: AllowStorageLocationPolicy()
        )
        store.enter()
        await store.requestScan(at: root, options: .init())
        return StorageResultPresentationFixture(root: root, store: store)
    }

    static func cleanupReview() throws -> CleanupReviewPresentationFixture {
        let root = URL(
            filePath: "/storage-presentation/private-library-root",
            directoryHint: .isDirectory
        )
        let keep = try storageEntry(
            root: root,
            components: ["Photos", "2025", "IMG_0001.mov"],
            identity: "photo-copy",
            size: 4_096
        )
        let trash = try storageEntry(
            root: root,
            components: ["Reference", "IMG_0001.mov"],
            identity: "reference-copy",
            size: 4_096
        )
        let groupID = StorageDuplicateGroupID(
            byteSize: 4_096,
            completeDigest: Data([0xCA, 0xFE])
        )
        return CleanupReviewPresentationFixture(
            root: root,
            review: StorageCleanupReview(
                id: UUID(uuidString: "B1000000-0000-0000-0000-000000000007")!,
                generation: 7,
                admission: testAdmission(root: root, identity: root.path),
                groups: [
                    StorageCleanupReviewGroup(
                        groupID: groupID,
                        keep: keep,
                        trash: [trash]
                    )
                ],
                reclaimableBytes: 4_096
            ),
            reclaimableText: "4 KB"
        )
    }

    static func twoVerifiedDuplicateGroups() async throws -> StorageResultPresentationFixture {
        let root = URL(
            filePath: "/storage-presentation/grouped-duplicates",
            directoryHint: .isDirectory
        )
        let entries = try [
            storageEntry(
                root: root,
                components: ["A", "first.bin"],
                identity: "a-first",
                size: 100
            ),
            storageEntry(
                root: root,
                components: ["A", "second.bin"],
                identity: "a-second",
                size: 100
            ),
            storageEntry(
                root: root,
                components: ["B", "first.bin"],
                identity: "b-first",
                size: 200
            ),
            storageEntry(
                root: root,
                components: ["B", "second.bin"],
                identity: "b-second",
                size: 200
            )
        ]
        let groups = [
            StorageDuplicateGroup(
                id: StorageDuplicateGroupID(
                    byteSize: 100,
                    completeDigest: Data([0x01])
                ),
                members: Array(entries[0 ... 1]),
                keepID: entries[0].id,
                trashIDs: [],
                reclaimableBytes: 0
            ),
            StorageDuplicateGroup(
                id: StorageDuplicateGroupID(
                    byteSize: 200,
                    completeDigest: Data([0x02])
                ),
                members: Array(entries[2 ... 3]),
                keepID: entries[2].id,
                trashIDs: [],
                reclaimableBytes: 0
            )
        ]
        let store = StorageAnalysisStore(
            scanner: LiteralStorageScanner(root: root, entries: entries),
            duplicates: LiteralStorageDuplicateDetector(groups: groups),
            locationPolicy: AllowStorageLocationPolicy()
        )
        store.enter()
        await store.requestScan(at: root, options: .init())
        return StorageResultPresentationFixture(root: root, store: store)
    }

    static func thresholdRows() async throws -> StorageResultPresentationFixture {
        let root = URL(
            filePath: "/storage-presentation/thresholds",
            directoryHint: .isDirectory
        )
        let entries = try [
            storageEntry(
                root: root,
                components: ["a-small.bin"],
                identity: "small",
                size: 10
            ),
            storageEntry(
                root: root,
                components: ["m-medium.bin"],
                identity: "medium",
                size: 20
            ),
            storageEntry(
                root: root,
                components: ["z-large.bin"],
                identity: "large",
                size: 30
            )
        ]
        let store = StorageAnalysisStore(
            scanner: LiteralStorageScanner(root: root, entries: entries),
            duplicates: EmptyStorageDuplicateDetector(),
            locationPolicy: AllowStorageLocationPolicy()
        )
        store.enter()
        await store.requestScan(at: root, options: .init())
        return StorageResultPresentationFixture(root: root, store: store)
    }

    private static func storageEntry(
        root: URL,
        components: [String],
        identity: String,
        size: Int64
    ) throws -> StorageEntry {
        let relativePath = try StorageRelativePath(components: components)
        return StorageEntry(
            relativePath: relativePath,
            url: components.reduce(root) {
                $0.appending(path: $1, directoryHint: .notDirectory)
            },
            kind: .regularFile,
            category: .video,
            fingerprint: ComparisonFingerprint(
                identity: FileIdentity(
                    entryIdentifier: identity,
                    resolvedIdentifier: identity
                ),
                byteSize: size,
                modifiedAt: Date(timeIntervalSince1970: 1_735_787_040),
                rawModifiedAt: ComparisonModificationTimestamp(
                    seconds: 1_735_787_040,
                    nanoseconds: 0
                )
            ),
            typeDescription: "QuickTime movie"
        )
    }
}

@MainActor
private struct StorageResultPresentationFixture {
    let root: URL
    let store: StorageAnalysisStore
}

private struct CleanupReviewPresentationFixture {
    let root: URL
    let review: StorageCleanupReview
    let reclaimableText: String
}

@MainActor
private struct StoragePrivacyFixture {
    let root: URL
    let filename: String
    let digestBase64: String
    let allUserIndependentMessages: [String]

    static func make() async throws -> Self {
        let root = URL(
            filePath: "/private/storage-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let filename = "private-\(UUID().uuidString).bin"
        let digest = Data("private-digest-\(UUID().uuidString)".utf8)
        let entry = StorageEntry(
            relativePath: try StorageRelativePath(components: [filename]),
            url: root.appending(path: filename, directoryHint: .notDirectory),
            kind: .regularFile,
            category: .other,
            fingerprint: ComparisonFingerprint(
                identity: FileIdentity(
                    entryIdentifier: "private-entry",
                    resolvedIdentifier: "private-resolved"
                ),
                byteSize: 10,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
                rawModifiedAt: ComparisonModificationTimestamp(
                    seconds: 1,
                    nanoseconds: 1
                )
            ),
            typeDescription: "Data"
        )
        let groupID = StorageDuplicateGroupID(
            byteSize: 10,
            completeDigest: digest
        )
        let review = StorageCleanupReview(
            id: UUID(),
            generation: 1,
            admission: testAdmission(root: root, identity: root.path),
            groups: [
                StorageCleanupReviewGroup(
                    groupID: groupID,
                    keep: entry,
                    trash: []
                )
            ],
            reclaimableBytes: 0
        )
        let store = StorageAnalysisStore(
            scanner: LiteralStorageScanner(root: root, entries: [entry]),
            duplicates: PrivacyStorageDuplicateDetector(
                id: entry.id,
                sensitiveError: "\(root.path)/\(filename)/\(digest.base64EncodedString())"
            ),
            locationPolicy: AllowStorageLocationPolicy()
        )
        store.enter()
        await store.requestScan(at: root, options: .init())
        let row = try #require(
            StorageInspectorPresentation.rows(section: .overview, store: store).first
        )
        let phases: [StorageAnalysisPhase] = [
            .inactive,
            .idle,
            .scanning,
            .verifying,
            .complete,
            .paused,
            .cancelled
        ]
        let messages = phases.flatMap {
            [
                StorageInspectorPresentation.phaseTitle($0),
                StorageInspectorPresentation.phaseAccessibilityValue($0)
            ]
        } + [
            row.verificationText,
            StorageInspectorPresentation.cleanupSummary(review),
            StorageCleanupValidationError.noSelection.errorDescription ?? "",
            StorageCleanupValidationError.missingKeepCopy(groupID).errorDescription ?? "",
            StorageCleanupValidationError.staleReview.errorDescription ?? "",
            OperationStatusSummary(result: FileOperationResult(outcomes: [
                .failed(
                    source: entry.url,
                    message: "\(root.path)/\(filename)/\(digest.base64EncodedString())"
                )
            ])).accessibilityLabel
        ]
        return Self(
            root: root,
            filename: filename,
            digestBase64: digest.base64EncodedString(),
            allUserIndependentMessages: messages
        )
    }
}

private struct StorageWorkspaceSnapshot: Equatable {
    let leftDirectory: URL
    let rightDirectory: URL
    let leftBackHistory: [URL]
    let rightBackHistory: [URL]
    let leftForwardHistory: [URL]
    let rightForwardHistory: [URL]
    let leftSelection: Set<URL>
    let rightSelection: Set<URL>
    let leftSort: FileSort
    let rightSort: FileSort
    let activePaneID: PaneID

    @MainActor
    init(workspace: WorkspaceState) {
        leftDirectory = workspace.left.currentDirectory
        rightDirectory = workspace.right.currentDirectory
        leftBackHistory = workspace.left.backHistory
        rightBackHistory = workspace.right.backHistory
        leftForwardHistory = workspace.left.forwardHistory
        rightForwardHistory = workspace.right.forwardHistory
        leftSelection = workspace.left.selection
        rightSelection = workspace.right.selection
        leftSort = workspace.left.sort
        rightSort = workspace.right.sort
        activePaneID = workspace.activePaneID
    }
}

private struct EmptyStorageScanner: StorageScanning {
    func identity(of root: URL) async throws -> FileIdentity {
        FileIdentity(entryIdentifier: root.path, resolvedIdentifier: root.path)
    }

    func batches(for _: StorageScanRequest)
        -> AsyncThrowingStream<StorageScanBatch, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct EmptyStorageDuplicateDetector: StorageDuplicateDetecting {
    func events(for _: [StorageEntry])
        -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct LiteralStorageScanner: StorageScanning {
    let root: URL
    let entries: [StorageEntry]

    func identity(of requestedRoot: URL) async throws -> FileIdentity {
        #expect(requestedRoot == root)
        return FileIdentity(
            entryIdentifier: root.path,
            resolvedIdentifier: root.path
        )
    }

    func batches(for _: StorageScanRequest)
        -> AsyncThrowingStream<StorageScanBatch, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StorageScanBatch(records: entries.map(StorageScanRecord.entry)))
            continuation.finish()
        }
    }
}

private struct LiteralStorageDuplicateDetector: StorageDuplicateDetecting {
    let groups: [StorageDuplicateGroup]

    init(group: StorageDuplicateGroup) {
        groups = [group]
    }

    init(groups: [StorageDuplicateGroup]) {
        self.groups = groups
    }

    func events(for _: [StorageEntry])
        -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error> {
        AsyncThrowingStream { continuation in
            for member in groups.flatMap(\.members) {
                continuation.yield(.state(member.id, .complete))
            }
            for group in groups {
                continuation.yield(.group(group))
            }
            continuation.finish()
        }
    }
}

private struct PrivacyStorageDuplicateDetector: StorageDuplicateDetecting {
    let id: StorageRelativePath
    let sensitiveError: String

    func events(
        for _: [StorageEntry]
    ) -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.excluded(id, .unreadable(sensitiveError)))
            continuation.finish()
        }
    }
}

@MainActor
private struct AllowStorageLocationPolicy: StorageScanLocationValidating {
    func decision(for root: URL) -> StorageScanLocationDecision {
        .allowed(testAdmission(root: root, identity: root.path))
    }
}

private func testAdmission(
    root: URL,
    identity: String
) -> StorageScanAdmissionToken {
    StorageScanAdmissionToken(
        root: root.standardizedFileURL,
        rootIdentity: FileIdentity(
            entryIdentifier: identity,
            resolvedIdentifier: identity
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

private actor StoragePresentationChecksumService: ChecksumService {
    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        await progress(1)
        return ChecksumResult(digest: Data(request.url.path.utf8))
    }
}

private actor NoopStoragePresentationFingerprintReader: StorageEntryFingerprintReading {
    func fingerprint(of _: URL) async throws -> ComparisonFingerprint {
        throw CancellationError()
    }
}

@MainActor
private final class StoragePresentationWorkspaceActions: CloudLocationWorkspaceActions {
    func revealInFinder(_: URL) {}
    func applicationURL(forBundleIdentifier _: String) -> URL? { nil }
    func openApplication(at _: URL) {}
}

@MainActor
private func storagePresentationWait(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
