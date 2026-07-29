import Foundation
import Testing
@testable import BloomFileManager

@Test func filenameValidationRejectsUnsafeNames() {
    #expect(throws: FilenameError.empty) { try FilenameValidator.validate("   ") }
    #expect(throws: FilenameError.containsPathSeparator) { try FilenameValidator.validate("a/b") }
    #expect(throws: FilenameError.dotEntry) { try FilenameValidator.validate(".") }
    #expect(throws: FilenameError.dotEntry) { try FilenameValidator.validate("..") }
}

@Test func keepBothPreservesExtensionAndUsesFirstAvailableNumber() {
    let existing: Set<String> = ["Report.pdf", "Report 2.pdf"]
    #expect(KeepBothNamer.availableName(for: "Report.pdf", existing: existing) == "Report 3.pdf")
}

@Test func keepBothUsesSecondSuffixForDirectExtensionCollision() {
    #expect(KeepBothNamer.availableName(for: "Report.pdf", existing: ["Report.pdf"]) == "Report 2.pdf")
}

@Test func keepBothUsesSecondSuffixForExtensionlessCollision() {
    #expect(KeepBothNamer.availableName(for: "Name", existing: ["Name"]) == "Name 2")
}
