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
