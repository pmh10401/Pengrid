import SwiftUI

struct ArchivePasswordSheet: View {
    struct Presentation: Equatable, Sendable {
        let title: String
        let subtitle: String
        let aesWarning: String
        let filenameVisibilityNote: String
        let lengthNote: String
        let genericDamageError: String
        let accessibilityLabel: String
        let passwordLabel: String
        let confirmationLabel: String
        let cancelLabel: String
        let submitLabel: String
    }

    private enum Field: Hashable {
        case password
        case confirmation
    }

    let request: ArchivePasswordRequest
    let coordinator: ArchivePasswordPromptCoordinator

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
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
        let warning: String
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
                : "이 ZIP 파일은 AES-256 암호화를 사용합니다."
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
                : "This ZIP archive uses AES-256 encryption."
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

        VStack(alignment: .leading, spacing: 14) {
            Text(copy.title)
                .font(.title2.weight(.semibold))

            Text(copy.subtitle)
                .font(.body.weight(.medium))
                .lineLimit(1)

            if request.purpose == .createAES256 {
                Text(copy.aesWarning)
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
                .accessibilityLabel(copy.passwordLabel)
                .accessibilityIdentifier(AccessibilityIdentifiers.archivePasswordField)
                .onSubmit { submitIfValid() }

            if request.purpose == .createAES256 {
                SecureField(copy.confirmationLabel, text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .confirmation)
                    .accessibilityLabel(copy.confirmationLabel)
                    .accessibilityIdentifier(
                        AccessibilityIdentifiers.archivePasswordConfirmationField
                    )
                    .onSubmit { submitIfValid() }
            }

            if request.previousAttemptFailed {
                Text(copy.genericDamageError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityIdentifiers.archivePasswordValidation)
            }

            if let validationError = coordinator.validationError {
                Text(ProtectedZIPStrings.passwordValidationMessage(for: validationError))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityIdentifiers.archivePasswordValidation)
            }

            HStack {
                Button(copy.cancelLabel, role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityIdentifiers.archivePasswordCancel)

                Spacer()

                Button(copy.submitLabel) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasRequiredInput)
                .accessibilityIdentifier(AccessibilityIdentifiers.archivePasswordSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.accessibilityLabel)
        .accessibilityIdentifier(AccessibilityIdentifiers.archivePasswordSheet)
        .onAppear {
            focusedField = .password
        }
        .onKeyPress(.return) {
            guard canSubmit else { return .ignored }
            submit()
            return .handled
        }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
    }

    private var hasRequiredInput: Bool {
        !password.isEmpty && (request.purpose == .extract || !confirmation.isEmpty)
    }

    private var canSubmit: Bool {
        guard hasRequiredInput,
              Self.isValid(password, purpose: request.purpose) else {
            return false
        }
        guard request.purpose == .createAES256 else { return true }
        return Self.isValid(confirmation, purpose: .createAES256) && password == confirmation
    }

    private func submitIfValid() {
        guard canSubmit else { return }
        submit()
    }

    private func submit() {
        let enteredPassword = password
        let enteredConfirmation = request.purpose == .createAES256 ? confirmation : nil
        password = ""
        confirmation = ""
        coordinator.submit(password: enteredPassword, confirmation: enteredConfirmation)
    }

    private func cancel() {
        password = ""
        confirmation = ""
        coordinator.cancel(requestID: request.id)
        dismiss()
    }

    private static func isValid(
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

    private nonisolated static func isKorean(_ locale: Locale) -> Bool {
        let identifier = locale.identifier.lowercased()
        return identifier == "ko"
            || identifier.hasPrefix("ko-")
            || identifier.hasPrefix("ko_")
    }
}
