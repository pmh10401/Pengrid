import Foundation
import Testing
@testable import BloomFileManager

@Suite("OperationLoggerTests")
struct OperationLoggerTests {
    @Test func transferVerificationFormattingContainsOnlyTypedAggregateFields() {
        let event = TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: 4,
            verifiedLogicalByteCount: 1_048_576,
            noByteTransferItemCount: 1,
            failedVerificationItemCount: 0,
            failureCategory: .contentMismatch
        )

        let message = LiveOperationLogger.transferVerificationLogMessage(event)

        #expect(message == "verificationEnabled=true verifiedFiles=4 verifiedLogicalBytes=1048576 noByteTransferItems=1 failedVerificationItems=0 failureCategory=contentMismatch")
        #expect(!message.contains("/Users/"))
        #expect(!message.contains("Report.txt"))
        #expect(!message.contains("sha256"))
        #expect(!message.contains("underlying error"))
    }

    @Test func existingOperationLoggingConformersReceiveTypedNoOpByDefault() async {
        let logger = LegacyOperationLogger()
        await logger.recordTransferVerification(TransferVerificationLogEvent(
            enabled: false,
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0,
            failureCategory: nil
        ))

        #expect(await logger.transferVerificationEventCount == 0)
    }
}

private actor LegacyOperationLogger: OperationLogging {
    private(set) var transferVerificationEventCount = 0

    func record(
        kind: FileOperationKind,
        duration: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int
    ) async {}
}
