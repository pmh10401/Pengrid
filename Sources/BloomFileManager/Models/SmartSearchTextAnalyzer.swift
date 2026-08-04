import Foundation

enum SmartSearchInitial: UInt8, CaseIterable, Sendable, Equatable {
    case kiyeok, ssangKiyeok, nieun, tikeut, ssangTikeut, rieul, mieum, pieup, ssangPieup
    case siot, ssangSiot, ieung, cieuc, ssangCieuc, chieuch, khieukh, thieuth, phieuph, hieuh
}

struct SmartSearchInitialPattern: Sendable, Equatable, ExpressibleByArrayLiteral {
    let initials: [SmartSearchInitial]
    let failureTable: [Int]

    init(_ initials: [SmartSearchInitial]) { try! self.init(initials, analysisStep: {}) }
    init(arrayLiteral elements: SmartSearchInitial...) { self.init(elements) }

    init(_ initials: [SmartSearchInitial], analysisStep: SmartSearchTextAnalyzer.AnalysisStep) throws {
        self.initials = initials
        var table = Array(repeating: 0, count: initials.count)
        var prefix = 0
        if initials.count > 1 {
            for index in 1..<initials.count {
                try analysisStep()
                while prefix > 0, initials[index] != initials[prefix] {
                    try analysisStep()
                    prefix = table[prefix - 1]
                }
                if initials[index] == initials[prefix] {
                    prefix += 1
                    table[index] = prefix
                }
            }
        }
        self.failureTable = table
    }
}

enum SmartSearchClause: Sendable, Equatable {
    case literal(String)
    case hangulInitials(SmartSearchInitialPattern)
}

struct SmartSearchQueryPlan: Sendable, Equatable {
    let clauses: [SmartSearchClause]
    var containsInitials: Bool { clauses.contains { if case .hangulInitials = $0 { return true }; return false } }
}

enum SmartSearchInitialField: Int, Sendable, Equatable { case relativePath = 1, filename = 2 }
enum SmartSearchInitialRepresentation: Int, Sendable, Equatable { case runHeads = 1, syllableRun = 2, literal = 3 }
enum SmartSearchInitialRelation: Int, Sendable, Equatable { case contains = 1, prefix = 2, exact = 3 }

struct SmartSearchInitialEvidenceKey: Sendable, Equatable, Comparable {
    let field: SmartSearchInitialField
    let representation: SmartSearchInitialRepresentation
    let relation: SmartSearchInitialRelation

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.field != rhs.field { return lhs.field.rawValue < rhs.field.rawValue }
        if lhs.representation != rhs.representation { return lhs.representation.rawValue < rhs.representation.rawValue }
        return lhs.relation.rawValue < rhs.relation.rawValue
    }
}

struct SmartSearchInitialEvidence: Sendable, Equatable {
    let key: SmartSearchInitialEvidenceKey
    let weightedTermFrequency: Double
    let documentLength: Int
}

struct SmartSearchInitialClauseMatch: Sendable, Equatable {
    let bestEvidence: SmartSearchInitialEvidence
    let filenameMatched: Bool
    let relativePathMatched: Bool

    init?(filenameEvidence: SmartSearchInitialEvidence?, relativePathEvidence: SmartSearchInitialEvidence?) {
        guard let best = [filenameEvidence, relativePathEvidence].compactMap({ $0 }).max(by: { $0.key < $1.key }) else { return nil }
        bestEvidence = best
        filenameMatched = filenameEvidence != nil
        relativePathMatched = relativePathEvidence != nil
    }

    func contains(_ field: SmartSearchInitialField) -> Bool {
        field == .filename ? filenameMatched : relativePathMatched
    }
}

struct SmartSearchInitialFieldLengths: Sendable, Equatable { let filename: Int; let relativePath: Int }

struct SmartSearchMatch: Sendable, Equatable {
    let initialClauseMatches: [SmartSearchInitialClauseMatch]
    let initialFieldLengths: SmartSearchInitialFieldLengths
    var initialEvidence: [SmartSearchInitialEvidence] { initialClauseMatches.map(\.bestEvidence) }
    static let noInitials = SmartSearchMatch(initialClauseMatches: [], initialFieldLengths: .init(filename: 1, relativePath: 1))
}

enum SmartSearchTextAnalyzer {
    typealias AnalysisStep = @Sendable () throws -> Void

    static func queryPlan(for text: String) -> SmartSearchQueryPlan { try! queryPlan(for: text, analysisStep: {}) }

    static func queryPlan(for text: String, analysisStep: AnalysisStep) throws -> SmartSearchQueryPlan {
        for _ in text.unicodeScalars { try analysisStep() }
        let normalized = folded(text)
        var words: [String] = []
        normalized.enumerateSubstrings(in: normalized.startIndex..., options: [.byWords, .substringNotRequired, .localized]) { _, range, _, _ in
            words.append(String(normalized[range]))
        }
        try analysisStep()
        var clauses: [SmartSearchClause] = []
        for word in words { try appendClauses(word, to: &clauses, analysisStep: analysisStep) }
        return SmartSearchQueryPlan(clauses: clauses)
    }

    static func literalTokens(in text: String) -> [String] {
        let normalized = folded(text)
        var tokens: [String] = []
        normalized.enumerateSubstrings(in: normalized.startIndex..., options: [.byWords, .substringNotRequired, .localized]) { _, range, _, _ in
            tokens.append(String(normalized[range]))
        }
        return tokens
    }

    static func match(plan: SmartSearchQueryPlan, filename: String, relativePath: String) -> SmartSearchMatch? {
        try! match(plan: plan, filename: filename, relativePath: relativePath, analysisStep: {})
    }

    static func match(plan: SmartSearchQueryPlan, filename: String, relativePath: String, analysisStep: AnalysisStep) throws -> SmartSearchMatch? {
        guard !plan.clauses.isEmpty else { return nil }
        let path = folded(relativePath)
        let needsInitials = plan.containsInitials
        let filenameFeatures = needsInitials ? try features(filename, analysisStep: analysisStep) : nil
        let pathFeatures = needsInitials ? try features(relativePath, analysisStep: analysisStep) : nil
        var matches: [SmartSearchInitialClauseMatch] = []
        for clause in plan.clauses {
            try analysisStep()
            switch clause {
            case let .literal(token): guard path.contains(token) else { return nil }
            case let .hangulInitials(pattern):
                guard let filenameFeatures, let pathFeatures,
                      let match = SmartSearchInitialClauseMatch(
                        filenameEvidence: try evidence(pattern, features: filenameFeatures, field: .filename, analysisStep: analysisStep),
                        relativePathEvidence: try evidence(pattern, features: pathFeatures, field: .relativePath, analysisStep: analysisStep)
                      ) else { return nil }
                matches.append(match)
            }
        }
        return SmartSearchMatch(initialClauseMatches: matches, initialFieldLengths: .init(filename: filenameFeatures?.length ?? 1, relativePath: pathFeatures?.length ?? 1))
    }

    private static func appendClauses(_ word: String, to clauses: inout [SmartSearchClause], analysisStep: AnalysisStep) throws {
        var literals = ""
        var initials: [SmartSearchInitial] = []
        func flushLiterals() throws {
            guard !literals.isEmpty else { return }
            try analysisStep()
            clauses.append(contentsOf: literalTokens(in: literals).map(SmartSearchClause.literal))
            literals = ""
        }
        func flushInitials() throws {
            guard !initials.isEmpty else { return }
            clauses.append(.hangulInitials(try SmartSearchInitialPattern(initials, analysisStep: analysisStep)))
            initials.removeAll(keepingCapacity: true)
        }
        for scalar in word.unicodeScalars {
            try analysisStep()
            if let initial = initial(for: scalar) {
                try flushLiterals(); initials.append(initial)
            } else {
                try flushInitials(); literals.unicodeScalars.append(scalar)
            }
        }
        try flushLiterals(); try flushInitials()
    }

    private struct Features { let explicit, syllables, heads: [[SmartSearchInitial]]; let length: Int }

    private static func features(_ text: String, analysisStep: AnalysisStep) throws -> Features {
        var explicit: [[SmartSearchInitial]] = [], syllables: [[SmartSearchInitial]] = [], heads: [[SmartSearchInitial]] = []
        var e: [SmartSearchInitial] = [], s: [SmartSearchInitial] = [], h: [SmartSearchInitial] = []
        var inSegment = false; var segmentHead: SmartSearchInitial?; var length = 0
        func finish(_ run: inout [SmartSearchInitial], into runs: inout [[SmartSearchInitial]]) { if !run.isEmpty { runs.append(run); run.removeAll(keepingCapacity: true) } }
        func finishSegment() {
            guard inSegment else { return }
            if let segmentHead { h.append(segmentHead) } else { finish(&h, into: &heads) }
            inSegment = false; segmentHead = nil
        }
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            try analysisStep()
            let explicitInitial = initial(for: scalar), syllableInitial = initialForSyllable(scalar)
            if let explicitInitial { e.append(explicitInitial); length += 1 } else { finish(&e, into: &explicit) }
            if let syllableInitial {
                // The silent initial ㅇ in a vowel-led syllable is not a
                // searchable consonant boundary (e.g. ㅍㄱ matches 파일관리).
                if syllableInitial != .ieung { s.append(syllableInitial); length += 1 }
            } else { finish(&s, into: &syllables) }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                inSegment = true
                if segmentHead == nil { segmentHead = explicitInitial ?? syllableInitial }
            } else { finishSegment() }
        }
        finish(&e, into: &explicit); finish(&s, into: &syllables); finishSegment(); finish(&h, into: &heads)
        return Features(explicit: explicit, syllables: syllables, heads: heads, length: max(1, length))
    }

    private static func evidence(_ pattern: SmartSearchInitialPattern, features: Features, field: SmartSearchInitialField, analysisStep: AnalysisStep) throws -> SmartSearchInitialEvidence? {
        let variants: [([[SmartSearchInitial]], SmartSearchInitialRepresentation, Double)] = [
            (features.explicit, .literal, 1), (features.syllables, .syllableRun, 1), (features.heads, .runHeads, 0.5)
        ]
        var candidates: [SmartSearchInitialEvidence] = []
        for (runs, representation, weight) in variants {
            var count = 0; var relation: SmartSearchInitialRelation?
            for run in runs {
                let summary = try occurrences(pattern, in: run, analysisStep: analysisStep)
                guard summary.count > 0 else { continue }
                count += summary.count
                let next: SmartSearchInitialRelation = run == pattern.initials ? .exact : (summary.prefix ? .prefix : .contains)
                if relation == nil || next.rawValue > relation!.rawValue { relation = next }
            }
            if let relation { candidates.append(.init(key: .init(field: field, representation: representation, relation: relation), weightedTermFrequency: Double(count) * weight, documentLength: features.length)) }
        }
        return candidates.max(by: { $0.key < $1.key })
    }

    private static func occurrences(_ pattern: SmartSearchInitialPattern, in values: [SmartSearchInitial], analysisStep: AnalysisStep) throws -> (count: Int, prefix: Bool) {
        guard !pattern.initials.isEmpty, pattern.initials.count <= values.count else { return (0, false) }
        var count = 0, matched = 0, prefix = false
        for (index, value) in values.enumerated() {
            while matched > 0, value != pattern.initials[matched] { try analysisStep(); matched = pattern.failureTable[matched - 1] }
            try analysisStep()
            if value == pattern.initials[matched] { matched += 1 }
            guard matched == pattern.initials.count else { continue }
            let start = index + 1 - matched; count += 1; prefix = prefix || start == 0; matched = pattern.failureTable[matched - 1]
        }
        return (count, prefix)
    }

    private static func folded(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    private static func initialForSyllable(_ scalar: Unicode.Scalar) -> SmartSearchInitial? { guard (0xAC00...0xD7A3).contains(scalar.value) else { return nil }; return .init(rawValue: UInt8((scalar.value - 0xAC00) / 588)) }
    private static func initial(for scalar: Unicode.Scalar) -> SmartSearchInitial? {
        if (0x1100...0x1112).contains(scalar.value) { return .init(rawValue: UInt8(scalar.value - 0x1100)) }
        let compatibility: [UInt32: SmartSearchInitial] = [0x3131: .kiyeok, 0x3132: .ssangKiyeok, 0x3134: .nieun, 0x3137: .tikeut, 0x3138: .ssangTikeut, 0x3139: .rieul, 0x3141: .mieum, 0x3142: .pieup, 0x3143: .ssangPieup, 0x3145: .siot, 0x3146: .ssangSiot, 0x3147: .ieung, 0x3148: .cieuc, 0x3149: .ssangCieuc, 0x314A: .chieuch, 0x314B: .khieukh, 0x314C: .thieuth, 0x314D: .phieuph, 0x314E: .hieuh]
        return compatibility[scalar.value]
    }
}
