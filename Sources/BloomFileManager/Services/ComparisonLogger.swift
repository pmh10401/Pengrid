import Foundation
import OSLog

struct ComparisonLogEvent: Equatable, Sendable {
    let duration: TimeInterval
    let discoveredCount: Int
    let checksumCount: Int
    let errorCount: Int
    let wasCancelled: Bool
}

protocol ComparisonLogging: Sendable {
    func record(_ event: ComparisonLogEvent) async
}

struct LiveComparisonLogger: ComparisonLogging {
    private let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "comparison"
    )

    func record(_ event: ComparisonLogEvent) {
        logger.info(
            "duration=\(event.duration) discovered=\(event.discoveredCount) checksums=\(event.checksumCount) errors=\(event.errorCount) cancelled=\(event.wasCancelled)"
        )
    }
}
