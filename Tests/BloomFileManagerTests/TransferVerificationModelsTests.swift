import Foundation
import Testing
@testable import BloomFileManager

@Suite("TransferVerificationModelsTests")
struct TransferVerificationModelsTests {
    @Test func policyPairLimitsKeepDisabledSeparateFromEnabledBounds() {
        #expect(TransferVerificationPolicy.disabled.effectivePairLimit == nil)
        #expect(TransferVerificationPolicy.sha256(maxConcurrentPairs: 1).effectivePairLimit == 1)
        #expect(TransferVerificationPolicy.sha256(maxConcurrentPairs: 2).effectivePairLimit == 2)
        #expect(TransferVerificationPolicy.sha256(maxConcurrentPairs: 0).effectivePairLimit == 1)
        #expect(TransferVerificationPolicy.sha256(maxConcurrentPairs: -9).effectivePairLimit == 1)
        #expect(TransferVerificationPolicy.sha256(maxConcurrentPairs: 99).effectivePairLimit == 2)
    }

    @Test func verificationInitializersClampCountersAndNormalizeProgress() {
        let progress = TransferVerificationProgress(
            phase: .hashing,
            fractionCompleted: .nan,
            completedFileCount: -1,
            totalFileCount: -2,
            completedLogicalByteCount: -3,
            totalLogicalByteCount: -4,
            currentName: "/Users/example/Folder/Report.txt\nwith-secret"
        )
        let summary = TransferVerificationSummary(
            verifiedFileCount: -1,
            verifiedLogicalByteCount: -2,
            noByteTransferItemCount: -3
        )
        let report = TransferVerificationReport(
            verifiedFileCount: -1,
            verifiedLogicalByteCount: -2,
            noByteTransferItemCount: -3,
            failedVerificationItemCount: -4
        )
        let event = TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: -1,
            verifiedLogicalByteCount: -2,
            noByteTransferItemCount: -3,
            failedVerificationItemCount: -4,
            failureCategory: .readFailed
        )

        #expect(progress.fractionCompleted == 0)
        #expect(progress.completedFileCount == 0)
        #expect(progress.totalFileCount == 0)
        #expect(progress.completedLogicalByteCount == 0)
        #expect(progress.totalLogicalByteCount == 0)
        #expect(progress.currentName == "Report.txt with-secret")
        #expect(summary == TransferVerificationSummary(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0
        ))
        #expect(report == TransferVerificationReport(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        ))
        #expect(event == TransferVerificationLogEvent(
            enabled: true,
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0,
            failureCategory: .readFailed
        ))
    }

    @Test func progressNormalizesFiniteFractionsAndBasenames() {
        let under = TransferVerificationProgress(
            phase: .preparingManifest,
            fractionCompleted: -0.5,
            completedFileCount: 1,
            totalFileCount: 2,
            completedLogicalByteCount: 1,
            totalLogicalByteCount: 2,
            currentName: "Report.txt"
        )
        let over = TransferVerificationProgress(
            phase: .finalValidation,
            fractionCompleted: 2,
            completedFileCount: 2,
            totalFileCount: 2,
            completedLogicalByteCount: 2,
            totalLogicalByteCount: 2,
            currentName: "Folder/Report.txt"
        )
        let infinite = TransferVerificationProgress(
            phase: .hashing,
            fractionCompleted: .infinity,
            completedFileCount: 2,
            totalFileCount: 2,
            completedLogicalByteCount: 2,
            totalLogicalByteCount: 2,
            currentName: "Report.txt"
        )

        #expect(under.fractionCompleted == 0)
        #expect(over.fractionCompleted == 1)
        #expect(infinite.fractionCompleted == 0)
        #expect(over.currentName == "Report.txt")
    }

    @Test func reportMergingSaturatesIntAndInt64Counters() {
        let left = TransferVerificationReport(
            verifiedFileCount: Int.max - 1,
            verifiedLogicalByteCount: Int64.max - 1,
            noByteTransferItemCount: 4,
            failedVerificationItemCount: 6
        )
        let right = TransferVerificationReport(
            verifiedFileCount: 4,
            verifiedLogicalByteCount: 4,
            noByteTransferItemCount: Int.max,
            failedVerificationItemCount: Int.max
        )

        #expect(left.merging(right) == TransferVerificationReport(
            verifiedFileCount: Int.max,
            verifiedLogicalByteCount: Int64.max,
            noByteTransferItemCount: Int.max,
            failedVerificationItemCount: Int.max
        ))
    }

    @Test func failureDescriptionsUseOnlyFixedTextAndSafeBasenames() {
        let failure = TransferVerificationFailure(
            category: .contentMismatch,
            safeName: "/Users/example/Private/Report.txt\n"
        )

        #expect(failure.safeName == "Report.txt")
        #expect(failure.errorDescription == "The transferred content does not match for Report.txt.")
        #expect(!failure.errorDescription!.contains("/Users/"))
        #expect(!failure.errorDescription!.contains("sha256"))
    }
}
