import Foundation
import Testing
@testable import BloomFileManager

@Suite @MainActor struct FolderSynchronizationReviewModelTests {
    @Test func readyReviewCapturesDirectionGenerationSummaryAndRelativeRepresentativePaths() async throws {
        let fixture = try ReviewFixture()
        let model = FolderSynchronizationReviewModel(preparer: fixture.preparer)

        model.prepare(fixture.draft)
        await fixture.preparer.waitForRequestCount(1)
        await fixture.preparer.releaseSuccess()
        await settle(model)

        guard case let .ready(review) = model.state else { throw ReviewTestError.expectedReady }
        #expect(review.direction == .leftToRight)
        #expect(review.comparisonGeneration == fixture.draft.comparisonGeneration)
        #expect(review.summary.copyCount == 1)
        #expect(review.summary.replaceCount == 1)
        #expect(review.summary.moveToTrashCount == 1)
        #expect(review.summary.skipCount == 2)
        #expect(review.representativeRelativePaths.map(\.string) == ["copy.txt", "replace.txt", "trash.txt"])
        #expect(!review.representativeRelativePaths.map(\.string).joined().contains("/fixtures"))
    }

    @Test func confirmationReturnsOnlyTheExactReadyPreparedAuthority() async throws {
        let fixture = try ReviewFixture()
        let model = FolderSynchronizationReviewModel(preparer: fixture.preparer)

        #expect(model.confirm() == nil)
        model.prepare(fixture.draft)
        await fixture.preparer.waitForRequestCount(1)
        await fixture.preparer.releaseSuccess()
        await settle(model)

        #expect(model.confirm() == fixture.prepared)
        #expect(model.confirm() == nil)
        #expect(model.state == .idle)
    }

    @Test func cancelResetsAndRejectsLatePreparationResult() async throws {
        let fixture = try ReviewFixture()
        let model = FolderSynchronizationReviewModel(preparer: fixture.preparer)

        model.prepare(fixture.draft)
        await fixture.preparer.waitForRequestCount(1)
        model.cancel()
        await fixture.preparer.releaseSuccess()
        await settle(model)

        #expect(model.state == .idle)
        #expect(model.confirm() == nil)
    }

    @Test func newerGenerationRejectsOlderLatePreparationResult() async throws {
        let fixture = try ReviewFixture()
        let newerDraft = try fixture.draft(replacingGenerationWith: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!)
        let model = FolderSynchronizationReviewModel(preparer: fixture.preparer)

        model.prepare(fixture.draft)
        model.prepare(newerDraft)
        await fixture.preparer.waitForRequestCount(2)
        await fixture.preparer.releaseSuccess()
        await settle(model)

        guard case let .ready(review) = model.state else { throw ReviewTestError.expectedReady }
        #expect(review.comparisonGeneration == newerDraft.comparisonGeneration)
    }

    @Test func preparationFailureBecomesBlockedWithoutAbsoluteRootPath() async throws {
        let fixture = try ReviewFixture(error: .unsafeRootRelationship)
        let model = FolderSynchronizationReviewModel(preparer: fixture.preparer)

        model.prepare(fixture.draft)
        await fixture.preparer.waitForRequestCount(1)
        await fixture.preparer.releaseFailure()
        await settle(model)

        guard case let .blocked(blocker) = model.state else { throw ReviewTestError.expectedBlocked }
        #expect(blocker.error == .unsafeRootRelationship)
        #expect(!blocker.presentation.contains("/fixtures"))
    }

    @Test func readyStateRemainsUnconsumedUntilConfirmIsInvoked() async throws {
        let fixture = try ReviewFixture()
        let model = FolderSynchronizationReviewModel(preparer: fixture.preparer)

        model.prepare(fixture.draft)
        await fixture.preparer.waitForRequestCount(1)
        await fixture.preparer.releaseSuccess()
        await settle(model)

        #expect(model.state.isReady)
        #expect(model.confirm() != nil)
        #expect(model.state.isReady == false)
    }
}

@MainActor private func settle(_ model: FolderSynchronizationReviewModel) async {
    for _ in 0..<100 where model.state.isPreparing { await Task.yield() }
}

private enum ReviewTestError: Error { case expectedReady, expectedBlocked }

private actor ReviewPreparer: FolderSynchronizationPreparing {
    private let result: Result<PreparedFolderSynchronizationPlan, FolderSynchronizationPreparationError>
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: Result<PreparedFolderSynchronizationPlan, FolderSynchronizationPreparationError>) { self.result = result }

    func prepare(_ draft: FolderSynchronizationPlanDraft) async throws -> PreparedFolderSynchronizationPlan {
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuations.append($0) }
        let prepared = try result.get()
        return .init(
            draft: draft,
            sourceFingerprints: prepared.sourceFingerprints,
            destinationFingerprints: prepared.destinationFingerprints,
            expectedAbsentDestinations: prepared.expectedAbsentDestinations,
            requiredCapacityBytes: prepared.requiredCapacityBytes,
            destinationFilenameComparisonPolicy: prepared.destinationFilenameComparisonPolicy,
            rootAuthority: prepared.rootAuthority
        )
    }

    func waitForRequestCount(_ count: Int) async {
        while continuations.count < count {
            await withCheckedContinuation { requestWaiters.append($0) }
        }
    }

    func releaseSuccess() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func releaseFailure() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct ReviewFixture {
    let draft: FolderSynchronizationPlanDraft
    let prepared: PreparedFolderSynchronizationPlan
    let preparer: ReviewPreparer

    init(error: FolderSynchronizationPreparationError? = nil) throws {
        let source = URL(filePath: "/fixtures/source", directoryHint: .isDirectory)
        let destination = URL(filePath: "/fixtures/destination", directoryHint: .isDirectory)
        let sourceIdentity = FileIdentity(entryIdentifier: "source", resolvedIdentifier: "source")
        let destinationIdentity = FileIdentity(entryIdentifier: "destination", resolvedIdentifier: "destination")
        let paths = try ["copy.txt", "replace.txt", "trash.txt"].map { try ComparisonRelativePath(components: [$0]) }
        let copy = reviewEntry(paths[0], root: source, identity: "copy")
        let replacementSource = reviewEntry(paths[1], root: source, identity: "replacement-source")
        let replacementDestination = reviewEntry(paths[1], root: destination, identity: "replacement-destination")
        let trash = reviewEntry(paths[2], root: destination, identity: "trash")
        let actions = try [
            FolderSynchronizationAction(relativePath: paths[0], kind: .copy, source: copy, destination: nil),
            FolderSynchronizationAction(relativePath: paths[1], kind: .replace, source: replacementSource, destination: replacementDestination),
            FolderSynchronizationAction(relativePath: paths[2], kind: .moveDestinationToTrash, source: nil, destination: trash)
        ]
        draft = try FolderSynchronizationPlanDraft(
            direction: .leftToRight,
            comparisonGeneration: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            sourceRoot: source,
            destinationRoot: destination,
            sourceRootIdentity: sourceIdentity,
            destinationRootIdentity: destinationIdentity,
            actions: actions,
            skipCount: 2,
            estimatedRegularFileCopyBytes: 2
        )
        prepared = .init(
            draft: draft,
            sourceFingerprints: [:],
            destinationFingerprints: [:],
            expectedAbsentDestinations: [paths[0]],
            requiredCapacityBytes: 2,
            destinationFilenameComparisonPolicy: .caseSensitiveCanonical,
            rootAuthority: .init(
                source: .init(identity: sourceIdentity, canonicalURL: source, volumeIdentifier: "fixture", mountIdentifier: "fixture:/"),
                destination: .init(identity: destinationIdentity, canonicalURL: destination, volumeIdentifier: "fixture", mountIdentifier: "fixture:/")
            )
        )
        preparer = ReviewPreparer(result: error.map(Result.failure) ?? .success(prepared))
    }

    func draft(replacingGenerationWith generation: UUID) throws -> FolderSynchronizationPlanDraft {
        try .init(
            direction: draft.direction,
            comparisonGeneration: generation,
            sourceRoot: draft.sourceRoot,
            destinationRoot: draft.destinationRoot,
            sourceRootIdentity: draft.sourceRootIdentity,
            destinationRootIdentity: draft.destinationRootIdentity,
            actions: draft.actions,
            skipCount: draft.skipCount,
            estimatedRegularFileCopyBytes: draft.estimatedRegularFileCopyBytes
        )
    }

}

private func reviewEntry(_ path: ComparisonRelativePath, root: URL, identity: String) -> ComparisonEntry {
    ComparisonEntry(
        relativePath: path,
        url: root.appending(path: path.string),
        kind: .regularFile,
        fingerprint: .init(identity: .init(entryIdentifier: identity, resolvedIdentifier: identity), byteSize: 1, modifiedAt: Date(timeIntervalSince1970: 1)),
        symbolicLinkTarget: nil,
        typeDescription: "regularFile"
    )
}
