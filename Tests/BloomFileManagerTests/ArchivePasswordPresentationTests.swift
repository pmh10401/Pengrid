import Foundation
import SwiftUI
import Testing
@testable import BloomFileManager

@Suite("ArchivePasswordPresentationTests")
struct ArchivePasswordPresentationTests {
    @MainActor
    @Test func creationPresentationUsesExactPublicCopyAndNeverTheFieldValue() {
        let request = ArchivePasswordRequest(
            id: UUID(),
            purpose: .createAES256,
            archiveBasename: "/private/Secret Archive.zip\n",
            previousAttemptFailed: false
        )
        let presentation = ArchivePasswordSheet.presentation(
            for: request,
            locale: Locale(identifier: "en")
        )

        #expect(presentation.title == "Create Password-Protected ZIP")
        #expect(presentation.subtitle == "Secret Archive.zip")
        #expect(presentation.aesWarning == "AES-256 encryption protects the contents of this ZIP archive.")
        #expect(presentation.filenameVisibilityNote == "Filenames remain visible in a protected ZIP archive.")
        #expect(presentation.lengthNote == "Use at least 8 bytes. A 12-character passphrase is recommended.")
        #expect(presentation.genericDamageError == "The password is incorrect or the encrypted data is damaged.")
        #expect(!presentation.accessibilityLabel.contains("Secret-passphrase"))
        #expect(presentation.subtitle.contains("/private") == false)
    }

    @MainActor
    @Test func extractionPresentationUsesFilenameOnlyAndPreviousAttemptMessage() {
        let request = ArchivePasswordRequest(
            id: UUID(),
            purpose: .extract,
            archiveBasename: "/private/Secret Archive.zip",
            previousAttemptFailed: true
        )
        let presentation = ArchivePasswordSheet.presentation(
            for: request,
            locale: Locale(identifier: "ko")
        )

        #expect(presentation.title == "압축 파일 암호 입력")
        #expect(presentation.subtitle == "Secret Archive.zip")
        #expect(presentation.aesWarning == nil)
        #expect(presentation.genericDamageError == "암호가 올바르지 않거나 암호화된 데이터가 손상되었습니다.")
        #expect(presentation.lengthNote == "암호는 UTF-8 기준 1~1,024바이트여야 합니다.")
        #expect(presentation.filenameVisibilityNote == "보호된 ZIP에서도 파일 이름은 표시됩니다.")
    }

    @Test func liveFormStateUsesModeSpecificFieldsFocusValidationAndClearing() {
        let sentinel = "form-sentinel"
        var creation = ArchivePasswordFormState(
            purpose: .createAES256,
            password: sentinel,
            confirmation: sentinel
        )
        #expect(creation.secureFieldCount == 2)
        #expect(creation.firstFocusTarget == .password)
        #expect(creation.canSubmit)
        let creationSubmission = creation.captureAndClear()
        #expect(creation.password.isEmpty)
        #expect(creation.confirmation.isEmpty)
        #expect(creationSubmission.password == sentinel)
        #expect(creationSubmission.confirmation == sentinel)
        #expect(String(reflecting: creation).contains(sentinel) == false)

        var extraction = ArchivePasswordFormState(
            purpose: .extract,
            password: sentinel,
            confirmation: "ignored"
        )
        #expect(extraction.secureFieldCount == 1)
        #expect(extraction.firstFocusTarget == .password)
        #expect(extraction.canSubmit)
        let extractionSubmission = extraction.captureAndClear()
        #expect(extraction.password.isEmpty)
        #expect(extraction.confirmation.isEmpty)
        #expect(extractionSubmission.password == sentinel)
        #expect(extractionSubmission.confirmation == nil)
        #expect(String(reflecting: extraction).contains(sentinel) == false)

        #expect(ArchivePasswordFormState(
            purpose: .createAES256,
            password: "short",
            confirmation: "short"
        ).canSubmit == false)
        #expect(ArchivePasswordFormState(
            purpose: .extract,
            password: "before\0after",
            confirmation: ""
        ).canSubmit == false)
    }

    @Test func presentationAndAccessibilityNeverReflectFormSentinel() {
        let request = ArchivePasswordRequest(
            id: UUID(),
            purpose: .extract,
            archiveBasename: "/private/Archive.zip",
            previousAttemptFailed: false
        )
        let presentation = ArchivePasswordSheet.presentation(for: request, locale: Locale(identifier: "en"))
        let rendered = String(reflecting: presentation)
        #expect(rendered.contains("form-sentinel") == false)
        #expect(presentation.accessibilityLabel.contains("form-sentinel") == false)
        #expect(presentation.passwordLabel == "Password")
        #expect(presentation.confirmationLabel == "Confirm Password")
        #expect(presentation.cancelLabel == "Cancel")
        #expect(presentation.submitLabel == "Unlock")
    }

    @Test func presentationSourceUsesSecureFieldsKeyboardPathsAndNarrowIdentifiers() throws {
        let source = try source(named: "Views/ArchivePasswordSheet.swift")
        #expect(source.contains("SecureField"))
        #expect(source.contains("@FocusState"))
        #expect(source.contains(".keyboardShortcut(.defaultAction)"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains(".onKeyPress(.return)"))
        #expect(source.contains(".onKeyPress(.escape)"))
        #expect(source.contains("AccessibilityIdentifiers.archivePasswordSheet"))
        #expect(source.contains("AccessibilityIdentifiers.archivePasswordField"))
        #expect(source.contains("AccessibilityIdentifiers.archivePasswordConfirmationField"))
        #expect(source.contains("AccessibilityIdentifiers.archivePasswordValidation"))
        #expect(source.contains("AccessibilityIdentifiers.archivePasswordSubmit"))
        #expect(source.contains("AccessibilityIdentifiers.archivePasswordCancel"))
        #expect(source.contains("formState.firstFocusTarget"))
        #expect(source.contains("password = \"\""))
        #expect(source.contains("confirmation = \"\""))
        #expect(source.contains("requestID: request.id"))
        #expect(source.contains("if let aesWarning = copy.aesWarning"))
        #expect(source.contains("pasteboard") == false)
        #expect(source.contains("remember") == false)
        #expect(source.contains("hint") == false)
    }

    @Test func accessibilityIdentifiersRemainStableAndDoNotEncodeSecrets() {
        let identifiers = [
            AccessibilityIdentifiers.archivePasswordSheet,
            AccessibilityIdentifiers.archivePasswordField,
            AccessibilityIdentifiers.archivePasswordConfirmationField,
            AccessibilityIdentifiers.archivePasswordValidation,
            AccessibilityIdentifiers.archivePasswordSubmit,
            AccessibilityIdentifiers.archivePasswordCancel
        ]
        #expect(identifiers == [
            "archivePasswordSheet",
            "archivePassword.field",
            "archivePassword.confirmationField",
            "archivePassword.validation",
            "archivePassword.submit",
            "archivePassword.cancel"
        ])
        #expect(identifiers.allSatisfy { !$0.contains("password-value") })
    }

    private func source(named relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot
            .appending(path: "Sources/BloomFileManager", directoryHint: .isDirectory)
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
