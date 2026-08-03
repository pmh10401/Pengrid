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

enum SmartSearchClause: Sendable, Equatable {
    case literal(String)
    case hangulInitials([SmartSearchInitial])
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

struct SmartSearchMatch: Sendable, Equatable {
    let initialEvidence: [SmartSearchInitialEvidence]
}

enum SmartSearchTextAnalyzer {
    static func queryPlan(for text: String) -> SmartSearchQueryPlan {
        let normalized = normalizedLiteralText(text)
        var clauses: [SmartSearchClause] = []

        normalized.enumerateSubstrings(
            in: normalized.startIndex...,
            options: [.byWords, .substringNotRequired, .localized]
        ) { _, range, _, _ in
            appendClauses(from: String(normalized[range]), to: &clauses)
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
        guard !plan.clauses.isEmpty else { return nil }

        let foldedPath = normalizedLiteralText(relativePath)
        let needsInitials = plan.containsInitials
        let filenameFeatures = needsInitials ? initialFeatures(in: filename) : nil
        let pathFeatures = needsInitials ? initialFeatures(in: relativePath) : nil
        var initialEvidence: [SmartSearchInitialEvidence] = []

        for clause in plan.clauses {
            switch clause {
            case let .literal(token):
                guard foldedPath.contains(token) else { return nil }
            case let .hangulInitials(initials):
                guard let filenameFeatures, let pathFeatures else { return nil }
                let filenameEvidence = bestEvidence(
                    for: initials,
                    in: filenameFeatures,
                    field: .filename
                )
                let pathEvidence = bestEvidence(
                    for: initials,
                    in: pathFeatures,
                    field: .relativePath
                )
                guard let evidence = [filenameEvidence, pathEvidence]
                    .compactMap({ $0 })
                    .max(by: { $0.key < $1.key }) else {
                    return nil
                }
                initialEvidence.append(evidence)
            }
        }

        return SmartSearchMatch(initialEvidence: initialEvidence)
    }

    private static func appendClauses(from word: String, to clauses: inout [SmartSearchClause]) {
        var literalBuffer = ""
        var initialBuffer: [SmartSearchInitial] = []

        func flushLiteral() {
            guard !literalBuffer.isEmpty else { return }
            clauses.append(contentsOf: literalTokens(in: literalBuffer).map(SmartSearchClause.literal))
            literalBuffer = ""
        }

        func flushInitials() {
            guard !initialBuffer.isEmpty else { return }
            clauses.append(.hangulInitials(initialBuffer))
            initialBuffer.removeAll(keepingCapacity: true)
        }

        for scalar in word.unicodeScalars {
            if let initial = initial(for: scalar) {
                flushLiteral()
                initialBuffer.append(initial)
            } else {
                flushInitials()
                literalBuffer.unicodeScalars.append(scalar)
            }
        }
        flushLiteral()
        flushInitials()
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

    private static func initialFeatures(in text: String) -> InitialFeatures {
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
        for query: [SmartSearchInitial],
        in features: InitialFeatures,
        field: SmartSearchInitialField
    ) -> SmartSearchInitialEvidence? {
        let candidates = [
            evidence(
                for: query,
                in: features.explicitRuns,
                field: field,
                representation: .literal,
                occurrenceWeight: 1,
                documentLength: features.documentLength
            ),
            evidence(
                for: query,
                in: features.syllableRuns,
                field: field,
                representation: .syllableRun,
                occurrenceWeight: 1,
                documentLength: features.documentLength
            ),
            evidence(
                for: query,
                in: features.runHeadGroups,
                field: field,
                representation: .runHeads,
                occurrenceWeight: 0.5,
                documentLength: features.documentLength
            )
        ].compactMap { $0 }

        return candidates.max(by: { $0.key < $1.key })
    }

    private static func evidence(
        for query: [SmartSearchInitial],
        in runs: [[SmartSearchInitial]],
        field: SmartSearchInitialField,
        representation: SmartSearchInitialRepresentation,
        occurrenceWeight: Double,
        documentLength: Int
    ) -> SmartSearchInitialEvidence? {
        guard !query.isEmpty else { return nil }
        var bestRelation: SmartSearchInitialRelation?
        var occurrenceCount = 0

        for run in runs {
            let starts = occurrenceStarts(of: query, in: run)
            guard !starts.isEmpty else { continue }
            occurrenceCount += starts.count
            let relation: SmartSearchInitialRelation
            if run == query {
                relation = .exact
            } else if starts.contains(0) {
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

    private static func occurrenceStarts(
        of query: [SmartSearchInitial],
        in candidate: [SmartSearchInitial]
    ) -> [Int] {
        guard !query.isEmpty, query.count <= candidate.count else { return [] }
        return (0...(candidate.count - query.count)).filter { start in
            candidate[start..<(start + query.count)].elementsEqual(query)
        }
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
