import Foundation
import os

enum FileOperationKind: String, Sendable {
    case createFolder
    case rename
    case trash
    case copy
    case move
}

protocol OperationLogging: Sendable {
    func record(
        kind: FileOperationKind,
        duration: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int
    ) async
}

struct LiveOperationLogger: OperationLogging {
    private let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "FileOperations"
    )

    func record(
        kind: FileOperationKind,
        duration: TimeInterval,
        succeeded: Int,
        failed: Int,
        skipped: Int
    ) async {
        logger.info(
            "operation=\(kind.rawValue, privacy: .public) duration=\(duration, format: .fixed(precision: 3), privacy: .public) succeeded=\(succeeded, privacy: .public) failed=\(failed, privacy: .public) skipped=\(skipped, privacy: .public)"
        )
    }
}
