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
            recentCount: 4,
            isQueueBlockedByRecovery: false
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
            recentCount: 1,
            isQueueBlockedByRecovery: false
        )

        #expect(presentation.isVisible)
        #expect(presentation.compactLabel == "Recent: 1")
    }

    @Test func emptySessionHidesTheOperationCenter() {
        let presentation = FileOperationCenterPresentation(
            activeJob: nil,
            queuedCount: 0,
            recentCount: 0,
            isQueueBlockedByRecovery: false
        )

        #expect(!presentation.isVisible)
    }

    @Test func recoveryBlockTakesPriorityInCompactAndAccessibilityLabels() {
        let presentation = FileOperationCenterPresentation(
            activeJob: nil,
            queuedCount: 2,
            recentCount: 1,
            isQueueBlockedByRecovery: true
        )

        #expect(presentation.compactLabel == "Recovery attention")
        #expect(presentation.accessibilityLabel
            == "Operation center, recovery attention required, 0 active operation, "
                + "2 queued operations, 1 recent operations")
    }

    @Test func protectedWaitingSnapshotUsesSafeTitleAndDetailWithoutSecret() {
        let snapshot = FileOperationJobSnapshot(
            id: UUID(),
            kind: .compressProtectedZIP,
            itemDisplayName: "/Users/example/Report.zip",
            itemCount: 1,
            state: .waitingForPassword,
            progress: FileOperationJobProgress(
                completedCount: 0,
                totalCount: 0,
                detail: "Waiting for password"
            ),
            canUndo: false
        )

        #expect(snapshot.title == "Compress Encrypted ZIP")
        #expect(snapshot.state.label == "Waiting for password")
        #expect(snapshot.progress?.detail == "Waiting for password")
        #expect(!snapshot.accessibilityLabel.contains("secret-sentinel-passphrase"))
        #expect(snapshot.accessibilityLabel ==
            "Compress Encrypted ZIP, Waiting for password, Report.zip, 1 item, 0 of 0, Waiting for password")
    }

    @Test func waitingForPasswordActiveRowOffersCancelButSuppressesPause() {
        let waiting = FileOperationJobSnapshot(
            id: UUID(),
            kind: .compressProtectedZIP,
            itemDisplayName: "Report.zip",
            itemCount: 1,
            state: .waitingForPassword,
            progress: FileOperationJobProgress(
                completedCount: 0,
                totalCount: 0,
                detail: "Waiting for password"
            ),
            canUndo: false
        )

        let actions = FileOperationCenterActiveActionPresentation(job: waiting)
        #expect(actions.showsCancel)
        #expect(!actions.showsPause)
        #expect(!actions.showsResume)
    }

    @Test func runningActiveRowOffersPauseAndCancel() {
        let running = FileOperationJobSnapshot(
            id: UUID(),
            kind: .compressProtectedZIP,
            itemDisplayName: "Report.zip",
            itemCount: 1,
            state: .running,
            progress: nil,
            canUndo: false
        )

        let actions = FileOperationCenterActiveActionPresentation(job: running)
        #expect(actions.showsCancel)
        #expect(actions.showsPause)
        #expect(!actions.showsResume)
    }
}
