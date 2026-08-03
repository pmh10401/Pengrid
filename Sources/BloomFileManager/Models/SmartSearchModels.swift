import Foundation

enum SmartSearchValidationError: Error, Equatable, Sendable {
    case emptyText
    case missingRoots
    case invalidRoot
}

struct SmartSearchQuery: Codable, Equatable, Sendable {
    static let defaultMaximumResults = 500
    static let maximumResultRange = 1...2_000
    static let maximumCandidateBudget = 50_000
    static let minimumCandidateBudget = 2_000
    static let candidateBudgetMultiplier = 20

    let text: String
    let roots: [URL]
    var includeHidden: Bool
    var includePackages: Bool
    var includeDirectories: Bool
    private(set) var maximumResults: Int

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

        self.text = trimmedText
        self.roots = standardizedRoots
        self.includeHidden = includeHidden
        self.includePackages = includePackages
        self.includeDirectories = includeDirectories
        self.maximumResults = maximumResults.clamped(to: Self.maximumResultRange)
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
            maximumResults: values.decode(Int.self, forKey: .maximumResults)
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
        try! ranked(candidates, for: query, cancellationCheck: {})
    }

    static func ranked(
        _ candidates: [SmartSearchResult],
        for query: SmartSearchQuery,
        cancellationCheck: @Sendable () throws -> Void,
        sortingHook: @Sendable () throws -> Void = {}
    ) throws -> [SmartSearchResult] {
        try cancellationCheck()
        let queryTokens = tokens(in: query.text)
        guard !queryTokens.isEmpty else { return candidates }

        var documentTokens: [[String]] = []
        documentTokens.reserveCapacity(candidates.count)
        for candidate in candidates {
            try cancellationCheck()
            documentTokens.append(tokens(in: candidate.relativePath))
        }
        let documentCount = Double(candidates.count)
        let averageLength = Double(max(1, documentTokens.map(\.count).reduce(0, +))) / max(1, documentCount)

        var documentFrequencies: [String: Double] = [:]
        for token in Set(queryTokens) {
            try cancellationCheck()
            documentFrequencies[token] = Double(documentTokens.count { $0.contains(token) })
        }

        var scored: [SmartSearchResult] = []
        scored.reserveCapacity(candidates.count)
        for (candidate, pathTokens) in zip(candidates, documentTokens) {
            try cancellationCheck()
            let filenameTokens = tokens(in: candidate.item.name)
            var score = 0.0
            for token in queryTokens {
                try cancellationCheck()
                let documentFrequency = documentFrequencies[token] ?? 0
                let idf = log((documentCount - documentFrequency + 0.5) / (documentFrequency + 0.5) + 1)
                let pathScore = bm25(token: token, tokens: pathTokens, averageLength: averageLength, idf: idf)
                let filenameScore = bm25(token: token, tokens: filenameTokens, averageLength: averageLength, idf: idf)
                score += pathScore + (filenameScore * 3) + filenameBonus(token: token, filename: candidate.item.name)
            }
            scored.append(SmartSearchResult(
                item: candidate.item,
                relativePath: candidate.relativePath,
                score: score
            ))
        }

        let sorted = try cancellableSorted(
            scored,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            try sortingHook()
            try cancellationCheck()
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let leftPath = lhs.item.url.standardizedFileURL.path
            let rightPath = rhs.item.url.standardizedFileURL.path
            let comparison = leftPath.localizedStandardCompare(rightPath)
            if comparison == .orderedSame {
                if leftPath != rightPath {
                    return leftPath < rightPath
                }
                return lhs.relativePath < rhs.relativePath
            }
            return comparison == .orderedAscending
        }
        try cancellationCheck()
        return sorted
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
        guard frequency > 0 else { return 0 }
        let length = Double(tokens.count)
        let k1 = 1.2
        let b = 0.75
        return idf * (frequency * (k1 + 1)) / (frequency + k1 * (1 - b + b * length / averageLength))
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
