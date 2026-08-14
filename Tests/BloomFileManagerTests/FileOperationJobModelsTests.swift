import Foundation
import Testing
@testable import BloomFileManager

@Suite("FileOperationJobModelsTests")
struct FileOperationJobModelsTests {
    @Test func redoIsNotRetryableAndReversalAvailabilityIsPrivacySafe() {
        let snapshot = FileOperationJobSnapshot(
            id: UUID(),
            kind: .redo,
            itemDisplayName: "/private/path/Report.txt",
            itemCount: 2,
            state: .failed,
            progress: nil,
            canUndo: false
        )
        let availability = FileOperationReversalAvailability(
            title: "Redo Report.txt",
            itemCount: 2,
            isEnabled: true
        )

        #expect(snapshot.title == "Redo")
        #expect(snapshot.canRetry == false)
        #expect(snapshot.itemDisplayName == "Report.txt")
        #expect(availability.title.contains("/private") == false)
    }
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
        let unsafePartialRetry = FileOperationJobSnapshot(
            id: id,
            kind: .trash,
            itemDisplayName: "Several items",
            itemCount: 3,
            state: .cancelled,
            progress: nil,
            canUndo: false,
            canRetry: false
        )

        #expect(failed.canRetry)
        #expect(!failed.canUndo)
        #expect(cancelled.canRetry)
        #expect(!unsafePartialRetry.canRetry)
        #expect(!cancelled.canUndo)
        #expect(!succeeded.canRetry)
        #expect(succeeded.canUndo)
    }

    @Test func waitingForPasswordIsNonTerminalAndNotRetryable() {
        let snapshot = FileOperationJobSnapshot(
            id: UUID(),
            kind: .extract(.zip),
            itemDisplayName: "자료.zip",
            itemCount: 1,
            state: .waitingForPassword,
            progress: nil,
            canUndo: false
        )

        #expect(snapshot.state.label == "Waiting for password")
        #expect(snapshot.canRetry == false)
        #expect(snapshot.canUndo == false)
    }

    @Test func multiItemRenameUsesAnExplicitBatchTitle() {
        let batch = FileOperationJobSnapshot(
            id: UUID(),
            kind: .rename,
            itemDisplayName: "A.txt",
            itemCount: 3,
            state: .running,
            progress: nil,
            canUndo: false
        )
        let single = FileOperationJobSnapshot(
            id: UUID(),
            kind: .rename,
            itemDisplayName: "A.txt",
            itemCount: 1,
            state: .running,
            progress: nil,
            canUndo: false
        )

        #expect(batch.title == "Rename 3 Items")
        #expect(single.title == "Rename")
        #expect(batch.accessibilityLabel.hasPrefix("Rename 3 Items, Running"))
    }

    @Test func duplicateUsesItsOwnQueueTitleAndKeepsRetryPresentation() {
        let snapshot = FileOperationJobSnapshot(
            id: UUID(),
            kind: .duplicate,
            itemDisplayName: "Report.txt",
            itemCount: 2,
            state: .failed,
            progress: FileOperationJobProgress(
                completedCount: 1,
                totalCount: 2,
                detail: "Report.txt"
            ),
            canUndo: false
        )

        #expect(snapshot.title == "Duplicate")
        #expect(snapshot.canRetry)
        #expect(snapshot.accessibilityLabel.contains("1 of 2, Report.txt"))
    }

    @Test func selectionEnclosureUsesItsOwnQueueTitle() {
        let snapshot = FileOperationJobSnapshot(
            id: UUID(),
            kind: .encloseSelection,
            itemDisplayName: "Collected",
            itemCount: 2,
            state: .running,
            progress: nil,
            canUndo: false
        )

        #expect(snapshot.title == "New Folder with Selection")
    }
}
