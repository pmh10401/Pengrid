import Foundation
import Testing
@testable import BloomFileManager

struct NavigationProductivityPerformanceTests {
    @Test func filenameFilteringTenThousandLoadedItemsStaysBelowRegressionCeiling() {
        let items = makeProjectionFixture(count: 10_000)
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
        let items = makeProjectionFixture(count: 10_000)
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
        let items = makeProjectionFixture(count: 10_000)
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
}

private func makeProjectionFixture(count: Int) -> [FileItem] {
    let root = URL(filePath: "/scale", directoryHint: .isDirectory)
    return (0..<count).map { index in
        let isDirectory = index.isMultiple(of: 10)
        let name = index.isMultiple(of: 2) ? "보고서-\(index)" : "report-\(index)"
        return FileItem(
            url: root.appending(path: name),
            name: name,
            isDirectory: isDirectory,
            isPackage: false,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            byteSize: isDirectory ? nil : Int64(index * 17),
            typeDescription: isDirectory ? "Folder" : "Text"
        )
    }
}
