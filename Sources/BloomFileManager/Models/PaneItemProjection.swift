import Foundation

struct ActiveOrderSnapshot: Equatable, Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let orderedItems: [FileItem]
    let standardizedURLs: [URL]
    let normalizedEntryPaths: [String]
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

/// Internal test seam for the active-order search traversal. The default
/// preserves the production policy; tests can make the serial and bounded
/// parallel paths directly comparable.
enum PaneActiveOrderPositionFilteringPolicy: Sendable {
    case automatic
    case forceSerial
    case forceParallel(laneCount: Int, reverseCompletedLaneResultsForTesting: Bool = false)
}

private struct PaneActiveOrderLaneResult: Sendable {
    let ordinal: Int
    let matchedASCIIPositions: [Int]
    let matchedLocalizedPositions: [Int]
    let visitedASCII: Int
    let visitedLocalized: Int
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
    let workerVisitProbe: PaneProjectionWorkerVisitProbe?

    init(
        items: [FileItem],
        directoryKey: String,
        key: PaneProjectionKey,
        activeOrder: ActiveOrderSnapshot?,
        previousSearch: AcceptedSearchSnapshot?,
        workerVisitProbe: PaneProjectionWorkerVisitProbe? = nil
    ) {
        self.items = items
        self.directoryKey = directoryKey
        self.key = key
        self.activeOrder = activeOrder
        self.previousSearch = previousSearch
        self.workerVisitProbe = workerVisitProbe
    }
}

/// Test-only lifecycle instrumentation. Production leaves this nil, so it has
/// no observable behavior or allocation on ordinary projection paths.
final class PaneProjectionWorkerVisitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let candidateVisitHook: (@Sendable () async -> Void)?
    private var cancellationRequested = false
    private var visitsAfterCancellation = 0

    init(candidateVisitHook: (@Sendable () async -> Void)? = nil) {
        self.candidateVisitHook = candidateVisitHook
    }

    func markCancellationRequested() {
        lock.withLock { cancellationRequested = true }
    }

    func recordCandidateVisit() async {
        lock.withLock {
            if cancellationRequested {
                visitsAfterCancellation += 1
            }
        }
        await candidateVisitHook?()
    }

    var cancelledWorkerCandidateVisits: Int {
        lock.withLock { visitsAfterCancellation }
    }

    var cancellationWasRequested: Bool {
        lock.withLock { cancellationRequested }
    }
}

final class PaneProjectionWorkerVisitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProbes: [ObjectIdentifier: PaneProjectionWorkerVisitProbe] = [:]
    private var completedMaximumVisits = 0
    private var completedCancelledWorkerCount = 0
    private var testProbeFactory: (@Sendable () -> PaneProjectionWorkerVisitProbe)?

    /// Test-only. Production keeps the factory nil and creates the no-op
    /// probe above, preserving ordinary projection behavior.
    func setTestProbeFactory(_ factory: (@Sendable () -> PaneProjectionWorkerVisitProbe)?) {
        lock.withLock { testProbeFactory = factory }
    }

    func beginWorker() -> PaneProjectionWorkerVisitProbe {
        let factory = lock.withLock { testProbeFactory }
        let probe = factory?() ?? PaneProjectionWorkerVisitProbe()
        lock.withLock {
            activeProbes[ObjectIdentifier(probe)] = probe
        }
        return probe
    }

    func finishWorker(_ probe: PaneProjectionWorkerVisitProbe?) {
        guard let probe else { return }
        lock.withLock {
            completedMaximumVisits = max(completedMaximumVisits, probe.cancelledWorkerCandidateVisits)
            if probe.cancellationWasRequested { completedCancelledWorkerCount += 1 }
            activeProbes.removeValue(forKey: ObjectIdentifier(probe))
        }
    }

    func reset() {
        lock.withLock {
            precondition(activeProbes.isEmpty, "Reset only after projection workers drain")
            completedMaximumVisits = 0
            completedCancelledWorkerCount = 0
        }
    }

    var maximumCancelledWorkerCandidateVisits: Int {
        lock.withLock {
            max(completedMaximumVisits, activeProbes.values.map(\.cancelledWorkerCandidateVisits).max() ?? 0)
        }
    }

    var activeWorkerCount: Int {
        lock.withLock { activeProbes.count }
    }

    var cancelledWorkerCount: Int {
        lock.withLock {
            completedCancelledWorkerCount
                + activeProbes.values.filter(\.cancellationWasRequested).count
        }
    }
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

func paneItemIdentity(for url: URL) -> (standardizedURL: URL, normalizedEntryPath: String) {
    autoreleasepool {
        let standardizedURL = url.standardizedFileURL
        var normalizedEntryPath = standardizedURL.path(percentEncoded: false)
        while normalizedEntryPath.count > 1, normalizedEntryPath.hasSuffix("/") {
            normalizedEntryPath.removeLast()
        }
        return (standardizedURL, normalizedEntryPath)
    }
}

enum PaneEntryPath {
    static func normalize(_ url: URL) -> String {
        paneItemIdentity(for: url).normalizedEntryPath
    }
}

struct PaneItemProjector: Sendable {
    private static let parallelFilteringThreshold = 4_096
    private static let maximumParallelFilteringLanes = 8

    private let activeOrderPositionFilteringPolicy: PaneActiveOrderPositionFilteringPolicy

    init(
        activeOrderPositionFilteringPolicy: PaneActiveOrderPositionFilteringPolicy = .automatic
    ) {
        self.activeOrderPositionFilteringPolicy = activeOrderPositionFilteringPolicy
    }

    func projectActiveOrder(_ input: PaneProjectionInput) async throws -> PaneItemProjection {
        try Task.checkCancellation()
        guard let activeOrder = input.activeOrder,
              activeOrder.directoryKey == input.directoryKey,
              activeOrder.itemsRevision == input.key.itemsRevision,
              activeOrder.sort == input.key.sort
        else {
            try Task.checkCancellation()
            return try await projectFallback(
                items: input.items,
                key: input.key,
                workerVisitProbe: input.workerVisitProbe
            )
        }

        if input.key.normalizedQuery.isEmpty {
            let search = Self.searchSnapshot(
                directoryKey: input.directoryKey,
                key: input.key,
                asciiPositions: activeOrder.asciiLiteralSafePositions,
                localizedPositions: activeOrder.localizedFallbackPositions
            )
            return try await makeActiveOrderProjection(
                key: input.key,
                activeOrder: activeOrder,
                search: search,
                diagnostics: .init(path: .emptyActiveOrder, visitedASCIIPositions: 0, visitedLocalizedPositions: 0),
                matchedPositions: nil
            )
        }

        guard !activeOrder.orderedItems.isEmpty else {
            let search = Self.searchSnapshot(
                directoryKey: input.directoryKey,
                key: input.key,
                asciiPositions: [],
                localizedPositions: []
            )
            return try await makeActiveOrderProjection(
                key: input.key,
                activeOrder: activeOrder,
                search: search,
                diagnostics: .init(path: .emptyActiveOrder, visitedASCIIPositions: 0, visitedLocalizedPositions: 0),
                matchedPositions: ([], [])
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
        let matches = try await filterActiveOrderPositions(
            asciiCandidates: asciiCandidates,
            localizedCandidates: localizedCandidates,
            in: activeOrder.orderedItems,
            query: query,
            workerVisitProbe: input.workerVisitProbe
        )
        try Task.checkCancellation()
        let search = Self.searchSnapshot(
            directoryKey: input.directoryKey,
            key: input.key,
            asciiPositions: matches.ascii.positions,
            localizedPositions: matches.localized.positions
        )
        return try await makeActiveOrderProjection(
            key: input.key,
            activeOrder: activeOrder,
            search: search,
            diagnostics: .init(
                path: isNarrowed ? .activeOrderNarrowedASCII : .activeOrderFullScan,
                visitedASCIIPositions: matches.ascii.visited,
                visitedLocalizedPositions: matches.localized.visited
            ),
            matchedPositions: (matches.ascii.positions, matches.localized.positions)
        )
    }

    func projectFallback(
        items: [FileItem],
        key: PaneProjectionKey,
        workerVisitProbe: PaneProjectionWorkerVisitProbe? = nil
    ) async throws -> PaneItemProjection {
        try Task.checkCancellation()
        let filtered = try await filterItems(
            items,
            query: key.normalizedQuery,
            workerVisitProbe: workerVisitProbe
        )
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
        var standardizedURLs: [URL] = []
        var normalizedEntryPaths: [String] = []
        asciiLiteralSafePositions.reserveCapacity(orderedItems.count)
        localizedFallbackPositions.reserveCapacity(orderedItems.count)
        standardizedURLs.reserveCapacity(orderedItems.count)
        normalizedEntryPaths.reserveCapacity(orderedItems.count)
        for (index, item) in orderedItems.enumerated() {
            let identity = paneItemIdentity(for: item.url)
            standardizedURLs.append(identity.standardizedURL)
            normalizedEntryPaths.append(identity.normalizedEntryPath)
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
            standardizedURLs: standardizedURLs,
            normalizedEntryPaths: normalizedEntryPaths,
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
        var urls: Set<URL> = []
        var paths: Set<String> = []
        urls.reserveCapacity(items.count)
        paths.reserveCapacity(items.count)
        for item in items {
            let identity = paneItemIdentity(for: item.url)
            guard urls.insert(identity.standardizedURL).inserted,
                  paths.insert(identity.normalizedEntryPath).inserted
            else { return false }
        }
        return true
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
        query: String,
        workerVisitProbe: PaneProjectionWorkerVisitProbe?
    ) async throws -> (positions: [Int], visited: Int) {
        if let workerVisitProbe {
            return try await filterPositionsWithInstrumentation(
                positions,
                in: orderedItems,
                query: query,
                workerVisitProbe: workerVisitProbe
            )
        }
        return try await filterPositionsWithoutInstrumentation(
            positions,
            in: orderedItems,
            query: query
        )
    }

    private func filterActiveOrderPositions(
        asciiCandidates: [Int],
        localizedCandidates: [Int],
        in orderedItems: [FileItem],
        query: String,
        workerVisitProbe: PaneProjectionWorkerVisitProbe?
    ) async throws -> (
        ascii: (positions: [Int], visited: Int),
        localized: (positions: [Int], visited: Int)
    ) {
        let candidateCount = asciiCandidates.count + localizedCandidates.count
        let laneCount = activeOrderFilteringLaneCount(for: candidateCount, normalizedQuery: query)
        guard laneCount > 1 else {
            let ascii = try await filterPositions(
                asciiCandidates,
                in: orderedItems,
                query: query,
                workerVisitProbe: workerVisitProbe
            )
            try Task.checkCancellation()
            let localized = try await filterPositions(
                localizedCandidates,
                in: orderedItems,
                query: query,
                workerVisitProbe: workerVisitProbe
            )
            return (ascii, localized)
        }

        return try await filterPositionsInParallel(
            asciiCandidates: asciiCandidates,
            localizedCandidates: localizedCandidates,
            orderedItems: orderedItems,
            query: query,
            laneCount: laneCount,
            workerVisitProbe: workerVisitProbe,
            reverseCompletedLaneResultsForTesting: shouldReverseCompletedLaneResultsForTesting
        )
    }

    func activeOrderFilteringLaneCount(for candidateCount: Int, normalizedQuery: String) -> Int {
        guard candidateCount > 0 else { return 1 }
        let maximumUsableLanes = min(
            Self.maximumParallelFilteringLanes,
            max(1, ProcessInfo.processInfo.activeProcessorCount),
            candidateCount
        )
        switch activeOrderPositionFilteringPolicy {
        case .automatic:
            return candidateCount >= Self.parallelFilteringThreshold
                && Self.isASCIIDecimalQuery(normalizedQuery)
                ? maximumUsableLanes
                : 1
        case .forceSerial:
            return 1
        case let .forceParallel(laneCount, _):
            return min(maximumUsableLanes, max(1, laneCount))
        }
    }

    private static func isASCIIDecimalQuery(_ query: String) -> Bool {
        !query.isEmpty && query.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
        }
    }

    private var shouldReverseCompletedLaneResultsForTesting: Bool {
        guard case let .forceParallel(_, reverseCompletedLaneResultsForTesting) = activeOrderPositionFilteringPolicy else {
            return false
        }
        return reverseCompletedLaneResultsForTesting
    }

    private func filterPositionsInParallel(
        asciiCandidates: [Int],
        localizedCandidates: [Int],
        orderedItems: [FileItem],
        query: String,
        laneCount: Int,
        workerVisitProbe: PaneProjectionWorkerVisitProbe?,
        reverseCompletedLaneResultsForTesting: Bool
    ) async throws -> (
        ascii: (positions: [Int], visited: Int),
        localized: (positions: [Int], visited: Int)
    ) {
        let candidateCount = asciiCandidates.count + localizedCandidates.count
        let cancellationStride = max(1, PaneFilenameFilter.cancellationCheckStride / laneCount)
        let laneResults = try await withThrowingTaskGroup(of: PaneActiveOrderLaneResult.self, returning: [PaneActiveOrderLaneResult].self) { group in
            // On an error, cancel siblings before structured scope drains them.
            // On success this is a no-op because every child has been consumed.
            defer { group.cancelAll() }
            let baseLaneSize = candidateCount / laneCount
            let extraCandidates = candidateCount % laneCount
            for ordinal in 0..<laneCount {
                let start = ordinal * baseLaneSize + min(ordinal, extraCandidates)
                let end = start + baseLaneSize + (ordinal < extraCandidates ? 1 : 0)
                group.addTask {
                    let result: PaneActiveOrderLaneResult
                    if let workerVisitProbe {
                        result = try await Self.filterParallelLaneWithInstrumentation(
                            ordinal: ordinal,
                            range: start..<end,
                            asciiCandidates: asciiCandidates,
                            localizedCandidates: localizedCandidates,
                            orderedItems: orderedItems,
                            query: query,
                            cancellationStride: cancellationStride,
                            workerVisitProbe: workerVisitProbe
                        )
                    } else {
                        result = try await Self.filterParallelLaneWithoutInstrumentation(
                            ordinal: ordinal,
                            range: start..<end,
                            asciiCandidates: asciiCandidates,
                            localizedCandidates: localizedCandidates,
                            orderedItems: orderedItems,
                            query: query,
                            cancellationStride: cancellationStride
                        )
                    }
                    return result
                }
            }

            var results: [PaneActiveOrderLaneResult] = []
            results.reserveCapacity(laneCount)
            for try await result in group {
                results.append(result)
            }
            return results
        }

        let resultsInCompletionOrder = reverseCompletedLaneResultsForTesting
            ? Array(laneResults.reversed())
            : laneResults
        let orderedResults = resultsInCompletionOrder.sorted { $0.ordinal < $1.ordinal }
        var asciiPositions: [Int] = []
        var localizedPositions: [Int] = []
        var visitedASCII = 0
        var visitedLocalized = 0
        for result in orderedResults {
            asciiPositions.append(contentsOf: result.matchedASCIIPositions)
            localizedPositions.append(contentsOf: result.matchedLocalizedPositions)
            visitedASCII += result.visitedASCII
            visitedLocalized += result.visitedLocalized
        }
        return ((asciiPositions, visitedASCII), (localizedPositions, visitedLocalized))
    }

    private static func filterParallelLaneWithoutInstrumentation(
        ordinal: Int,
        range: Range<Int>,
        asciiCandidates: [Int],
        localizedCandidates: [Int],
        orderedItems: [FileItem],
        query: String,
        cancellationStride: Int
    ) async throws -> PaneActiveOrderLaneResult {
        try Task.checkCancellation()
        var matchedASCIIPositions: [Int] = []
        var matchedLocalizedPositions: [Int] = []
        matchedASCIIPositions.reserveCapacity(range.count)
        matchedLocalizedPositions.reserveCapacity(range.count)
        var visitedASCII = 0
        var visitedLocalized = 0
        var visited = 0
        for logicalIndex in range {
            let isASCII = logicalIndex < asciiCandidates.count
            let position = isASCII
                ? asciiCandidates[logicalIndex]
                : localizedCandidates[logicalIndex - asciiCandidates.count]
            if query.isEmpty || orderedItems[position].name.localizedStandardContains(query) {
                if isASCII {
                    matchedASCIIPositions.append(position)
                } else {
                    matchedLocalizedPositions.append(position)
                }
            }
            if isASCII { visitedASCII += 1 } else { visitedLocalized += 1 }
            visited += 1
            if visited.isMultiple(of: cancellationStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return .init(
            ordinal: ordinal,
            matchedASCIIPositions: matchedASCIIPositions,
            matchedLocalizedPositions: matchedLocalizedPositions,
            visitedASCII: visitedASCII,
            visitedLocalized: visitedLocalized
        )
    }

    private static func filterParallelLaneWithInstrumentation(
        ordinal: Int,
        range: Range<Int>,
        asciiCandidates: [Int],
        localizedCandidates: [Int],
        orderedItems: [FileItem],
        query: String,
        cancellationStride: Int,
        workerVisitProbe: PaneProjectionWorkerVisitProbe
    ) async throws -> PaneActiveOrderLaneResult {
        try Task.checkCancellation()
        var matchedASCIIPositions: [Int] = []
        var matchedLocalizedPositions: [Int] = []
        matchedASCIIPositions.reserveCapacity(range.count)
        matchedLocalizedPositions.reserveCapacity(range.count)
        var visitedASCII = 0
        var visitedLocalized = 0
        var visited = 0
        for logicalIndex in range {
            await workerVisitProbe.recordCandidateVisit()
            let isASCII = logicalIndex < asciiCandidates.count
            let position = isASCII
                ? asciiCandidates[logicalIndex]
                : localizedCandidates[logicalIndex - asciiCandidates.count]
            if query.isEmpty || orderedItems[position].name.localizedStandardContains(query) {
                if isASCII {
                    matchedASCIIPositions.append(position)
                } else {
                    matchedLocalizedPositions.append(position)
                }
            }
            if isASCII { visitedASCII += 1 } else { visitedLocalized += 1 }
            visited += 1
            if visited.isMultiple(of: cancellationStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return .init(
            ordinal: ordinal,
            matchedASCIIPositions: matchedASCIIPositions,
            matchedLocalizedPositions: matchedLocalizedPositions,
            visitedASCII: visitedASCII,
            visitedLocalized: visitedLocalized
        )
    }

    private func filterPositionsWithoutInstrumentation(
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

    private func filterPositionsWithInstrumentation(
        _ positions: [Int],
        in orderedItems: [FileItem],
        query: String,
        workerVisitProbe: PaneProjectionWorkerVisitProbe
    ) async throws -> (positions: [Int], visited: Int) {
        try Task.checkCancellation()
        var matches: [Int] = []
        matches.reserveCapacity(positions.count)
        var visited = 0
        for position in positions {
            await workerVisitProbe.recordCandidateVisit()
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
        query: String,
        workerVisitProbe: PaneProjectionWorkerVisitProbe? = nil
    ) async throws -> (items: [FileItem], visitedASCII: Int, visitedLocalized: Int) {
        if let workerVisitProbe {
            return try await filterItemsWithInstrumentation(
                items,
                query: query,
                workerVisitProbe: workerVisitProbe
            )
        }
        return try await filterItemsWithoutInstrumentation(items, query: query)
    }

    private func filterItemsWithoutInstrumentation(
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

    private func filterItemsWithInstrumentation(
        _ items: [FileItem],
        query: String,
        workerVisitProbe: PaneProjectionWorkerVisitProbe
    ) async throws -> (items: [FileItem], visitedASCII: Int, visitedLocalized: Int) {
        try Task.checkCancellation()
        var matches: [FileItem] = []
        matches.reserveCapacity(items.count)
        var visitedASCII = 0
        var visitedLocalized = 0
        for (index, item) in items.enumerated() {
            await workerVisitProbe.recordCandidateVisit()
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

    private func makeActiveOrderProjection(
        key: PaneProjectionKey,
        activeOrder: ActiveOrderSnapshot,
        search: AcceptedSearchSnapshot?,
        diagnostics: PaneProjectionDiagnostics,
        matchedPositions: (ascii: [Int], localized: [Int])?
    ) async throws -> PaneItemProjection {
        try Task.checkCancellation()
        let items: [FileItem]
        let indexes: (indexByURL: [URL: Int], urlByEntryPath: [String: URL])
        if let matchedPositions {
            let visibleCount = matchedPositions.ascii.count + matchedPositions.localized.count
            var filteredItems: [FileItem] = []
            var indexByURL: [URL: Int] = [:]
            var urlByEntryPath: [String: URL] = [:]
            filteredItems.reserveCapacity(visibleCount)
            indexByURL.reserveCapacity(visibleCount)
            urlByEntryPath.reserveCapacity(visibleCount)
            var asciiIndex = 0
            var localizedIndex = 0
            var visibleIndex = 0
            while asciiIndex < matchedPositions.ascii.count || localizedIndex < matchedPositions.localized.count {
                let sourcePosition: Int
                if localizedIndex == matchedPositions.localized.count
                    || (asciiIndex < matchedPositions.ascii.count
                        && matchedPositions.ascii[asciiIndex] < matchedPositions.localized[localizedIndex]) {
                    sourcePosition = matchedPositions.ascii[asciiIndex]
                    asciiIndex += 1
                } else {
                    sourcePosition = matchedPositions.localized[localizedIndex]
                    localizedIndex += 1
                }
                filteredItems.append(activeOrder.orderedItems[sourcePosition])
                let url = activeOrder.standardizedURLs[sourcePosition]
                indexByURL[url] = visibleIndex
                urlByEntryPath[activeOrder.normalizedEntryPaths[sourcePosition]] = url
                if (visibleIndex + 1).isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                    try Task.checkCancellation()
                }
                visibleIndex += 1
            }
            items = filteredItems
            indexes = (indexByURL, urlByEntryPath)
        } else {
            items = activeOrder.orderedItems
            indexes = try await makeFullActiveOrderIndexes(activeOrder)
        }
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

    private func makeFullActiveOrderIndexes(
        _ activeOrder: ActiveOrderSnapshot
    ) async throws -> (indexByURL: [URL: Int], urlByEntryPath: [String: URL]) {
        try Task.checkCancellation()
        var indexByURL: [URL: Int] = [:]
        var urlByEntryPath: [String: URL] = [:]
        indexByURL.reserveCapacity(activeOrder.orderedItems.count)
        urlByEntryPath.reserveCapacity(activeOrder.orderedItems.count)
        for visibleIndex in activeOrder.orderedItems.indices {
            let url = activeOrder.standardizedURLs[visibleIndex]
            indexByURL[url] = visibleIndex
            urlByEntryPath[activeOrder.normalizedEntryPaths[visibleIndex]] = url
            if (visibleIndex + 1).isMultiple(of: PaneFilenameFilter.cancellationCheckStride) {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return (indexByURL, urlByEntryPath)
    }

    private func makeIndexes(for items: [FileItem]) async throws -> (indexByURL: [URL: Int], urlByEntryPath: [String: URL]) {
        try Task.checkCancellation()
        var indexByURL: [URL: Int] = [:]
        var urlByEntryPath: [String: URL] = [:]
        indexByURL.reserveCapacity(items.count)
        urlByEntryPath.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let identity = paneItemIdentity(for: item.url)
            indexByURL[identity.standardizedURL] = index
            urlByEntryPath[identity.normalizedEntryPath] = identity.standardizedURL
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
            let identity = paneItemIdentity(for: item.url)
            guard urls.insert(identity.standardizedURL).inserted,
                  paths.insert(identity.normalizedEntryPath).inserted
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

    private func makeIndexesSynchronously(for items: [FileItem]) -> (indexByURL: [URL: Int], urlByEntryPath: [String: URL]) {
        var indexByURL: [URL: Int] = [:]
        var urlByEntryPath: [String: URL] = [:]
        for (index, item) in items.enumerated() {
            let identity = paneItemIdentity(for: item.url)
            indexByURL[identity.standardizedURL] = index
            urlByEntryPath[identity.normalizedEntryPath] = identity.standardizedURL
        }
        return (indexByURL, urlByEntryPath)
    }
}
