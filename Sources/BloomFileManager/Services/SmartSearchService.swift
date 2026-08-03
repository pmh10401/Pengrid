import Foundation

protocol SmartSearching: Sendable {
    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult]
    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult]
}

extension SmartSearching {
    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        try await search(query)
    }
}

enum SmartSearchServiceError: Error, Equatable, Sendable {
    case invalidRoot
}

struct PreparedSmartSearchCandidate: Sendable {
    let result: SmartSearchResult
    let match: SmartSearchMatch
}

final class LocalSmartSearchService: SmartSearching, @unchecked Sendable {
    typealias TraversalHook = @Sendable (URL) throws -> Void
    typealias RankingHook = @Sendable () throws -> Void
    typealias TypeDescriptionReader = @Sendable (URL) throws -> String?

    private let fileManager: FileManager
    private let availabilityReader: any CloudItemAvailabilityReading
    private let scopedAccessCoordinator: CloudLocationScopedAccessCoordinator
    private let traversalHook: TraversalHook
    private let rankingHook: RankingHook
    private let typeDescriptionReader: TypeDescriptionReader

    init(
        fileManager: FileManager = .default,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        scopedAccessCoordinator: CloudLocationScopedAccessCoordinator = CloudLocationScopedAccessCoordinator(),
        traversalHook: @escaping TraversalHook = { _ in },
        rankingHook: @escaping RankingHook = {},
        typeDescriptionReader: @escaping TypeDescriptionReader = {
            try $0.resourceValues(
                forKeys: [.localizedTypeDescriptionKey]
            ).localizedTypeDescription
        }
    ) {
        self.fileManager = fileManager
        self.availabilityReader = availabilityReader
        self.scopedAccessCoordinator = scopedAccessCoordinator
        self.traversalHook = traversalHook
        self.rankingHook = rankingHook
        self.typeDescriptionReader = typeDescriptionReader
    }

    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        try await search(query, progress: { _ in })
    }

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        let queryPlan = try query.executablePlan()
        let roots = try validatedRoots(from: query.roots)
        let leases = try scopedAccessCoordinator.acquireAccess(for: roots)
        defer { leases.forEach { $0.finish() } }
        var allCandidates: [PreparedSmartSearchCandidate] = []
        allCandidates.reserveCapacity(query.candidateBudget)
        var seenCandidatePaths = Set<String>()
        var examinedEntryCount = 0
        for root in roots {
            try Task.checkCancellation()
            let remainingBudget = query.candidateBudget - allCandidates.count
            guard remainingBudget > 0 else { break }
            let batch = try await candidates(
                in: root,
                query: query,
                queryPlan: queryPlan,
                maximumCandidates: remainingBudget,
                examinedEntryCount: examinedEntryCount,
                progress: progress
            )
            examinedEntryCount = batch.examinedEntryCount
            for candidate in batch.results where allCandidates.count < query.candidateBudget {
                let path = candidate.result.item.url.standardizedFileURL.path
                if seenCandidatePaths.insert(path).inserted {
                    allCandidates.append(candidate)
                }
            }
        }
        try Task.checkCancellation()
        let ranked = try SmartSearchRanker.ranked(
            allCandidates,
            for: query,
            plan: queryPlan,
            cancellationCheck: {
                try Task.checkCancellation()
                try rankingHook()
            }
        )
        try Task.checkCancellation()
        let limited = Array(ranked.prefix(query.maximumResults))
        try Task.checkCancellation()
        return limited
    }

    private func validatedRoots(from roots: [URL]) throws -> [URL] {
        var seen = Set<String>()
        var validated: [URL] = []
        for root in roots {
            let standardized = root.standardizedFileURL
            guard standardized.isFileURL,
                  (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw SmartSearchServiceError.invalidRoot
            }
            guard seen.insert(standardized.path).inserted else { continue }
            validated.append(standardized)
        }
        return validated.filter { candidate in
            !validated.contains { possibleParent in
                possibleParent != candidate && contains(candidate, within: possibleParent)
            }
        }
    }

    private func candidates(
        in root: URL,
        query: SmartSearchQuery,
        queryPlan: SmartSearchQueryPlan,
        maximumCandidates: Int,
        examinedEntryCount: Int,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> (results: [PreparedSmartSearchCandidate], examinedEntryCount: Int) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
            .contentModificationDateKey, .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { throw SmartSearchServiceError.invalidRoot }

        var results: [PreparedSmartSearchCandidate] = []
        results.reserveCapacity(maximumCandidates)
        var examinedEntryCount = examinedEntryCount
        while results.count < maximumCandidates,
              let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            examinedEntryCount += 1
            progress(examinedEntryCount)
            do {
                try traversalHook(url)
                let isSymbolicLink = try fileManager.attributesOfItem(atPath: url.path)[.type]
                    as? FileAttributeType == .typeSymbolicLink
                let hasSymbolicLinkBoundary = try hasSymbolicLinkBoundary(for: url, below: root)
                // FileManager does not descend through a symlink entry. Calling
                // skipDescendants() on that non-directory entry can instead skip
                // the next sibling directory, so only use it for an observed
                // descendant boundary.
                if isSymbolicLink {
                    continue
                }
                if hasSymbolicLinkBoundary {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try url.resourceValues(forKeys: keys)
                let hidden = values.isHidden == true || url.lastPathComponent.hasPrefix(".")
                let directory = values.isDirectory == true
                let package = values.isPackage == true
                let symlink = values.isSymbolicLink == true

                if hidden && !query.includeHidden {
                    if directory { enumerator.skipDescendants() }
                    continue
                }
                if package && !query.includePackages {
                    if directory { enumerator.skipDescendants() }
                    continue
                }
                if symlink {
                    if directory { enumerator.skipDescendants() }
                    continue
                }
                let relativePath = relativePath(of: url, from: root)
                guard (query.includeDirectories || !directory),
                      !(directory && package),
                      let match = try SmartSearchTextAnalyzer.match(
                          plan: queryPlan,
                          filename: url.lastPathComponent,
                          relativePath: relativePath,
                          analysisStep: { try Task.checkCancellation() }
                      ) else { continue }

                let standardizedURL = url.standardizedFileURL
                let availability = await availabilityReader.availability(of: standardizedURL)
                let typeDescription = (try? typeDescriptionReader(url))
                    ?? (directory ? "Folder" : "File")
                try Task.checkCancellation()
                results.append(PreparedSmartSearchCandidate(
                    result: SmartSearchResult(
                        item: FileItem(
                            url: standardizedURL, name: url.lastPathComponent, isDirectory: directory,
                            isPackage: package, modifiedAt: values.contentModificationDate,
                            byteSize: values.fileSize.map(Int64.init),
                            typeDescription: typeDescription,
                            availability: availability
                        ),
                        relativePath: relativePath,
                        score: 0
                    ),
                    match: match
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return (results, examinedEntryCount)
    }

    private func contains(_ candidate: URL, within root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if rootPath == "/" { return candidatePath.hasPrefix("/") }
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func hasSymbolicLinkBoundary(for url: URL, below root: URL) throws -> Bool {
        let path = url.path
        guard let rootRange = path.range(of: root.path) else { return false }
        var candidatePath = String(path[..<rootRange.upperBound])
        for component in path[rootRange.upperBound...].split(separator: "/") {
            candidatePath += "/" + component
            let attributes = try fileManager.attributesOfItem(atPath: candidatePath)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return true
            }
        }
        return false
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

}
