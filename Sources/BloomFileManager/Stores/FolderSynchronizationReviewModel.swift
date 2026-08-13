import Foundation
import Observation

struct FolderSynchronizationReviewSummary: Sendable, Equatable {
    let copyCount: Int
    let replaceCount: Int
    let moveToTrashCount: Int
    let skipCount: Int
    let estimatedCopyBytes: Int64
    let requiredCapacityBytes: Int64
}

struct FolderSynchronizationReview: Sendable, Equatable {
    let preparedPlan: PreparedFolderSynchronizationPlan
    let direction: ComparisonDirection
    let comparisonGeneration: UUID
    let summary: FolderSynchronizationReviewSummary
    let representativeRelativePaths: [ComparisonRelativePath]
}

struct FolderSynchronizationReviewBlocker: Sendable, Equatable {
    let error: FolderSynchronizationPreparationError

    var presentation: String { error.localizedDescription }
}

enum FolderSynchronizationReviewState: Sendable, Equatable {
    case idle
    case preparing(direction: ComparisonDirection, comparisonGeneration: UUID)
    case ready(FolderSynchronizationReview)
    case blocked(FolderSynchronizationReviewBlocker)

    var isPreparing: Bool {
        guard case .preparing = self else { return false }
        return true
    }

    var isReady: Bool {
        guard case .ready = self else { return false }
        return true
    }
}

enum FolderSynchronizationReviewPresentation: Sendable, Equatable {
    case idle
    case plannerBlocked([FolderSynchronizationBlocker])
    case alreadySynchronized(FolderSynchronizationPlanSummary)
    case preparing(direction: ComparisonDirection, comparisonGeneration: UUID)
    case preparationBlocked(FolderSynchronizationReviewBlocker)
    case ready(FolderSynchronizationReview)

    var isPreparing: Bool {
        guard case .preparing = self else { return false }
        return true
    }
}

@MainActor @Observable
final class FolderSynchronizationReviewModel {
    private(set) var state: FolderSynchronizationReviewState = .idle

    @ObservationIgnored private let preparer: any FolderSynchronizationPreparing
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(preparer: any FolderSynchronizationPreparing = FolderSynchronizationPreparationService()) {
        self.preparer = preparer
    }

    func prepare(_ draft: FolderSynchronizationPlanDraft) {
        reset()
        generation &+= 1
        let requestGeneration = generation
        state = .preparing(
            direction: draft.direction,
            comparisonGeneration: draft.comparisonGeneration
        )
        let preparer = self.preparer
        preparationTask = Task { [weak self] in
            let result: Result<PreparedFolderSynchronizationPlan, any Error>
            do {
                result = .success(try await preparer.prepare(draft))
            } catch {
                result = .failure(error)
            }
            guard let self,
                  !Task.isCancelled,
                  requestGeneration == generation,
                  case let .preparing(direction, comparisonGeneration) = state,
                  direction == draft.direction,
                  comparisonGeneration == draft.comparisonGeneration
            else { return }
            switch result {
            case let .success(prepared):
                state = .ready(Self.review(for: prepared))
            case let .failure(error as FolderSynchronizationPreparationError):
                state = .blocked(.init(error: error))
            case let .failure(error as CancellationError):
                _ = error
                break
            case .failure:
                state = .blocked(.init(error: .itemUnavailable))
            }
        }
    }

    /// Confirmation transfers the exact immutable authority once; a caller must explicitly invoke it.
    func confirm() -> PreparedFolderSynchronizationPlan? {
        guard case let .ready(review) = state else { return nil }
        generation &+= 1
        preparationTask = nil
        state = .idle
        return review.preparedPlan
    }

    func cancel() { reset() }

    func reset() {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        state = .idle
    }

    private static func review(for prepared: PreparedFolderSynchronizationPlan) -> FolderSynchronizationReview {
        let actions = prepared.draft.actions
        return FolderSynchronizationReview(
            preparedPlan: prepared,
            direction: prepared.draft.direction,
            comparisonGeneration: prepared.draft.comparisonGeneration,
            summary: .init(
                copyCount: actions.count(where: { $0.kind == .copy }),
                replaceCount: actions.count(where: { $0.kind == .replace }),
                moveToTrashCount: actions.count(where: { $0.kind == .moveDestinationToTrash }),
                skipCount: prepared.draft.skipCount,
                estimatedCopyBytes: prepared.draft.estimatedRegularFileCopyBytes,
                requiredCapacityBytes: prepared.requiredCapacityBytes
            ),
            representativeRelativePaths: Array(actions.prefix(8).map(\.relativePath))
        )
    }
}
