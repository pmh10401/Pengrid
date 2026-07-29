import AppKit
import Foundation

struct ComparisonStatusPresentation: Equatable {
    let symbolName: String
    let label: String
    let value: String

    init(_ status: ComparisonStatus) {
        switch status {
        case let .identical(verification):
            self = .init(
                symbolName: "equal.circle",
                label: "Identical",
                value: verification == .checksum
                    ? "Identical, checksum verified"
                    : "Identical, quick metadata comparison"
            )
        case .metadataChanged:
            self = .init(
                symbolName: "equal.circle.fill",
                label: "Metadata changed",
                value: "Difference detected"
            )
        case .contentChanged:
            self = .init(
                symbolName: "exclamationmark.arrow.triangle.2.circlepath",
                label: "Content changed",
                value: "Contents differ"
            )
        case .leftOnly:
            self = .init(
                symbolName: "arrow.left",
                label: "Left only",
                value: "Exists only on the left"
            )
        case .rightOnly:
            self = .init(
                symbolName: "arrow.right",
                label: "Right only",
                value: "Exists only on the right"
            )
        case .typeConflict:
            self = .init(
                symbolName: "square.2.layers.3d",
                label: "Type conflict",
                value: "Item kinds differ"
            )
        case .nameConflict:
            self = .init(
                symbolName: "textformat",
                label: "Name conflict",
                value: "Name pairing is ambiguous"
            )
        case let .checking(progress):
            let percentage: String
            if let progress, progress.isFinite {
                let boundedProgress = min(max(progress, 0), 1)
                percentage = "Checking, \(Int(boundedProgress * 100)) percent"
            } else {
                percentage = "Checking"
            }
            self = .init(
                symbolName: "progress.indicator",
                label: "Checking",
                value: percentage
            )
        case .unstable:
            self = .init(
                symbolName: "waveform.path.ecg",
                label: "Unstable",
                value: "Item changed repeatedly during verification"
            )
        case let .error(message):
            self = .init(
                symbolName: "exclamationmark.triangle",
                label: "Error",
                value: message
            )
        }
    }

    init(symbolName: String, label: String, value: String) {
        self.symbolName = symbolName
        self.label = label
        self.value = value
    }
}

enum ComparisonAccessibility {
    static func status(_ status: ComparisonStatus) -> ComparisonStatusPresentation {
        ComparisonStatusPresentation(status)
    }

    static func status(_ row: ComparisonRow) -> ComparisonStatusPresentation {
        let presentation = status(row.status)
        guard let value = contextualValue(for: row) else { return presentation }
        return ComparisonStatusPresentation(
            symbolName: presentation.symbolName,
            label: presentation.label,
            value: value
        )
    }

    static func row(_ row: ComparisonRow) -> String {
        let left = entry(row.left, side: "Left")
        let right = entry(row.right, side: "Right")
        return "\(row.relativePath.string). \(left). \(status(row).value). \(right)."
    }

    static func summary(phase: ComparisonPhase, count: Int) -> String {
        let itemCount = count == 1 ? "1 item" : "\(count) items"
        return "\(phaseDescription(phase)), \(itemCount)."
    }

    private static func entry(_ entry: ComparisonEntry?, side: String) -> String {
        guard let entry else { return "\(side), missing" }
        let size = entry.fingerprint.byteSize.map { value in
            value == 1 ? "1 byte" : "\(value) bytes"
        } ?? "size unavailable"
        return "\(side), \(entry.typeDescription), \(size)"
    }

    private static func contextualValue(for row: ComparisonRow) -> String? {
        switch row.status {
        case .metadataChanged:
            if hasRegularFilePair(row) {
                return "Contents match; metadata differs, checksum verified"
            }
            if row.descendantDifferenceCount > 0 {
                let count = row.descendantDifferenceCount
                let descendants = count == 1
                    ? "1 descendant difference"
                    : "\(count) descendant differences"
                let metadataAlsoDiffers = row.left?.fingerprint.modifiedAt
                    != row.right?.fingerprint.modifiedAt
                return metadataAlsoDiffers
                    ? "Metadata differs and contains \(descendants), quick comparison"
                    : "Contains \(descendants), quick comparison"
            }
            return "Metadata differs, quick comparison"
        case .contentChanged:
            guard hasRegularFilePair(row) else { return "Contents differ, quick comparison" }
            return row.left?.fingerprint.byteSize == row.right?.fingerprint.byteSize
                ? "Contents differ, checksum verified"
                : "Contents differ, quick comparison"
        default:
            return nil
        }
    }

    private static func hasRegularFilePair(_ row: ComparisonRow) -> Bool {
        row.left?.kind == .regularFile && row.right?.kind == .regularFile
    }

    private static func phaseDescription(_ phase: ComparisonPhase) -> String {
        switch phase {
        case .idle: "Comparison idle"
        case .comparing: "Comparing folders"
        case .verifying: "Verifying contents"
        case .upToDate: "Comparison up to date"
        case .paused: "Comparison paused"
        case .disconnected: "Folder disconnected"
        }
    }
}

@MainActor
protocol ComparisonAnnouncementPosting: AnyObject {
    func post(_ message: String)
}

@MainActor
final class LiveComparisonAnnouncementPoster: ComparisonAnnouncementPosting {
    func post(_ message: String) {
        let application = NSApplication.shared
        let element: Any = application.mainWindow ?? application
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}
