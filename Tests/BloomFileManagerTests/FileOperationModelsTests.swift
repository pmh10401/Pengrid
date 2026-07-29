import Testing
@testable import BloomFileManager

@Test func transferModeAndConflictDecisionAreEquatable() {
    assertEquatable(TransferMode.copy, .copy)
    assertEquatable(ConflictDecision.keepBoth, .keepBoth)
}

private func assertEquatable<Value: Equatable>(_ value: Value, _ expected: Value) {
    #expect(value == expected)
}
