import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SmartSearchModelTests {
    @Test func queryTrimsTextStandardizesRootsAndClampsMaximumResults() throws {
        let query = try SmartSearchQuery(
            text: "  Café reports  ",
            roots: [
                URL(filePath: "/search/./root", directoryHint: .isDirectory),
                URL(filePath: "/search/root", directoryHint: .isDirectory)
            ],
            maximumResults: 9_999
        )

        #expect(query.text == "Café reports")
        #expect(query.roots == [URL(filePath: "/search/root", directoryHint: .isDirectory)])
        #expect(query.maximumResults == 2_000)
        #expect(try SmartSearchQuery(text: "query", roots: [URL(filePath: "/root")], maximumResults: 0).maximumResults == 1)
    }

    @Test func validationRejectsEmptyTextInvalidRootsAndComplexQueries() {
        #expect(throws: SmartSearchValidationError.emptyText) {
            try SmartSearchQuery(text: " \n ", roots: [URL(filePath: "/search/root")])
        }
        #expect(throws: SmartSearchValidationError.missingRoots) {
            try SmartSearchQuery(text: "report", roots: [])
        }
        #expect(throws: SmartSearchValidationError.invalidRoot) {
            try SmartSearchQuery(text: "report", roots: [URL(string: "https://example.com/search")!])
        }
        #expect(throws: SmartSearchValidationError.queryTooComplex) {
            try SmartSearchQuery(
                text: String(repeating: "a", count: SmartSearchQuery.maximumTextScalarCount + 1),
                roots: [URL(filePath: "/search/root")]
            )
        }
        #expect(throws: SmartSearchValidationError.noSearchableTerms) {
            try SmartSearchQuery(text: "---", roots: [URL(filePath: "/search/root")])
        }
    }

    @Test func decodedQueriesRetainLegacyTextButCannotExecuteWhenTooComplex() throws {
        let legacyText = Array(
            repeating: "ㄱ",
            count: SmartSearchQuery.maximumClauseCount + 1
        ).joined(separator: " ")
        let query = try JSONDecoder().decode(
            SmartSearchQuery.self,
            from: JSONEncoder().encode(queryPayload(text: legacyText))
        )

        #expect(query.text == legacyText)
        #expect(!query.isWithinComplexityLimits)
        #expect(throws: SmartSearchValidationError.queryTooComplex) {
            try query.executablePlan()
        }
    }

    @Test func candidateBudgetScalesWithRequestedResultLimitWithoutExceedingBound() throws {
        let small = try SmartSearchQuery(
            text: "report",
            roots: [URL(filePath: "/search/root")],
            maximumResults: 1
        )
        let largest = try SmartSearchQuery(
            text: "report",
            roots: [URL(filePath: "/search/root")],
            maximumResults: SmartSearchQuery.maximumResultRange.upperBound
        )

        #expect(small.candidateBudget == 2_000)
        #expect(largest.candidateBudget == 40_000)
        #expect(largest.candidateBudget <= SmartSearchQuery.maximumCandidateBudget)
    }

    @Test func rankerBoundsCandidatesBeforeScoringAndResultsAfterRanking() throws {
        let query = try SmartSearchQuery(
            text: "report",
            roots: [URL(filePath: "/search/root")],
            maximumResults: 1
        )
        let candidates = (0...query.candidateBudget).map { index in
            result(
                name: index == query.candidateBudget ? "report" : "report-\(index).txt",
                path: "reports/report-\(index).txt"
            )
        }

        let ranked = SmartSearchRanker.ranked(candidates, for: query)

        #expect(ranked.count == query.maximumResults)
        #expect(ranked.first?.item.name != "report")
    }

    @Test func resultCarriesExactFileIdentity() {
        let item = fileItem(name: "report.txt", path: "report.txt")
        let identity = FileIdentity(entryIdentifier: "entry-1", resolvedIdentifier: "resolved-1")
        let result = SmartSearchResult(
            item: item,
            relativePath: "report.txt",
            score: 0,
            identity: identity
        )

        #expect(result.identity == identity)
        #expect(result.id == item.url)
    }

    @Test func rankerPreservesExactIdentityWhileReconstructingScores() throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let identity = FileIdentity(entryIdentifier: "entry-42", resolvedIdentifier: "resolved-42")
        let candidate = SmartSearchResult(
            item: fileItem(name: "report.txt", path: "report.txt"),
            relativePath: "report.txt",
            score: 0,
            identity: identity
        )

        let ranked = SmartSearchRanker.ranked([candidate], for: query)

        #expect(ranked.first?.identity == identity)
    }

    @Test func tokenizationIsLocalizedCaseAndDiacriticInsensitive() {
        #expect(SmartSearchRanker.tokens(in: "Café 보고서") == ["cafe", "보고서"])
    }

    @Test func filenameTokenMatchesScoreAbovePathOnlyMatches() throws {
        let query = try SmartSearchQuery(text: "notes", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "archive.pdf", path: "notes/2026/archive.pdf"),
            result(name: "meeting-notes.txt", path: "meetings/meeting-notes.txt")
        ], for: query)

        #expect(ranked.map(\.item.name) == ["meeting-notes.txt", "archive.pdf"])
        #expect(ranked[0].score > ranked[1].score)
    }

    @Test func initialSearchRanksLiteralJamoBeforeSyllableAndPathEvidence() throws {
        let query = try SmartSearchQuery(text: "ㅎㄱ", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "notes.txt", path: "한국/notes.txt"),
            result(name: "한국.txt", path: "한국.txt"),
            result(name: "ㅎㄱ", path: "ㅎㄱ")
        ], for: query)

        #expect(ranked.map(\.item.name) == ["ㅎㄱ", "한국.txt", "notes.txt"])
    }

    @Test func rankerRejectsAnOverLimitPersistedQueryBeforePreparingCandidates() throws {
        let legacyQuery = try JSONDecoder().decode(
            SmartSearchQuery.self,
            from: JSONEncoder().encode(queryPayload(
                text: String(repeating: "a", count: SmartSearchQuery.maximumTextScalarCount + 1)
            ))
        )
        let candidates = [result(name: "a.txt", path: "a.txt")]
        let steps = RankerStepCounter()

        #expect(throws: SmartSearchValidationError.queryTooComplex) {
            try SmartSearchRanker.ranked(candidates, for: legacyQuery, cancellationCheck: steps.increment)
        }
        #expect(steps.value == 0)
        #expect(SmartSearchRanker.ranked(candidates, for: legacyQuery).isEmpty)
    }

    @Test func rankerCancellationInterruptsLongLiteralTokenization() throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let candidate = result(
            name: "report.txt",
            path: String(repeating: "report ", count: 1_024)
        )
        let probe = RankerCancellationProbe(allowedSteps: 64)

        #expect(throws: RankerProbeError.cancelled) {
            try SmartSearchRanker.ranked([candidate], for: query, cancellationCheck: probe.step)
        }
        #expect(probe.value > 64)
    }

    @Test func savedSearchRecordRoundTripsURLsAndDatesThroughCodable() throws {
        let query = try SmartSearchQuery(
            text: "résumé",
            roots: [URL(filePath: "/search/root", directoryHint: .isDirectory)],
            includeHidden: true,
            includePackages: true,
            includeDirectories: false,
            maximumResults: 42
        )
        let record = SmartSearchRecord(
            id: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            displayName: "Recent résumés",
            query: query,
            createdAt: Date(timeIntervalSince1970: 1_234_567_890)
        )

        let decoded = try JSONDecoder().decode(SmartSearchRecord.self, from: JSONEncoder().encode(record))

        #expect(decoded == record)
    }
}

private final class RankerStepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private enum RankerProbeError: Error {
    case cancelled
}

private final class RankerCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let allowedSteps: Int
    private var count = 0

    init(allowedSteps: Int) {
        self.allowedSteps = allowedSteps
    }

    var value: Int { lock.withLock { count } }

    func step() throws {
        let shouldCancel = lock.withLock {
            count += 1
            return count > allowedSteps
        }
        if shouldCancel {
            throw RankerProbeError.cancelled
        }
    }
}

private func result(name: String, path: String) -> SmartSearchResult {
    let item = fileItem(name: name, path: path)
    return SmartSearchResult(
        item: item,
        relativePath: path,
        score: 0,
        identity: FileIdentity(entryIdentifier: path, resolvedIdentifier: path)
    )
}

private func fileItem(name: String, path: String) -> FileItem {
    FileItem(
        url: URL(filePath: "/search/root").appending(path: path),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: "Text"
    )
}

private struct SmartSearchQueryPayload: Codable {
    let text: String
    let roots: [URL]
    let includeHidden: Bool
    let includePackages: Bool
    let includeDirectories: Bool
    let maximumResults: Int
}

private func queryPayload(
    text: String,
    roots: [URL] = [URL(filePath: "/search/root")],
    includeHidden: Bool = false,
    includePackages: Bool = false,
    includeDirectories: Bool = true,
    maximumResults: Int = 500
) -> SmartSearchQueryPayload {
    SmartSearchQueryPayload(
        text: text,
        roots: roots,
        includeHidden: includeHidden,
        includePackages: includePackages,
        includeDirectories: includeDirectories,
        maximumResults: maximumResults
    )
}
