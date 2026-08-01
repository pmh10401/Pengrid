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
    let format: ArchiveFormat

    init(
        kind: ArchiveOperationKind,
        currentDisplayName: String,
        format: ArchiveFormat = .zip
    ) {
        self.kind = kind
        self.currentDisplayName = currentDisplayName
        self.format = format
    }
}

struct ArchiveRequest: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let verifiedSources: [URL]
    let finalDestination: URL
    let progressDisplayName: String
    let format: ArchiveFormat

    init(
        kind: ArchiveOperationKind,
        verifiedSources: [URL],
        finalDestination: URL,
        progressDisplayName: String? = nil,
        format: ArchiveFormat = .zip
    ) {
        self.kind = kind
        self.verifiedSources = verifiedSources
        self.finalDestination = finalDestination
        self.format = format
        if let progressDisplayName {
            self.progressDisplayName = progressDisplayName
        } else {
            self.progressDisplayName = switch kind {
            case .compress:
                finalDestination.lastPathComponent
            case .extract:
                verifiedSources.first?.lastPathComponent
                    ?? finalDestination.lastPathComponent
            }
        }
    }
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
