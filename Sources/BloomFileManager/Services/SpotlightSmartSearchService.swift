import Foundation

protocol SpotlightContentSearching: Sendable {
    func searchIndexedContents(_ query: SmartSearchQuery) async throws -> [SmartSearchResult]
}

final class LiveSpotlightSmartSearchService: SpotlightContentSearching, @unchecked Sendable {
    typealias TypeDescriptionReader = @Sendable (URL) throws -> String?

    private let runner: any SpotlightMetadataQueryRunning
    private let fileManager: FileManager
    private let fileSystem: any FileSystemAccess
    private let availabilityReader: any CloudItemAvailabilityReading
    private let scopedAccessCoordinator: CloudLocationScopedAccessCoordinator
    private let typeDescriptionReader: TypeDescriptionReader

    init(
        runner: any SpotlightMetadataQueryRunning,
        fileManager: FileManager = .default,
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        scopedAccessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        typeDescriptionReader: @escaping TypeDescriptionReader = {
            try $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
        }
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.fileSystem = fileSystem
        self.availabilityReader = availabilityReader
        self.scopedAccessCoordinator = scopedAccessCoordinator
        self.typeDescriptionReader = typeDescriptionReader
    }

    func searchIndexedContents(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        let plan = try query.executablePlan()
        let tokens = try literalTokens(from: plan)
        let roots = try validatedRoots(from: query.roots)
        let leases = try scopedAccessCoordinator.acquireAccess(for: roots)
        defer { leases.forEach { $0.finish() } }

        let rootAuthorities = try await captureRootAuthorities(for: roots)
        let matchingURLs = try await runner.matchingURLs(tokens: tokens, roots: roots)
        try await validateRootAuthorities(rootAuthorities)
        var results: [SmartSearchResult] = []
        results.reserveCapacity(min(matchingURLs.count, query.candidateBudget))
        var seenPaths = Set<String>()
        var hydratedCandidates = 0

        for returnedURL in matchingURLs {
            try Task.checkCancellation()
            let url = returnedURL.standardizedFileURL
            guard seenPaths.insert(url.path).inserted,
                  let root = containingRoot(for: url, roots: roots),
                  let rootAuthority = rootAuthorities.first(where: { $0.root == root }) else {
                continue
            }
            guard hydratedCandidates < query.candidateBudget else { break }
            hydratedCandidates += 1

            if let result = try await hydrate(
                url,
                root: root,
                rootAuthority: rootAuthority,
                query: query
            ) {
                results.append(result)
            }
        }

        try await validateRootAuthorities(rootAuthorities)
        return results
    }

    private func literalTokens(from plan: SmartSearchQueryPlan) throws -> [String] {
        var tokens: [String] = []
        tokens.reserveCapacity(plan.clauses.count)
        for clause in plan.clauses {
            guard case let .literal(token) = clause else {
                throw SpotlightMetadataQueryError.unavailable
            }
            tokens.append(token)
        }
        guard !tokens.isEmpty else {
            throw SpotlightMetadataQueryError.unavailable
        }
        return tokens
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

    private func hydrate(
        _ candidate: URL,
        root: URL,
        rootAuthority: SpotlightRootAuthority,
        query: SmartSearchQuery
    ) async throws -> SmartSearchResult? {
        try await validateRootAuthority(rootAuthority)
        do {
            let candidateAuthority = try await capturePathAuthority(
                for: candidateAncestorURLs(of: candidate, below: root)
            )
            try await validateRootAuthority(rootAuthority)
            try await validatePathAuthority(candidateAuthority)
            guard try respectsTraversalBoundaries(candidate, below: root, query: query) else {
                return nil
            }
            try await validateRootAuthority(rootAuthority)
            try await validatePathAuthority(candidateAuthority)
            guard let identityBefore = try await fileSystem.identity(of: candidate) else {
                return nil
            }
            try await validateRootAuthority(rootAuthority)
            try await validatePathAuthority(candidateAuthority)

            var uncachedCandidate = candidate
            uncachedCandidate.removeAllCachedResourceValues()
            let metadataKeys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isPackageKey,
                .isHiddenKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileSizeKey
            ]
            let metadata = try uncachedCandidate.resourceValues(forKeys: metadataKeys)
            let isDirectory = metadata.isDirectory == true
            let isPackage = metadata.isPackage == true
            let isSymbolicLink = metadata.isSymbolicLink == true
            let isHidden = metadata.isHidden == true || candidate.lastPathComponent.hasPrefix(".")
            let byteSize = metadata.fileSize.map(Int64.init)

            guard !isSymbolicLink,
                  !(isDirectory && isPackage),
                  (!isHidden || query.includeHidden),
                  (!isPackage || query.includePackages),
                  query.metadata.matches(
                      isDirectory: isDirectory,
                      extension: candidate.pathExtension,
                      byteSize: byteSize,
                      modifiedAt: metadata.contentModificationDate
                  ) else {
                return nil
            }

            let typeDescription = (try? typeDescriptionReader(uncachedCandidate))
                ?? (isDirectory ? "Folder" : "File")
            let availability = await availabilityReader.availability(of: candidate)
            try Task.checkCancellation()
            guard let identityAfter = try await fileSystem.identity(of: candidate),
                  identityBefore == identityAfter else {
                return nil
            }
            try await validateRootAuthority(rootAuthority)
            try await validatePathAuthority(candidateAuthority)

            return SmartSearchResult(
                item: FileItem(
                    url: candidate,
                    name: candidate.lastPathComponent,
                    isDirectory: isDirectory,
                    isPackage: isPackage,
                    isSymbolicLink: isSymbolicLink,
                    modifiedAt: metadata.contentModificationDate,
                    byteSize: byteSize,
                    typeDescription: typeDescription,
                    availability: availability
                ),
                relativePath: relativePath(of: candidate, from: root),
                score: 0,
                identity: identityBefore
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SmartSearchServiceError {
            throw error
        } catch {
            return nil
        }
    }

    private func captureRootAuthorities(
        for roots: [URL]
    ) async throws -> [SpotlightRootAuthority] {
        var authorities: [SpotlightRootAuthority] = []
        authorities.reserveCapacity(roots.count)
        do {
            for root in roots {
                let pathAuthority = try await capturePathAuthority(
                    for: rootAuthorityURLs(through: root)
                )
                try await validatePathAuthority(pathAuthority)
                authorities.append(.init(root: root, pathAuthority: pathAuthority))
            }
            return authorities
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SmartSearchServiceError.invalidRoot
        }
    }

    private func validateRootAuthorities(
        _ authorities: [SpotlightRootAuthority]
    ) async throws {
        for authority in authorities {
            try await validateRootAuthority(authority)
        }
    }

    private func validateRootAuthority(
        _ authority: SpotlightRootAuthority
    ) async throws {
        do {
            try await validatePathAuthority(authority.pathAuthority)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SmartSearchServiceError.invalidRoot
        }
    }

    private func capturePathAuthority(
        for urls: [URL]
    ) async throws -> SpotlightPathAuthority {
        var entries: [SpotlightPathAuthority.Entry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            guard try !isSymbolicLink(url),
                  let identity = try await fileSystem.identity(of: url),
                  identity.entryIdentifier == identity.resolvedIdentifier else {
                throw SpotlightPathAuthorityError.invalid
            }
            entries.append(.init(url: url, identity: identity))
        }
        return .init(entries: entries)
    }

    private func validatePathAuthority(
        _ authority: SpotlightPathAuthority
    ) async throws {
        for entry in authority.entries {
            try Task.checkCancellation()
            guard try !isSymbolicLink(entry.url),
                  let identity = try await fileSystem.identity(of: entry.url),
                  identity.entryIdentifier == identity.resolvedIdentifier,
                  identity == entry.identity else {
                throw SpotlightPathAuthorityError.invalid
            }
        }
    }

    private func rootAuthorityURLs(through root: URL) -> [URL] {
        var url = URL(fileURLWithPath: "/", isDirectory: true)
        var urls = [url]
        for component in root.standardizedFileURL.pathComponents.dropFirst() {
            url = url.appending(path: component, directoryHint: .isDirectory)
            urls.append(url)
        }
        return urls
    }

    private func candidateAncestorURLs(of candidate: URL, below root: URL) -> [URL] {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard let relativePath = relativePathBelowRoot(
            candidatePath: candidatePath,
            rootPath: rootPath
        ) else {
            return []
        }
        let components = relativePath.split(separator: "/")
        guard components.count > 1 else { return [] }

        var url = root
        var urls: [URL] = []
        urls.reserveCapacity(components.count - 1)
        for component in components.dropLast() {
            url = url.appending(path: String(component), directoryHint: .isDirectory)
            urls.append(url)
        }
        return urls
    }

    private func respectsTraversalBoundaries(
        _ candidate: URL,
        below root: URL,
        query: SmartSearchQuery
    ) throws -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        guard let relativePath = relativePathBelowRoot(
            candidatePath: path,
            rootPath: rootPath
        ) else {
            return false
        }
        guard path != rootPath else { return true }

        var url = root
        for component in relativePath.split(separator: "/") {
            url.append(path: String(component))
            if try isSymbolicLink(url) {
                return false
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isPackageKey,
                .isHiddenKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                return false
            }
            if !query.includeHidden,
               values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                return false
            }
            if !query.includePackages, values.isPackage == true {
                return false
            }
        }
        return true
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

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func containingRoot(for candidate: URL, roots: [URL]) -> URL? {
        roots.first { candidate == $0 || contains(candidate, within: $0) }
    }

    private func contains(_ candidate: URL, within root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return rootPath == "/" ? candidatePath.hasPrefix("/") : candidatePath.hasPrefix(rootPath + "/")
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard let relativePath = relativePathBelowRoot(
            candidatePath: path,
            rootPath: rootPath
        ), !relativePath.isEmpty else {
            return url.lastPathComponent
        }
        return relativePath
    }

    private func relativePathBelowRoot(
        candidatePath: String,
        rootPath: String
    ) -> String? {
        if candidatePath == rootPath { return "" }
        if rootPath == "/" {
            guard candidatePath.hasPrefix("/") else { return nil }
            return String(candidatePath.dropFirst())
        }
        guard candidatePath.hasPrefix(rootPath + "/") else { return nil }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }
}

private struct SpotlightRootAuthority: Sendable {
    let root: URL
    let pathAuthority: SpotlightPathAuthority
}

private struct SpotlightPathAuthority: Sendable {
    struct Entry: Sendable {
        let url: URL
        let identity: FileIdentity
    }

    let entries: [Entry]
}

private enum SpotlightPathAuthorityError: Error {
    case invalid
}
