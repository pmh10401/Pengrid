import Foundation
import os

/// The only diagnostic boundary exposed by protected archive work. Keeping
/// this protocol typed prevents a caller from accidentally logging a secret,
/// an upstream error string, or an internal archive entry name.
protocol ProtectedZIPLogging: Sendable {
    func record(_ event: ProtectedZIPDiagnosticEvent) async
}
struct LiveProtectedZIPLogger: ProtectedZIPLogging {
    private let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "ProtectedZIP"
    )

    func record(_ event: ProtectedZIPDiagnosticEvent) async {
        let category: String = switch event.category {
        case .compression: "compression"
        case .extraction: "extraction"
        case .inspection: "inspection"
        case .preflight: "preflight"
        }
        logger.info(
            "category=\(category, privacy: .public) archive=\(event.archiveBasename, privacy: .public) duration=\(event.duration, format: .fixed(precision: 3), privacy: .public) succeeded=\(event.succeededCount, privacy: .public) failed=\(event.failedCount, privacy: .public) skipped=\(event.skippedCount, privacy: .public) cancelled=\(event.cancelledCount, privacy: .public)"
        )
    }
}
