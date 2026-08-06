import SwiftUI

enum ArchivePasswordFormField: Hashable, Sendable {
    case password
    case confirmation
}

struct ArchivePasswordSubmission: Equatable, Sendable {
    let password: String
    let confirmation: String?
}

struct ArchivePasswordFormState: Equatable, Sendable {
    let purpose: ArchivePasswordPurpose
    var password: String
    var confirmation: String

    init(
        purpose: ArchivePasswordPurpose,
        password: String = "",
        confirmation: String = ""
    ) {
        self.purpose = purpose
        self.password = password
        self.confirmation = confirmation
    }

    var secureFieldCount: Int {
        purpose == .createAES256 ? 2 : 1
    }

    var firstFocusTarget: ArchivePasswordFormField {
        .password
    }

    var canSubmit: Bool {
        guard Self.isValid(password, purpose: purpose) else { return false }
        guard purpose == .createAES256 else { return true }
        return Self.isValid(confirmation, purpose: .createAES256)
            && password == confirmation
    }

    mutating func captureAndClear() -> ArchivePasswordSubmission {
        let submission = ArchivePasswordSubmission(
            password: password,
            confirmation: purpose == .createAES256 ? confirmation : nil
        )
        password = ""
        confirmation = ""
        return submission
    }

    static func isValid(
        _ input: String,
        purpose: ArchivePasswordPurpose
    ) -> Bool {
        guard !input.isEmpty,
              input.unicodeScalars.allSatisfy({ $0.value != 0 }) else {
            return false
        }
        let byteCount = input.utf8.count
        switch purpose {
        case .createAES256:
            return (8...256).contains(byteCount)
        case .extract:
            return (1...1_024).contains(byteCount)
        }
    }

    mutating func submit(
        using callback: (ArchivePasswordFormState, ArchivePasswordSubmission) -> Void
    ) -> Bool {
        guard canSubmit else { return false }
        let submission = captureAndClear()
        callback(self, submission)
        return true
    }

    mutating func cancel(
        using callback: (ArchivePasswordFormState) -> Void
    ) {
        password = ""
        confirmation = ""
        callback(self)
    }
}

struct ArchivePasswordSheet: View {
    struct Presentation: Equatable, Sendable {
        let title: String
        let subtitle: String
        let aesWarning: String?
        let filenameVisibilityNote: String
        let lengthNote: String
        let genericDamageError: String
        let accessibilityLabel: String
        let passwordLabel: String
        let confirmationLabel: String
        let cancelLabel: String
        let submitLabel: String
    }

    struct AccessibilityProjection: Equatable, Sendable {
        let containerLabel: String
        let containerIdentifier: String
        let passwordLabel: String
        let passwordIdentifier: String
        let confirmationLabel: String
        let confirmationIdentifier: String
        let validationLabel: String
        let validationIdentifier: String
        let cancelLabel: String
        let cancelIdentifier: String
        let submitLabel: String
        let submitIdentifier: String
        let confirmationVisible: Bool

        init(
            request: ArchivePasswordRequest,
            presentation: Presentation
        ) {
            containerLabel = presentation.accessibilityLabel
            containerIdentifier = AccessibilityIdentifiers.archivePasswordSheet
            passwordLabel = presentation.passwordLabel
            passwordIdentifier = AccessibilityIdentifiers.archivePasswordField
            confirmationLabel = presentation.confirmationLabel
            confirmationIdentifier = AccessibilityIdentifiers.archivePasswordConfirmationField
            validationLabel = request.previousAttemptFailed
                ? presentation.genericDamageError
                : "Validation"
            validationIdentifier = AccessibilityIdentifiers.archivePasswordValidation
            cancelLabel = presentation.cancelLabel
            cancelIdentifier = AccessibilityIdentifiers.archivePasswordCancel
            submitLabel = presentation.submitLabel
            submitIdentifier = AccessibilityIdentifiers.archivePasswordSubmit
            confirmationVisible = request.purpose == .createAES256
        }
    }

    let request: ArchivePasswordRequest
    let coordinator: ArchivePasswordPromptCoordinator

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: ArchivePasswordFormField?
    @State private var password = ""
    @State private var confirmation = ""

    init(
        request: ArchivePasswordRequest,
        coordinator: ArchivePasswordPromptCoordinator
    ) {
        self.request = request
        self.coordinator = coordinator
    }

    nonisolated static func presentation(
        for request: ArchivePasswordRequest,
        locale: Locale = .current
    ) -> Presentation {
        let korean = isKorean(locale)
        let creation = request.purpose == .createAES256
        let title: String
        let warning: String?
        let filenameNote: String
        let length: String
        let passwordLabel: String
        let confirmationLabel: String
        let cancelLabel: String
        let submitLabel: String
        if korean {
            title = creation ? "암호로 ZIP 보호" : "압축 파일 암호 입력"
            warning = creation
                ? "AES-256 암호화는 이 ZIP 파일의 내용을 보호합니다."
                : nil
            filenameNote = "보호된 ZIP에서도 파일 이름은 표시됩니다."
            length = creation
                ? "암호는 UTF-8 기준 8바이트 이상이어야 하며 12자 암호를 권장합니다."
                : "암호는 UTF-8 기준 1~1,024바이트여야 합니다."
            passwordLabel = "암호"
            confirmationLabel = "암호 확인"
            cancelLabel = "취소"
            submitLabel = creation ? "압축" : "잠금 해제"
        } else {
            title = creation ? "Create Password-Protected ZIP" : "Enter Archive Password"
            warning = creation
                ? "AES-256 encryption protects the contents of this ZIP archive."
                : nil
            filenameNote = "Filenames remain visible in a protected ZIP archive."
            length = creation
                ? "Use at least 8 bytes. A 12-character passphrase is recommended."
                : "Passwords must be 1–1,024 UTF-8 bytes."
            passwordLabel = "Password"
            confirmationLabel = "Confirm Password"
            cancelLabel = "Cancel"
            submitLabel = creation ? "Compress" : "Unlock"
        }

        return Presentation(
            title: title,
            subtitle: request.archiveBasename,
            aesWarning: warning,
            filenameVisibilityNote: filenameNote,
            lengthNote: length,
            genericDamageError: ProtectedZIPStrings.message(
                for: .incorrectPasswordOrDamagedData,
                locale: locale
            ),
            accessibilityLabel: korean ? "암호 입력" : "Archive password prompt",
            passwordLabel: passwordLabel,
            confirmationLabel: confirmationLabel,
            cancelLabel: cancelLabel,
            submitLabel: submitLabel
        )
    }

    var body: some View {
        let copy = Self.presentation(for: request)
        let accessibility = AccessibilityProjection(request: request, presentation: copy)

        VStack(alignment: .leading, spacing: 14) {
            Text(copy.title)
                .font(.title2.weight(.semibold))

            Text(copy.subtitle)
                .font(.body.weight(.medium))
                .lineLimit(1)

            if let aesWarning = copy.aesWarning {
                Text(aesWarning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(copy.filenameVisibilityNote)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(copy.lengthNote)
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField(copy.passwordLabel, text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
                .accessibilityLabel(accessibility.passwordLabel)
                .accessibilityIdentifier(accessibility.passwordIdentifier)
                .onSubmit { submitIfValid() }

            if accessibility.confirmationVisible {
                SecureField(copy.confirmationLabel, text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .confirmation)
                    .accessibilityLabel(accessibility.confirmationLabel)
                    .accessibilityIdentifier(accessibility.confirmationIdentifier)
                    .onSubmit { submitIfValid() }
            }

            if request.previousAttemptFailed {
                Text(copy.genericDamageError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel(accessibility.validationLabel)
                    .accessibilityIdentifier(accessibility.validationIdentifier)
            }

            if let validationError = coordinator.validationError {
                Text(ProtectedZIPStrings.passwordValidationMessage(for: validationError))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel(accessibility.validationLabel)
                    .accessibilityIdentifier(accessibility.validationIdentifier)
            }

            HStack {
                Button(accessibility.cancelLabel, role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(accessibility.cancelIdentifier)

                Spacer()

                Button(accessibility.submitLabel) {
                    _ = submitFromButton()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!formState.canSubmit)
                .accessibilityIdentifier(accessibility.submitIdentifier)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility.containerLabel)
        .accessibilityIdentifier(accessibility.containerIdentifier)
        .onAppear {
            focusedField = formState.firstFocusTarget
        }
        .onKeyPress(.return) {
            guard submitFromKeyboard() else { return .ignored }
            return .handled
        }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
    }

    private var formState: ArchivePasswordFormState {
        ArchivePasswordFormState(
            purpose: request.purpose,
            password: password,
            confirmation: confirmation
        )
    }

    private func submitIfValid() {
        _ = submitFromKeyboard()
    }

    private func submitFromKeyboard() -> Bool {
        submitForm()
    }

    private func submitFromButton() -> Bool {
        submitForm()
    }

    private func submitForm() -> Bool {
        var state = formState
        return state.submit(using: { clearedState, submission in
            password = clearedState.password
            confirmation = clearedState.confirmation
            coordinator.submit(
                password: submission.password,
                confirmation: submission.confirmation,
                requestID: request.id
            )
        })
    }

    private func cancel() {
        var state = formState
        state.cancel(using: { clearedState in
            password = clearedState.password
            confirmation = clearedState.confirmation
            coordinator.cancel(requestID: request.id)
            dismiss()
        })
    }

    private nonisolated static func isKorean(_ locale: Locale) -> Bool {
        let identifier = locale.identifier.lowercased()
        return identifier == "ko"
            || identifier.hasPrefix("ko-")
            || identifier.hasPrefix("ko_")
    }
}
