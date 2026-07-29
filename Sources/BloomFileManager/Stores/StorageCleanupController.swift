import Foundation
import Observation

struct StorageCleanupReview: Identifiable, Equatable, Sendable {
    let id: UUID
    let generation: UInt64
    let admission: StorageScanAdmissionToken
    let groups: [StorageCleanupReviewGroup]
    let reclaimableBytes: Int64
}

struct StorageCleanupReviewGroup: Equatable, Sendable {
    let groupID: StorageDuplicateGroupID
    let keep: StorageEntry
    let trash: [StorageEntry]
}

enum StorageCleanupValidationError: LocalizedError, Equatable {
    case noSelection
    case missingKeepCopy(StorageDuplicateGroupID)
    case staleReview
    case cleanupAcknowledgementRequired

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "No items are selected for cleanup."
        case .missingKeepCopy:
            "Cleanup requires a current unselected copy."
        case .staleReview:
            "The cleanup review is no longer current."
        case .cleanupAcknowledgementRequired:
            "Confirm the protected-location cleanup warning before reviewing files."
        }
    }
}

@MainActor @Observable
final class StorageCleanupController {
    private struct GroupSnapshot: Equatable {
        let members: [StorageRelativePath: StorageEntry]
        let keepID: StorageRelativePath
        let trashIDs: Set<StorageRelativePath>
    }

    private struct ReviewSnapshot {
        let reviewID: UUID
        let generation: UInt64
        let admission: StorageScanAdmissionToken
        let groups: [StorageDuplicateGroupID: GroupSnapshot]
    }

    @ObservationIgnored private var reviewSnapshot: ReviewSnapshot?

    private(set) var pendingReview: StorageCleanupReview?
    private(set) var excludedIDs: Set<StorageRelativePath> = []
    private(set) var lastResult: FileOperationResult?
    private(set) var isRunning = false

    init(fingerprints _: any StorageEntryFingerprintReading) {}

    func prepareReview(
        generation: UInt64,
        admission: StorageScanAdmissionToken,
        groups: [StorageDuplicateGroup],
        cleanupAuthorized: Bool
    ) throws {
        pendingReview = nil
        reviewSnapshot = nil
        excludedIDs = []
        lastResult = nil

        guard cleanupAuthorized else {
            throw StorageCleanupValidationError.cleanupAcknowledgementRequired
        }
        guard !isRunning else {
            throw StorageCleanupValidationError.staleReview
        }

        let includedGroups = groups.filter { !$0.trashIDs.isEmpty }
        guard !includedGroups.isEmpty else {
            throw StorageCleanupValidationError.noSelection
        }

        let groupSnapshots = try Self.snapshots(for: groups)
        var reviewGroups: [StorageCleanupReviewGroup] = []
        var reclaimableBytes: Int64 = 0

        for group in includedGroups {
            guard let keep = group.members.first(where: { $0.id == group.keepID }),
                  !group.trashIDs.contains(keep.id),
                  group.trashIDs.isSubset(of: Set(group.members.map(\.id)))
            else {
                throw StorageCleanupValidationError.missingKeepCopy(group.id)
            }

            let selectedEntries = group.members.filter {
                group.trashIDs.contains($0.id)
            }
            guard selectedEntries.count == group.trashIDs.count else {
                throw StorageCleanupValidationError.staleReview
            }

            for entry in selectedEntries {
                reclaimableBytes = Self.saturatingSum(
                    reclaimableBytes,
                    max(0, entry.fingerprint.byteSize ?? 0)
                )
            }
            reviewGroups.append(StorageCleanupReviewGroup(
                groupID: group.id,
                keep: keep,
                trash: selectedEntries
            ))
        }

        let review = StorageCleanupReview(
            id: UUID(),
            generation: generation,
            admission: admission,
            groups: reviewGroups,
            reclaimableBytes: reclaimableBytes
        )
        pendingReview = review
        reviewSnapshot = ReviewSnapshot(
            reviewID: review.id,
            generation: generation,
            admission: admission,
            groups: groupSnapshots
        )
    }

    func cancelReview() {
        guard !isRunning else { return }
        pendingReview = nil
        reviewSnapshot = nil
        excludedIDs = []
        lastResult = nil
    }

    func confirm(
        currentGeneration: UInt64,
        currentAdmission: StorageScanAdmissionToken?,
        groups: [StorageDuplicateGroup],
        operationController: FileOperationController,
        workspace: WorkspaceState,
        validateAdmission:
            @escaping @MainActor (StorageScanAdmissionToken) async -> Bool,
        onCompletion: @escaping @MainActor (FileOperationResult) -> Void
    ) async -> Bool {
        guard let review = pendingReview,
              let snapshot = reviewSnapshot,
              review.id == snapshot.reviewID,
              review.generation == snapshot.generation,
              currentGeneration == snapshot.generation,
              currentAdmission == snapshot.admission,
              snapshot.admission.authorization.cleanupAuthorized,
              let currentSnapshots = try? Self.snapshots(for: groups),
              currentSnapshots == snapshot.groups,
              !isRunning
        else {
            return false
        }

        let selectedEntries = review.groups.flatMap(\.trash)
        guard await validateAdmission(snapshot.admission) else {
            excludedIDs = Set(selectedEntries.map(\.id))
            lastResult = FileOperationResult(outcomes: selectedEntries.map {
                .skipped(source: $0.url)
            })
            return false
        }

        let mutationGroups = review.groups.map {
            StorageCleanupMutationGroup(keep: $0.keep, trash: $0.trash)
        }
        let started = operationController.trashStorageCleanup(
            mutationGroups,
            workspace: workspace,
            onCompletion: { [weak self] operationResult in
                let skippedURLs = Set(operationResult.outcomes.compactMap {
                    if case let .skipped(source) = $0 {
                        source.standardizedFileURL
                    } else {
                        nil
                    }
                })
                self?.excludedIDs = Set(selectedEntries.filter {
                    skippedURLs.contains($0.url.standardizedFileURL)
                }.map(\.id))
                self?.isRunning = false
                self?.lastResult = operationResult
                onCompletion(operationResult)
            }
        )
        if started {
            isRunning = true
        }
        return started
    }

    private static func snapshots(
        for groups: [StorageDuplicateGroup]
    ) throws -> [StorageDuplicateGroupID: GroupSnapshot] {
        var snapshots: [StorageDuplicateGroupID: GroupSnapshot] = [:]
        snapshots.reserveCapacity(groups.count)

        for group in groups {
            guard snapshots[group.id] == nil else {
                throw StorageCleanupValidationError.staleReview
            }
            var members: [StorageRelativePath: StorageEntry] = [:]
            members.reserveCapacity(group.members.count)
            for member in group.members {
                guard members.updateValue(member, forKey: member.id) == nil else {
                    throw StorageCleanupValidationError.staleReview
                }
            }
            snapshots[group.id] = GroupSnapshot(
                members: members,
                keepID: group.keepID,
                trashIDs: group.trashIDs
            )
        }
        return snapshots
    }

    private static func saturatingSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
