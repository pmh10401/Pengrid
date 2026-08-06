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

    @Test func creationFormStateBoundariesDriveButtonDisabledAndReturnGuard() {
        let cases: [(
            password: String,
            confirmation: String,
            fieldsValid: Bool,
            canSubmit: Bool
        )] = [
            (String(repeating: "a", count: 7), String(repeating: "a", count: 7), false, false),
            (String(repeating: "a", count: 8), String(repeating: "a", count: 8), true, true),
            (String(repeating: "a", count: 256), String(repeating: "a", count: 256), true, true),
            (String(repeating: "a", count: 257), String(repeating: "a", count: 257), false, false),
            ("abcdefgh\0", "abcdefgh\0", false, false),
            ("abcdefgh", "abcdefgi", true, false)
        ]

        for entry in cases {
            let state = ArchivePasswordFormState(
                purpose: .createAES256,
                password: entry.password,
                confirmation: entry.confirmation
            )
            #expect(
                ArchivePasswordFormState.isValid(entry.password, purpose: .createAES256)
                    == entry.fieldsValid &&
                ArchivePasswordFormState.isValid(entry.confirmation, purpose: .createAES256)
                    == entry.fieldsValid
            )
            #expect(state.canSubmit == entry.canSubmit)
            #expect((!state.canSubmit) == (!entry.canSubmit))

            var returnState = state
            var callbackSubmission: ArchivePasswordSubmission?
            let returnHandled = returnState.submit(using: { _, submission in
                callbackSubmission = submission
            })
            #expect(returnHandled == entry.canSubmit)
            #expect((callbackSubmission != nil) == entry.canSubmit)
        }
    }

    @Test func extractionFormStateBoundariesDriveButtonDisabledAndReturnGuard() {
        let cases: [(password: String, valid: Bool)] = [
            ("", false),
            ("a", true),
            (String(repeating: "a", count: 1_024), true),
            (String(repeating: "a", count: 1_025), false),
            ("a\0b", false)
        ]

        for entry in cases {
            let state = ArchivePasswordFormState(
                purpose: .extract,
                password: entry.password
            )
            #expect(
                ArchivePasswordFormState.isValid(entry.password, purpose: .extract)
                    == entry.valid
            )
            #expect(state.canSubmit == entry.valid)
            #expect((!state.canSubmit) == (!entry.valid))

            var returnState = state
            var callbackSubmission: ArchivePasswordSubmission?
            let returnHandled = returnState.submit(using: { _, submission in
                callbackSubmission = submission
            })
            #expect(returnHandled == entry.valid)
            #expect((callbackSubmission != nil) == entry.valid)
        }
    }

    @Test func liveSubmitAndCancelHelpersClearBeforeCallbacks() {
        let sentinel = "form-sentinel"
        var form = ArchivePasswordFormState(
            purpose: .createAES256,
            password: sentinel,
            confirmation: sentinel
        )
        var submitObservedCleared = false
        var submitted: ArchivePasswordSubmission?
        let didSubmit = form.submit(using: { clearedState, submission in
            submitObservedCleared = clearedState.password.isEmpty
                && clearedState.confirmation.isEmpty
            submitted = submission
        })
        #expect(didSubmit)
        #expect(submitObservedCleared)
        #expect(form.password.isEmpty)
        #expect(form.confirmation.isEmpty)
        #expect(submitted?.password == sentinel)
        #expect(submitted?.confirmation == sentinel)

        var cancelForm = ArchivePasswordFormState(
            purpose: .createAES256,
            password: sentinel,
            confirmation: sentinel
        )
        var cancelObservedCleared = false
        cancelForm.cancel(using: { clearedState in
            cancelObservedCleared = clearedState.password.isEmpty
                && clearedState.confirmation.isEmpty
        })
        #expect(cancelObservedCleared)
        #expect(cancelForm.password.isEmpty)
        #expect(cancelForm.confirmation.isEmpty)
    }

    @Test func liveAccessibilityProjectionNeverReflectsFormSentinel() {
        let sentinel = "form-sentinel"
        let request = ArchivePasswordRequest(
            id: UUID(),
            purpose: .createAES256,
            archiveBasename: "Archive.zip",
            previousAttemptFailed: true
        )
        let presentation = ArchivePasswordSheet.presentation(
            for: request,
            locale: Locale(identifier: "en")
        )
        let projection = ArchivePasswordSheet.AccessibilityProjection(
            request: request,
            presentation: presentation
        )
        let form = ArchivePasswordFormState(
            purpose: request.purpose,
            password: sentinel,
            confirmation: sentinel
        )

        #expect(mirrorContainsSentinel(projection, sentinel: sentinel) == false)
        #expect(mirrorContainsSentinel(presentation, sentinel: sentinel) == false)
        #expect(mirrorContainsSentinel(form, sentinel: sentinel))
        #expect(projection.containerLabel == presentation.accessibilityLabel)
        #expect(projection.passwordLabel == presentation.passwordLabel)
        #expect(projection.passwordIdentifier == AccessibilityIdentifiers.archivePasswordField)
        #expect(projection.confirmationIdentifier == AccessibilityIdentifiers.archivePasswordConfirmationField)
        #expect(projection.validationIdentifier == AccessibilityIdentifiers.archivePasswordValidation)
        #expect(projection.submitIdentifier == AccessibilityIdentifiers.archivePasswordSubmit)
        #expect(projection.cancelIdentifier == AccessibilityIdentifiers.archivePasswordCancel)
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
        #expect(source.contains("AccessibilityProjection(request: request, presentation: copy)"))
        #expect(source.contains("submitFromKeyboard()"))
        #expect(source.contains("submit(using:"))
        #expect(source.contains("cancel(using:"))
        #expect(source.contains(".disabled(!formState.canSubmit)"))
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

    private func mirrorContainsSentinel(
        _ value: Any,
        sentinel: String,
        depth: Int = 0,
        visited: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard depth < 12 else { return false }
        if Mirror(reflecting: value).displayStyle == .class,
           let object = value as AnyObject? {
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return false }
        }
        if String(reflecting: value).contains(sentinel) { return true }
        for child in Mirror(reflecting: value).children {
            if mirrorContainsSentinel(
                child.value,
                sentinel: sentinel,
                depth: depth + 1,
                visited: &visited
            ) {
                return true
            }
        }
        return false
    }

    private func mirrorContainsSentinel(_ value: Any, sentinel: String) -> Bool {
        var visited = Set<ObjectIdentifier>()
        return mirrorContainsSentinel(value, sentinel: sentinel, visited: &visited)
    }
}
