import Foundation
import Testing
@testable import BloomFileManager

@Suite struct StorageAnalysisModelTests {
    @Test func defaultsMatchTheApprovedThresholds() {
        let values = StorageAnalysisThresholds()

        #expect(values.largeFileBytes == 1_073_741_824)
        #expect(values.longUnmodifiedDays == 365)
    }

    @Test func thresholdPresetsExposeApprovedLargeFileAndAgeChoices() {
        #expect(StorageLargeFileThresholdPreset.allCases.map(\.bytes) == [
            104_857_600,
            524_288_000,
            1_073_741_824,
            5_368_709_120
        ])
        #expect(StorageAgeThresholdPreset.allCases.map(\.days) == [
            90,
            180,
            365,
            730
        ])
    }

    @Test func relativePathsRejectUnsafeComponentsAndSortStably() throws {
        #expect(throws: StoragePathError.invalidComponent("")) {
            try StorageRelativePath(components: [])
        }
        #expect(throws: StoragePathError.invalidComponent("..")) {
            try StorageRelativePath(components: ["Documents", ".."])
        }

        let alpha = try StorageRelativePath(components: ["alpha"])
        let beta = try StorageRelativePath(components: ["beta"])
        #expect(alpha < beta)

        let file10 = try StorageRelativePath(components: ["file10"])
        let file2 = try StorageRelativePath(components: ["file2"])
        #expect(file10 < file2)
    }

    @Test func keepRecommendationUsesExplicitPreferredNewestShallowestThenPath() throws {
        let members = try StorageModelFixture.members()
        let explicit = members[2].id

        #expect(StorageKeepRecommender.recommendedKeep(
            in: members,
            explicitKeep: explicit,
            preferredFolder: nil
        ) == explicit)
        #expect(StorageKeepRecommender.recommendedKeep(
            in: members,
            explicitKeep: nil,
            preferredFolder: try StorageRelativePath(components: ["Preferred"])
        ) == members[1].id)
    }

    @Test func keepRecommendationUsesNewestThenShallowestThenPath() throws {
        let members = try StorageModelFixture.members()
        #expect(StorageKeepRecommender.recommendedKeep(
            in: members,
            explicitKeep: nil,
            preferredFolder: nil
        ) == members[0].id)

        let tieMembers = try StorageModelFixture.entries(
            paths: [["zeta"], ["a", "deep"], ["alpha"]],
            modificationDates: [10, 10, 10]
        )
        #expect(StorageKeepRecommender.recommendedKeep(
            in: tieMembers,
            explicitKeep: nil,
            preferredFolder: nil
        ) == tieMembers[2].id)
    }

    @Test func cleanupCanNeverSelectTheRequiredFinalCopy() throws {
        let group = try StorageModelFixture.group(memberCount: 2, trashedIndexes: [1])

        #expect(StorageCleanupSelectionPolicy.canMarkForTrash(
            group.members[0].id,
            in: group
        ) == false)
    }

    @Test func cleanupRejectsUnknownAndKeepMembersButAllowsOneAdditionalSelection() throws {
        let group = try StorageModelFixture.group(memberCount: 3, trashedIndexes: [])
        let unknown = try StorageRelativePath(components: ["unknown.txt"])

        #expect(!StorageCleanupSelectionPolicy.canMarkForTrash(unknown, in: group))
        #expect(!StorageCleanupSelectionPolicy.canMarkForTrash(group.keepID, in: group))
        #expect(StorageCleanupSelectionPolicy.canMarkForTrash(group.members[1].id, in: group))
    }

    @Test func reclaimableBytesUsesOnlySelectedMembersAndSaturates() throws {
        var group = try StorageModelFixture.group(
            memberCount: 3,
            trashedIndexes: [1, 2],
            byteSizes: [1, Int64.max, 1]
        )

        group.recalculateReclaimableBytes()
        #expect(group.reclaimableBytes == Int64.max)
    }

    @Test func duplicateGroupIdentityIsDerivedFromVerifiedContent() {
        let first = StorageDuplicateGroupID(byteSize: 512, completeDigest: Data([1, 2, 3]))
        let sameContent = StorageDuplicateGroupID(byteSize: 512, completeDigest: Data([1, 2, 3]))
        let differentContent = StorageDuplicateGroupID(byteSize: 512, completeDigest: Data([3, 2, 1]))

        #expect(first == sameContent)
        #expect(first != differentContent)
    }
}

enum StorageModelFixture {
    static func members() throws -> [StorageEntry] {
        try entries(
            paths: [["Newest.txt"], ["Preferred", "Older.txt"], ["Other", "Explicit.txt"]],
            modificationDates: [3, 1, 2]
        )
    }

    static func group(
        memberCount: Int,
        trashedIndexes: Set<Int>,
        byteSizes: [Int64]? = nil
    ) throws -> StorageDuplicateGroup {
        let members = try entries(
            paths: (0..<memberCount).map { ["member-\($0).txt"] },
            modificationDates: Array(repeating: 1, count: memberCount),
            byteSizes: byteSizes ?? Array(repeating: 100, count: memberCount)
        )
        var group = StorageDuplicateGroup(
            id: StorageDuplicateGroupID(byteSize: 100, completeDigest: Data([0xAB])),
            members: members,
            keepID: members[0].id,
            trashIDs: Set(trashedIndexes.map { members[$0].id }),
            reclaimableBytes: 0
        )
        group.recalculateReclaimableBytes()
        return group
    }

    static func entries(
        paths: [[String]],
        modificationDates: [TimeInterval],
        byteSizes: [Int64] = []
    ) throws -> [StorageEntry] {
        try zip(paths.indices, paths).map { index, components in
            let path = try StorageRelativePath(components: components)
            return StorageEntry(
                relativePath: path,
                url: URL(fileURLWithPath: "/fixtures/\(path.string)"),
                kind: .regularFile,
                category: .document,
                fingerprint: ComparisonFingerprint(
                    identity: FileIdentity(
                        entryIdentifier: "entry-\(index)",
                        resolvedIdentifier: "resolved-\(index)"
                    ),
                    byteSize: byteSizes.isEmpty ? 100 : byteSizes[index],
                    modifiedAt: Date(timeIntervalSinceReferenceDate: modificationDates[index])
                ),
                typeDescription: "Plain text"
            )
        }
    }
}
