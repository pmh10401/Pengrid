import Foundation
import Testing
@testable import BloomFileManager

@Suite("FileOperationJobModelsTests")
struct FileOperationJobModelsTests {
    @Test func snapshotSanitizesAbsolutePathsAndExposesStableLabels() {
        let snapshot = FileOperationJobSnapshot(
            id: UUID(),
            kind: .compress(.tarGzip),
            itemDisplayName: "/Users/example/Confidential/Report.txt",
            itemCount: 3,
            state: .queued,
            progress: nil,
            canUndo: false
        )

        #expect(snapshot.itemDisplayName == "Report.txt")
        #expect(snapshot.title == "Compress TAR.GZ")
        #expect(snapshot.state.label == "Queued")
        #expect(!snapshot.accessibilityLabel.contains("/Users/example"))
        #expect(snapshot.accessibilityLabel.contains("3 items"))
    }

    @Test func blankAndDirectoryLikeDisplayNamesBecomeSafeBasenames() {
        let blank = FileOperationJobSnapshot(
            id: UUID(),
            kind: .trash,
            itemDisplayName: "",
            itemCount: 1,
            state: .running,
            progress: nil,
            canUndo: false
        )
        let directory = FileOperationJobSnapshot(
            id: UUID(),
            kind: .copy,
            itemDisplayName: "/private/source/Folder/",
            itemCount: 1,
            state: .running,
            progress: nil,
            canUndo: false
        )

        #expect(blank.itemDisplayName == "Item")
        #expect(directory.itemDisplayName == "Folder")
    }

    @Test func progressFractionClampsInvalidCounts() {
        #expect(FileOperationJobProgress(
            completedCount: -4,
            totalCount: 0,
            detail: "Preparing"
        ).fractionCompleted == 0)
        #expect(FileOperationJobProgress(
            completedCount: 8,
            totalCount: 4,
            detail: "Preparing"
        ).fractionCompleted == 1)
        #expect(FileOperationJobProgress(
            completedCount: 1,
            totalCount: 4,
            detail: "Preparing"
        ).fractionCompleted == 0.25)
    }

    @Test func retryAndUndoAvailabilityFollowTerminalState() {
        let id = UUID()
        let failed = FileOperationJobSnapshot(
            id: id,
            kind: .move,
            itemDisplayName: "Report.txt",
            itemCount: 1,
            state: .failed,
            progress: nil,
            canUndo: true
        )
        let cancelled = FileOperationJobSnapshot(
            id: id,
            kind: .move,
            itemDisplayName: "Report.txt",
            itemCount: 1,
            state: .cancelled,
            progress: nil,
            canUndo: false
        )
        let succeeded = FileOperationJobSnapshot(
            id: id,
            kind: .move,
            itemDisplayName: "Report.txt",
            itemCount: 1,
            state: .succeeded,
            progress: nil,
            canUndo: true
        )

        #expect(failed.canRetry)
        #expect(!failed.canUndo)
        #expect(cancelled.canRetry)
        #expect(!cancelled.canUndo)
        #expect(!succeeded.canRetry)
        #expect(succeeded.canUndo)
    }
}
