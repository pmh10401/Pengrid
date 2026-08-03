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

    @Test func validationRejectsEmptyTextAndInvalidRoots() {
        #expect(throws: SmartSearchValidationError.emptyText) {
            try SmartSearchQuery(text: " \n ", roots: [URL(filePath: "/search/root")])
        }
        #expect(throws: SmartSearchValidationError.missingRoots) {
            try SmartSearchQuery(text: "report", roots: [])
        }
        #expect(throws: SmartSearchValidationError.invalidRoot) {
            try SmartSearchQuery(text: "report", roots: [URL(string: "https://example.com/search")!])
        }
        #expect(throws: SmartSearchValidationError.invalidRoot) {
            try SmartSearchQuery(text: "report", roots: [URL(string: "file://fileserver/share")!])
        }
        #expect(throws: SmartSearchValidationError.invalidRoot) {
            try SmartSearchQuery(text: "report", roots: [URL(string: "file:relative-path")!])
        }
    }

    @Test func decodedQueriesRunTheSameValidationAndNormalization() throws {
        #expect(throws: SmartSearchValidationError.emptyText) {
            try JSONDecoder().decode(
                SmartSearchQuery.self,
                from: JSONEncoder().encode(queryPayload(text: "  ", roots: [URL(filePath: "/search/root")]))
            )
        }
        #expect(throws: SmartSearchValidationError.invalidRoot) {
            try JSONDecoder().decode(
                SmartSearchQuery.self,
                from: JSONEncoder().encode(queryPayload(text: "report", roots: [URL(string: "file://fileserver/share")!]))
            )
        }

        let decoded = try JSONDecoder().decode(
            SmartSearchQuery.self,
            from: JSONEncoder().encode(queryPayload(
                text: "  report  ",
                roots: [URL(filePath: "/search/./root")],
                maximumResults: 9_999
            ))
        )
        #expect(decoded.text == "report")
        #expect(decoded.roots == [URL(filePath: "/search/root")])
        #expect(decoded.maximumResults == 2_000)
    }

    @Test func maximumResultsStaysClampedAfterMutation() throws {
        var query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])

        query.setMaximumResults(-1)
        #expect(query.maximumResults == 1)
        query.setMaximumResults(9_999)
        #expect(query.maximumResults == 2_000)
    }

    @Test func candidateBudgetIsHardBoundedWhileScalingWithRequestedResults() throws {
        let smallQuery = try SmartSearchQuery(
            text: "report",
            roots: [URL(filePath: "/search/root")],
            maximumResults: 1
        )
        let largestQuery = try SmartSearchQuery(
            text: "report",
            roots: [URL(filePath: "/search/root")],
            maximumResults: SmartSearchQuery.maximumResultRange.upperBound
        )

        #expect(smallQuery.candidateBudget == 2_000)
        #expect(largestQuery.candidateBudget == 40_000)
        #expect(largestQuery.candidateBudget <= 50_000)
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

    @Test func exactAndPrefixFilenameMatchesReceiveBonuses() throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "monthly-report.txt", path: "monthly-report.txt"),
            result(name: "report-draft.txt", path: "report-draft.txt"),
            result(name: "report", path: "report")
        ], for: query)

        #expect(ranked.map(\.item.name) == ["report", "report-draft.txt", "monthly-report.txt"])
    }

    @Test func equalScoresUseLocalizedNumericStandardizedPathOrdering() throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "report.txt", path: "folder/report10.txt"),
            result(name: "report.txt", path: "folder/report2.txt")
        ], for: query)

        #expect(ranked.map(\.relativePath) == ["folder/report2.txt", "folder/report10.txt"])
    }

    @Test func localizedPathOrderingRemainsDeterministicForCaseVariants() throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "report.txt", path: "folder/report.txt"),
            result(name: "report.txt", path: "folder/Report.txt")
        ], for: query)

        #expect(ranked.map(\.relativePath) == ["folder/report.txt", "folder/Report.txt"])
    }

    @Test func equalStandardizedPathsUseRelativePathFallback() throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let item = FileItem(
            url: URL(filePath: "/search/root/folder/report.txt"),
            name: "report.txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Text"
        )
        let ranked = SmartSearchRanker.ranked([
            SmartSearchResult(item: item, relativePath: "z-report.txt", score: 0),
            SmartSearchResult(item: item, relativePath: "a-report.txt", score: 0)
        ], for: query)

        #expect(ranked.map(\.relativePath) == ["a-report.txt", "z-report.txt"])
    }

    @Test func literalJamoFilenameOutranksDerivedInitialAndPathMatches() throws {
        let query = try SmartSearchQuery(text: "ㅎㄱ", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "notes.txt", path: "한국/notes.txt"),
            result(name: "한국.txt", path: "한국.txt"),
            result(name: "ㅎㄱ", path: "ㅎㄱ")
        ], for: query)

        #expect(ranked.map(\.item.name) == ["ㅎㄱ", "한국.txt", "notes.txt"])
    }

    @Test func syllableFilenameOutranksRunHeadFilenameAndPathOnlyEvidence() throws {
        let query = try SmartSearchQuery(text: "ㄱㄷ", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "notes.txt", path: "구글 드라이브/notes.txt"),
            result(name: "구글 드라이브", path: "구글 드라이브"),
            result(name: "기대", path: "기대")
        ], for: query)

        #expect(ranked.map(\.item.name) == ["기대", "구글 드라이브", "notes.txt"])
    }

    @Test func weakestInitialClauseWinsBeforeOneExcellentClause() throws {
        let query = try SmartSearchQuery(text: "ㅎㄱ ㄱㄷ", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "ㅎㄱ.txt", path: "구글 드라이브/ㅎㄱ.txt"),
            result(name: "한국 기대.txt", path: "한국 기대.txt")
        ], for: query)

        #expect(ranked.map(\.item.name) == ["한국 기대.txt", "ㅎㄱ.txt"])
    }

    @Test func initialRankingIsIndependentOfCandidateInputOrder() throws {
        let query = try SmartSearchQuery(text: "ㅎㄱ", roots: [URL(filePath: "/search/root")])
        let candidates = [
            result(name: "한국2.txt", path: "한국2.txt"),
            result(name: "한국10.txt", path: "한국10.txt"),
            result(name: "한글.txt", path: "한글.txt")
        ]

        let forward = SmartSearchRanker.ranked(candidates, for: query).map(\.item.url)
        let reversed = SmartSearchRanker.ranked(Array(candidates.reversed()), for: query).map(\.item.url)

        #expect(forward == reversed)
    }

    @Test func literalOnlyRankingKeepsTheExistingExactPrefixAndContainsOrder() throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let ranked = SmartSearchRanker.ranked([
            result(name: "monthly-report.txt", path: "monthly-report.txt"),
            result(name: "report-draft.txt", path: "report-draft.txt"),
            result(name: "report", path: "report")
        ], for: query)

        #expect(ranked.map(\.item.name) == ["report", "report-draft.txt", "monthly-report.txt"])
        #expect(ranked.allSatisfy { $0.score > 0 })
    }

    @Test func cancellationAfterMergeSortStartsStopsRanking() async throws {
        let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
        let candidates = (0..<500).map { index in
            result(name: "report-\(index).txt", path: "folder/report-\(index).txt")
        }
        let sortingProbe = SortingCancellationProbe()
        let task = Task {
            try SmartSearchRanker.ranked(
                candidates,
                for: query,
                cancellationCheck: { try Task.checkCancellation() },
                sortingHook: sortingProbe.checkCancellation
            )
        }
        await sortingProbe.waitUntilStarted()

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
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

private final class SortingCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func checkCancellation() throws {
        lock.withLock { started = true }
        while !Task.isCancelled {
            usleep(100)
        }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        while !lock.withLock({ started }) {
            await Task.yield()
        }
    }
}

private func result(name: String, path: String) -> SmartSearchResult {
    SmartSearchResult(
        item: FileItem(
            url: URL(filePath: "/search/root").appending(path: path),
            name: name,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Text"
        ),
        relativePath: path,
        score: 0
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
    roots: [URL],
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
