import Foundation

enum SmartSearchValidationError: Error, Equatable, Sendable {
    case emptyText
    case missingRoots
    case invalidRoot
}

struct SmartSearchQuery: Codable, Equatable, Sendable {
    static let defaultMaximumResults = 500
    static let maximumResultRange = 1...2_000

    let text: String
    let roots: [URL]
    var includeHidden: Bool
    var includePackages: Bool
    var includeDirectories: Bool
    var maximumResults: Int

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
            guard root.isFileURL, root.path.hasPrefix("/") else {
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
        let normalized = text
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var tokens: [String] = []
        normalized.enumerateSubstrings(
            in: normalized.startIndex..., options: [.byWords, .substringNotRequired, .localized]
        ) { _, range, _, _ in
            tokens.append(String(normalized[range]))
        }
        return tokens
    }

    static func ranked(_ candidates: [SmartSearchResult], for query: SmartSearchQuery) -> [SmartSearchResult] {
        let queryTokens = tokens(in: query.text)
        guard !queryTokens.isEmpty else { return candidates }

        let documentTokens = candidates.map { tokens(in: $0.relativePath) }
        let documentCount = Double(candidates.count)
        let averageLength = Double(max(1, documentTokens.map(\.count).reduce(0, +))) / max(1, documentCount)

        return zip(candidates, documentTokens).map { candidate, pathTokens in
            let filenameTokens = tokens(in: candidate.item.name)
            let score = queryTokens.reduce(0.0) { total, token in
                let documentFrequency = Double(documentTokens.count { $0.contains(token) })
                let idf = log((documentCount - documentFrequency + 0.5) / (documentFrequency + 0.5) + 1)
                let pathScore = bm25(token: token, tokens: pathTokens, averageLength: averageLength, idf: idf)
                let filenameScore = bm25(token: token, tokens: filenameTokens, averageLength: averageLength, idf: idf)
                return total + pathScore + (filenameScore * 3) + filenameBonus(token: token, filename: candidate.item.name)
            }
            return SmartSearchResult(item: candidate.item, relativePath: candidate.relativePath, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.item.url.standardizedFileURL.path.localizedStandardCompare(rhs.item.url.standardizedFileURL.path) == .orderedAscending
        }
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
