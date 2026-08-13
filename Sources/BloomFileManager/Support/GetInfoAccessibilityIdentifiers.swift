enum GetInfoAccessibilityIdentifiers {
    static let panel = "getInfo.panel"
    static let inspectorHost = "getInfo.inspector.host"
    static let inspector = "getInfo.inspector"
    static let title = "getInfo.title"
    static let status = "getInfo.status"
    static let details = "getInfo.details"
    static let outcomes = "getInfo.outcomes"
    static let inspectionProgress = "getInfo.inspection.progress"
    static let inspectionFailure = "getInfo.inspection.failure"
    static let checksumCalculate = "getInfo.checksum.calculate"
    static let checksumProgress = "getInfo.checksum.progress"
    static let checksumDigest = "getInfo.checksum.digest"
    static let checksumCopy = "getInfo.checksum.copy"
    static let checksumFailure = "getInfo.checksum.failure"
    static let checksumRetry = "getInfo.checksum.retry"
}

enum GetInfoAccessibilityPresentation {
    struct Element: Equatable, Sendable {
        let identifier: String
        let label: String
        let value: String
        let hint: String?
    }

    static let inspectionProgress = Element(
        identifier: GetInfoAccessibilityIdentifiers.inspectionProgress,
        label: "Get Info inspection status",
        value: "Inspecting selection",
        hint: "Metadata inspection is in progress."
    )

    static let inspectionFailure = Element(
        identifier: GetInfoAccessibilityIdentifiers.inspectionFailure,
        label: "Get Info inspection status",
        value: "Information unavailable",
        hint: "Close Get Info and try inspecting the selection again."
    )

    static func loaded(_ details: GetInfoInspectorPresentation.Details) -> [Element] {
        [
            inspector(value: details.summary),
            title(details),
            status(details),
            metadata(details),
            outcomes(details)
        ]
    }

    static func inspector(value: String) -> Element {
        .init(
            identifier: GetInfoAccessibilityIdentifiers.inspector,
            label: "Get Info inspector",
            value: value,
            hint: "Displays read-only metadata for the inspected selection."
        )
    }

    static func title(_ details: GetInfoInspectorPresentation.Details) -> Element {
        .init(
            identifier: GetInfoAccessibilityIdentifiers.title,
            label: "Inspected selection",
            value: details.title,
            hint: nil
        )
    }

    static func status(_ details: GetInfoInspectorPresentation.Details) -> Element {
        .init(
            identifier: GetInfoAccessibilityIdentifiers.status,
            label: "Inspection status",
            value: details.summary,
            hint: "Reports inspected and unavailable item counts."
        )
    }

    static func metadata(_ details: GetInfoInspectorPresentation.Details) -> Element {
        let noun = details.rows.count == 1 ? "field" : "fields"
        let qualifier = details.outcomes.count > 1 ? "summary " : ""
        return .init(
            identifier: GetInfoAccessibilityIdentifiers.details,
            label: "Selection metadata",
            value: "\(details.rows.count) \(qualifier)\(noun)",
            hint: "Contains read-only file metadata."
        )
    }

    static func outcomes(_ details: GetInfoInspectorPresentation.Details) -> Element {
        let successfulCount = details.outcomes.reduce(into: 0) { count, outcome in
            if case .success = outcome { count += 1 }
        }
        let failedCount = details.outcomes.count - successfulCount
        return .init(
            identifier: GetInfoAccessibilityIdentifiers.outcomes,
            label: "Inspection outcomes",
            value: "\(successfulCount) successful, \(failedCount) unavailable",
            hint: "Lists each inspected or unavailable item in selection order."
        )
    }

    static func checksum(_ controls: GetInfoInspectorPresentation.ChecksumControls) -> [Element] {
        switch controls {
        case .hidden:
            []
        case .calculate:
            [checksumCalculate]
        case let .calculating(progress):
            [checksumProgress(progress)]
        case let .copy(hexDigest):
            [checksumDigest(hexDigest), checksumCopy(hexDigest)]
        case let .retry(message):
            [checksumFailure(message), checksumRetry]
        }
    }

    static let checksumCalculate = Element(
        identifier: GetInfoAccessibilityIdentifiers.checksumCalculate,
        label: "Calculate SHA-256",
        value: "Ready",
        hint: "Reads the selected file to calculate its SHA-256 checksum."
    )

    static func checksumProgress(_ progress: Double) -> Element {
        .init(
            identifier: GetInfoAccessibilityIdentifiers.checksumProgress,
            label: "SHA-256 calculation progress",
            value: "\(Int((progress * 100).rounded())) percent",
            hint: "Checksum calculation is in progress."
        )
    }

    static func checksumDigest(_ hexDigest: String) -> Element {
        .init(
            identifier: GetInfoAccessibilityIdentifiers.checksumDigest,
            label: "SHA-256 digest",
            value: hexDigest,
            hint: "The calculated lowercase hexadecimal checksum."
        )
    }

    static func checksumCopy(_ hexDigest: String) -> Element {
        .init(
            identifier: GetInfoAccessibilityIdentifiers.checksumCopy,
            label: "Copy SHA-256 digest",
            value: hexDigest,
            hint: "Copies the SHA-256 digest to the clipboard."
        )
    }

    static func checksumFailure(_ message: String) -> Element {
        .init(
            identifier: GetInfoAccessibilityIdentifiers.checksumFailure,
            label: "SHA-256 calculation status",
            value: message,
            hint: "The checksum was not calculated."
        )
    }

    static let checksumRetry = Element(
        identifier: GetInfoAccessibilityIdentifiers.checksumRetry,
        label: "Retry SHA-256 calculation",
        value: "Available",
        hint: "Retries calculating the selected file's SHA-256 checksum."
    )
}
