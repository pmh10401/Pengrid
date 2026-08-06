import Foundation

enum ProtectedZIPStrings {
    static func message(
        for error: ProtectedZIPError,
        locale: Locale = .current
    ) -> String {
        if isKorean(locale) {
            return koreanMessage(for: error)
        }
        return englishMessage(for: error)
    }

    static func message(
        for state: ArchivePasswordValidationError,
        locale: Locale = .current
    ) -> String {
        if isKorean(locale) {
            return koreanMessage(for: state)
        }
        return englishMessage(for: state)
    }

    static func passwordValidationMessage(
        for state: ArchivePasswordValidationError,
        locale: Locale = .current
    ) -> String {
        message(for: state, locale: locale)
    }

    private static func englishMessage(for error: ProtectedZIPError) -> String {
        switch error {
        case .invalidPasswordInput:
            "The password could not be used."
        case .incorrectPasswordOrDamagedData:
            "The password is incorrect or the encrypted data is damaged."
        case .unsupportedEncryption:
            "The archive uses unsupported encryption."
        case .unsupportedCompression:
            "The archive uses unsupported compression."
        case .malformedArchive:
            "The archive is malformed."
        case .unsafeEntry:
            "The archive contains an unsafe item."
        case .entryCountOverflow:
            "The archive contains too many items."
        case .insufficientCapacity:
            "There is not enough free space to safely complete this operation."
        case .outputBudgetOverflow:
            "The archive exceeds the allowed output size."
        case .identityChanged:
            "The archive changed while it was being processed."
        case .cancelled:
            "The archive operation was cancelled."
        case .recoveryRequired:
            "Archive cleanup could not finish safely and requires recovery review."
        }
    }

    private static func koreanMessage(for error: ProtectedZIPError) -> String {
        switch error {
        case .invalidPasswordInput:
            "암호를 사용할 수 없습니다."
        case .incorrectPasswordOrDamagedData:
            "암호가 올바르지 않거나 암호화된 데이터가 손상되었습니다."
        case .unsupportedEncryption:
            "압축 파일에 지원되지 않는 암호화 방식이 사용되었습니다."
        case .unsupportedCompression:
            "압축 파일에 지원되지 않는 압축 방식이 사용되었습니다."
        case .malformedArchive:
            "압축 파일 형식이 올바르지 않습니다."
        case .unsafeEntry:
            "압축 파일에 안전하지 않은 항목이 있습니다."
        case .entryCountOverflow:
            "압축 파일에 항목이 너무 많습니다."
        case .insufficientCapacity:
            "이 작업을 안전하게 완료할 수 있는 여유 공간이 부족합니다."
        case .outputBudgetOverflow:
            "압축 파일이 허용된 출력 크기를 초과합니다."
        case .identityChanged:
            "처리하는 동안 압축 파일이 변경되었습니다."
        case .cancelled:
            "압축 작업이 취소되었습니다."
        case .recoveryRequired:
            "압축 정리를 안전하게 완료하지 못해 복구 검토가 필요합니다."
        }
    }

    private static func englishMessage(for state: ArchivePasswordValidationError) -> String {
        switch state {
        case .empty:
            "Enter a password."
        case .invalidLength:
            "The password length is not supported."
        case .tooShort:
            "The password is too short."
        case .tooLong:
            "The password is too long."
        case .containsNull:
            "The password contains an unsupported character."
        case .confirmationMismatch:
            "The passwords do not match."
        }
    }

    private static func koreanMessage(for state: ArchivePasswordValidationError) -> String {
        switch state {
        case .empty:
            "암호를 입력하세요."
        case .invalidLength:
            "암호 길이가 지원 범위를 벗어났습니다."
        case .tooShort:
            "암호가 너무 짧습니다."
        case .tooLong:
            "암호가 너무 깁니다."
        case .containsNull:
            "암호에 지원되지 않는 문자가 있습니다."
        case .confirmationMismatch:
            "암호가 일치하지 않습니다."
        }
    }

    private static func isKorean(_ locale: Locale) -> Bool {
        let identifier = locale.identifier.lowercased()
        return identifier == "ko"
            || identifier.hasPrefix("ko-")
            || identifier.hasPrefix("ko_")
    }
}
