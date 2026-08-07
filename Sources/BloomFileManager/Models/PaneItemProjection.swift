import Foundation

struct ActiveOrderSnapshot: Equatable, Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let orderedItems: [FileItem]
    let asciiLiteralSafePositions: [Int]
    let localizedFallbackPositions: [Int]
}

struct AcceptedSearchSnapshot: Equatable, Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let normalizedQuery: String
    let matchedASCIIPositions: [Int]
    let matchedLocalizedPositions: [Int]
}

struct PaneProjectionKey: Equatable, Sendable {
    let itemsRevision: UInt64
    let normalizedQuery: String
    let sort: FileSort

    init(itemsRevision: UInt64, normalizedQuery: String, sort: FileSort) {
        self.itemsRevision = itemsRevision
        self.normalizedQuery = PaneFilenameFilter.normalize(normalizedQuery)
        self.sort = sort
    }
}

enum PaneProjectionPath: Equatable, Sendable {
    case fallbackFilterThenSort
    case activeOrderFullScan
    case activeOrderNarrowedASCII
    case emptyActiveOrder
    case sortedVisibleSubset
}

struct PaneProjectionDiagnostics: Equatable, Sendable {
    let path: PaneProjectionPath
    let visitedASCIIPositions: Int
    let visitedLocalizedPositions: Int
}

struct PaneItemProjection: Equatable, Sendable {
    let key: PaneProjectionKey
    let items: [FileItem]
    let indexByURL: [URL: Int]
    let urlByEntryPath: [String: URL]
    let activeOrder: ActiveOrderSnapshot?
    let search: AcceptedSearchSnapshot?
    let diagnostics: PaneProjectionDiagnostics

    init(
        key: PaneProjectionKey,
        items: [FileItem],
        indexByURL: [URL: Int],
        urlByEntryPath: [String: URL],
        activeOrder: ActiveOrderSnapshot? = nil,
        search: AcceptedSearchSnapshot? = nil,
        diagnostics: PaneProjectionDiagnostics = .init(
            path: .fallbackFilterThenSort,
            visitedASCIIPositions: 0,
            visitedLocalizedPositions: 0
        )
    ) {
        self.key = key
        self.items = items
        self.indexByURL = indexByURL
        self.urlByEntryPath = urlByEntryPath
        self.activeOrder = activeOrder
        self.search = search
        self.diagnostics = diagnostics
    }
}

struct PaneProjectionInput: Sendable {
    let items: [FileItem]
    let directoryKey: String
    let key: PaneProjectionKey
    let activeOrder: ActiveOrderSnapshot?
    let previousSearch: AcceptedSearchSnapshot?
}

struct ActiveOrderWarmUpRequest: Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let navigationGeneration: UInt64
    let projectionGeneration: UInt64
    let warmUpGeneration: UInt64
    let items: [FileItem]
}

enum PaneEntryPath {
    static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

struct PaneItemProjector: Sendable {
    func projectActiveOrder(_ input: PaneProjectionInput) async throws -> PaneItemProjection {
        try Task.checkCancellation()
        guard let activeOrder = input.activeOrder,
              activeOrder.directoryKey == input.directoryKey,
              activeOrder.itemsRevision == input.key.itemsRevision,
              activeOrder.sort == input.key.sort
        else {
            try Task.checkCancellation()
            return try await projectFallback(items: input.items, key: input.key)
        }

        guard !activeOrder.orderedItems.isEmpty else {
            let search = Self.searchSnapshot(
                directoryKey: input.directoryKey,
                key: input.key,
                asciiPositions: [],
                localizedPositions: []
            )
            return try await makeProjection(
                key: input.key,
                items: [],
                activeOrder: activeOrder,
                search: search,
                diagnostics: .init(path: .emptyActiveOrder, visitedASCIIPositions: 0, visitedLocalizedPositions: 0)
            )
        }

        let isNarrowed = canNarrow(
            previousSearch: input.previousSearch,
            activeOrder: activeOrder,
            directoryKey: input.directoryKey,
            key: input.key
        )
        let asciiCandidates = isNarrowed
            ? input.previousSearch!.matchedASCIIPositions
            : activeOrder.asciiLiteralSafePositions
        let localizedCandidates = activeOrder.localizedFallbackPositions
        let query = input.key.normalizedQuery

        try Task.checkCancellation()
        let asciiMatches = try await filterPositions(
            asciiCandidates,
            in: activeOrder.orderedItems,
            query: query
        )
        try Task.checkCancellation()
        let localizedMatches = try await filterPositions(
            localizedCandidates,
            in: activeOrder.orderedItems,
            query: query
        )
        try Task.checkCancellation()
        let positions = mergePositions(asciiMatches.positions, localizedMatches.positions)
        try Task.checkCancellation()
        let projectedItems = positions.map { activeOrder.orderedItems[$0] }
        let search = Self.searchSnapshot(
            directoryKey: input.directoryKey,
            key: input.key,
            asciiPositions: asciiMatches.positions,
            localizedPositions: localizedMatches.positions
        )
        return try await makeProjection(
            key: input.key,
            items: projectedItems,
            activeOrder: activeOrder,
            search: search,
            diagnostics: .init(
                path: isNarrowed ? .activeOrderNarrowedASCII : .activeOrderFullScan,
                visitedASCIIPositions: asciiMatches.visited,
                visitedLocalizedPositions: localizedMatches.visited
            )
        )
    }

    func projectFallback(items: [FileItem], key: PaneProjectionKey) async throws -> PaneItemProjection {
        try Task.checkCancellation()
        let filtered = try await filterItems(items, query: key.normalizedQuery)
        try Task.checkCancellation()
        try Task.checkCancellation()
        let sorted = key.sort.apply(to: filtered.items)
        try Task.checkCancellation()
        return try await makeProjection(
            key: key,
            items: sorted,
            activeOrder: nil,
            search: nil,
            diagnostics: .init(
                path: .fallbackFilterThenSort,
                visitedASCIIPositions: filtered.visitedASCII,
                visitedLocalizedPositions: filtered.visitedLocalized
            )
        )
    }

    func buildActiveOrder(
        items: [FileItem],
        directoryKey: String,
        key: PaneProjectionKey
    ) async throws -> ActiveOrderSnapshot? {
        try Task.checkCancellation()
        guard try await hasUniqueFinalTieBreakIdentitiesCancellable(in: items) else { return nil }
        try Task.checkCancellation()
        let orderedItems = key.sort.apply(to: items)
        try Task.checkCancellation()

        var asciiLiteralSafePositions: [Int] = []
        var localizedFallbackPositions: [Int] = []
        asciiLiteralSafePositions.reserveCapacity(orderedItems.count)
        localizedFallbackPositions.reserveCapacity(orderedItems.count)
        for (index, item) in orderedItems.enumerated() {
            if PaneFilenameFilter.isPrintableASCII(item.name) {
                asciiLiteralSafePositions.append(index)
            } else {
                localizedFallbackPositions.append(index)
            }
            if (index + 1).isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return .init(
            directoryKey: directoryKey,
            itemsRevision: key.itemsRevision,
            sort: key.sort,
            orderedItems: orderedItems,
            asciiLiteralSafePositions: asciiLiteralSafePositions,
            localizedFallbackPositions: localizedFallbackPositions
        )
    }

    func projectSortedSubset(items: [FileItem], key: PaneProjectionKey) async throws -> PaneItemProjection {
        try Task.checkCancellation()
        guard try await hasUniqueFinalTieBreakIdentitiesCancellable(in: items) else {
            return try await projectFallback(items: items, key: key)
        }
        try Task.checkCancellation()
        let sorted = key.sort.apply(to: items)
        try Task.checkCancellation()
        return try await makeProjection(
            key: key,
            items: sorted,
            activeOrder: nil,
            search: nil,
            diagnostics: .init(path: .sortedVisibleSubset, visitedASCIIPositions: 0, visitedLocalizedPositions: 0)
        )
    }

    static func hasUniqueFinalTieBreakIdentities(in items: [FileItem]) -> Bool {
        Set(items.map { $0.url.standardizedFileURL }).count == items.count
            && Set(items.map { PaneEntryPath.normalize($0.url) }).count == items.count
    }

    // Retained until Task 5 migrates FilePaneState and its controlled projector.
    func project(items: [FileItem], key: PaneProjectionKey) -> PaneItemProjection {
        let filtered = PaneFilenameFilter(query: key.normalizedQuery).apply(to: items)
        let projected = key.sort.apply(to: filtered)
        let indexes = makeIndexesSynchronously(for: projected)
        return .init(
            key: key,
            items: projected,
            indexByURL: indexes.indexByURL,
            urlByEntryPath: indexes.urlByEntryPath,
            activeOrder: nil,
            search: nil,
            diagnostics: .init(path: .fallbackFilterThenSort, visitedASCIIPositions: items.count, visitedLocalizedPositions: 0)
        )
    }

    private func canNarrow(
        previousSearch: AcceptedSearchSnapshot?,
        activeOrder: ActiveOrderSnapshot,
        directoryKey: String,
        key: PaneProjectionKey
    ) -> Bool {
        guard let previousSearch,
              previousSearch.directoryKey == directoryKey,
              previousSearch.itemsRevision == key.itemsRevision,
              previousSearch.sort == key.sort,
              PaneFilenameFilter.isEligibleASCIIExtension(
                from: previousSearch.normalizedQuery,
                to: key.normalizedQuery
              )
        else { return false }

        return positionsAreStrictlyAscending(
            previousSearch.matchedASCIIPositions,
            containedIn: activeOrder.asciiLiteralSafePositions
        ) && positionsAreStrictlyAscending(
            previousSearch.matchedLocalizedPositions,
            containedIn: activeOrder.localizedFallbackPositions
        )
    }

    private func filterPositions(
        _ positions: [Int],
        in orderedItems: [FileItem],
        query: String
    ) async throws -> (positions: [Int], visited: Int) {
        try Task.checkCancellation()
        var matches: [Int] = []
        matches.reserveCapacity(positions.count)
        var visited = 0
        for position in positions {
            if query.isEmpty || orderedItems[position].name.localizedStandardContains(query) {
                matches.append(position)
            }
            visited += 1
            if visited.isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return (matches, visited)
    }

    private func filterItems(
        _ items: [FileItem],
        query: String
    ) async throws -> (items: [FileItem], visitedASCII: Int, visitedLocalized: Int) {
        try Task.checkCancellation()
        var matches: [FileItem] = []
        matches.reserveCapacity(items.count)
        var visitedASCII = 0
        var visitedLocalized = 0
        for (index, item) in items.enumerated() {
            if query.isEmpty || item.name.localizedStandardContains(query) {
                matches.append(item)
            }
            if PaneFilenameFilter.isPrintableASCII(item.url.lastPathComponent) {
                visitedASCII += 1
            } else {
                visitedLocalized += 1
            }
            if (index + 1).isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return (matches, visitedASCII, visitedLocalized)
    }

    private func makeProjection(
        key: PaneProjectionKey,
        items: [FileItem],
        activeOrder: ActiveOrderSnapshot?,
        search: AcceptedSearchSnapshot?,
        diagnostics: PaneProjectionDiagnostics
    ) async throws -> PaneItemProjection {
        try Task.checkCancellation()
        let indexes = try await makeIndexes(for: items)
        try Task.checkCancellation()
        return .init(
            key: key,
            items: items,
            indexByURL: indexes.indexByURL,
            urlByEntryPath: indexes.urlByEntryPath,
            activeOrder: activeOrder,
            search: search,
            diagnostics: diagnostics
        )
    }

    private func makeIndexes(for items: [FileItem]) async throws -> (indexByURL: [URL: Int], urlByEntryPath: [String: URL]) {
        try Task.checkCancellation()
        var indexByURL: [URL: Int] = [:]
        var urlByEntryPath: [String: URL] = [:]
        indexByURL.reserveCapacity(items.count)
        urlByEntryPath.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let url = item.url.standardizedFileURL
            indexByURL[url] = index
            urlByEntryPath[PaneEntryPath.normalize(url)] = url
            if (index + 1).isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return (indexByURL, urlByEntryPath)
    }

    private func hasUniqueFinalTieBreakIdentitiesCancellable(in items: [FileItem]) async throws -> Bool {
        try Task.checkCancellation()
        var urls: Set<URL> = []
        var paths: Set<String> = []
        urls.reserveCapacity(items.count)
        paths.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard urls.insert(item.url.standardizedFileURL).inserted,
                  paths.insert(PaneEntryPath.normalize(item.url)).inserted
            else { return false }
            if (index + 1).isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return true
    }

    private static func searchSnapshot(
        directoryKey: String,
        key: PaneProjectionKey,
        asciiPositions: [Int],
        localizedPositions: [Int]
    ) -> AcceptedSearchSnapshot {
        .init(
            directoryKey: directoryKey,
            itemsRevision: key.itemsRevision,
            sort: key.sort,
            normalizedQuery: key.normalizedQuery,
            matchedASCIIPositions: asciiPositions,
            matchedLocalizedPositions: localizedPositions
        )
    }

    private func positionsAreStrictlyAscending(_ positions: [Int], containedIn allowed: [Int]) -> Bool {
        var allowedIndex = 0
        var prior: Int?
        for position in positions {
            guard prior.map({ $0 < position }) ?? true else { return false }
            while allowedIndex < allowed.count, allowed[allowedIndex] < position {
                allowedIndex += 1
            }
            guard allowedIndex < allowed.count, allowed[allowedIndex] == position else { return false }
            prior = position
        }
        return true
    }

    private func mergePositions(_ left: [Int], _ right: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(left.count + right.count)
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count || rightIndex < right.count {
            if rightIndex == right.count
                || (leftIndex < left.count && left[leftIndex] < right[rightIndex]) {
                result.append(left[leftIndex])
                leftIndex += 1
            } else {
                result.append(right[rightIndex])
                rightIndex += 1
            }
        }
        return result
    }

    private func makeIndexesSynchronously(for items: [FileItem]) -> (indexByURL: [URL: Int], urlByEntryPath: [String: URL]) {
        var indexByURL: [URL: Int] = [:]
        var urlByEntryPath: [String: URL] = [:]
        for (index, item) in items.enumerated() {
            let url = item.url.standardizedFileURL
            indexByURL[url] = index
            urlByEntryPath[PaneEntryPath.normalize(url)] = url
        }
        return (indexByURL, urlByEntryPath)
    }
}
