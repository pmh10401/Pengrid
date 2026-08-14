import Foundation

enum SmartSearchCoverage: Equatable, Sendable {
    case namesAndPathsOnly
    case indexedContentsIncluded
    case indexedContentsUnavailable
    case indexedContentsSkippedForInitialQuery
}

protocol SmartSearching: Sendable {
    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult]

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void,
        coverage: @escaping @Sendable (SmartSearchCoverage) -> Void
    ) async throws -> [SmartSearchResult]
}

extension SmartSearching {
    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        try await search(query, progress: { _ in })
    }

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void,
        coverage: @escaping @Sendable (SmartSearchCoverage) -> Void
    ) async throws -> [SmartSearchResult] {
        coverage(.namesAndPathsOnly)
        return try await search(query, progress: progress)
    }
}

enum SmartSearchServiceError: Error, Equatable, Sendable {
    case invalidRoot
}

final class LocalSmartSearchService: SmartSearching, @unchecked Sendable {
    typealias TypeDescriptionReader = @Sendable (URL) throws -> String?

    private let fileManager: FileManager
    private let fileSystem: any FileSystemAccess
    private let availabilityReader: any CloudItemAvailabilityReading
    private let scopedAccessCoordinator: CloudLocationScopedAccessCoordinator
    private let typeDescriptionReader: TypeDescriptionReader

    init(
        fileManager: FileManager = .default,
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        scopedAccessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        typeDescriptionReader: @escaping @Sendable (URL) throws -> String? = {
            try $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
        }
    ) {
        self.fileManager = fileManager
        self.fileSystem = fileSystem
        self.availabilityReader = availabilityReader
        self.scopedAccessCoordinator = scopedAccessCoordinator
        self.typeDescriptionReader = typeDescriptionReader
    }

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        let queryPlan = try query.executablePlan()
        let roots = try validatedRoots(from: query.roots)
        let leases = try scopedAccessCoordinator.acquireAccess(for: roots)
        defer { leases.forEach { $0.finish() } }

        var retainedCandidates: [PreparedSmartSearchCandidate] = []
        retainedCandidates.reserveCapacity(query.candidateBudget)
        var seenPaths = Set<String>()
        var examinedEntries = 0

        for root in roots {
            try Task.checkCancellation()
            guard retainedCandidates.count < query.candidateBudget else { break }
            let batch = try await candidates(
                in: root,
                query: query,
                plan: queryPlan,
                maximumCandidates: query.candidateBudget - retainedCandidates.count,
                examinedEntries: examinedEntries,
                progress: progress
            )
            examinedEntries = batch.examinedEntries

            for candidate in batch.candidates where retainedCandidates.count < query.candidateBudget {
                let path = candidate.result.item.url.standardizedFileURL.path
                if seenPaths.insert(path).inserted {
                    retainedCandidates.append(candidate)
                }
            }
        }

        try Task.checkCancellation()
        return try SmartSearchRanker.ranked(
            retainedCandidates,
            for: query,
            plan: queryPlan,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    private func validatedRoots(from roots: [URL]) throws -> [URL] {
        var uniqueRoots: [URL] = []
        var seenPaths = Set<String>()

        for root in roots {
            let standardized = root.standardizedFileURL
            guard standardized.isFileURL,
                  (try? hasSymbolicLinkAncestor(at: standardized)) == false,
                  (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw SmartSearchServiceError.invalidRoot
            }
            if seenPaths.insert(standardized.path).inserted {
                uniqueRoots.append(standardized)
            }
        }

        return uniqueRoots.filter { candidate in
            !uniqueRoots.contains { other in
                candidate != other && contains(candidate, within: other)
            }
        }
    }

    private func candidates(
        in root: URL,
        query: SmartSearchQuery,
        plan: SmartSearchQueryPlan,
        maximumCandidates: Int,
        examinedEntries: Int,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> (candidates: [PreparedSmartSearchCandidate], examinedEntries: Int) {
        let boundaryKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .isSymbolicLinkKey
        ]
        let filterKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(boundaryKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw SmartSearchServiceError.invalidRoot
        }

        var retained: [PreparedSmartSearchCandidate] = []
        retained.reserveCapacity(maximumCandidates)
        var examined = examinedEntries

        while retained.count < maximumCandidates,
              let enumeratedURL = enumerator.nextObject() as? URL {
            var url = enumeratedURL
            try Task.checkCancellation()
            examined += 1
            progress(examined)

            do {
                if try isSymbolicLink(url) {
                    continue
                }
                if try hasSymbolicLinkBoundary(for: url, below: root) {
                    enumerator.skipDescendants()
                    continue
                }

                let boundary = try url.resourceValues(forKeys: boundaryKeys)
                let traversalIsDirectory = boundary.isDirectory == true
                let traversalIsPackage = boundary.isPackage == true
                let traversalIsHidden = boundary.isHidden == true || url.lastPathComponent.hasPrefix(".")

                if traversalIsHidden && !query.includeHidden {
                    if traversalIsDirectory { enumerator.skipDescendants() }
                    continue
                }
                if traversalIsPackage && !query.includePackages {
                    if traversalIsDirectory { enumerator.skipDescendants() }
                    continue
                }

                let relativePath = relativePath(of: url, from: root)
                guard let match = try SmartSearchTextAnalyzer.match(
                          plan: plan,
                          filename: url.lastPathComponent,
                          relativePath: relativePath,
                          analysisStep: { try Task.checkCancellation() }
                      ) else {
                    continue
                }

                let standardizedURL = url.standardizedFileURL
                guard let identityBefore = try await fileSystem.identity(of: standardizedURL) else {
                    continue
                }

                url.removeAllCachedResourceValues()
                let metadata = try url.resourceValues(forKeys: boundaryKeys.union(filterKeys))
                let isDirectory = metadata.isDirectory == true
                let isPackage = metadata.isPackage == true
                let isSymbolicLink = metadata.isSymbolicLink == true
                let isHidden = metadata.isHidden == true || url.lastPathComponent.hasPrefix(".")
                let byteSize = metadata.fileSize.map(Int64.init)
                guard !(isDirectory && isPackage),
                      (!isHidden || query.includeHidden),
                      (!isPackage || query.includePackages),
                      query.metadata.matches(
                    isDirectory: isDirectory,
                    extension: url.pathExtension,
                    byteSize: byteSize,
                    modifiedAt: metadata.contentModificationDate
                ) else {
                    continue
                }

                let typeDescription = (try? typeDescriptionReader(url))
                    ?? (isDirectory ? "Folder" : "File")
                let availability = await availabilityReader.availability(of: standardizedURL)
                try Task.checkCancellation()
                guard let identityAfter = try await fileSystem.identity(of: standardizedURL),
                      identityBefore == identityAfter else {
                    continue
                }

                retained.append(
                    PreparedSmartSearchCandidate(
                        result: SmartSearchResult(
                            item: FileItem(
                                url: standardizedURL,
                                name: url.lastPathComponent,
                                isDirectory: isDirectory,
                                isPackage: isPackage,
                                isSymbolicLink: isSymbolicLink,
                                modifiedAt: metadata.contentModificationDate,
                                byteSize: byteSize,
                                typeDescription: typeDescription,
                                availability: availability
                            ),
                            relativePath: relativePath,
                            score: 0,
                            identity: identityBefore
                        ),
                        match: match
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        return (retained, examined)
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func hasSymbolicLinkBoundary(for url: URL, below root: URL) throws -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }

        var candidatePath = rootPath
        for component in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            candidatePath += "/" + component
            if try isSymbolicLink(URL(fileURLWithPath: candidatePath)) {
                return true
            }
        }
        return false
    }

    private func hasSymbolicLinkAncestor(at url: URL) throws -> Bool {
        var path = ""
        for component in url.standardizedFileURL.path.split(separator: "/") {
            path += "/" + component
            if try isSymbolicLink(URL(fileURLWithPath: path)) {
                return true
            }
        }
        return false
    }

    private func contains(_ candidate: URL, within root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return rootPath == "/" ? candidatePath.hasPrefix("/") : candidatePath.hasPrefix(rootPath + "/")
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
