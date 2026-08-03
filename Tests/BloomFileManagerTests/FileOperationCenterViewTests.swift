import Foundation
import Testing
@testable import BloomFileManager

@Suite("File operation center presentation")
struct FileOperationCenterViewTests {
    @Test func summaryCountsActiveQueuedAndRecentJobsWithoutPathMetadata() {
        let active = FileOperationJobSnapshot(
            id: UUID(),
            kind: .copy,
            itemDisplayName: "/Users/example/Private/Report.txt",
            itemCount: 1,
            state: .running,
            progress: nil,
            canUndo: false
        )
        let presentation = FileOperationCenterPresentation(
            activeJob: active,
            queuedCount: 2,
            recentCount: 4
        )

        #expect(presentation.isVisible)
        #expect(presentation.compactLabel == "1 active, 2 queued")
        #expect(presentation.accessibilityLabel
            == "Operation center, 1 active operation, 2 queued operations, 4 recent operations")
        #expect(!presentation.accessibilityLabel.contains("/Users/example"))
    }

    @Test func completedHistoryKeepsTheOperationCenterDiscoverable() {
        let presentation = FileOperationCenterPresentation(
            activeJob: nil,
            queuedCount: 0,
            recentCount: 1
        )

        #expect(presentation.isVisible)
        #expect(presentation.compactLabel == "Recent: 1")
    }

    @Test func emptySessionHidesTheOperationCenter() {
        let presentation = FileOperationCenterPresentation(
            activeJob: nil,
            queuedCount: 0,
            recentCount: 0
        )

        #expect(!presentation.isVisible)
    }
}
