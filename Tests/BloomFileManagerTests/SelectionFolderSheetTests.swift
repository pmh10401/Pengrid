import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SelectionFolderSheetTests {
    @Test func presentationUsesDynamicItemCountAndValidationState() {
        let ready = SelectionFolderSheetPresentation(itemCount: 3, validationMessage: nil)
        let invalid = SelectionFolderSheetPresentation(
            itemCount: 2,
            validationMessage: "A folder named Existing already exists."
        )

        #expect(ready.title == "New Folder with 3 Items")
        #expect(ready.submitTitle == "Create Folder")
        #expect(ready.isSubmitEnabled)
        #expect(invalid.title == "New Folder with 2 Items")
        #expect(invalid.validationMessage == "A folder named Existing already exists.")
        #expect(!invalid.isSubmitEnabled)
    }

    @Test func initialFocusTargetsFolderName() {
        #expect(SelectionFolderFocusRouting.initialTarget == .folderName)
    }

    @Test func sheetExposesKeyboardAccessibilityAndDisabledSubmitContracts() throws {
        #expect(AccessibilityIdentifiers.selectionFolderSheet == "selectionFolder.sheet")
        #expect(AccessibilityIdentifiers.selectionFolderName == "selectionFolder.name")
        #expect(AccessibilityIdentifiers.selectionFolderValidation == "selectionFolder.validation")
        #expect(AccessibilityIdentifiers.selectionFolderSubmit == "selectionFolder.submit")
        #expect(AccessibilityIdentifiers.selectionFolderCancel == "selectionFolder.cancel")

        let source = try selectionFolderSource()
        #expect(source.contains(".focused($focusedField, equals: .folderName)"))
        #expect(source.contains(".keyboardShortcut(.defaultAction)"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains(".disabled(!model.canSubmit)"))
    }

    private func selectionFolderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appending(path: "Sources/BloomFileManager/Views/SelectionFolderSheet.swift"),
            encoding: .utf8
        )
    }
}
