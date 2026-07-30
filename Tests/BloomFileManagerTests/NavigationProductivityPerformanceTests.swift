import Foundation
import Testing
@testable import BloomFileManager

struct NavigationProductivityPerformanceTests {
    @Test func filenameFilteringTenThousandLoadedItemsStaysBelowRegressionCeiling() {
        let items = (0..<10_000).map { index in
            FileItem(
                url: URL(filePath: "/scale/report-\(index).txt"),
                name: "report-\(index).txt",
                isDirectory: false,
                isPackage: false,
                modifiedAt: nil,
                byteSize: 1,
                typeDescription: "Text"
            )
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for query in ["1", "19", "199", "1999", "report"] {
                _ = PaneFilenameFilter(query: query).apply(to: items)
            }
        }
        #expect(elapsed < .seconds(5))
    }
}
