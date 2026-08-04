import Foundation

enum SmartSearchValidationError: Error, Equatable, Sendable {
    case emptyText, missingRoots, invalidRoot, queryTooComplex, noSearchableTerms
}

struct SmartSearchQuery: Codable, Equatable, Sendable {
    static let defaultMaximumResults = 500
    static let maximumTextScalarCount = 512
    static let maximumClauseCount = 16
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
    private let preparedPlan: SmartSearchQueryPlan?

    var isWithinComplexityLimits: Bool { preparedPlan != nil }
    var candidateBudget: Int { min(Self.maximumCandidateBudget, max(Self.minimumCandidateBudget, maximumResults * Self.candidateBudgetMultiplier)) }

    init(text: String, roots: [URL], includeHidden: Bool = false, includePackages: Bool = false, includeDirectories: Bool = true, maximumResults: Int = Self.defaultMaximumResults) throws {
        try self.init(text: text, roots: roots, includeHidden: includeHidden, includePackages: includePackages, includeDirectories: includeDirectories, maximumResults: maximumResults, enforceComplexityLimits: true)
    }

    private init(text: String, roots: [URL], includeHidden: Bool, includePackages: Bool, includeDirectories: Bool, maximumResults: Int, enforceComplexityLimits: Bool) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SmartSearchValidationError.emptyText }
        guard !roots.isEmpty else { throw SmartSearchValidationError.missingRoots }
        var standardized: [URL] = []; var paths = Set<String>()
        for root in roots {
            let host = root.host ?? ""
            guard root.isFileURL, root.path.hasPrefix("/"), host.isEmpty || host.caseInsensitiveCompare("localhost") == .orderedSame else { throw SmartSearchValidationError.invalidRoot }
            let url = root.standardizedFileURL
            if paths.insert(url.path).inserted { standardized.append(url) }
        }
        let plan: SmartSearchQueryPlan?
        if trimmed.unicodeScalars.count > Self.maximumTextScalarCount { plan = nil }
        else {
            let candidate = SmartSearchTextAnalyzer.queryPlan(for: trimmed)
            plan = candidate.clauses.count <= Self.maximumClauseCount ? candidate : nil
        }
        if enforceComplexityLimits, plan == nil { throw SmartSearchValidationError.queryTooComplex }
        if enforceComplexityLimits, plan?.clauses.isEmpty == true { throw SmartSearchValidationError.noSearchableTerms }
        self.text = trimmed; self.roots = standardized; self.includeHidden = includeHidden; self.includePackages = includePackages; self.includeDirectories = includeDirectories
        self.maximumResults = maximumResults.clamped(to: Self.maximumResultRange); preparedPlan = plan
    }

    func executablePlan() throws -> SmartSearchQueryPlan {
        guard let preparedPlan else { throw SmartSearchValidationError.queryTooComplex }
        guard !preparedPlan.clauses.isEmpty else { throw SmartSearchValidationError.noSearchableTerms }
        return preparedPlan
    }
    mutating func setMaximumResults(_ value: Int) { maximumResults = value.clamped(to: Self.maximumResultRange) }

    private enum CodingKeys: String, CodingKey { case text, roots, includeHidden, includePackages, includeDirectories, maximumResults }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(text: values.decode(String.self, forKey: .text), roots: values.decode([URL].self, forKey: .roots), includeHidden: values.decode(Bool.self, forKey: .includeHidden), includePackages: values.decode(Bool.self, forKey: .includePackages), includeDirectories: values.decode(Bool.self, forKey: .includeDirectories), maximumResults: values.decode(Int.self, forKey: .maximumResults), enforceComplexityLimits: false)
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text); try values.encode(roots, forKey: .roots); try values.encode(includeHidden, forKey: .includeHidden); try values.encode(includePackages, forKey: .includePackages); try values.encode(includeDirectories, forKey: .includeDirectories); try values.encode(maximumResults, forKey: .maximumResults)
    }
}

struct SmartSearchResult: Identifiable, Equatable, Sendable {
    let item: FileItem
    let relativePath: String
    let score: Double
    let identity: FileIdentity
    var id: URL { item.url }

    init(item: FileItem, relativePath: String, score: Double, identity: FileIdentity) {
        self.item = item; self.relativePath = relativePath; self.score = max(0, score); self.identity = identity
    }
}

struct SmartSearchRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var query: SmartSearchQuery
    let createdAt: Date
    init(id: UUID = UUID(), displayName: String, query: SmartSearchQuery, createdAt: Date = .now) { self.id = id; self.displayName = displayName; self.query = query; self.createdAt = createdAt }
}

struct PreparedSmartSearchCandidate: Sendable {
    let result: SmartSearchResult
    let match: SmartSearchMatch
}

enum SmartSearchRanker {
    static func tokens(in text: String) -> [String] { SmartSearchTextAnalyzer.literalTokens(in: text) }

    static func ranked(_ candidates: [SmartSearchResult], for query: SmartSearchQuery) -> [SmartSearchResult] {
        guard (try? query.executablePlan()) != nil else { return [] }
        return (try? ranked(candidates, for: query, cancellationCheck: {})) ?? []
    }

    static func ranked(_ candidates: [SmartSearchResult], for query: SmartSearchQuery, cancellationCheck: @Sendable () throws -> Void, sortingHook: @Sendable () throws -> Void = {}) throws -> [SmartSearchResult] {
        let plan = try query.executablePlan()
        let boundedCandidates = candidates.prefix(query.candidateBudget)
        var prepared: [PreparedSmartSearchCandidate] = []; prepared.reserveCapacity(boundedCandidates.count)
        for candidate in boundedCandidates {
            try cancellationCheck()
            if !plan.containsInitials { prepared.append(.init(result: candidate, match: .noInitials)) }
            else if let match = try SmartSearchTextAnalyzer.match(plan: plan, filename: candidate.item.name, relativePath: candidate.relativePath, analysisStep: cancellationCheck) { prepared.append(.init(result: candidate, match: match)) }
        }
        return try ranked(prepared, for: query, plan: plan, cancellationCheck: cancellationCheck, sortingHook: sortingHook)
    }

    static func ranked(_ candidates: [PreparedSmartSearchCandidate], for query: SmartSearchQuery, plan: SmartSearchQueryPlan, cancellationCheck: @Sendable () throws -> Void, sortingHook: @Sendable () throws -> Void = {}) throws -> [SmartSearchResult] {
        guard query.isWithinComplexityLimits, plan.clauses.count <= SmartSearchQuery.maximumClauseCount else { throw SmartSearchValidationError.queryTooComplex }
        guard !plan.clauses.isEmpty else { return [] }
        let queryTokens = plan.clauses.compactMap { if case let .literal(token) = $0 { return token }; return nil }
        let boundedCandidates = candidates.prefix(query.candidateBudget)
        var documents: [[String]] = []
        documents.reserveCapacity(boundedCandidates.count)
        var tokenCount = 0
        for candidate in boundedCandidates {
            try cancellationCheck()
            let tokens = try SmartSearchTextAnalyzer.literalTokens(
                in: candidate.result.relativePath,
                analysisStep: cancellationCheck
            )
            documents.append(tokens)
            tokenCount += tokens.count
        }
        let averageLength = Double(max(1, tokenCount)) / Double(max(1, documents.count))
        var frequencies: [String: Double] = [:]
        for token in Set(queryTokens) {
            var frequency = 0
            for document in documents {
                if try contains(token, in: document, cancellationCheck: cancellationCheck) {
                    frequency += 1
                }
            }
            frequencies[token] = Double(frequency)
        }
        let count = Double(boundedCandidates.count)
        var values: [(SmartSearchResult, [SmartSearchInitialEvidenceKey], Double)] = []
        values.reserveCapacity(boundedCandidates.count)
        for (candidate, pathTokens) in zip(boundedCandidates, documents) {
            try cancellationCheck()
            let filenameTokens = try SmartSearchTextAnalyzer.literalTokens(
                in: candidate.result.item.name,
                analysisStep: cancellationCheck
            )
            var score = 0.0
            for token in queryTokens {
                try cancellationCheck()
                let frequency = frequencies[token] ?? 0
                let idf = log((count - frequency + 0.5) / (frequency + 0.5) + 1)
                score += try bm25(token, in: pathTokens, average: averageLength, idf: idf, cancellationCheck: cancellationCheck)
                score += 3 * (try bm25(token, in: filenameTokens, average: averageLength, idf: idf, cancellationCheck: cancellationCheck))
                score += try filenameBonus(token, filename: candidate.result.item.name, cancellationCheck: cancellationCheck)
            }
            let evidence = candidate.match.initialEvidence
            for value in evidence { score += initialWeight(value) }
            values.append((.init(item: candidate.result.item, relativePath: candidate.result.relativePath, score: score, identity: candidate.result.identity), evidence.map(\.key).sorted(), score))
        }
        let sorted = try mergeSorted(values, cancellationCheck: cancellationCheck) { left, right in
            try sortingHook(); try cancellationCheck()
            if plan.containsInitials {
                let evidence = compareEvidence(left.1, right.1)
                if evidence != 0 { return evidence > 0 }
            }
            if left.2 != right.2 { return left.2 > right.2 }
            let lpath = left.0.item.url.standardizedFileURL.path, rpath = right.0.item.url.standardizedFileURL.path
            let comparison = lpath.localizedStandardCompare(rpath)
            if comparison == .orderedSame { return lpath == rpath ? left.0.relativePath < right.0.relativePath : lpath < rpath }
            return comparison == .orderedAscending
        }.map(\.0)
        return Array(sorted.prefix(query.maximumResults))
    }

    private static func initialWeight(_ evidence: SmartSearchInitialEvidence) -> Double {
        let field = evidence.key.field == .filename ? 3.0 : 1.0
        return Double(evidence.key.representation.rawValue * 10 + evidence.key.relation.rawValue) * field + evidence.weightedTermFrequency / Double(max(1, evidence.documentLength))
    }
    private static func contains(_ token: String, in tokens: [String], cancellationCheck: @Sendable () throws -> Void) throws -> Bool {
        for candidate in tokens {
            try cancellationCheck()
            if candidate == token { return true }
        }
        return false
    }
    private static func bm25(_ token: String, in tokens: [String], average: Double, idf: Double, cancellationCheck: @Sendable () throws -> Void) throws -> Double {
        var frequency = 0
        for candidate in tokens {
            try cancellationCheck()
            if candidate == token { frequency += 1 }
        }
        guard frequency > 0 else { return 0 }
        let frequencyValue = Double(frequency)
        return idf * (frequencyValue * 2.2) / (frequencyValue + 1.2 * (0.25 + 0.75 * Double(max(1, tokens.count)) / average))
    }
    private static func filenameBonus(_ token: String, filename: String, cancellationCheck: @Sendable () throws -> Void) throws -> Double {
        for _ in filename.unicodeScalars { try cancellationCheck() }
        let folded = filename.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        try cancellationCheck()
        if folded == token { return 8 }; if folded.hasPrefix(token) { return 4 }; if folded.contains(token) { return 2 }; return 0
    }
    private static func compareEvidence(_ lhs: [SmartSearchInitialEvidenceKey], _ rhs: [SmartSearchInitialEvidenceKey]) -> Int {
        for (left, right) in zip(lhs, rhs) where left != right { return left > right ? 1 : -1 }
        if lhs.count == rhs.count { return 0 }; return lhs.count > rhs.count ? 1 : -1
    }
    private static func mergeSorted<Element>(_ values: [Element], cancellationCheck: @Sendable () throws -> Void, by ordered: (Element, Element) throws -> Bool) throws -> [Element] {
        guard values.count > 1 else { return values }
        var source = values, destination = values, width = 1
        while width < source.count {
            try cancellationCheck()
            for start in stride(from: 0, to: source.count, by: width * 2) {
                var left = start, right = min(start + width, source.count); let middle = right, end = min(start + width * 2, source.count)
                for output in start..<end {
                    try cancellationCheck()
                    if left < middle, right < end, try !ordered(source[right], source[left]) { destination[output] = source[left]; left += 1 }
                    else if right < end { destination[output] = source[right]; right += 1 }
                    else { destination[output] = source[left]; left += 1 }
                }
            }
            swap(&source, &destination); width *= 2
        }
        return source
    }
}

private extension Comparable { func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) } }
