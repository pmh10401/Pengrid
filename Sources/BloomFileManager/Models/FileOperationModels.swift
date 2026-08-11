import Foundation

enum TransferMode: Sendable, Equatable {
    case copy
    case move
}

enum ConflictDecision: Sendable, Equatable {
    case replace
    case keepBoth
    case skip
    case cancel
}

struct FileConflict: Sendable, Equatable {
    let source: URL
    let proposedDestination: URL
}

struct FileOperationProgress: Sendable, Equatable {
    let completedCount: Int
    let totalCount: Int
    let currentName: String
}

struct IdentifiedFileRequest: Sendable, Equatable {
    let url: URL
    let identity: FileIdentity
}

struct IdentifiedCreatedFileRequest: Sendable, Equatable {
    let url: URL
    let identity: FileIdentity
    let fingerprint: SourceFingerprint?
}

struct IdentifiedTransferRequest: Sendable, Equatable {
    let source: URL
    let sourceIdentity: FileIdentity
    let destinationRoot: URL
    let destinationRootIdentity: FileIdentity
    let relativeParentComponents: [String]
}

enum SelectionFolderTransactionPhase: Sendable, Equatable {
    case creatingFolder
    case movingItems
    case rollingBack
}

struct SelectionFolderTransactionProgress: Sendable, Equatable {
    let phase: SelectionFolderTransactionPhase
    let completedCount: Int
    let totalCount: Int
    let currentName: String
}

struct SelectionFolderUndoEntry: Sendable, Equatable {
    let originalSource: ContextActionSource
    let folderURL: URL
    let folderIdentity: FileIdentity
    let fingerprint: SourceFingerprint
}

struct SelectionFolderUndoPlan: Sendable, Equatable {
    let parentURL: URL
    let parentIdentity: FileIdentity
    let folderURL: URL
    let folderIdentity: FileIdentity
    let entries: [SelectionFolderUndoEntry]
}

enum ArchiveSelectionEligibility {
    static func canCompress(_ items: [FileItem]) -> Bool {
        !items.isEmpty
    }

    static func canExtract(_ items: [FileItem]) -> Bool {
        !items.isEmpty && items.allSatisfy {
            !$0.isDirectory
                && ArchiveFormat.detect(filename: $0.name) != nil
        }
    }
}

struct ArchiveDestinationPlan: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let selectedSources: [URL]
    let sourceDisplayNames: [String]
    let destinations: [URL]
    let formats: [ArchiveFormat]
    let protection: ArchiveProtection

    init(
        kind: ArchiveOperationKind,
        selectedSources: [URL],
        sourceDisplayNames: [String],
        destinations: [URL],
        formats: [ArchiveFormat]
    ) {
        self.init(
            kind: kind,
            selectedSources: selectedSources,
            sourceDisplayNames: sourceDisplayNames,
            destinations: destinations,
            formats: formats,
            protection: .none,
            validated: ()
        )
    }

    init?(
        kind: ArchiveOperationKind,
        selectedSources: [URL],
        sourceDisplayNames: [String],
        destinations: [URL],
        formats: [ArchiveFormat],
        protection: ArchiveProtection
    ) {
        guard Self.isAllowed(
            kind: kind,
            formats: formats,
            protection: protection
        ) else { return nil }
        self.init(
            kind: kind,
            selectedSources: selectedSources,
            sourceDisplayNames: sourceDisplayNames,
            destinations: destinations,
            formats: formats,
            protection: protection,
            validated: ()
        )
    }

    private init(
        kind: ArchiveOperationKind,
        selectedSources: [URL],
        sourceDisplayNames: [String],
        destinations: [URL],
        formats: [ArchiveFormat],
        protection: ArchiveProtection,
        validated _: Void
    ) {
        self.kind = kind
        self.selectedSources = selectedSources
        self.sourceDisplayNames = sourceDisplayNames
        self.destinations = destinations
        self.formats = formats
        self.protection = protection
    }

    private static func isAllowed(
        kind: ArchiveOperationKind,
        formats: [ArchiveFormat],
        protection: ArchiveProtection
    ) -> Bool {
        protection == .none
            || (kind == .compress && formats.count == 1 && formats.first == .zip)
    }

    func requests(
        for verifiedSources: [IdentifiedFileRequest],
        destinationParentIdentity: FileIdentity
    ) -> [ArchiveRequest]? {
        guard verifiedSources.count == selectedSources.count,
              sourceDisplayNames.count == selectedSources.count
        else { return nil }
        switch kind {
        case .compress:
            guard destinations.count == 1, formats.count == 1 else { return nil }
            let request: ArchiveRequest?
            if protection == .none {
                request = ArchiveRequest(
                    kind: .compress,
                    verifiedSources: verifiedSources,
                    finalDestination: destinations[0],
                    destinationParentIdentity: destinationParentIdentity,
                    progressDisplayName: destinations[0].lastPathComponent,
                    format: formats[0]
                )
            } else {
                request = ArchiveRequest(
                    kind: .compress,
                    verifiedSources: verifiedSources,
                    finalDestination: destinations[0],
                    destinationParentIdentity: destinationParentIdentity,
                    progressDisplayName: destinations[0].lastPathComponent,
                    format: formats[0],
                    protection: protection
                )
            }
            guard let request else { return nil }
            return [request]
        case .extract:
            guard destinations.count == verifiedSources.count,
                  formats.count == verifiedSources.count
            else { return nil }
            return verifiedSources.indices.map { index in
                ArchiveRequest(
                    kind: .extract,
                    verifiedSources: [verifiedSources[index]],
                    finalDestination: destinations[index],
                    destinationParentIdentity: destinationParentIdentity,
                    progressDisplayName: sourceDisplayNames[index],
                    format: formats[index]
                )
            }
        }
    }
}

enum ArchiveDestinationPlanner {
    static func compression(
        selectedItems: [FileItem],
        in directory: URL,
        occupiedNames: Set<String>,
        format: ArchiveFormat = .zip,
        protection: ArchiveProtection = .none
    ) -> ArchiveDestinationPlan? {
        guard ArchiveSelectionEligibility.canCompress(selectedItems),
              protection == .none || (format == .zip && protection == .aes256)
        else { return nil }
        let proposedName = selectedItems.count == 1
            ? "\(selectedItems[0].name)\(format.canonicalSuffix)"
            : "Archive\(format.canonicalSuffix)"
        let destinationName = KeepBothNamer.availableName(
            for: proposedName,
            existing: occupiedNames
        )
        return ArchiveDestinationPlan(
            kind: .compress,
            selectedSources: selectedItems.map(\.url),
            sourceDisplayNames: selectedItems.map(\.name),
            destinations: [directory.appending(path: destinationName)],
            formats: [format],
            protection: protection
        )
    }

    static func extraction(
        selectedItems: [FileItem],
        in directory: URL,
        occupiedNames: Set<String>,
        protection: ArchiveProtection = .none
    ) -> ArchiveDestinationPlan? {
        guard ArchiveSelectionEligibility.canExtract(selectedItems),
              protection == .none
        else { return nil }
        var occupied = occupiedNames
        var destinations: [URL] = []
        var formats: [ArchiveFormat] = []
        for item in selectedItems {
            guard let format = ArchiveFormat.detect(filename: item.name),
                  let stem = ArchiveFormat.removingRecognizedSuffix(from: item.name),
                  !stem.isEmpty
            else { return nil }
            let destinationName = KeepBothNamer.availableName(
                for: stem,
                existing: occupied
            )
            occupied.insert(destinationName)
            destinations.append(directory.appending(
                path: destinationName,
                directoryHint: .isDirectory
            ))
            formats.append(format)
        }
        return ArchiveDestinationPlan(
            kind: .extract,
            selectedSources: selectedItems.map(\.url),
            sourceDisplayNames: selectedItems.map(\.name),
            destinations: destinations,
            formats: formats
        )
    }
}

enum FileOperationItemOutcome: Sendable, Equatable {
    case succeeded(source: URL, destination: URL?)
    case recoveryNeeded(source: URL)
    case skipped(source: URL)
    case cancelled(source: URL)
    case failed(source: URL, message: String)
}

struct FileOperationResult: Sendable, Equatable {
    let outcomes: [FileOperationItemOutcome]
    private let safeRelativePathsBySource: [URL: ComparisonRelativePath]
    private let undoDestinationIdentities: [URL: FileIdentity]
    private let undoDestinationFingerprints: [URL: SourceFingerprint]
    private let batchRenameUndoPlan: BatchRenameUndoPlan?
    private let selectionFolderUndoPlan: SelectionFolderUndoPlan?

    init(
        outcomes: [FileOperationItemOutcome],
        safeRelativePathsBySource: [URL: ComparisonRelativePath] = [:],
        undoDestinationIdentities: [URL: FileIdentity] = [:],
        undoDestinationFingerprints: [URL: SourceFingerprint] = [:],
        batchRenameUndoPlan: BatchRenameUndoPlan? = nil,
        selectionFolderUndoPlan: SelectionFolderUndoPlan? = nil
    ) {
        self.outcomes = outcomes
        var normalized: [URL: ComparisonRelativePath] = [:]
        var ambiguous: Set<URL> = []
        for (source, path) in safeRelativePathsBySource {
            let key = source.standardizedFileURL
            guard !ambiguous.contains(key) else { continue }
            if let existing = normalized[key], existing != path {
                normalized.removeValue(forKey: key)
                ambiguous.insert(key)
            } else {
                normalized[key] = path
            }
        }
        self.safeRelativePathsBySource = normalized
        var normalizedUndoIdentities: [URL: FileIdentity] = [:]
        for (destination, identity) in undoDestinationIdentities {
            normalizedUndoIdentities[destination.standardizedFileURL] = identity
        }
        self.undoDestinationIdentities = normalizedUndoIdentities
        var normalizedUndoFingerprints: [URL: SourceFingerprint] = [:]
        for (destination, fingerprint) in undoDestinationFingerprints {
            normalizedUndoFingerprints[destination.standardizedFileURL] = fingerprint
        }
        self.undoDestinationFingerprints = normalizedUndoFingerprints
        self.batchRenameUndoPlan = batchRenameUndoPlan
        self.selectionFolderUndoPlan = selectionFolderUndoPlan
    }

    func safeRelativePath(for source: URL) -> ComparisonRelativePath? {
        safeRelativePathsBySource[source.standardizedFileURL]
    }

    func undoDestinationIdentity(for destination: URL) -> FileIdentity? {
        undoDestinationIdentities[destination.standardizedFileURL]
    }

    func undoDestinationFingerprint(for destination: URL) -> SourceFingerprint? {
        undoDestinationFingerprints[destination.standardizedFileURL]
    }

    func batchRenameUndoMetadata() -> BatchRenameUndoPlan? {
        batchRenameUndoPlan
    }

    func selectionFolderUndoMetadata() -> SelectionFolderUndoPlan? {
        selectionFolderUndoPlan
    }

    func addingSafeRelativePaths(
        _ paths: [URL: ComparisonRelativePath]
    ) -> FileOperationResult {
        var mergedPaths = safeRelativePathsBySource
        for (source, path) in paths {
            mergedPaths[source.standardizedFileURL] = path
        }
        return FileOperationResult(
            outcomes: outcomes,
            safeRelativePathsBySource: mergedPaths,
            undoDestinationIdentities: undoDestinationIdentities,
            undoDestinationFingerprints: undoDestinationFingerprints,
            batchRenameUndoPlan: batchRenameUndoPlan,
            selectionFolderUndoPlan: selectionFolderUndoPlan
        )
    }

    /// Appends an operation result without dropping the safe metadata collected
    /// by either request. Earlier metadata wins for a repeated key so a later
    /// request cannot overwrite the identity captured by an earlier publish.
    func merging(_ other: FileOperationResult) -> FileOperationResult {
        var paths = safeRelativePathsBySource
        for (source, path) in other.safeRelativePathsBySource {
            paths[source] = paths[source] ?? path
        }
        var identities = undoDestinationIdentities
        for (destination, identity) in other.undoDestinationIdentities {
            identities[destination] = identities[destination] ?? identity
        }
        var fingerprints = undoDestinationFingerprints
        for (destination, fingerprint) in other.undoDestinationFingerprints {
            fingerprints[destination] = fingerprints[destination] ?? fingerprint
        }
        return FileOperationResult(
            outcomes: outcomes + other.outcomes,
            safeRelativePathsBySource: paths,
            undoDestinationIdentities: identities,
            undoDestinationFingerprints: fingerprints,
            batchRenameUndoPlan: batchRenameUndoPlan ?? other.batchRenameUndoPlan,
            selectionFolderUndoPlan: selectionFolderUndoPlan ?? other.selectionFolderUndoPlan
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.outcomes == rhs.outcomes
            && lhs.safeRelativePathsBySource == rhs.safeRelativePathsBySource
    }

    var hasFailures: Bool {
        outcomes.contains {
            switch $0 {
            case .recoveryNeeded, .failed, .cancelled:
                return true
            case .succeeded, .skipped:
                return false
            }
        }
    }
}

typealias ConflictResolver = @Sendable (FileConflict) async -> ConflictDecision
typealias OperationProgressHandler = @Sendable (FileOperationProgress) async -> Void
