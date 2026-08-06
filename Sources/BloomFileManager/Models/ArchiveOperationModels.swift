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

enum ArchiveOperationPhase: Sendable, Equatable {
    case preparingSources(completedCount: Int, totalCount: Int)
    case processingBytes(completedByteCount: Int64, totalByteCount: Int64?)
    case waitingForPassword
    case encoding
    case publishing
}

struct ArchiveOperationProgress: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let currentDisplayName: String
    let format: ArchiveFormat
    let phase: ArchiveOperationPhase

    init(
        kind: ArchiveOperationKind,
        currentDisplayName: String,
        format: ArchiveFormat = .zip,
        phase: ArchiveOperationPhase = .encoding
    ) {
        self.kind = kind
        self.currentDisplayName = currentDisplayName
        self.format = format
        self.phase = phase
    }

    var fractionCompleted: Double? {
        switch phase {
        case let .preparingSources(completedCount, totalCount):
            let safeTotal = max(totalCount, 0)
            guard safeTotal > 0 else { return 0 }
            let safeCompleted = min(max(completedCount, 0), safeTotal)
            return Double(safeCompleted) / Double(safeTotal)
        case let .processingBytes(completedByteCount, totalByteCount):
            guard let totalByteCount, totalByteCount > 0 else { return nil }
            let safeCompleted = min(max(completedByteCount, 0), totalByteCount)
            return Double(safeCompleted) / Double(totalByteCount)
        case .waitingForPassword, .encoding, .publishing:
            return nil
        }
    }
}

struct ArchiveRequest: Sendable, Equatable {
    let kind: ArchiveOperationKind
    let verifiedSources: [IdentifiedFileRequest]
    let finalDestination: URL
    let destinationParentIdentity: FileIdentity
    let progressDisplayName: String
    let format: ArchiveFormat
    let protection: ArchiveProtection

    init(
        kind: ArchiveOperationKind,
        verifiedSources: [IdentifiedFileRequest],
        finalDestination: URL,
        destinationParentIdentity: FileIdentity,
        progressDisplayName: String? = nil,
        format: ArchiveFormat = .zip
    ) {
        self.kind = kind
        self.verifiedSources = verifiedSources
        self.finalDestination = finalDestination
        self.destinationParentIdentity = destinationParentIdentity
        self.format = format
        self.protection = .none
        if let progressDisplayName {
            self.progressDisplayName = progressDisplayName
        } else {
            self.progressDisplayName = switch kind {
            case .compress:
                finalDestination.lastPathComponent
            case .extract:
                verifiedSources.first?.url.lastPathComponent
                    ?? finalDestination.lastPathComponent
            }
        }
    }

    init?(
        kind: ArchiveOperationKind,
        verifiedSources: [IdentifiedFileRequest],
        finalDestination: URL,
        destinationParentIdentity: FileIdentity,
        progressDisplayName: String? = nil,
        format: ArchiveFormat = .zip,
        protection: ArchiveProtection
    ) {
        guard protection == .none || (kind == .compress && format == .zip) else {
            return nil
        }
        self.kind = kind
        self.verifiedSources = verifiedSources
        self.finalDestination = finalDestination
        self.destinationParentIdentity = destinationParentIdentity
        self.format = format
        self.protection = protection
        if let progressDisplayName {
            self.progressDisplayName = progressDisplayName
        } else {
            self.progressDisplayName = switch kind {
            case .compress:
                finalDestination.lastPathComponent
            case .extract:
                verifiedSources.first?.url.lastPathComponent
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
    case recoveryRequired

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
        case .recoveryRequired:
            "Archive cleanup could not finish safely and requires recovery review."
        }
    }
}
