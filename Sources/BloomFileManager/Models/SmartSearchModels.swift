import Foundation

enum SmartSearchValidationError: Error, Equatable, Sendable {
    case emptyText
    case missingRoots
    case invalidRoot
    case queryTooComplex
    case noSearchableTerms
}

struct SmartSearchQuery: Codable, Equatable, Sendable {
    static let defaultMaximumResults = 500
    static let maximumResultRange = 1...2_000
    static let maximumCandidateBudget = 50_000
    static let minimumCandidateBudget = 2_000
    static let candidateBudgetMultiplier = 20
    static let maximumTextScalarCount = 512
    static let maximumClauseCount = 16

    let text: String
    let roots: [URL]
    var includeHidden: Bool
    var includePackages: Bool
    var includeDirectories: Bool
    private(set) var maximumResults: Int
    private let preparedPlan: SmartSearchQueryPlan?

    /// Older saved searches remain decodable even when they exceed today's
    /// execution limits. They stay visible, but must be shortened before use.
    var isWithinComplexityLimits: Bool { preparedPlan != nil }

    /// The hard upper bound on matching metadata retained before ranking.
    /// This keeps every query bounded independently of the size of its roots.
    var candidateBudget: Int {
        min(
            Self.maximumCandidateBudget,
            max(Self.minimumCandidateBudget, maximumResults * Self.candidateBudgetMultiplier)
        )
    }

    init(
        text: String,
        roots: [URL],
        includeHidden: Bool = false,
        includePackages: Bool = false,
        includeDirectories: Bool = true,
        maximumResults: Int = SmartSearchQuery.defaultMaximumResults
    ) throws {
        try self.init(
            text: text,
            roots: roots,
            includeHidden: includeHidden,
            includePackages: includePackages,
            includeDirectories: includeDirectories,
            maximumResults: maximumResults,
            enforceComplexityLimits: true
        )
    }

    private init(
        text: String,
        roots: [URL],
        includeHidden: Bool,
        includePackages: Bool,
        includeDirectories: Bool,
        maximumResults: Int,
        enforceComplexityLimits: Bool
    ) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw SmartSearchValidationError.emptyText
        }
        guard !roots.isEmpty else {
            throw SmartSearchValidationError.missingRoots
        }

        var standardizedRoots: [URL] = []
        var paths = Set<String>()
        for root in roots {
            let host = root.host ?? ""
            guard root.isFileURL,
                  root.path.hasPrefix("/"),
                  host.isEmpty || host.caseInsensitiveCompare("localhost") == .orderedSame else {
                throw SmartSearchValidationError.invalidRoot
            }
            let standardizedRoot = root.standardizedFileURL
            if paths.insert(standardizedRoot.path).inserted {
                standardizedRoots.append(standardizedRoot)
            }
        }

        let preparedPlan: SmartSearchQueryPlan?
        if trimmedText.unicodeScalars.count > Self.maximumTextScalarCount {
            preparedPlan = nil
        } else {
            let candidatePlan = SmartSearchTextAnalyzer.queryPlan(for: trimmedText)
            preparedPlan = candidatePlan.clauses.count <= Self.maximumClauseCount
                ? candidatePlan
                : nil
        }
        if enforceComplexityLimits, preparedPlan == nil {
            throw SmartSearchValidationError.queryTooComplex
        }
        if enforceComplexityLimits, preparedPlan?.clauses.isEmpty == true {
            throw SmartSearchValidationError.noSearchableTerms
        }

        self.text = trimmedText
        self.roots = standardizedRoots
        self.includeHidden = includeHidden
        self.includePackages = includePackages
        self.includeDirectories = includeDirectories
        self.maximumResults = maximumResults.clamped(to: Self.maximumResultRange)
        self.preparedPlan = preparedPlan
    }

    func executablePlan() throws -> SmartSearchQueryPlan {
        guard let preparedPlan else {
            throw SmartSearchValidationError.queryTooComplex
        }
        guard !preparedPlan.clauses.isEmpty else {
            throw SmartSearchValidationError.noSearchableTerms
        }
        return preparedPlan
    }

    mutating func setMaximumResults(_ maximumResults: Int) {
        self.maximumResults = maximumResults.clamped(to: Self.maximumResultRange)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case roots
        case includeHidden
        case includePackages
        case includeDirectories
        case maximumResults
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: values.decode(String.self, forKey: .text),
            roots: values.decode([URL].self, forKey: .roots),
            includeHidden: values.decode(Bool.self, forKey: .includeHidden),
            includePackages: values.decode(Bool.self, forKey: .includePackages),
            includeDirectories: values.decode(Bool.self, forKey: .includeDirectories),
            maximumResults: values.decode(Int.self, forKey: .maximumResults),
            enforceComplexityLimits: false
        )
    }
}

struct SmartSearchResult: Identifiable, Equatable, Sendable {
    let item: FileItem
    let relativePath: String
    let score: Double

    var id: URL { item.url }

    init(item: FileItem, relativePath: String, score: Double) {
        self.item = item
        self.relativePath = relativePath
        self.score = max(0, score)
    }
}

struct SmartSearchRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var query: SmartSearchQuery
    let createdAt: Date

    init(id: UUID = UUID(), displayName: String, query: SmartSearchQuery, createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.query = query
        self.createdAt = createdAt
    }
}

enum SmartSearchRanker {
    static func tokens(in text: String) -> [String] {
        SmartSearchTextAnalyzer.literalTokens(in: text)
    }

    static func ranked(_ candidates: [SmartSearchResult], for query: SmartSearchQuery) -> [SmartSearchResult] {
        // The non-throwing entry point keeps pure model callers source-compatible.
        // Search services use the cancellable overload below.
        guard (try? query.executablePlan()) != nil else { return [] }
        return try! ranked(candidates, for: query, cancellationCheck: {})
    }

    static func ranked(
        _ candidates: [SmartSearchResult],
        for query: SmartSearchQuery,
        cancellationCheck: @Sendable () throws -> Void,
        sortingHook: @Sendable () throws -> Void = {}
    ) throws -> [SmartSearchResult] {
        let plan = try query.executablePlan()
        var prepared: [PreparedSmartSearchCandidate] = []
        prepared.reserveCapacity(candidates.count)
        for candidate in candidates {
            try cancellationCheck()
            if !plan.containsInitials {
                prepared.append(PreparedSmartSearchCandidate(
                    result: candidate,
                    match: .noInitials
                ))
            } else if let match = try SmartSearchTextAnalyzer.match(
                plan: plan,
                filename: candidate.item.name,
                relativePath: candidate.relativePath,
                analysisStep: cancellationCheck
            ) {
                prepared.append(PreparedSmartSearchCandidate(result: candidate, match: match))
            }
        }
        return try ranked(
            prepared,
            for: query,
            plan: plan,
            cancellationCheck: cancellationCheck,
            sortingHook: sortingHook
        )
    }

    static func ranked(
        _ candidates: [PreparedSmartSearchCandidate],
        for query: SmartSearchQuery,
        plan: SmartSearchQueryPlan,
        cancellationCheck: @Sendable () throws -> Void,
        sortingHook: @Sendable () throws -> Void = {}
    ) throws -> [SmartSearchResult] {
        guard query.isWithinComplexityLimits,
              plan.clauses.count <= SmartSearchQuery.maximumClauseCount else {
            throw SmartSearchValidationError.queryTooComplex
        }
        try cancellationCheck()
        let queryTokens = plan.clauses.compactMap { clause -> String? in
            guard case let .literal(token) = clause else { return nil }
            return token
        }
        guard !plan.clauses.isEmpty else { return [] }

        var documentTokens: [[String]] = []
        documentTokens.reserveCapacity(candidates.count)
        var totalDocumentTokenCount = 0
        for candidate in candidates {
            try cancellationCheck()
            let pathTokens = tokens(in: candidate.result.relativePath)
            documentTokens.append(pathTokens)
            totalDocumentTokenCount += pathTokens.count
        }
        let documentCount = Double(candidates.count)
        let averageLength = Double(max(1, totalDocumentTokenCount)) / max(1, documentCount)

        var documentFrequencies: [String: Double] = [:]
        for token in Set(queryTokens) {
            try cancellationCheck()
            var frequency = 0
            for tokens in documentTokens {
                try cancellationCheck()
                if tokens.contains(token) {
                    frequency += 1
                }
            }
            documentFrequencies[token] = Double(frequency)
        }

        let initialStatistics = try initialClauseStatistics(
            for: candidates,
            cancellationCheck: cancellationCheck
        )

        var scored: [RankedCandidate] = []
        scored.reserveCapacity(candidates.count)
        for (candidate, pathTokens) in zip(candidates, documentTokens) {
            try cancellationCheck()
            let filenameTokens = tokens(in: candidate.result.item.name)
            var literalScore = 0.0
            for token in queryTokens {
                try cancellationCheck()
                let documentFrequency = documentFrequencies[token] ?? 0
                let idf = log((documentCount - documentFrequency + 0.5) / (documentFrequency + 0.5) + 1)
                let pathScore = bm25(token: token, tokens: pathTokens, averageLength: averageLength, idf: idf)
                let filenameScore = bm25(token: token, tokens: filenameTokens, averageLength: averageLength, idf: idf)
                literalScore += pathScore
                    + (filenameScore * 3)
                    + filenameBonus(token: token, filename: candidate.result.item.name)
            }

            var initialScore = 0.0
            let initialEvidence = candidate.match.initialEvidence
            for (index, evidence) in initialEvidence.enumerated() {
                try cancellationCheck()
                guard index < initialStatistics.count else { continue }
                let statistics = initialStatistics[index].statistics(for: evidence.key.field)
                let documentFrequency = Double(statistics.documentFrequency)
                let idf = log(
                    (documentCount - documentFrequency + 0.5)
                        / (documentFrequency + 0.5)
                        + 1
                )
                let fieldMultiplier = evidence.key.field == .filename ? 3.0 : 1.0
                initialScore += bm25(
                    frequency: evidence.weightedTermFrequency * fieldMultiplier,
                    length: Double(evidence.documentLength),
                    averageLength: statistics.averageLength,
                    idf: idf
                )
            }

            let combinedScore = max(0, literalScore + initialScore)
            scored.append(RankedCandidate(
                result: SmartSearchResult(
                    item: candidate.result.item,
                    relativePath: candidate.result.relativePath,
                    score: combinedScore
                ),
                weakestFirstEvidence: initialEvidence.map(\.key).sorted(),
                combinedScore: combinedScore
            ))
        }

        let sorted = try cancellableSorted(
            scored,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            try sortingHook()
            try cancellationCheck()
            if plan.containsInitials {
                let evidenceComparison = compareEvidence(
                    lhs.weakestFirstEvidence,
                    rhs.weakestFirstEvidence
                )
                if evidenceComparison != 0 {
                    return evidenceComparison > 0
                }
            }
            if lhs.combinedScore != rhs.combinedScore {
                return lhs.combinedScore > rhs.combinedScore
            }
            let leftPath = lhs.result.item.url.standardizedFileURL.path
            let rightPath = rhs.result.item.url.standardizedFileURL.path
            let comparison = leftPath.localizedStandardCompare(rightPath)
            if comparison == .orderedSame {
                if leftPath != rightPath {
                    return leftPath < rightPath
                }
                return lhs.result.relativePath < rhs.result.relativePath
            }
            return comparison == .orderedAscending
        }
        try cancellationCheck()
        return sorted.map(\.result)
    }

    private struct RankedCandidate {
        let result: SmartSearchResult
        let weakestFirstEvidence: [SmartSearchInitialEvidenceKey]
        let combinedScore: Double
    }

    private struct InitialFieldStatistics {
        var documentFrequency = 0
        var documentCount = 0
        var totalLength = 0

        var averageLength: Double {
            guard documentCount > 0 else { return 1 }
            return Double(max(documentCount, totalLength)) / Double(documentCount)
        }

        mutating func recordDocument(length: Int) {
            documentCount += 1
            totalLength += max(1, length)
        }

        mutating func recordMatch() {
            documentFrequency += 1
        }
    }

    private struct InitialClauseStatistics {
        var filename = InitialFieldStatistics()
        var relativePath = InitialFieldStatistics()

        func statistics(for field: SmartSearchInitialField) -> InitialFieldStatistics {
            switch field {
            case .filename: filename
            case .relativePath: relativePath
            }
        }
    }

    private static func initialClauseStatistics(
        for candidates: [PreparedSmartSearchCandidate],
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [InitialClauseStatistics] {
        var clauseCount = 0
        for candidate in candidates {
            try cancellationCheck()
            clauseCount = max(clauseCount, candidate.match.initialClauseMatches.count)
        }
        var statistics = Array(repeating: InitialClauseStatistics(), count: clauseCount)
        for candidate in candidates {
            try cancellationCheck()
            for index in statistics.indices {
                try cancellationCheck()
                statistics[index].filename.recordDocument(
                    length: candidate.match.initialFieldLengths.filename
                )
                statistics[index].relativePath.recordDocument(
                    length: candidate.match.initialFieldLengths.relativePath
                )
            }
            for (index, clauseMatch) in candidate.match.initialClauseMatches.enumerated()
                where index < statistics.count {
                try cancellationCheck()
                if clauseMatch.contains(.filename) {
                    statistics[index].filename.recordMatch()
                }
                if clauseMatch.contains(.relativePath) {
                    statistics[index].relativePath.recordMatch()
                }
            }
        }
        return statistics
    }

    private static func compareEvidence(
        _ lhs: [SmartSearchInitialEvidenceKey],
        _ rhs: [SmartSearchInitialEvidenceKey]
    ) -> Int {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left > right ? 1 : -1
        }
        if lhs.count == rhs.count { return 0 }
        return lhs.count > rhs.count ? 1 : -1
    }

    private static func cancellableSorted<Element>(
        _ values: [Element],
        cancellationCheck: @Sendable () throws -> Void,
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) throws -> [Element] {
        guard values.count > 1 else { return values }
        var source = values
        var destination = values
        var width = 1

        while width < source.count {
            try cancellationCheck()
            for start in stride(from: 0, to: source.count, by: width * 2) {
                let middle = min(start + width, source.count)
                let end = min(start + width * 2, source.count)
                var left = start
                var right = middle

                for output in start..<end {
                    try cancellationCheck()
                    if left < middle,
                       right < end,
                       try !areInIncreasingOrder(source[right], source[left]) {
                        destination[output] = source[left]
                        left += 1
                    } else if right < end {
                        destination[output] = source[right]
                        right += 1
                    } else {
                        destination[output] = source[left]
                        left += 1
                    }
                }
            }
            swap(&source, &destination)
            width *= 2
        }
        return source
    }

    private static func bm25(token: String, tokens: [String], averageLength: Double, idf: Double) -> Double {
        let frequency = Double(tokens.count { $0 == token })
        return bm25(
            frequency: frequency,
            length: Double(tokens.count),
            averageLength: averageLength,
            idf: idf
        )
    }

    private static func bm25(
        frequency: Double,
        length: Double,
        averageLength: Double,
        idf: Double
    ) -> Double {
        guard frequency > 0 else { return 0 }
        let k1 = 1.2
        let b = 0.75
        return idf * (frequency * (k1 + 1))
            / (frequency + k1 * (1 - b + b * max(1, length) / averageLength))
    }

    private static func filenameBonus(token: String, filename: String) -> Double {
        let foldedFilename = filename
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if foldedFilename == token { return 8 }
        if foldedFilename.hasPrefix(token) { return 4 }
        if foldedFilename.contains(token) { return 2 }
        return 0
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
