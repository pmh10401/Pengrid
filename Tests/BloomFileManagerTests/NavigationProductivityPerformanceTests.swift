import Foundation
import Testing
@testable import BloomFileManager

struct NavigationProductivityPerformanceTests {
    @Test func filenameFilteringTenThousandLoadedItemsStaysBelowRegressionCeiling() {
        let items = paneSearchFixture(count: 10_000)
        let clock = ContinuousClock()
        let cases: [(query: String, expectedCount: Int)] = [
            ("1", 3_439),
            ("19", 299),
            ("199", 20),
            ("1999", 1),
            ("report", 5_000)
        ]

        for (query, expectedCount) in cases {
            var filtered: [FileItem] = []
            let elapsed = clock.measure {
                filtered = PaneFilenameFilter(query: query).apply(to: items)
            }
            #expect(filtered.count == expectedCount)
            #expect(elapsed < .seconds(5), "filter query \(query) exceeded the hang ceiling")
            print("navigation-baseline filter query=\(query) count=\(filtered.count) elapsed=\(elapsed)")
        }
    }

    @Test func fileSortingTenThousandLoadedItemsMeasuresEachSortKeyIndependently() {
        let items = paneSearchFixture(count: 10_000)
        let directoryCount = items.filter(\.isDirectory).count
        let clock = ContinuousClock()

        for key in FileSortKey.allCases {
            var sorted: [FileItem] = []
            let elapsed = clock.measure {
                sorted = FileSort(key: key).apply(to: items)
            }
            let directoriesRemainFirst = sorted.prefix(directoryCount).allSatisfy { $0.isDirectory }
            let filesFollowDirectories = sorted.dropFirst(directoryCount).allSatisfy { !$0.isDirectory }
            #expect(sorted.count == items.count)
            #expect(directoriesRemainFirst)
            #expect(filesFollowDirectories)
            #expect(elapsed < .seconds(5), "sort key \(key.rawValue) exceeded the hang ceiling")
            print("navigation-baseline sort key=\(key.rawValue) count=\(sorted.count) elapsed=\(elapsed)")
        }
    }

    @MainActor @Test func tablePopulationTenThousandLoadedItemsMeasuresFirstRenderedNonemptyState() {
        let items = paneSearchFixture(count: 10_000)
        let sample = measureFirstRenderedTableState(firstNonemptyItems: items)

        #expect(sample.rowCount == items.count)
        #expect(sample.requestToFirstNonemptyRows < .seconds(5))
        #expect(sample.coordinatorApplication < .seconds(5))
        print(
            "navigation-baseline table rows=\(sample.rowCount) "
                + "requestToFirstNonempty=\(sample.requestToFirstNonemptyRows) "
                + "coordinatorApplication=\(sample.coordinatorApplication)"
        )
    }

    @MainActor @Test func acceptedPaneProjectionSupportsConstantTimeRepeatedReads() async {
        let directory = URL(filePath: "/scale", directoryHint: .isDirectory)
        let items = paneSearchFixture(count: 10_000)
        let pane = FilePaneState(
            directory: directory,
            listingService: StubDirectoryListingService(values: [directory: items])
        )
        await pane.navigate(to: directory, recordHistory: false)
        let acceptedDiagnostics = pane.acceptedProjectionDiagnostics
        #expect(acceptedDiagnostics.path == .emptyActiveOrder)
        let clock = ContinuousClock()
        var observedRows = 0
        var observedTokens = 0
        var observedStableAcceptedDiagnostics = 0

        let elapsed = clock.measure {
            for _ in 0..<100 {
                observedRows += pane.visibleItems.count
                observedRows += pane.visibleIndexByURL.count
                if pane.acceptedProjectionToken != nil {
                    observedTokens += 1
                }
                if pane.acceptedProjectionDiagnostics == acceptedDiagnostics {
                    observedStableAcceptedDiagnostics += 1
                }
            }
        }

        #expect(observedRows == 2_000_000)
        #expect(observedTokens == 100)
        #expect(observedStableAcceptedDiagnostics == 100)
        #expect(elapsed < .seconds(5), "stored pane projection reads exceeded the hang ceiling")
        print("navigation-pane-projection repeatedReads=100 elapsed=\(elapsed)")
    }
}
