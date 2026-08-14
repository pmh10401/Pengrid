import Foundation

struct ContentAwareSmartSearchService: SmartSearching {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let local: any SmartSearching
    private let spotlight: any SpotlightContentSearching
    private let timeout: Duration
    private let sleep: Sleep

    init(
        local: any SmartSearching,
        spotlight: any SpotlightContentSearching,
        timeout: Duration = .seconds(5),
        sleep: @escaping Sleep = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.local = local
        self.spotlight = spotlight
        self.timeout = timeout
        self.sleep = sleep
    }

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        try await search(
            query,
            progress: progress,
            coverage: { _ in }
        )
    }

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void,
        coverage: @escaping @Sendable (SmartSearchCoverage) -> Void
    ) async throws -> [SmartSearchResult] {
        try Task.checkCancellation()
        let plan = try query.executablePlan()
        guard query.searchIndexedContents else {
            coverage(.namesAndPathsOnly)
            return try await local.search(query, progress: progress)
        }
        guard !plan.containsInitials else {
            coverage(.indexedContentsSkippedForInitialQuery)
            return try await local.search(query, progress: progress)
        }

        return try await searchBothBackends(
            query,
            progress: progress,
            coverage: coverage
        )
    }

    private func searchBothBackends(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void,
        coverage: @escaping @Sendable (SmartSearchCoverage) -> Void
    ) async throws -> [SmartSearchResult] {
        try await withThrowingTaskGroup(
            of: BackendEvent.self,
            returning: [SmartSearchResult].self
        ) { group in
            group.addTask {
                .local(try await local.search(query, progress: progress))
            }
            group.addTask {
                do {
                    return .spotlight(try await spotlightOutcome(for: query))
                } catch is CancellationError {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    return .spotlight(.unavailable)
                } catch {
                    return .spotlight(.unavailable)
                }
            }

            var localResults: [SmartSearchResult]?
            var spotlightResult: SpotlightOutcome?
            while let event = try await group.next() {
                switch event {
                case let .local(results):
                    localResults = results
                case let .spotlight(outcome):
                    spotlightResult = outcome
                }
                guard let localResults, let spotlightResult else {
                    continue
                }

                switch spotlightResult {
                case let .results(indexedResults):
                    let ranked = try mergedAndRanked(
                        localResults: localResults,
                        indexedResults: indexedResults,
                        query: query
                    )
                    coverage(.indexedContentsIncluded)
                    return ranked
                case .unavailable:
                    coverage(.indexedContentsUnavailable)
                    return localResults
                }
            }
            throw CancellationError()
        }
    }

    private func spotlightOutcome(for query: SmartSearchQuery) async throws -> SpotlightOutcome {
        try await withThrowingTaskGroup(
            of: SpotlightRaceEvent.self,
            returning: SpotlightOutcome.self
        ) { group in
            group.addTask {
                .results(try await spotlight.searchIndexedContents(query))
            }
            group.addTask {
                try await sleep(timeout)
                try Task.checkCancellation()
                return .timedOut
            }
            guard let first = try await group.next() else {
                throw SpotlightMetadataQueryError.unavailable
            }
            group.cancelAll()

            switch first {
            case let .results(results):
                return .results(results)
            case .timedOut:
                return .unavailable
            }
        }
    }

    private func mergedAndRanked(
        localResults: [SmartSearchResult],
        indexedResults: [SmartSearchResult],
        query: SmartSearchQuery
    ) throws -> [SmartSearchResult] {
        var localResultsByPath: [String: SmartSearchResult] = [:]
        localResultsByPath.reserveCapacity(localResults.count)
        for result in localResults {
            try Task.checkCancellation()
            let path = result.item.url.standardizedFileURL.path
            localResultsByPath[path] = localResultsByPath[path] ?? result
        }

        var merged: [SmartSearchResult] = []
        merged.reserveCapacity(
            min(query.candidateBudget, localResults.count + indexedResults.count)
        )
        var seenPaths = Set<String>()
        var localIndex = 0
        var indexedIndex = 0

        while merged.count < query.candidateBudget,
              localIndex < localResults.count || indexedIndex < indexedResults.count {
            try Task.checkCancellation()

            if localIndex < localResults.count {
                let result = localResults[localIndex]
                localIndex += 1
                let path = result.item.url.standardizedFileURL.path
                if seenPaths.insert(path).inserted {
                    merged.append(result)
                }
            }

            guard merged.count < query.candidateBudget else { break }
            if indexedIndex < indexedResults.count {
                let indexedResult = indexedResults[indexedIndex]
                indexedIndex += 1
                let path = indexedResult.item.url.standardizedFileURL.path
                if seenPaths.insert(path).inserted {
                    merged.append(localResultsByPath[path] ?? indexedResult)
                }
            }
        }
        return try SmartSearchRanker.ranked(
            merged,
            for: query,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }
}

private enum BackendEvent: Sendable {
    case local([SmartSearchResult])
    case spotlight(SpotlightOutcome)
}

private enum SpotlightOutcome: Sendable {
    case results([SmartSearchResult])
    case unavailable
}

private enum SpotlightRaceEvent: Sendable {
    case results([SmartSearchResult])
    case timedOut
}
