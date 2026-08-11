import Foundation
import Testing
@testable import BloomFileManager

@Suite struct BatchRenamePerformanceTests {
    @Test func tenThousandRowPreviewCompletesWithinFiveSeconds() throws {
        let parent = URL(filePath: "/performance", directoryHint: .isDirectory)
        let sources = (0..<10_000).map { index in
            let name = "IMG_\(String(format: "%05d", index)).jpg"
            return BatchRenameSource(
                url: parent.appending(path: name),
                identity: FileIdentity(
                    entryIdentifier: "entry-\(index)",
                    resolvedIdentifier: "resolved-\(index)"
                ),
                name: name,
                isDirectory: false,
                isPackage: false
            )
        }
        let request = BatchRenamePlanningRequest(
            parentURL: parent,
            parentIdentity: FileIdentity(entryIdentifier: "parent", resolvedIdentifier: "parent"),
            sources: sources
        )
        let occupiedNames = Set(sources.map(\.name))
        let clock = ContinuousClock()

        let duration = try clock.measure {
            _ = try BatchRenamePlanner.preview(
                request: request,
                rule: .sequence(baseName: "Photo", start: 1, digits: 5),
                occupiedNames: occupiedNames,
                comparisonPolicy: .caseInsensitiveCanonical
            )
        }

        #expect(duration < .seconds(5))
    }
}
