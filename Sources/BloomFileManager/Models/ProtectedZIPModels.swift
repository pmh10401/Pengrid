import Foundation

enum ArchiveProtection: Sendable, Equatable {
    case none
    case aes256
}

enum ArchivePasswordPurpose: Sendable, Equatable {
    case createAES256
    case extract
}

enum ArchivePasswordValidationError: Sendable, Equatable {
    case empty
    case invalidLength
    case tooShort
    case tooLong
    case containsNull
    case confirmationMismatch
}

struct ArchivePasswordRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let purpose: ArchivePasswordPurpose
    let archiveBasename: String
    let previousAttemptFailed: Bool

    init(
        id: UUID,
        purpose: ArchivePasswordPurpose,
        archiveBasename: String,
        previousAttemptFailed: Bool
    ) {
        self.id = id
        self.purpose = purpose
        self.archiveBasename = Self.publicBasename(archiveBasename)
        self.previousAttemptFailed = previousAttemptFailed
    }

    private static func publicBasename(_ value: String) -> String {
        // Keep only the first public line. Joining lines would allow an
        // internal archive entry appended after a newline to become part of
        // the supposedly public basename.
        let firstLine = value.components(separatedBy: .newlines).first ?? value
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Archive" }
        let basename = URL(filePath: trimmed).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? "Archive" : basename
    }
}

struct ProtectedZIPInspection: Sendable, Equatable {
    let entryCount: Int
    let totalUncompressedByteCount: Int64
    let hasEncryptedEntries: Bool
    let hasUnsupportedEncryption: Bool
    let hasUnsupportedCompression: Bool
    let strongestAESStrength: Int

    init(
        entryCount: Int = 0,
        totalUncompressedByteCount: Int64 = 0,
        hasEncryptedEntries: Bool = false,
        hasUnsupportedEncryption: Bool = false,
        hasUnsupportedCompression: Bool = false,
        strongestAESStrength: Int = 0
    ) {
        self.entryCount = max(entryCount, 0)
        self.totalUncompressedByteCount = max(totalUncompressedByteCount, 0)
        self.hasEncryptedEntries = hasEncryptedEntries
        self.hasUnsupportedEncryption = hasUnsupportedEncryption
        self.hasUnsupportedCompression = hasUnsupportedCompression
        self.strongestAESStrength = max(strongestAESStrength, 0)
    }

    var totalUncompressedBytes: Int64 { totalUncompressedByteCount }
}

struct ProtectedZIPProgress: Sendable, Equatable {
    let completedByteCount: Int64
    let totalByteCount: Int64?

    var fractionCompleted: Double? {
        guard let totalByteCount, totalByteCount > 0 else { return nil }
        let completed = min(max(completedByteCount, 0), totalByteCount)
        return Double(completed) / Double(totalByteCount)
    }
}

struct ProtectedZIPLimits: Sendable, Equatable {
    static let maximumEntryCount = 100_000
    static let minimumCapacityReserve: Int64 = 512 * 1_024 * 1_024

    let maximumOutputByteCount: Int64
    let capacityReserveByteCount: Int64
}

enum ProtectedZIPDiagnosticCategory: Sendable, Equatable {
    case compression
    case extraction
    case inspection
    case preflight
}

struct ProtectedZIPDiagnosticEvent: Sendable, Equatable {
    let category: ProtectedZIPDiagnosticCategory
    let archiveBasename: String
    let duration: TimeInterval
    let succeededCount: Int
    let failedCount: Int
    let skippedCount: Int
    let cancelledCount: Int

    init(
        category: ProtectedZIPDiagnosticCategory,
        archiveBasename: String,
        duration: TimeInterval,
        succeededCount: Int,
        failedCount: Int,
        skippedCount: Int,
        cancelledCount: Int = 0
    ) {
        self.category = category
        self.archiveBasename = Self.publicBasename(archiveBasename)
        self.duration = max(duration, 0)
        self.succeededCount = max(succeededCount, 0)
        self.failedCount = max(failedCount, 0)
        self.skippedCount = max(skippedCount, 0)
        self.cancelledCount = max(cancelledCount, 0)
    }

    init(
        category: ProtectedZIPDiagnosticCategory,
        archiveBasename: String,
        duration: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int,
        cancelled: Int = 0
    ) {
        self.init(
            category: category,
            archiveBasename: archiveBasename,
            duration: duration,
            succeededCount: succeeded,
            failedCount: failed,
            skippedCount: skipped,
            cancelledCount: cancelled
        )
    }

    var succeeded: Int { succeededCount }
    var failed: Int { failedCount }
    var skipped: Int { skippedCount }
    var cancelled: Int { cancelledCount }

    private static func publicBasename(_ value: String) -> String {
        let firstLine = value.components(separatedBy: .newlines).first ?? value
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Archive" }
        let basename = URL(filePath: trimmed).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? "Archive" : basename
    }
}

enum ProtectedZIPError: Error, LocalizedError, Sendable, Equatable {
    case invalidPasswordInput
    case incorrectPasswordOrDamagedData
    case unsupportedEncryption
    case unsupportedCompression
    case malformedArchive
    case unsafeEntry
    case entryCountOverflow
    case insufficientCapacity
    case outputBudgetOverflow
    case identityChanged
    case cancelled
    case recoveryRequired
    case engineSetupFailed
    case engineLaunchFailed

    // Stable compatibility spellings for callers that use noun-first labels.
    static var identityChange: Self { .identityChanged }
    static var outputBudgetExceeded: Self { .outputBudgetOverflow }
    static var entryCountExceeded: Self { .entryCountOverflow }
    static var cancellation: Self { .cancelled }

    var errorDescription: String? {
        ProtectedZIPStrings.message(for: self, locale: .current)
    }
}
