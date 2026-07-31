import Foundation

enum ArchiveOperationKind: Sendable, Equatable {
    case compress
    case extract

    var title: String {
        switch self {
        case .compress: "Compressing"
        case .extract: "Extracting"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .compress: "Compressing ZIP archive"
        case .extract: "Extracting ZIP archive"
        }
    }
}

struct ArchiveOperationProgress: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let currentDisplayName: String
}

struct ArchiveRequest: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let verifiedSources: [URL]
    let finalDestination: URL
}

enum ArchiveOperationError: LocalizedError, Sendable, Equatable {
    case commandLaunch(String)
    case nonZeroTermination(status: Int32, standardError: String)
    case invalidRequest
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .commandLaunch(message):
            "The archive command could not be started: \(message)"
        case let .nonZeroTermination(status, standardError):
            if standardError.isEmpty {
                "The archive command failed with status \(status)."
            } else {
                "The archive command failed with status \(status): \(standardError)"
            }
        case .invalidRequest:
            "The archive request is invalid."
        case .cancelled:
            "The archive operation was cancelled."
        }
    }
}
