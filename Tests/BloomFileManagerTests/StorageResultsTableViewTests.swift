import AppKit
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct StorageResultsTableViewTests {
    @Test func structuralUpdateAlsoReloadsChangedRetainedRow() throws {
        let first = try row(path: ["A.txt"], verification: "Not verified")
        let second = try row(path: ["B.txt"], verification: "Not verified")
        let changedSecond = try row(path: ["B.txt"], verification: "Verified duplicate")
        let inserted = try row(path: ["C.txt"], verification: "Not verified")

        let plan = StorageResultsTableUpdatePlan.make(
            from: [first, second],
            to: [first, changedSecond, inserted]
        )

        #expect(plan.removals.isEmpty)
        #expect(plan.insertions == IndexSet(integer: 2))
        #expect(plan.cellReloads == [
            StorageResultCellReload(
                rows: IndexSet(integer: 1),
                columns: IndexSet(integer: 5)
            )
        ])
    }

    @MainActor
    @Test func duplicateMemberTableIsAStableKeyboardNavigationTarget() {
        let table = StorageResultsNSTableView()

        #expect(table.acceptsFirstResponder)
        #expect(StorageResultsAccessibilityPresentation.identifier(
            section: .duplicates
        ) == AccessibilityIdentifiers.storageInspectorGroupMembers)
        #expect(StorageResultsAccessibilityPresentation.label(
            section: .duplicates
        ) == "Duplicate group members")
    }

    private func row(
        path components: [String],
        verification: String
    ) throws -> StorageResultRow {
        let path = try StorageRelativePath(components: components)
        return StorageResultRow(
            id: path,
            name: components.last!,
            relativeParent: "Top level",
            sizeText: "4 KB",
            modifiedText: "Jan 2, 2025 at 3:04 AM",
            categoryText: "Document",
            verificationText: verification,
            accessibilityLabel: "\(components.last!), Top level, 4 KB, "
                + "Jan 2, 2025 at 3:04 AM, Document, \(verification)"
        )
    }
}
