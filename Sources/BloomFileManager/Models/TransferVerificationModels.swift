import Foundation

enum TransferVerificationPolicy: Sendable, Equatable {
    case disabled
    case sha256(maxConcurrentPairs: Int)

    var effectivePairLimit: Int? {
        switch self {
        case .disabled:
            nil
        case let .sha256(maxConcurrentPairs):
            min(max(maxConcurrentPairs, 1), 2)
        }
    }
}

enum TransferVerificationPhase: Sendable, Equatable {
    case preparingManifest
    case hashing
    case finalValidation
}

struct TransferVerificationProgress: Sendable, Equatable {
    let phase: TransferVerificationPhase
    let fractionCompleted: Double
    let completedFileCount: Int
    let totalFileCount: Int
    let completedLogicalByteCount: Int64
    let totalLogicalByteCount: Int64
    let currentName: String

    init(
        phase: TransferVerificationPhase,
        fractionCompleted: Double,
        completedFileCount: Int,
        totalFileCount: Int,
        completedLogicalByteCount: Int64,
        totalLogicalByteCount: Int64,
        currentName: String
    ) {
        self.phase = phase
        self.fractionCompleted = Self.normalizedFraction(fractionCompleted)
        self.completedFileCount = max(completedFileCount, 0)
        self.totalFileCount = max(totalFileCount, 0)
        self.completedLogicalByteCount = max(completedLogicalByteCount, 0)
        self.totalLogicalByteCount = max(totalLogicalByteCount, 0)
        self.currentName = TransferVerificationModelSupport.basename(currentName)
    }

    private static func normalizedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

struct TransferVerificationSummary: Sendable, Equatable {
    let verifiedFileCount: Int
    let verifiedLogicalByteCount: Int64
    let noByteTransferItemCount: Int

    init(
        verifiedFileCount: Int,
        verifiedLogicalByteCount: Int64,
        noByteTransferItemCount: Int
    ) {
        self.verifiedFileCount = max(verifiedFileCount, 0)
        self.verifiedLogicalByteCount = max(verifiedLogicalByteCount, 0)
        self.noByteTransferItemCount = max(noByteTransferItemCount, 0)
    }
}

struct TransferVerificationReport: Sendable, Equatable {
    let verifiedFileCount: Int
    let verifiedLogicalByteCount: Int64
    let noByteTransferItemCount: Int
    let failedVerificationItemCount: Int

    init(
        verifiedFileCount: Int,
        verifiedLogicalByteCount: Int64,
        noByteTransferItemCount: Int,
        failedVerificationItemCount: Int
    ) {
        self.verifiedFileCount = max(verifiedFileCount, 0)
        self.verifiedLogicalByteCount = max(verifiedLogicalByteCount, 0)
        self.noByteTransferItemCount = max(noByteTransferItemCount, 0)
        self.failedVerificationItemCount = max(failedVerificationItemCount, 0)
    }

    func merging(_ other: Self) -> Self {
        Self(
            verifiedFileCount: Self.saturatedAdd(
                verifiedFileCount,
                other.verifiedFileCount
            ),
            verifiedLogicalByteCount: Self.saturatedAdd(
                verifiedLogicalByteCount,
                other.verifiedLogicalByteCount
            ),
            noByteTransferItemCount: Self.saturatedAdd(
                noByteTransferItemCount,
                other.noByteTransferItemCount
            ),
            failedVerificationItemCount: Self.saturatedAdd(
                failedVerificationItemCount,
                other.failedVerificationItemCount
            )
        )
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

enum TransferVerificationFailureCategory: String, Sendable, Equatable {
    case sourceChanged
    case stagedOutputChanged
    case structureMismatch
    case contentMismatch
    case unsupportedItem
    case unsupportedName
    case identityUnavailable
    case readFailed
    case scopeTooLarge
    case cancelled
}

struct TransferVerificationFailure: LocalizedError, Sendable, Equatable {
    let category: TransferVerificationFailureCategory
    let safeName: String?

    init(
        category: TransferVerificationFailureCategory,
        safeName: String? = nil
    ) {
        self.category = category
        self.safeName = safeName.flatMap(TransferVerificationModelSupport.optionalBasename)
    }

    var errorDescription: String? {
        let message: String = switch category {
        case .sourceChanged:
            "The source changed during verification"
        case .stagedOutputChanged:
            "The staged output changed during verification"
        case .structureMismatch:
            "The transferred structure does not match"
        case .contentMismatch:
            "The transferred content does not match"
        case .unsupportedItem:
            "The item is not supported for verification"
        case .unsupportedName:
            "The item name is not supported for verification"
        case .identityUnavailable:
            "The item identity is unavailable"
        case .readFailed:
            "The item could not be read for verification"
        case .scopeTooLarge:
            "The item exceeds the safe verification scope"
        case .cancelled:
            "Verification was cancelled"
        }
        if let safeName {
            return "\(message) for \(safeName)."
        }
        return "\(message)."
    }
}

struct TransferVerificationLogEvent: Sendable, Equatable {
    let enabled: Bool
    let verifiedFileCount: Int
    let verifiedLogicalByteCount: Int64
    let noByteTransferItemCount: Int
    let failedVerificationItemCount: Int
    let failureCategory: TransferVerificationFailureCategory?

    init(
        enabled: Bool,
        verifiedFileCount: Int,
        verifiedLogicalByteCount: Int64,
        noByteTransferItemCount: Int,
        failedVerificationItemCount: Int,
        failureCategory: TransferVerificationFailureCategory?
    ) {
        self.enabled = enabled
        self.verifiedFileCount = max(verifiedFileCount, 0)
        self.verifiedLogicalByteCount = max(verifiedLogicalByteCount, 0)
        self.noByteTransferItemCount = max(noByteTransferItemCount, 0)
        self.failedVerificationItemCount = max(failedVerificationItemCount, 0)
        self.failureCategory = failureCategory
    }
}

private enum TransferVerificationModelSupport {
    static func basename(_ value: String) -> String {
        let withoutNewlines = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutNewlines.isEmpty else { return "Item" }
        let basename = URL(filePath: withoutNewlines).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? "Item" : basename
    }

    static func optionalBasename(_ value: String) -> String? {
        let sanitized = basename(value)
        return sanitized == "Item" && value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? nil
            : sanitized
    }
}
