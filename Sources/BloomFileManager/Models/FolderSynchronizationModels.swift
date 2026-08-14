import Foundation

enum FolderSynchronizationActionKind: String, CaseIterable, Sendable, Equatable {
    case copy
    case replace
    case moveDestinationToTrash
}

enum FolderSynchronizationModelValidationError: Error, Equatable {
    case inconsistentAction
    case duplicateActionPath
    case unorderedActions
    case negativeCount
    case negativeByteEstimate
    case emptyDraft
    case actionOutsideRoots
    case inconsistentByteEstimate
}

struct FolderSynchronizationAction: Sendable, Equatable, Identifiable {
    let relativePath: ComparisonRelativePath
    let kind: FolderSynchronizationActionKind
    let source: ComparisonEntry?
    let destination: ComparisonEntry?

    var id: ComparisonRelativePath { relativePath }

    init(
        relativePath: ComparisonRelativePath,
        kind: FolderSynchronizationActionKind,
        source: ComparisonEntry?,
        destination: ComparisonEntry?
    ) throws {
        guard (source.map { $0.relativePath == relativePath } ?? true),
              (destination.map { $0.relativePath == relativePath } ?? true) else {
            throw FolderSynchronizationModelValidationError.inconsistentAction
        }

        switch kind {
        case .copy:
            guard source != nil, destination == nil else {
                throw FolderSynchronizationModelValidationError.inconsistentAction
            }
        case .replace:
            guard let source, let destination,
                  source.kind == destination.kind,
                  source.kind != .directory else {
                throw FolderSynchronizationModelValidationError.inconsistentAction
            }
        case .moveDestinationToTrash:
            guard source == nil, destination != nil else {
                throw FolderSynchronizationModelValidationError.inconsistentAction
            }
        }

        self.relativePath = relativePath
        self.kind = kind
        self.source = source
        self.destination = destination
    }

    static func deterministicOrder(_ left: Self, _ right: Self) -> Bool {
        if left.relativePath.components.count != right.relativePath.components.count {
            return left.relativePath.components.count < right.relativePath.components.count
        }
        return left.relativePath < right.relativePath
    }
}

struct FolderSynchronizationPlanDraft: Sendable, Equatable {
    let direction: ComparisonDirection
    let comparisonGeneration: UUID
    let sourceRoot: URL
    let destinationRoot: URL
    let sourceRootIdentity: FileIdentity
    let destinationRootIdentity: FileIdentity
    let actions: [FolderSynchronizationAction]
    let skipCount: Int
    /// Exact sum of regular-file source byte sizes among the emitted actions.
    let estimatedRegularFileCopyBytes: Int64

    init(
        direction: ComparisonDirection,
        comparisonGeneration: UUID,
        sourceRoot: URL,
        destinationRoot: URL,
        sourceRootIdentity: FileIdentity,
        destinationRootIdentity: FileIdentity,
        actions: [FolderSynchronizationAction],
        skipCount: Int,
        estimatedRegularFileCopyBytes: Int64
    ) throws {
        guard skipCount >= 0 else { throw FolderSynchronizationModelValidationError.negativeCount }
        guard estimatedRegularFileCopyBytes >= 0 else {
            throw FolderSynchronizationModelValidationError.negativeByteEstimate
        }
        guard !actions.isEmpty else { throw FolderSynchronizationModelValidationError.emptyDraft }
        guard Set(actions.map(\.relativePath)).count == actions.count else {
            throw FolderSynchronizationModelValidationError.duplicateActionPath
        }
        guard zip(actions, actions.dropFirst()).allSatisfy({
            FolderSynchronizationAction.deterministicOrder($0, $1)
        }) else {
            throw FolderSynchronizationModelValidationError.unorderedActions
        }
        guard actions.allSatisfy({ action in
            action.source.map {
                Self.isExpectedURL($0.url, root: sourceRoot, relativePath: action.relativePath)
            } ?? true
                && action.destination.map {
                    Self.isExpectedURL($0.url, root: destinationRoot, relativePath: action.relativePath)
                } ?? true
        }) else {
            throw FolderSynchronizationModelValidationError.actionOutsideRoots
        }
        let directRegularFileBytes = actions.reduce(into: Int64(0)) { total, action in
            guard let source = action.source, source.kind == .regularFile else { return }
            let bytes = max(0, source.fingerprint.byteSize ?? 0)
            total = total > Int64.max - bytes ? Int64.max : total + bytes
        }
        guard estimatedRegularFileCopyBytes == directRegularFileBytes else {
            throw FolderSynchronizationModelValidationError.inconsistentByteEstimate
        }

        self.direction = direction
        self.comparisonGeneration = comparisonGeneration
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.sourceRootIdentity = sourceRootIdentity
        self.destinationRootIdentity = destinationRootIdentity
        self.actions = actions
        self.skipCount = skipCount
        self.estimatedRegularFileCopyBytes = estimatedRegularFileCopyBytes
    }

    private static func isExpectedURL(_ url: URL, root: URL, relativePath: ComparisonRelativePath) -> Bool {
        url.standardizedFileURL == root.appending(path: relativePath.string).standardizedFileURL
    }
}

struct FolderSynchronizationPlanSummary: Sendable, Equatable {
    let direction: ComparisonDirection
    let comparisonGeneration: UUID
    let sourceRoot: URL
    let destinationRoot: URL
    let sourceRootIdentity: FileIdentity
    let destinationRootIdentity: FileIdentity
    let skipCount: Int

    init(
        direction: ComparisonDirection,
        comparisonGeneration: UUID,
        sourceRoot: URL,
        destinationRoot: URL,
        sourceRootIdentity: FileIdentity,
        destinationRootIdentity: FileIdentity,
        skipCount: Int
    ) throws {
        guard skipCount >= 0 else { throw FolderSynchronizationModelValidationError.negativeCount }
        self.direction = direction
        self.comparisonGeneration = comparisonGeneration
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.sourceRootIdentity = sourceRootIdentity
        self.destinationRootIdentity = destinationRootIdentity
        self.skipCount = skipCount
    }
}

struct FolderSynchronizationBlocker: Sendable, Equatable, Identifiable {
    enum Reason: String, Sendable, Equatable {
        case comparisonNotCurrent
        case missingComparisonSession
        case equalRoots
        case nestedRoots
        case unsafeAncestorRelationship
        case duplicateComparisonPath
        case invalidComparisonRow
        case typeConflict
        case nameConflict
        case checking
        case unstable
        case comparisonError
        case unsupportedEntryKind

        var presentation: String {
            switch self {
            case .comparisonNotCurrent: "Comparison is not current."
            case .missingComparisonSession: "Comparison session is unavailable."
            case .equalRoots: "The comparison roots identify the same folder."
            case .nestedRoots: "One comparison root is inside the other."
            case .unsafeAncestorRelationship: "An ancestor relationship is unsafe for synchronization."
            case .duplicateComparisonPath: "The comparison contains a duplicate relative path."
            case .invalidComparisonRow: "The comparison row is incomplete."
            case .typeConflict: "The item kinds conflict."
            case .nameConflict: "The item name conflicts."
            case .checking: "The item is still being checked."
            case .unstable: "The item changed while being checked."
            case .comparisonError: "The item could not be compared."
            case .unsupportedEntryKind: "This item kind is not supported for synchronization."
            }
        }
    }

    let relativePath: ComparisonRelativePath?
    let reason: Reason

    var id: String { "\(relativePath?.string ?? "roots"):\(reason.rawValue)" }

    var presentation: String {
        guard let relativePath else { return reason.presentation }
        return "\(relativePath.string): \(reason.presentation)"
    }

    init(relativePath: ComparisonRelativePath? = nil, reason: Reason) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

enum FolderSynchronizationPlanningResult: Sendable, Equatable {
    case ready(FolderSynchronizationPlanDraft)
    case alreadySynchronized(FolderSynchronizationPlanSummary)
    case blocked([FolderSynchronizationBlocker])
}
