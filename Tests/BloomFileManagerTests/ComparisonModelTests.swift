import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ComparisonModelTests {
    @Test func relativePathsRejectEscapesAndSortByComponents() throws {
        #expect(throws: ComparisonPathError.self) {
            try ComparisonRelativePath(components: ["folder", "..", "secret"])
        }
        let a = try ComparisonRelativePath(components: ["A", "1.txt"])
        let b = try ComparisonRelativePath(components: ["B.txt"])
        #expect(a < b)
        #expect(a.string == "A/1.txt")
    }

    @Test func relativePathCachesItsNormalizedJoinedRepresentation() throws {
        let value = try ComparisonRelativePath(components: ["Cafe\u{301}", "report.txt"])

        #expect(value.components == ["Café", "report.txt"])
        #expect(value.string == "Café/report.txt")
        #expect(value.foldedComparisonKey == "cafe/report.txt")
        #expect(value.parentComponents == ["Café"])
        #expect(value.id == value.string)
    }

    @Test func pathSortFastSubsetAndFallbackMatchLocalizedStandardOrdering() throws {
        let values = try [
            "a", "aa", "ab", "faaaa", "fbaaa", "z",
            "a1", "a01", "a2", "z/child", "Z", "Café"
        ].map {
            try ComparisonRelativePath(components: $0.split(separator: "/").map(String.init))
        }

        for left in values {
            for right in values where left != right {
                let expected = left.string.localizedStandardCompare(right.string) == .orderedAscending
                #expect((left < right) == expected)
            }
        }
    }

    @Test func matcherProducesOneAlignedRowForExactPath() throws {
        let path = try ComparisonRelativePath(components: ["report.txt"])
        let left = ComparisonEntry.fixture(path: path, identity: "1:1", size: 12, modified: 10)
        let right = ComparisonEntry.fixture(path: path, identity: "2:1", size: 12, modified: 10)
        let rows = ComparisonMatcher.rows(left: [left], right: [right])
        #expect(rows.count == 1)
        #expect(rows[0].left == left)
        #expect(rows[0].right == right)
        #expect(rows[0].status == .identical(.quick))
    }

    @Test func sameSizeDifferentDateRequiresChecksum() throws {
        let path = try ComparisonRelativePath(components: ["movie.mov"])
        let left = ComparisonEntry.fixture(path: path, identity: "1:2", size: 50, modified: 10)
        let right = ComparisonEntry.fixture(path: path, identity: "2:2", size: 50, modified: 11)
        #expect(ComparisonMatcher.rows(left: [left], right: [right])[0].status == .checking(nil))
    }

    @Test func foldedCollisionBecomesNameConflict() throws {
        let upper = try ComparisonRelativePath(components: ["Readme"])
        let lower = try ComparisonRelativePath(components: ["README"])
        let rows = ComparisonMatcher.rows(
            left: [.fixture(path: upper, identity: "1:3")],
            right: [.fixture(path: lower, identity: "2:3")]
        )
        #expect(rows.allSatisfy { $0.status == .nameConflict })
    }
}

private extension ComparisonEntry {
    static func fixture(
        path: ComparisonRelativePath,
        identity: String,
        size: Int64 = 1,
        modified: TimeInterval = 1,
        kind: ComparisonEntryKind = .regularFile
    ) -> Self {
        .init(
            relativePath: path,
            url: URL(filePath: "/tmp/comparison-fixture").appending(path: path.string),
            kind: kind,
            fingerprint: .init(
                identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
                byteSize: size,
                modifiedAt: Date(timeIntervalSince1970: modified)
            ),
            symbolicLinkTarget: nil,
            typeDescription: kind.rawValue
        )
    }
}
