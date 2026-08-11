import Foundation

enum BatchRenameRule: Sendable, Equatable {
    case findReplace(find: String, replacement: String, caseSensitive: Bool)
    case prefix(String)
    case suffix(String)
    case sequence(baseName: String, start: Int, digits: Int)
}

enum FilenameComparisonPolicy: Sendable, Equatable {
    case caseSensitiveCanonical
    case caseInsensitiveCanonical

    func key(for name: String) -> String {
        let canonical = name.precomposedStringWithCanonicalMapping
        switch self {
        case .caseSensitiveCanonical:
            return canonical
        case .caseInsensitiveCanonical:
            return canonical.folding(
                options: .caseInsensitive,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }
}

struct BatchRenameSource: Sendable, Equatable {
    let url: URL
    let identity: FileIdentity
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
}

struct BatchRenamePlanningRequest: Sendable, Equatable {
    let parentURL: URL
    let parentIdentity: FileIdentity
    let sources: [BatchRenameSource]
}

enum BatchRenamePreviewStatus: Sendable, Equatable {
    case ready
    case unchanged
    case invalidName(FilenameError)
    case duplicate
    case occupied
}

struct BatchRenamePreviewEntry: Sendable, Equatable {
    let source: BatchRenameSource
    let proposedName: String
    let status: BatchRenamePreviewStatus
}

struct BatchRenamePlanEntry: Sendable, Equatable {
    let source: BatchRenameSource
    let proposedName: String
    let destinationURL: URL
}

struct BatchRenamePlan: Sendable, Equatable {
    let parentURL: URL
    let parentIdentity: FileIdentity
    let entries: [BatchRenamePlanEntry]
    let comparisonPolicy: FilenameComparisonPolicy
}

struct BatchRenamePreview: Sendable, Equatable {
    let entries: [BatchRenamePreviewEntry]
    let plan: BatchRenamePlan?

    var isExecutable: Bool { plan != nil }
}

enum BatchRenamePlanningError: Error, Equatable, Sendable {
    case selectionTooSmall
    case mixedParents
    case emptyFindText
    case invalidSequence
    case proposedNameCountMismatch
}
