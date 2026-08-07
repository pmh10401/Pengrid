import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Test func paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries() async throws {
    let sample = try await measurePaneSearchTrace(
        trace: .numeric,
        warmups: 0,
        samples: 1
    )

    #expect(sample.transitions.map(\.expectedCount) == [3_439, 299, 20, 1])
    #expect(sample.transitions.allSatisfy { $0.setterToAcceptanceSeconds >= 0 })
    #expect(sample.transitions.allSatisfy { $0.acceptanceToTableSeconds >= 0 })
    #expect(sample.transitions.allSatisfy { $0.endToEndSeconds >= 0 })
}

@Test func paneSearchFixtureMakesEnglishAndKoreanPrefixTransitionsStrictlyNarrow() {
    let items = paneSearchFixture()
    let englishCounts = ["r", "re", "rep", "report"].map {
        PaneFilenameFilter(query: $0).apply(to: items).count
    }
    let koreanCounts = ["보", "보고", "보고서"].map {
        PaneFilenameFilter(query: $0).apply(to: items).count
    }

    #expect(PaneFilenameFilter(query: "report").apply(to: items).count == 5_000)
    #expect(zip(englishCounts, englishCounts.dropFirst()).allSatisfy { $0 > $1 })
    #expect(zip(koreanCounts, koreanCounts.dropFirst()).allSatisfy { $0 > $1 })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_BENCHMARK"] == "1"))
func paneSearchReleaseBenchmark() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 3,
        sampleCount: 30,
        scenario: try #require(ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_SCENARIO"])
    ).measureSelectedScenario()
    try report.writeJSON(to: try #require(
        ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_REPORT"]
    ))
}
