import Foundation

enum GetInfoEntryKind: String, Equatable, Sendable {
    case regularFile
    case directory
    case package
    case symbolicLink
    case special
}

struct GetInfoItemSnapshot: Identifiable, Equatable, Sendable {
    var id: URL { url }

    let url: URL
    let name: String
    let kind: GetInfoEntryKind
    let typeDescription: String
    let typeIdentifier: String?
    let logicalByteSize: Int64?
    let allocatedByteSize: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let ownerID: UInt32
    let groupID: UInt32
    let posixMode: UInt16
    let finderTags: [String]
    let symbolicLinkDestination: String?
    let availability: CloudItemAvailability
    let identity: FileIdentity
    let checksumRequest: ChecksumRequest?
}

struct GetInfoInspectionFailure: Equatable, Sendable {
    enum Reason: Error, Equatable, Sendable {
        case itemChanged
        case accessDenied
        case metadataUnavailable
    }

    let url: URL
    let reason: Reason
}

enum GetInfoInspectionOutcome: Equatable, Sendable {
    case success(GetInfoItemSnapshot)
    case failure(GetInfoInspectionFailure)
}

struct GetInfoInspectionReport: Equatable, Sendable {
    let outcomes: [GetInfoInspectionOutcome]

    var summary: GetInfoSelectionSummary {
        GetInfoSelectionSummary(outcomes: outcomes)
    }

    var successfulSnapshots: [GetInfoItemSnapshot] {
        outcomes.compactMap {
            guard case let .success(snapshot) = $0 else { return nil }
            return snapshot
        }
    }

    var failures: [GetInfoInspectionFailure] {
        outcomes.compactMap {
            guard case let .failure(failure) = $0 else { return nil }
            return failure
        }
    }
}

struct GetInfoSelectionSummary: Equatable, Sendable {
    let selectedCount: Int
    let inspectedCount: Int
    let failedCount: Int
    let knownLogicalByteTotal: Int64
    let knownAllocatedByteTotal: Int64
    let commonParentURL: URL?
    let checksumRequest: ChecksumRequest?

    init(outcomes: [GetInfoInspectionOutcome]) {
        let snapshots = outcomes.compactMap { outcome -> GetInfoItemSnapshot? in
            guard case let .success(snapshot) = outcome else { return nil }
            return snapshot
        }
        selectedCount = outcomes.count
        inspectedCount = snapshots.count
        failedCount = outcomes.count - snapshots.count
        knownLogicalByteTotal = snapshots.reduce(into: Int64(0)) { total, snapshot in
            total += snapshot.logicalByteSize ?? 0
        }
        knownAllocatedByteTotal = snapshots.reduce(into: Int64(0)) { total, snapshot in
            total += snapshot.allocatedByteSize ?? 0
        }

        let parents = snapshots.map { $0.url.deletingLastPathComponent().standardizedFileURL }
        commonParentURL = parents.first.flatMap { parent in
            parents.allSatisfy { $0 == parent } ? parent : nil
        }

        guard outcomes.count == 1,
              let snapshot = snapshots.first,
              snapshot.kind == .regularFile
        else {
            checksumRequest = nil
            return
        }
        checksumRequest = snapshot.checksumRequest
    }
}
