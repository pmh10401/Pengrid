import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct FolderSynchronizationIntegrationTests {
    @Test func requestPlansTheCompleteRowSetIndependentOfSelectionAndFilter() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(
            leftOnly: ["visible.txt"],
            identical: ["hidden-identical.txt"]
        )
        fixture.comparison.selection = []
        fixture.comparison.filter = .leftOnly
        #expect(fixture.comparison.visibleRows.count < fixture.comparison.rows.count)

        fixture.comparison.requestFolderSynchronization(.leftToRight)

        #expect(fixture.planner.receivedRows == fixture.comparison.rows)
        #expect(fixture.planner.receivedDirection == .leftToRight)
        #expect(fixture.planner.receivedRows.contains { $0.relativePath.string == "hidden-identical.txt" })
        fixture.stop()
    }

    @Test func readyCurrentComparisonStartsPreparation() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(leftOnly: ["copy.txt"])
        fixture.comparison.requestFolderSynchronization(.leftToRight)
        await fixture.preparer.waitForRequestCount(1)

        guard case let .preparing(direction, generation) = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }
        #expect(direction == .leftToRight)
        #expect(generation == fixture.comparison.session?.generation)
        #expect(await fixture.preparer.prepareCount == 1)

        await fixture.preparer.releaseSuccess()
        await settleReview(fixture.comparison)
        guard case .ready = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }
        fixture.stop()
    }

    @Test func alreadySynchronizedNeverCallsThePreparer() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(
            identical: ["same.txt"]
        )
        fixture.comparison.requestFolderSynchronization(.rightToLeft)

        guard case .alreadySynchronized = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }
        #expect(await fixture.preparer.prepareCount == 0)
        #expect(fixture.planner.receivedDirection == .rightToLeft)
        fixture.stop()
    }

    @Test func plannerBlockersNeverCallThePreparer() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(
            typeConflict: "conflict.bin"
        )
        fixture.comparison.requestFolderSynchronization(.leftToRight)

        guard case let .plannerBlocked(blockers) = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }
        #expect(!blockers.isEmpty)
        #expect(await fixture.preparer.prepareCount == 0)
        fixture.stop()
    }

    @Test func nonCurrentComparisonIsBlockedWithoutPreparation() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(leftOnly: ["copy.txt"])
        fixture.comparison.stop()
        fixture.comparison.requestFolderSynchronization(.leftToRight)

        guard case .plannerBlocked = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }
        #expect(await fixture.preparer.prepareCount == 0)
        fixture.stop()
    }

    @Test func cancellingOrStartingANewerDirectionRejectsLatePreparation() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(leftOnly: ["copy.txt"])
        fixture.comparison.requestFolderSynchronization(.leftToRight)
        await fixture.preparer.waitForRequestCount(1)
        fixture.comparison.requestFolderSynchronization(.rightToLeft)
        await fixture.preparer.waitForRequestCount(2)
        await fixture.preparer.releaseSuccess()
        await settleReview(fixture.comparison)

        guard case let .ready(review) = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }
        #expect(review.direction == .rightToLeft)
        fixture.stop()
    }

    @Test func rejectedAdmissionLeavesTheReadyReviewUnconsumed() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(leftOnly: ["copy.txt"])
        fixture.comparison.requestFolderSynchronization(.leftToRight)
        await fixture.preparer.waitForRequestCount(1)
        await fixture.preparer.releaseSuccess()
        await settleReview(fixture.comparison)
        guard case .ready = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }

        let token = fixture.controller.beginTerminationPreparation()
        #expect(fixture.controller.canAdmitFolderSynchronization == false)
        #expect(fixture.comparison.confirmFolderSynchronizationReview(
            operationController: fixture.controller,
            workspace: fixture.workspace
        ) == false)
        guard case .ready = fixture.comparison.folderSynchronizationReview else {
            throw OrchestrationError.unexpectedPresentation
        }
        #expect(fixture.comparison.synchronizationReview.state.isReady)
        #expect(await fixture.executor.executeCount == 0)

        fixture.controller.finishTerminationPreparation(token, restartQueue: true)
        #expect(fixture.comparison.confirmFolderSynchronizationReview(
            operationController: fixture.controller,
            workspace: fixture.workspace
        ))
        #expect(fixture.comparison.synchronizationReview.confirm() == nil)
        await fixture.executor.waitUntilStarted()
        #expect(await fixture.executor.executeCount == 1)
        await fixture.executor.releaseHeldExecution()
        await waitUntilQueueIdle(fixture.controller)
        fixture.stop()
    }

    @Test func successReconcilesCapturedRootsWithoutRequiringTheOldGeneration() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(leftOnly: ["copy.txt"])
        fixture.comparison.requestFolderSynchronization(.leftToRight)
        await fixture.preparer.waitForRequestCount(1)
        await fixture.preparer.releaseSuccess()
        await settleReview(fixture.comparison)

        #expect(fixture.comparison.confirmFolderSynchronizationReview(
            operationController: fixture.controller,
            workspace: fixture.workspace
        ))
        await fixture.executor.waitUntilStarted()
        let capturedRoots = (
            fixture.comparison.session?.leftRoot,
            fixture.comparison.session?.rightRoot
        )
        fixture.comparison.rootsDidChange(workspace: fixture.workspace)
        #expect(await waitUntilOrchestration {
            fixture.comparison.phase == .upToDate && fixture.comparison.session != nil
        })
        let generationAfterChange = try #require(fixture.comparison.session?.generation)

        await fixture.executor.releaseHeldExecution()
        await waitUntilQueueIdle(fixture.controller)
        #expect(await waitUntilOrchestration {
            fixture.comparison.session?.generation != generationAfterChange
                && fixture.comparison.session?.leftRoot == capturedRoots.0
                && fixture.comparison.session?.rightRoot == capturedRoots.1
        })
        fixture.stop()
    }

    @Test func failureRestartsOnlyTheCapturedWorkspaceAndRootPair() async throws {
        let fixture = try await FolderSynchronizationOrchestrationFixture.make(
            leftOnly: ["copy.txt"],
            result: FileOperationResult(outcomes: [
                .failed(source: URL(filePath: "/private/SecretSource/copy.txt"), message: "sync-failed")
            ])
        )
        fixture.comparison.requestFolderSynchronization(.leftToRight)
        await fixture.preparer.waitForRequestCount(1)
        await fixture.preparer.releaseSuccess()
        await settleReview(fixture.comparison)
        #expect(fixture.comparison.confirmFolderSynchronizationReview(
            operationController: fixture.controller,
            workspace: fixture.workspace
        ))
        await fixture.executor.waitUntilStarted()

        let other = try await FolderSynchronizationOrchestrationFixture.make(leftOnly: ["other.txt"])
        fixture.comparison.stop()
        other.comparison.start(workspace: other.workspace)
        #expect(await waitUntilOrchestration { other.comparison.phase == .upToDate })
        let otherGeneration = try #require(other.comparison.session?.generation)

        await fixture.executor.releaseHeldExecution()
        await waitUntilQueueIdle(fixture.controller)
        #expect(other.comparison.session?.generation == otherGeneration)
        #expect(other.comparison.session?.leftRoot == other.workspace.left.currentDirectory)
        other.stop()
        fixture.stop()
    }
}

@MainActor
private func settleReview(_ comparison: ComparisonCoordinator) async {
    for _ in 0..<200 {
        if !comparison.folderSynchronizationReview.isPreparing { return }
        await Task.yield()
    }
}

@MainActor
func waitUntilOrchestration(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func waitUntilQueueIdle(_ controller: FileOperationController) async {
    while controller.isRunning || !controller.queuedJobs.isEmpty {
        await Task.yield()
    }
}

private enum OrchestrationError: Error { case unexpectedPresentation }

final class RecordingFolderSynchronizationPlanner: FolderSynchronizationPlanning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRows: [ComparisonRow] = []
    private var storedDirection: ComparisonDirection?
    private let inner = FolderSynchronizationPlanningService()

    var receivedRows: [ComparisonRow] {
        lock.lock()
        defer { lock.unlock() }
        return storedRows
    }

    var receivedDirection: ComparisonDirection? {
        lock.lock()
        defer { lock.unlock() }
        return storedDirection
    }

    func plan(
        phase: ComparisonPhase,
        session: ComparisonSession?,
        rows: [ComparisonRow],
        direction: ComparisonDirection
    ) -> FolderSynchronizationPlanningResult {
        lock.lock()
        storedRows = rows
        storedDirection = direction
        lock.unlock()
        return inner.plan(phase: phase, session: session, rows: rows, direction: direction)
    }
}

actor RecordingFolderSynchronizationPreparer: FolderSynchronizationPreparing {
    private(set) var prepareCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(_ draft: FolderSynchronizationPlanDraft) async throws -> PreparedFolderSynchronizationPlan {
        prepareCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuations.append($0) }
        return PreparedFolderSynchronizationPlan(
            draft: draft,
            sourceFingerprints: [:],
            destinationFingerprints: [:],
            expectedAbsentDestinations: Set(draft.actions.compactMap {
                $0.kind == .copy ? $0.relativePath : nil
            }),
            requiredCapacityBytes: draft.estimatedRegularFileCopyBytes,
            destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
            rootAuthority: .init(
                source: .init(
                    identity: draft.sourceRootIdentity,
                    canonicalURL: draft.sourceRoot,
                    volumeIdentifier: "fixture",
                    mountIdentifier: "fixture:/"
                ),
                destination: .init(
                    identity: draft.destinationRootIdentity,
                    canonicalURL: draft.destinationRoot,
                    volumeIdentifier: "fixture",
                    mountIdentifier: "fixture:/"
                )
            )
        )
    }

    func waitForRequestCount(_ count: Int) async {
        while prepareCount < count {
            await withCheckedContinuation { requestWaiters.append($0) }
        }
    }

    func releaseSuccess() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
struct FolderSynchronizationOrchestrationFixture {
    let workspace: WorkspaceState
    let comparison: ComparisonCoordinator
    let planner: RecordingFolderSynchronizationPlanner
    let preparer: RecordingFolderSynchronizationPreparer
    let controller: FileOperationController
    let executor: RecordingFolderSynchronizationExecutor

    static func make(
        leftOnly: [String] = [],
        identical: [String] = [],
        typeConflict: String? = nil,
        result: FileOperationResult? = nil
    ) async throws -> Self {
        let leftRoot = URL(filePath: "/private/SecretSource", directoryHint: .isDirectory)
        let rightRoot = URL(filePath: "/private/SecretDestination", directoryHint: .isDirectory)
        var leftEntries: [ComparisonEntry] = []
        var rightEntries: [ComparisonEntry] = []
        for name in leftOnly {
            leftEntries.append(try orchestrationEntry(name, root: leftRoot, identity: "left-\(name)"))
        }
        for name in identical {
            leftEntries.append(try orchestrationEntry(name, root: leftRoot, identity: "same-\(name)"))
            rightEntries.append(try orchestrationEntry(name, root: rightRoot, identity: "same-\(name)"))
        }
        if let typeConflict {
            leftEntries.append(try orchestrationEntry(
                typeConflict,
                root: leftRoot,
                identity: "file-\(typeConflict)"
            ))
            rightEntries.append(try orchestrationEntry(
                typeConflict,
                root: rightRoot,
                identity: "dir-\(typeConflict)",
                kind: .directory
            ))
        }
        let listings = InMemoryComparisonListingService([
            leftRoot: leftEntries.isEmpty ? [] : [.init(records: leftEntries.map(ComparisonListingRecord.entry))],
            rightRoot: rightEntries.isEmpty ? [] : [.init(records: rightEntries.map(ComparisonListingRecord.entry))]
        ])
        let planner = RecordingFolderSynchronizationPlanner()
        let preparer = RecordingFolderSynchronizationPreparer()
        let review = FolderSynchronizationReviewModel(preparer: preparer)
        let comparison = ComparisonCoordinator(
            listings: listings,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: InMemoryComparisonTreeMonitor(),
            folderSynchronizationPlanner: planner,
            folderSynchronizationReview: review
        )
        let firstSource = leftOnly.first.map { leftRoot.appending(path: $0) }
            ?? leftRoot.appending(path: "copy.txt")
        let executor = RecordingFolderSynchronizationExecutor(
            result: result ?? FileOperationResult(outcomes: [
                .succeeded(source: firstSource, destination: rightRoot.appending(path: firstSource.lastPathComponent))
            ]),
            holdUntilReleased: true,
            progressToPublish: []
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: RecordingFileSystem(existingURLs: [leftRoot, rightRoot])),
            folderSynchronizationService: executor
        )
        let workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )
        comparison.start(workspace: workspace)
        #expect(await waitUntilOrchestration {
            comparison.phase == .upToDate && !comparison.rows.isEmpty
        })
        return Self(
            workspace: workspace,
            comparison: comparison,
            planner: planner,
            preparer: preparer,
            controller: controller,
            executor: executor
        )
    }

    func stop() {
        comparison.stop()
        controller.cancel()
    }
}

private func orchestrationEntry(
    _ name: String,
    root: URL,
    identity: String,
    kind: ComparisonEntryKind = .regularFile
) throws -> ComparisonEntry {
    let path = try ComparisonRelativePath(components: [name])
    return ComparisonEntry(
        relativePath: path,
        url: root.appending(path: name),
        kind: kind,
        fingerprint: .init(
            identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
            byteSize: kind == .regularFile ? 4 : nil,
            modifiedAt: Date(timeIntervalSince1970: 1)
        ),
        symbolicLinkTarget: nil,
        typeDescription: kind == .directory ? "Folder" : "File"
    )
}
