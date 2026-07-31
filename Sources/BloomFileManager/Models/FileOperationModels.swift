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

struct IdentifiedTransferRequest: Sendable, Equatable {
    let source: URL
    let sourceIdentity: FileIdentity
    let destinationRoot: URL
    let destinationRootIdentity: FileIdentity
    let relativeParentComponents: [String]
}

enum ArchiveSelectionEligibility {
    static func canCompress(_ items: [FileItem]) -> Bool {
        !items.isEmpty
    }

    static func canExtract(_ items: [FileItem]) -> Bool {
        !items.isEmpty && items.allSatisfy {
            !$0.isDirectory
                && URL(filePath: $0.name).pathExtension.lowercased() == "zip"
        }
    }
}

struct ArchiveDestinationPlan: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let selectedSources: [URL]
    let destinations: [URL]

    func requests(for verifiedSources: [URL]) -> [ArchiveRequest]? {
        guard verifiedSources.count == selectedSources.count else { return nil }
        switch kind {
        case .compress:
            guard destinations.count == 1 else { return nil }
            return [
                ArchiveRequest(
                    kind: .compress,
                    verifiedSources: verifiedSources,
                    finalDestination: destinations[0]
                )
            ]
        case .extract:
            guard destinations.count == verifiedSources.count else { return nil }
            return zip(verifiedSources, destinations).map { source, destination in
                ArchiveRequest(
                    kind: .extract,
                    verifiedSources: [source],
                    finalDestination: destination
                )
            }
        }
    }
}

enum ArchiveDestinationPlanner {
    static func compression(
        selectedItems: [FileItem],
        in directory: URL,
        occupiedNames: Set<String>
    ) -> ArchiveDestinationPlan? {
        guard ArchiveSelectionEligibility.canCompress(selectedItems) else { return nil }
        let proposedName = selectedItems.count == 1
            ? "\(selectedItems[0].name).zip"
            : "Archive.zip"
        let destinationName = KeepBothNamer.availableName(
            for: proposedName,
            existing: occupiedNames
        )
        return ArchiveDestinationPlan(
            kind: .compress,
            selectedSources: selectedItems.map(\.url),
            destinations: [directory.appending(path: destinationName)]
        )
    }

    static func extraction(
        selectedItems: [FileItem],
        in directory: URL,
        occupiedNames: Set<String>
    ) -> ArchiveDestinationPlan? {
        guard ArchiveSelectionEligibility.canExtract(selectedItems) else { return nil }
        var occupied = occupiedNames
        var destinations: [URL] = []
        for item in selectedItems {
            let stem = URL(filePath: item.name)
                .deletingPathExtension()
                .lastPathComponent
            let destinationName = KeepBothNamer.availableName(
                for: stem,
                existing: occupied
            )
            occupied.insert(destinationName)
            destinations.append(directory.appending(
                path: destinationName,
                directoryHint: .isDirectory
            ))
        }
        return ArchiveDestinationPlan(
            kind: .extract,
            selectedSources: selectedItems.map(\.url),
            destinations: destinations
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

    init(
        outcomes: [FileOperationItemOutcome],
        safeRelativePathsBySource: [URL: ComparisonRelativePath] = [:]
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
    }

    func safeRelativePath(for source: URL) -> ComparisonRelativePath? {
        safeRelativePathsBySource[source.standardizedFileURL]
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
