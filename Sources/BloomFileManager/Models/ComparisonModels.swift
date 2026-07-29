import Foundation

enum ComparisonPathError: Error, Equatable { case invalidComponent(String) }

struct ComparisonRelativePath: Hashable, Comparable, Sendable, Identifiable {
    let components: [String]
    let string: String
    let foldedComparisonKey: String
    let parentComponents: [String]
    private let usesSimpleASCIISort: Bool
    private let simpleASCIISortKey: UInt64?
    var id: String { string }

    init(components: [String]) throws {
        guard !components.isEmpty else { throw ComparisonPathError.invalidComponent("") }
        for component in components {
            let normalized = component.precomposedStringWithCanonicalMapping
            guard !normalized.isEmpty, normalized != ".", normalized != "..",
                  !normalized.contains("/") else {
                throw ComparisonPathError.invalidComponent(component)
            }
        }
        let normalizedComponents = components.map(\.precomposedStringWithCanonicalMapping)
        self.components = normalizedComponents
        string = normalizedComponents.joined(separator: "/")
        foldedComparisonKey = string.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
        parentComponents = Array(normalizedComponents.dropLast())
        let isSimpleASCII = string.utf8.allSatisfy { $0 >= 97 && $0 <= 122 }
        usesSimpleASCIISort = isSimpleASCII
        if isSimpleASCII, string.utf8.count <= 8 {
            var key: UInt64 = 0
            for byte in string.utf8 {
                key = (key << 8) | UInt64(byte)
            }
            simpleASCIISortKey = key << ((8 - string.utf8.count) * 8)
        } else {
            simpleASCIISortKey = nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if let leftKey = lhs.simpleASCIISortKey, let rightKey = rhs.simpleASCIISortKey {
            return leftKey < rightKey
        }
        if lhs.usesSimpleASCIISort, rhs.usesSimpleASCIISort {
            return lhs.string < rhs.string
        }
        return lhs.string.localizedStandardCompare(rhs.string) == .orderedAscending
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.string == rhs.string
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(string)
    }
}

enum ComparisonEntryKind: String, Sendable { case regularFile, directory, symbolicLink, package, special }
enum ComparisonSide: Hashable, Sendable { case left, right }

struct ComparisonModificationTimestamp: Hashable, Sendable {
    let seconds: Int64
    let nanoseconds: Int64
}

struct ComparisonFingerprint: Hashable, Sendable {
    let identity: FileIdentity
    let byteSize: Int64?
    let modifiedAt: Date?
    let rawModifiedAt: ComparisonModificationTimestamp?

    init(
        identity: FileIdentity,
        byteSize: Int64?,
        modifiedAt: Date?,
        rawModifiedAt: ComparisonModificationTimestamp? = nil
    ) {
        self.identity = identity
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.rawModifiedAt = rawModifiedAt
    }
}

struct ComparisonEntry: Hashable, Sendable {
    let relativePath: ComparisonRelativePath
    let url: URL
    let kind: ComparisonEntryKind
    let fingerprint: ComparisonFingerprint
    let symbolicLinkTarget: String?
    let typeDescription: String
}

enum ComparisonVerification: Hashable, Sendable { case quick, checksum }
enum ComparisonStatus: Hashable, Sendable {
    case identical(ComparisonVerification)
    case metadataChanged
    case contentChanged
    case leftOnly
    case rightOnly
    case typeConflict
    case nameConflict
    case checking(Double?)
    case unstable
    case error(String)
}

struct ComparisonRow: Identifiable, Hashable, Sendable {
    var id: ComparisonRelativePath { relativePath }
    let relativePath: ComparisonRelativePath
    var left: ComparisonEntry?
    var right: ComparisonEntry?
    var status: ComparisonStatus
    var descendantDifferenceCount = 0
}

struct ComparisonOptions: Equatable, Sendable {
    var includeSubfolders = false
    var includeHiddenItems = false
}

enum ComparisonFilter: CaseIterable, Sendable {
    case differences, all, leftOnly, rightOnly, contentChanged, errors

    func includes(_ status: ComparisonStatus) -> Bool {
        switch self {
        case .all: true
        case .differences:
            status != .identical(.quick) && status != .identical(.checksum)
        case .leftOnly: status == .leftOnly
        case .rightOnly: status == .rightOnly
        case .contentChanged: status == .contentChanged || status == .metadataChanged
        case .errors:
            if case .error = status { true } else { status == .unstable || status == .nameConflict }
        }
    }

    func apply(_ rows: [ComparisonRow]) -> [ComparisonRow] {
        rows.filter { includes($0.status) }
    }
}
enum ComparisonDirection: Hashable, Sendable { case leftToRight, rightToLeft }

struct ComparisonMoveConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let direction: ComparisonDirection
    let requests: [IdentifiedTransferRequest]
    let sourceRoot: URL
    let destinationRoot: URL
    let sourceRootIdentity: FileIdentity
    let destinationRootIdentity: FileIdentity
    let sessionGeneration: UUID
    let representativeNames: [String]
    let crossesVolumes: Bool?

    init(
        id: UUID = UUID(),
        direction: ComparisonDirection,
        requests: [IdentifiedTransferRequest],
        sourceRoot: URL,
        destinationRoot: URL,
        sourceRootIdentity: FileIdentity,
        destinationRootIdentity: FileIdentity,
        sessionGeneration: UUID,
        representativeNames: [String],
        crossesVolumes: Bool?
    ) {
        self.id = id
        self.direction = direction
        self.requests = requests
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.sourceRootIdentity = sourceRootIdentity
        self.destinationRootIdentity = destinationRootIdentity
        self.sessionGeneration = sessionGeneration
        self.representativeNames = representativeNames
        self.crossesVolumes = crossesVolumes
    }

    func updatingCrossVolumeStatus(_ value: Bool?) -> Self {
        Self(
            id: id,
            direction: direction,
            requests: requests,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity,
            sessionGeneration: sessionGeneration,
            representativeNames: representativeNames,
            crossesVolumes: value
        )
    }
}

extension ComparisonRow {
    func source(for direction: ComparisonDirection) -> ComparisonEntry? {
        direction == .leftToRight ? left : right
    }

    func destination(for direction: ComparisonDirection) -> ComparisonEntry? {
        direction == .leftToRight ? right : left
    }
}

enum ComparisonActionPolicy {
    static func canCopy(
        _ selected: [ComparisonRow],
        direction: ComparisonDirection,
        allRows: [ComparisonRow]
    ) -> Bool {
        !selected.isEmpty && selected.allSatisfy { row in
            row.source(for: direction) != nil
                && row.status.allowsCopy
                && !hasBlockedAncestor(row, direction: direction, allRows: allRows)
        }
    }

    static func canMove(
        _ selected: [ComparisonRow],
        direction: ComparisonDirection,
        allRows: [ComparisonRow]
    ) -> Bool {
        !selected.isEmpty && selected.allSatisfy { row in
            let oneSided = direction == .leftToRight
                ? row.status == .leftOnly
                : row.status == .rightOnly
            return oneSided
                && !hasBlockedAncestor(row, direction: direction, allRows: allRows)
        }
    }

    static func moveBlockReason(
        _ selected: [ComparisonRow],
        _ direction: ComparisonDirection
    ) -> String? {
        guard let row = selected.first(where: {
            direction == .leftToRight ? $0.status != .leftOnly : $0.status != .rightOnly
        }) else { return nil }
        return "\(row.relativePath.string) exists on both sides and cannot be moved in comparison mode."
    }

    private static func hasBlockedAncestor(
        _ row: ComparisonRow,
        direction: ComparisonDirection,
        allRows: [ComparisonRow]
    ) -> Bool {
        let parents = row.relativePath.components.indices.dropLast().map {
            Array(row.relativePath.components.prefix($0 + 1))
        }
        return parents.contains { components in
            guard let path = try? ComparisonRelativePath(components: components),
                  let ancestor = allRows.first(where: { $0.id == path })
            else { return false }
            return ancestor.status == .typeConflict
                || ancestor.status == .nameConflict
                || ancestor.status.isErrorLike
                || (ancestor.destination(for: direction).map { $0.kind != .directory } ?? false)
        }
    }
}

extension ComparisonStatus {
    var allowsMoveFromLeft: Bool { self == .leftOnly }
    var allowsMoveFromRight: Bool { self == .rightOnly }

    var allowsCopy: Bool {
        switch self {
        case .nameConflict, .checking, .unstable, .error:
            false
        default:
            true
        }
    }

    var isErrorLike: Bool {
        if case .error = self { return true }
        return self == .unstable
    }
}
