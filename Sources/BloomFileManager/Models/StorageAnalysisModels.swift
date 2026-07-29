import Foundation

enum StoragePathError: Error, Equatable {
    case invalidComponent(String)
}

struct StorageRelativePath: Hashable, Comparable, Identifiable, Sendable {
    let components: [String]
    let string: String

    var id: String { string }

    init(components: [String]) throws {
        guard !components.isEmpty else { throw StoragePathError.invalidComponent("") }
        for component in components {
            let normalized = component.precomposedStringWithCanonicalMapping
            guard !normalized.isEmpty,
                  normalized != ".",
                  normalized != "..",
                  !normalized.contains("/")
            else {
                throw StoragePathError.invalidComponent(component)
            }
        }

        self.components = components.map(\.precomposedStringWithCanonicalMapping)
        string = self.components.joined(separator: "/")
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.string < rhs.string
    }
}

enum StorageEntryKind: String, Sendable {
    case regularFile, directory, symbolicLink, package, special
}

enum StorageFileCategory: String, CaseIterable, Sendable {
    case document, image, video, audio, archive, application, other
}

struct StorageEntry: Identifiable, Hashable, Sendable {
    var id: StorageRelativePath { relativePath }

    let relativePath: StorageRelativePath
    let url: URL
    let kind: StorageEntryKind
    let category: StorageFileCategory
    let fingerprint: ComparisonFingerprint
    let typeDescription: String
}

enum StorageVerificationState: Hashable, Sendable {
    case unverified
    case partial(Double?)
    case complete
    case unstable
    case unreadable(String)
}

struct StorageDuplicateGroupID: Hashable, Sendable {
    let byteSize: Int64
    let completeDigest: Data
}

struct StorageDuplicateGroup: Identifiable, Hashable, Sendable {
    let id: StorageDuplicateGroupID
    var members: [StorageEntry]
    var keepID: StorageRelativePath
    var trashIDs: Set<StorageRelativePath>
    var reclaimableBytes: Int64
}

extension StorageDuplicateGroup {
    mutating func recalculateReclaimableBytes() {
        reclaimableBytes = trashIDs.reduce(into: Int64(0)) { total, id in
            guard let size = members.first(where: { $0.id == id })?
                .fingerprint.byteSize else { return }
            total = size > Int64.max - total ? Int64.max : total + size
        }
    }
}

struct StorageAnalysisThresholds: Equatable, Sendable {
    var largeFileBytes: Int64 = 1_073_741_824
    var longUnmodifiedDays: Int = 365
}

enum StorageLargeFileThresholdPreset: CaseIterable, Hashable, Sendable {
    case hundredMegabytes
    case fiveHundredMegabytes
    case oneGigabyte
    case fiveGigabytes

    var bytes: Int64 {
        switch self {
        case .hundredMegabytes: 104_857_600
        case .fiveHundredMegabytes: 524_288_000
        case .oneGigabyte: 1_073_741_824
        case .fiveGigabytes: 5_368_709_120
        }
    }
}

enum StorageAgeThresholdPreset: CaseIterable, Hashable, Sendable {
    case ninetyDays
    case oneHundredEightyDays
    case oneYear
    case twoYears

    var days: Int {
        switch self {
        case .ninetyDays: 90
        case .oneHundredEightyDays: 180
        case .oneYear: 365
        case .twoYears: 730
        }
    }
}

struct StorageOverviewMetrics: Equatable, Sendable {
    let fileCount: Int
    let directoryCount: Int
    let inaccessibleCount: Int
    let reclaimableBytes: Int64
}

struct StorageFileTypeGroup: Identifiable, Equatable, Sendable {
    var id: StorageFileCategory { category }
    let category: StorageFileCategory
    let entryCount: Int
    let byteCount: Int64
}

enum StorageAnalysisSection: String, CaseIterable, Sendable {
    case overview, duplicates, largeFiles, longUnmodified, fileTypes
}

enum StorageAnalysisPhase: Equatable, Sendable {
    case inactive, idle, scanning, verifying, complete, paused, cancelled
}

enum StorageKeepRecommender {
    static func recommendedKeep(
        in members: [StorageEntry],
        explicitKeep: StorageRelativePath?,
        preferredFolder: StorageRelativePath?
    ) -> StorageRelativePath? {
        if let explicitKeep, members.contains(where: { $0.id == explicitKeep }) {
            return explicitKeep
        }

        return members.min { lhs, rhs in
            ranksBefore(lhs, rhs, preferredFolder: preferredFolder)
        }?.id
    }

    private static func ranksBefore(
        _ lhs: StorageEntry,
        _ rhs: StorageEntry,
        preferredFolder: StorageRelativePath?
    ) -> Bool {
        let lhsIsPreferred = isInsidePreferredFolder(lhs, preferredFolder: preferredFolder)
        let rhsIsPreferred = isInsidePreferredFolder(rhs, preferredFolder: preferredFolder)
        if lhsIsPreferred != rhsIsPreferred {
            return lhsIsPreferred
        }

        switch (lhs.fingerprint.modifiedAt, rhs.fingerprint.modifiedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        if lhs.relativePath.components.count != rhs.relativePath.components.count {
            return lhs.relativePath.components.count < rhs.relativePath.components.count
        }
        return lhs.relativePath < rhs.relativePath
    }

    private static func isInsidePreferredFolder(
        _ entry: StorageEntry,
        preferredFolder: StorageRelativePath?
    ) -> Bool {
        guard let preferredFolder else { return false }
        return entry.relativePath.components.starts(with: preferredFolder.components)
    }
}

enum StorageCleanupSelectionPolicy {
    static func canMarkForTrash(
        _ candidate: StorageRelativePath,
        in group: StorageDuplicateGroup
    ) -> Bool {
        guard candidate != group.keepID,
              !group.trashIDs.contains(candidate),
              group.members.contains(where: { $0.id == candidate })
        else {
            return false
        }

        return group.members.contains { member in
            member.id != candidate && !group.trashIDs.contains(member.id)
        }
    }
}
