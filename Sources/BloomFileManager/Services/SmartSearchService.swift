import Foundation

protocol SmartSearching: Sendable {
    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult]
}

enum SmartSearchServiceError: Error, Equatable, Sendable {
    case invalidRoot
}

final class LocalSmartSearchService: SmartSearching, @unchecked Sendable {
    typealias TraversalHook = @Sendable (URL) throws -> Void

    private let fileManager: FileManager
    private let availabilityReader: any CloudItemAvailabilityReading
    private let scopedAccessCoordinator: CloudLocationScopedAccessCoordinator
    private let traversalHook: TraversalHook

    init(
        fileManager: FileManager = .default,
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        scopedAccessCoordinator: CloudLocationScopedAccessCoordinator = CloudLocationScopedAccessCoordinator(),
        traversalHook: @escaping TraversalHook = { _ in }
    ) {
        self.fileManager = fileManager
        self.availabilityReader = availabilityReader
        self.scopedAccessCoordinator = scopedAccessCoordinator
        self.traversalHook = traversalHook
    }

    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        let roots = try validatedRoots(from: query.roots)
        let leases = try scopedAccessCoordinator.acquireAccess(for: roots)
        defer { leases.forEach { $0.finish() } }

        var allCandidates: [SmartSearchResult] = []
        for root in roots {
            try Task.checkCancellation()
            allCandidates += try await candidates(in: root, query: query)
        }
        return Array(SmartSearchRanker.ranked(allCandidates, for: query).prefix(query.maximumResults))
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
        return validated
    }

    private func candidates(in root: URL, query: SmartSearchQuery) async throws -> [SmartSearchResult] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
            .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { throw SmartSearchServiceError.invalidRoot }

        var results: [SmartSearchResult] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            do {
                try traversalHook(url)
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
                guard query.includeDirectories || !directory,
                      matches(url: url, relativeTo: root, query: query) else { continue }

                let standardizedURL = url.standardizedFileURL
                let availability = await availabilityReader.availability(of: standardizedURL)
                try Task.checkCancellation()
                results.append(SmartSearchResult(
                    item: FileItem(
                        url: standardizedURL, name: url.lastPathComponent, isDirectory: directory,
                        isPackage: package, modifiedAt: values.contentModificationDate,
                        byteSize: values.fileSize.map(Int64.init),
                        typeDescription: values.localizedTypeDescription ?? "",
                        availability: availability
                    ),
                    relativePath: relativePath(of: url, from: root), score: 0
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return results
    }

    private func matches(url: URL, relativeTo root: URL, query: SmartSearchQuery) -> Bool {
        let haystack = fold(relativePath(of: url, from: root))
        return SmartSearchRanker.tokens(in: query.text).allSatisfy { haystack.contains($0) }
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
