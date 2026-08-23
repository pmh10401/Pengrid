import Foundation
import Testing
@testable import BloomFileManager

@Test func transferModeAndConflictDecisionAreEquatable() {
    assertEquatable(TransferMode.copy, .copy)
    assertEquatable(ConflictDecision.keepBoth, .keepBoth)
}

@Test func fileOperationResultPreservesAndMergesVerificationReports() throws {
    let report = TransferVerificationReport(
        verifiedFileCount: 2,
        verifiedLogicalByteCount: 1_048_576,
        noByteTransferItemCount: 1,
        failedVerificationItemCount: 0
    )
    let source = URL(filePath: "/private/source/Report.txt")
    let path = try ComparisonRelativePath(components: ["Report.txt"])
    let result = FileOperationResult(
        outcomes: [.succeeded(source: source, destination: nil)],
        verificationReport: report
    )

    let withPath = result.addingSafeRelativePaths([source: path])
    let mergedWithAbsent = result.merging(FileOperationResult(outcomes: []))
    let mergedReport = result.merging(FileOperationResult(
        outcomes: [],
        verificationReport: TransferVerificationReport(
            verifiedFileCount: 3,
            verifiedLogicalByteCount: 2,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 1
        )
    ))

    #expect(withPath.verificationReport == report)
    #expect(mergedWithAbsent.verificationReport == report)
    #expect(mergedReport.verificationReport == TransferVerificationReport(
        verifiedFileCount: 5,
        verifiedLogicalByteCount: 1_048_578,
        noByteTransferItemCount: 1,
        failedVerificationItemCount: 1
    ))
    #expect(FileOperationResult(outcomes: [], verificationReport: nil)
        != FileOperationResult(outcomes: [], verificationReport: .init(
            verifiedFileCount: 0,
            verifiedLogicalByteCount: 0,
            noByteTransferItemCount: 0,
            failedVerificationItemCount: 0
        )))
}

private func assertEquatable<Value: Equatable>(_ value: Value, _ expected: Value) {
    #expect(value == expected)
}
