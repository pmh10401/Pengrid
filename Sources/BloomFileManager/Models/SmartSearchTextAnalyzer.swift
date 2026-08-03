import Foundation

enum SmartSearchInitial: UInt8, CaseIterable, Sendable, Equatable {
    case kiyeok
    case ssangKiyeok
    case nieun
    case tikeut
    case ssangTikeut
    case rieul
    case mieum
    case pieup
    case ssangPieup
    case siot
    case ssangSiot
    case ieung
    case cieuc
    case ssangCieuc
    case chieuch
    case khieukh
    case thieuth
    case phieuph
    case hieuh
}

struct SmartSearchInitialPattern: Sendable, Equatable, ExpressibleByArrayLiteral {
    let initials: [SmartSearchInitial]
    let failureTable: [Int]

    init(_ initials: [SmartSearchInitial]) {
        try! self.init(initials, analysisStep: {})
    }

    init(
        _ initials: [SmartSearchInitial],
        analysisStep: SmartSearchTextAnalyzer.AnalysisStep
    ) throws {
        self.initials = initials
        self.failureTable = try Self.makeFailureTable(
            for: initials,
            analysisStep: analysisStep
        )
    }

    init(arrayLiteral elements: SmartSearchInitial...) {
        self.init(elements)
    }

    private static func makeFailureTable(
        for pattern: [SmartSearchInitial],
        analysisStep: SmartSearchTextAnalyzer.AnalysisStep
    ) throws -> [Int] {
        guard pattern.count > 1 else {
            return Array(repeating: 0, count: pattern.count)
        }
        var table = Array(repeating: 0, count: pattern.count)
        var prefixLength = 0
        for index in 1..<pattern.count {
            try analysisStep()
            while prefixLength > 0, pattern[index] != pattern[prefixLength] {
                try analysisStep()
                prefixLength = table[prefixLength - 1]
            }
            if pattern[index] == pattern[prefixLength] {
                prefixLength += 1
                table[index] = prefixLength
            }
        }
        return table
    }
}

enum SmartSearchClause: Sendable, Equatable {
    case literal(String)
    case hangulInitials(SmartSearchInitialPattern)
}

struct SmartSearchQueryPlan: Sendable, Equatable {
    let clauses: [SmartSearchClause]

    var containsInitials: Bool {
        clauses.contains { clause in
            if case .hangulInitials = clause {
                return true
            }
            return false
        }
    }
}

enum SmartSearchInitialField: Int, Sendable, Equatable {
    case relativePath = 1
    case filename = 2
}

enum SmartSearchInitialRepresentation: Int, Sendable, Equatable {
    case runHeads = 1
    case syllableRun = 2
    case literal = 3
}

enum SmartSearchInitialRelation: Int, Sendable, Equatable {
    case contains = 1
    case prefix = 2
    case exact = 3
}

struct SmartSearchInitialEvidenceKey: Sendable, Equatable, Comparable {
    let field: SmartSearchInitialField
    let representation: SmartSearchInitialRepresentation
    let relation: SmartSearchInitialRelation

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.field != rhs.field {
            return lhs.field.rawValue < rhs.field.rawValue
        }
        if lhs.representation != rhs.representation {
            return lhs.representation.rawValue < rhs.representation.rawValue
        }
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

    init?(
        filenameEvidence: SmartSearchInitialEvidence?,
        relativePathEvidence: SmartSearchInitialEvidence?
    ) {
        guard let bestEvidence = [filenameEvidence, relativePathEvidence]
            .compactMap({ $0 })
            .max(by: { $0.key < $1.key }) else {
            return nil
        }
        self.bestEvidence = bestEvidence
        self.filenameMatched = filenameEvidence != nil
        self.relativePathMatched = relativePathEvidence != nil
    }

    func contains(_ field: SmartSearchInitialField) -> Bool {
        switch field {
        case .filename: filenameMatched
        case .relativePath: relativePathMatched
        }
    }
}

struct SmartSearchInitialFieldLengths: Sendable, Equatable {
    let filename: Int
    let relativePath: Int

    func length(for field: SmartSearchInitialField) -> Int {
        switch field {
        case .filename: filename
        case .relativePath: relativePath
        }
    }
}

struct SmartSearchMatch: Sendable, Equatable {
    let initialClauseMatches: [SmartSearchInitialClauseMatch]
    let initialFieldLengths: SmartSearchInitialFieldLengths

    var initialEvidence: [SmartSearchInitialEvidence] {
        initialClauseMatches.map(\.bestEvidence)
    }

    static let noInitials = SmartSearchMatch(
        initialClauseMatches: [],
        initialFieldLengths: SmartSearchInitialFieldLengths(filename: 1, relativePath: 1)
    )
}

enum SmartSearchTextAnalyzer {
    typealias AnalysisStep = @Sendable () throws -> Void

    static func queryPlan(for text: String) -> SmartSearchQueryPlan {
        try! queryPlan(for: text, analysisStep: {})
    }

    static func queryPlan(
        for text: String,
        analysisStep: AnalysisStep
    ) throws -> SmartSearchQueryPlan {
        for _ in text.unicodeScalars {
            try analysisStep()
        }
        let normalized = normalizedLiteralText(text)
        var clauses: [SmartSearchClause] = []
        var words: [String] = []

        normalized.enumerateSubstrings(
            in: normalized.startIndex...,
            options: [.byWords, .substringNotRequired, .localized]
        ) { _, range, _, _ in
            words.append(String(normalized[range]))
        }
        try analysisStep()
        for word in words {
            try appendClauses(
                from: word,
                to: &clauses,
                analysisStep: analysisStep
            )
        }

        return SmartSearchQueryPlan(clauses: clauses)
    }

    static func literalTokens(in text: String) -> [String] {
        let normalized = normalizedLiteralText(text)
        var tokens: [String] = []
        normalized.enumerateSubstrings(
            in: normalized.startIndex...,
            options: [.byWords, .substringNotRequired, .localized]
        ) { _, range, _, _ in
            tokens.append(String(normalized[range]))
        }
        return tokens
    }

    static func match(
        plan: SmartSearchQueryPlan,
        filename: String,
        relativePath: String
    ) -> SmartSearchMatch? {
        try! match(
            plan: plan,
            filename: filename,
            relativePath: relativePath,
            analysisStep: {}
        )
    }

    static func match(
        plan: SmartSearchQueryPlan,
        filename: String,
        relativePath: String,
        analysisStep: AnalysisStep
    ) throws -> SmartSearchMatch? {
        guard !plan.clauses.isEmpty else { return nil }

        let foldedPath = normalizedLiteralText(relativePath)
        let needsInitials = plan.containsInitials
        let filenameFeatures = needsInitials
            ? try initialFeatures(in: filename, analysisStep: analysisStep)
            : nil
        let pathFeatures = needsInitials
            ? try initialFeatures(in: relativePath, analysisStep: analysisStep)
            : nil
        var initialClauseMatches: [SmartSearchInitialClauseMatch] = []

        for clause in plan.clauses {
            try analysisStep()
            switch clause {
            case let .literal(token):
                guard foldedPath.contains(token) else { return nil }
            case let .hangulInitials(pattern):
                guard let filenameFeatures, let pathFeatures else { return nil }
                let filenameEvidence = try bestEvidence(
                    for: pattern,
                    in: filenameFeatures,
                    field: .filename,
                    analysisStep: analysisStep
                )
                let pathEvidence = try bestEvidence(
                    for: pattern,
                    in: pathFeatures,
                    field: .relativePath,
                    analysisStep: analysisStep
                )
                guard let clauseMatch = SmartSearchInitialClauseMatch(
                    filenameEvidence: filenameEvidence,
                    relativePathEvidence: pathEvidence
                ) else {
                    return nil
                }
                initialClauseMatches.append(clauseMatch)
            }
        }

        return SmartSearchMatch(
            initialClauseMatches: initialClauseMatches,
            initialFieldLengths: SmartSearchInitialFieldLengths(
                filename: filenameFeatures?.documentLength ?? 1,
                relativePath: pathFeatures?.documentLength ?? 1
            )
        )
    }

    private static func appendClauses(
        from word: String,
        to clauses: inout [SmartSearchClause],
        analysisStep: AnalysisStep
    ) throws {
        var literalBuffer = ""
        var initialBuffer: [SmartSearchInitial] = []

        func flushLiteral() throws {
            guard !literalBuffer.isEmpty else { return }
            try analysisStep()
            clauses.append(contentsOf: literalTokens(in: literalBuffer).map(SmartSearchClause.literal))
            literalBuffer = ""
        }

        func flushInitials() throws {
            guard !initialBuffer.isEmpty else { return }
            let pattern = try SmartSearchInitialPattern(
                initialBuffer,
                analysisStep: analysisStep
            )
            clauses.append(.hangulInitials(pattern))
            initialBuffer.removeAll(keepingCapacity: true)
        }

        for scalar in word.unicodeScalars {
            try analysisStep()
            if let initial = initial(for: scalar) {
                try flushLiteral()
                initialBuffer.append(initial)
            } else {
                try flushInitials()
                literalBuffer.unicodeScalars.append(scalar)
            }
        }
        try flushLiteral()
        try flushInitials()
    }

    private static func normalizedLiteralText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private struct InitialFeatures {
        let explicitRuns: [[SmartSearchInitial]]
        let syllableRuns: [[SmartSearchInitial]]
        let runHeadGroups: [[SmartSearchInitial]]
        let documentLength: Int
    }

    private static func initialFeatures(
        in text: String,
        analysisStep: AnalysisStep
    ) throws -> InitialFeatures {
        let normalized = text.precomposedStringWithCanonicalMapping
        var explicitRuns: [[SmartSearchInitial]] = []
        var syllableRuns: [[SmartSearchInitial]] = []
        var runHeadGroups: [[SmartSearchInitial]] = []
        var currentExplicitRun: [SmartSearchInitial] = []
        var currentSyllableRun: [SmartSearchInitial] = []
        var currentRunHeadGroup: [SmartSearchInitial] = []
        var insideSegment = false
        var segmentHead: SmartSearchInitial?
        var documentLength = 0

        func finishExplicitRun() {
            guard !currentExplicitRun.isEmpty else { return }
            explicitRuns.append(currentExplicitRun)
            currentExplicitRun.removeAll(keepingCapacity: true)
        }

        func finishSyllableRun() {
            guard !currentSyllableRun.isEmpty else { return }
            syllableRuns.append(currentSyllableRun)
            currentSyllableRun.removeAll(keepingCapacity: true)
        }

        func finishRunHeadGroup() {
            guard !currentRunHeadGroup.isEmpty else { return }
            runHeadGroups.append(currentRunHeadGroup)
            currentRunHeadGroup.removeAll(keepingCapacity: true)
        }

        func finishSegment() {
            guard insideSegment else { return }
            if let segmentHead {
                currentRunHeadGroup.append(segmentHead)
            } else {
                finishRunHeadGroup()
            }
            insideSegment = false
            segmentHead = nil
        }

        for scalar in normalized.unicodeScalars {
            try analysisStep()
            let explicitInitial = initial(for: scalar)
            let syllableInitial = initialForHangulSyllable(scalar)

            if let explicitInitial {
                currentExplicitRun.append(explicitInitial)
                documentLength += 1
            } else {
                finishExplicitRun()
            }

            if let syllableInitial {
                currentSyllableRun.append(syllableInitial)
                documentLength += 1
            } else {
                finishSyllableRun()
            }

            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                insideSegment = true
                if segmentHead == nil {
                    segmentHead = explicitInitial ?? syllableInitial
                }
            } else {
                finishSegment()
            }
        }

        finishExplicitRun()
        finishSyllableRun()
        finishSegment()
        finishRunHeadGroup()

        return InitialFeatures(
            explicitRuns: explicitRuns,
            syllableRuns: syllableRuns,
            runHeadGroups: runHeadGroups,
            documentLength: max(1, documentLength)
        )
    }

    private static func bestEvidence(
        for pattern: SmartSearchInitialPattern,
        in features: InitialFeatures,
        field: SmartSearchInitialField,
        analysisStep: AnalysisStep
    ) throws -> SmartSearchInitialEvidence? {
        var candidates: [SmartSearchInitialEvidence] = []
        if let explicit = try evidence(
            for: pattern,
            in: features.explicitRuns,
            field: field,
            representation: .literal,
            occurrenceWeight: 1,
            documentLength: features.documentLength,
            analysisStep: analysisStep
        ) {
            candidates.append(explicit)
        }
        if let syllable = try evidence(
            for: pattern,
            in: features.syllableRuns,
            field: field,
            representation: .syllableRun,
            occurrenceWeight: 1,
            documentLength: features.documentLength,
            analysisStep: analysisStep
        ) {
            candidates.append(syllable)
        }
        if let runHeads = try evidence(
            for: pattern,
            in: features.runHeadGroups,
            field: field,
            representation: .runHeads,
            occurrenceWeight: 0.5,
            documentLength: features.documentLength,
            analysisStep: analysisStep
        ) {
            candidates.append(runHeads)
        }

        return candidates.max(by: { $0.key < $1.key })
    }

    private static func evidence(
        for pattern: SmartSearchInitialPattern,
        in runs: [[SmartSearchInitial]],
        field: SmartSearchInitialField,
        representation: SmartSearchInitialRepresentation,
        occurrenceWeight: Double,
        documentLength: Int,
        analysisStep: AnalysisStep
    ) throws -> SmartSearchInitialEvidence? {
        guard !pattern.initials.isEmpty else { return nil }
        var bestRelation: SmartSearchInitialRelation?
        var occurrenceCount = 0

        for run in runs {
            let occurrences = try occurrenceSummary(
                of: pattern,
                in: run,
                analysisStep: analysisStep
            )
            guard occurrences.count > 0 else { continue }
            occurrenceCount += occurrences.count
            let relation: SmartSearchInitialRelation
            if run == pattern.initials {
                relation = .exact
            } else if occurrences.hasPrefix {
                relation = .prefix
            } else {
                relation = .contains
            }
            if bestRelation == nil || relation.rawValue > bestRelation!.rawValue {
                bestRelation = relation
            }
        }

        guard let bestRelation else { return nil }
        return SmartSearchInitialEvidence(
            key: SmartSearchInitialEvidenceKey(
                field: field,
                representation: representation,
                relation: bestRelation
            ),
            weightedTermFrequency: Double(occurrenceCount) * occurrenceWeight,
            documentLength: max(1, documentLength)
        )
    }

    private struct OccurrenceSummary {
        var count = 0
        var hasPrefix = false
    }

    private static func occurrenceSummary(
        of pattern: SmartSearchInitialPattern,
        in candidate: [SmartSearchInitial],
        analysisStep: AnalysisStep
    ) throws -> OccurrenceSummary {
        let query = pattern.initials
        guard !query.isEmpty, query.count <= candidate.count else {
            return OccurrenceSummary()
        }

        var summary = OccurrenceSummary()
        var matchedLength = 0
        for (index, value) in candidate.enumerated() {
            while matchedLength > 0 {
                try analysisStep()
                if value == query[matchedLength] {
                    break
                }
                matchedLength = pattern.failureTable[matchedLength - 1]
            }

            if matchedLength == 0 {
                try analysisStep()
                guard value == query[0] else { continue }
            }

            matchedLength += 1
            guard matchedLength == query.count else { continue }
            let start = index + 1 - query.count
            summary.count += 1
            summary.hasPrefix = summary.hasPrefix || start == 0
            matchedLength = pattern.failureTable[matchedLength - 1]
        }
        return summary
    }

    private static func initialForHangulSyllable(_ scalar: Unicode.Scalar) -> SmartSearchInitial? {
        guard (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        let initialIndex = (scalar.value - 0xAC00) / 588
        return SmartSearchInitial(rawValue: UInt8(initialIndex))
    }

    private static func initial(for scalar: Unicode.Scalar) -> SmartSearchInitial? {
        if (0x1100...0x1112).contains(scalar.value) {
            return SmartSearchInitial(rawValue: UInt8(scalar.value - 0x1100))
        }

        return switch scalar.value {
        case 0x3131: .kiyeok
        case 0x3132: .ssangKiyeok
        case 0x3134: .nieun
        case 0x3137: .tikeut
        case 0x3138: .ssangTikeut
        case 0x3139: .rieul
        case 0x3141: .mieum
        case 0x3142: .pieup
        case 0x3143: .ssangPieup
        case 0x3145: .siot
        case 0x3146: .ssangSiot
        case 0x3147: .ieung
        case 0x3148: .cieuc
        case 0x3149: .ssangCieuc
        case 0x314A: .chieuch
        case 0x314B: .khieukh
        case 0x314C: .thieuth
        case 0x314D: .phieuph
        case 0x314E: .hieuh
        default: nil
        }
    }
}
