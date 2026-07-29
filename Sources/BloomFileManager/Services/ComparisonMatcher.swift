import Foundation

enum ComparisonMatcher {
    static func rows(left: [ComparisonEntry], right: [ComparisonEntry]) -> [ComparisonRow] {
        let nameConflicts = foldedConflicts(left: left, right: right)
        let paths = Set(left.map(\.relativePath)).union(right.map(\.relativePath))
        let leftByPath = Dictionary(uniqueKeysWithValues: left.map { ($0.relativePath, $0) })
        let rightByPath = Dictionary(uniqueKeysWithValues: right.map { ($0.relativePath, $0) })
        return paths.sorted().map { path in
            let lhs = leftByPath[path]
            let rhs = rightByPath[path]
            let status = nameConflicts.contains(path) ? .nameConflict : quickStatus(lhs, rhs)
            return ComparisonRow(relativePath: path, left: lhs, right: rhs, status: status)
        }
    }

    static func quickStatus(_ left: ComparisonEntry?, _ right: ComparisonEntry?) -> ComparisonStatus {
        guard let left else { return .rightOnly }
        guard let right else { return .leftOnly }
        guard left.kind == right.kind else { return .typeConflict }
        if left.kind == .symbolicLink {
            return left.symbolicLinkTarget == right.symbolicLinkTarget
                ? .identical(.quick) : .contentChanged
        }
        guard left.kind == .regularFile else {
            return left.fingerprint.modifiedAt == right.fingerprint.modifiedAt
                ? .identical(.quick) : .metadataChanged
        }
        guard left.fingerprint.byteSize == right.fingerprint.byteSize else { return .contentChanged }
        return left.fingerprint.modifiedAt == right.fingerprint.modifiedAt
            ? .identical(.quick) : .checking(nil)
    }

    private static func foldedConflicts(
        left: [ComparisonEntry], right: [ComparisonEntry]
    ) -> Set<ComparisonRelativePath> {
        let all = left + right
        let groups = Dictionary(grouping: all) {
            $0.relativePath.foldedComparisonKey
        }
        return Set(groups.values.filter { group in
            Set(group.map(\.relativePath)).count > 1
        }.flatMap { $0.map(\.relativePath) })
    }
}

extension ComparisonMatcher {
    static func applying(
        left: ChecksumResult,
        right: ChecksumResult,
        to row: ComparisonRow
    ) -> ComparisonRow {
        var updated = row
        if left.digest != right.digest {
            updated.status = .contentChanged
        } else if row.status == .identical(.quick) {
            updated.status = .identical(.checksum)
        } else {
            updated.status = .metadataChanged
        }
        return updated
    }
}
