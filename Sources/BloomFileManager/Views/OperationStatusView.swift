import SwiftUI

struct OperationStatusSummary: Equatable, Sendable {
    let succeeded: Int
    let recoveryNeeded: Int
    let failed: Int
    let skipped: Int
    let cancelled: Int

    init(result: FileOperationResult) {
        var succeeded = 0
        var recoveryNeeded = 0
        var failed = 0
        var skipped = 0
        var cancelled = 0
        for outcome in result.outcomes {
            switch outcome {
            case .succeeded:
                succeeded += 1
            case .recoveryNeeded:
                recoveryNeeded += 1
            case .failed:
                failed += 1
            case .skipped:
                skipped += 1
            case .cancelled:
                cancelled += 1
            }
        }
        self.succeeded = succeeded
        self.recoveryNeeded = recoveryNeeded
        self.failed = failed
        self.skipped = skipped
        self.cancelled = cancelled
    }

    var accessibilityLabel: String {
        let recoverySummary = recoveryNeeded == 0
            ? ""
            : "\(recoveryNeeded) recovery needed, "
        return "\(succeeded) succeeded, \(recoverySummary)"
            + "\(failed) failed, \(skipped) skipped, \(cancelled) cancelled"
    }
}

struct OperationResultDetails: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        enum Status: Equatable, Sendable {
            case failed
            case recoveryNeeded
            case skipped
            case cancelled
        }

        let id: Int
        let name: String
        let status: Status
        let guidance: String
    }

    let items: [Item]
    let accessibilityLabel: String

    init(result: FileOperationResult) {
        let summary = OperationStatusSummary(result: result)
        let detailSources = result.outcomes.compactMap(\.detailSource)
        let duplicateBasenames = Dictionary(grouping: detailSources, by: \.lastPathComponent)
            .filter { $0.value.count > 1 }
            .keys

        items = result.outcomes.enumerated().compactMap { index, outcome in
            switch outcome {
            case .succeeded:
                return nil
            case .recoveryNeeded:
                return Item(
                    id: index,
                    name: "Recovery needed",
                    status: .recoveryNeeded,
                    guidance: "A staged item was retained for safe manual recovery."
                )
            case let .failed(source, message):
                return Item(
                    id: index,
                    name: duplicateBasenames.contains(source.lastPathComponent)
                        ? result.safeRelativePath(for: source)?.string ?? source.lastPathComponent
                        : source.lastPathComponent,
                    status: .failed,
                    guidance: Self.failureGuidance(for: message)
                )
            case let .skipped(source):
                return Item(
                    id: index,
                    name: duplicateBasenames.contains(source.lastPathComponent)
                        ? result.safeRelativePath(for: source)?.string ?? source.lastPathComponent
                        : source.lastPathComponent,
                    status: .skipped,
                    guidance: "Choose Replace or Keep Both to process this item."
                )
            case let .cancelled(source):
                return Item(
                    id: index,
                    name: duplicateBasenames.contains(source.lastPathComponent)
                        ? result.safeRelativePath(for: source)?.string ?? source.lastPathComponent
                        : source.lastPathComponent,
                    status: .cancelled,
                    guidance: "Run the operation again when you are ready."
                )
            }
        }
        accessibilityLabel = summary.accessibilityLabel
    }

    private static func failureGuidance(for message: String) -> String {
        switch message {
        case "cloud-preparation:offline":
            "Connect to the internet, then try the download again."
        case "cloud-preparation:insufficient-storage":
            "Free local storage, then try the download again."
        case "cloud-preparation:permission-denied":
            "Check file access in the provider, then try again."
        case "cloud-preparation:item-changed":
            "Refresh the folder and select the item again."
        case "cloud-preparation:provider-failure":
            "Check the cloud provider status, then try again."
        default:
            "Check access and available space, then try again."
        }
    }
}

private extension FileOperationItemOutcome {
    var detailSource: URL? {
        switch self {
        case .succeeded:
            nil
        case .recoveryNeeded:
            nil
        case let .failed(source, _), let .skipped(source), let .cancelled(source):
            source
        }
    }
}

struct ArchiveOperationStatusPresentation: Equatable, Sendable {
    let title: String
    let currentItemName: String
    let progressLabel: String
    let statusAccessibilityLabel: String
    let cancelAccessibilityLabel: String

    init(progress: ArchiveOperationProgress) {
        title = "\(progress.kind.title) \(progress.format.accessibilityName)"
        currentItemName = Self.safeDisplayName(progress.currentDisplayName)
        progressLabel = switch progress.phase {
        case let .preparingSources(completedCount, totalCount):
            "Preparing files, \(min(max(completedCount, 0), max(totalCount, 0))) of \(max(totalCount, 0))"
        case let .processingBytes(completedByteCount, totalByteCount):
            Self.byteProgressLabel(
                kind: progress.kind,
                completedByteCount: completedByteCount,
                totalByteCount: totalByteCount
            )
        case .encoding:
            "Encoding archive"
        case .waitingForPassword:
            "Waiting for password"
        case .publishing:
            "Finishing archive"
        }
        statusAccessibilityLabel = "\(title), \(progressLabel), "
            + "current item \(currentItemName)"
        cancelAccessibilityLabel = switch progress.kind {
        case .compress:
            "Cancel \(progress.format.displayName) compression"
        case .extract:
            "Cancel \(progress.format.displayName) extraction"
        }
    }

    private static func byteProgressLabel(
        kind: ArchiveOperationKind,
        completedByteCount: Int64,
        totalByteCount: Int64?
    ) -> String {
        let operationLabel = switch kind {
        case .compress: "Encrypting archive"
        case .extract: "Extracting archive"
        }
        guard let totalByteCount, totalByteCount > 0 else {
            return operationLabel
        }

        let safeCompleted = min(max(completedByteCount, 0), totalByteCount)
        let completedText = ByteCountFormatter.string(
            fromByteCount: safeCompleted,
            countStyle: .file
        )
        let totalText = ByteCountFormatter.string(
            fromByteCount: totalByteCount,
            countStyle: .file
        )

        // Keep one readable unit after "of" when both values share it (for
        // example, "25 of 100 bytes"), while retaining full formatter output
        // when the values cross a unit boundary (for example, "1 KB of 2 MB").
        let completedParts = completedText.split(separator: " ", maxSplits: 1)
        let totalParts = totalText.split(separator: " ", maxSplits: 1)
        if completedParts.count == 2,
           totalParts.count == 2,
           completedParts[1] == totalParts[1] {
            return "\(operationLabel), \(completedParts[0]) of \(totalText)"
        }
        return "\(operationLabel), \(completedText) of \(totalText)"
    }

    private static func safeDisplayName(_ value: String) -> String {
        let withoutNewlines = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutNewlines.isEmpty else { return "Item" }
        let basename = URL(filePath: withoutNewlines).lastPathComponent
        return basename.isEmpty ? "Item" : basename
    }
}

struct OperationStatusView: View {
    let controller: FileOperationController

    var body: some View {
        Group {
            if controller.isRunning, let stage = controller.stage {
                runningStatus(stage)
            } else if let result = controller.lastResult {
                completedStatus(result)
            }
        }
    }

    private func runningStatus(_ stage: FileOperationStage) -> some View {
        Group {
            switch stage {
            case let .preparing(progress):
                preparationStatus(progress)
            case let .operating(progress):
                operationStatus(progress)
            case let .archiving(progress):
                archiveStatus(progress)
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.operationStatus)
    }

    private func preparationStatus(_ progress: CloudMaterializationProgress) -> some View {
        HStack(spacing: 10) {
            Text("Preparing Download")
                .font(.caption.weight(.semibold))

            ProgressView(
                value: Double(progress.completedCount),
                total: Double(max(progress.totalCount, 1))
            )
            .frame(maxWidth: 180)

            Text(progress.currentName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text("\(progress.completedCount) of \(progress.totalCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Cancel") {
                controller.cancel()
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Preparing Download, \(progress.completedCount) of \(progress.totalCount), current item \(progress.currentName)"
        )
        .modifier(StatusBarStyle())
    }

    private func archiveStatus(_ progress: ArchiveOperationProgress) -> some View {
        let presentation = ArchiveOperationStatusPresentation(progress: progress)
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))

                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction, total: 1)
                        .frame(maxWidth: 180)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(presentation.progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(presentation.currentItemName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.statusAccessibilityLabel)

            Spacer(minLength: 8)

            Button("Cancel") {
                controller.cancel()
            }
            .controlSize(.small)
            .accessibilityLabel(presentation.cancelAccessibilityLabel)
        }
        .modifier(StatusBarStyle())
    }

    private func operationStatus(_ progress: FileOperationProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView(
                value: Double(progress.completedCount),
                total: Double(max(progress.totalCount, 1))
            )
            .frame(maxWidth: 180)

            Text(progress.currentName.isEmpty ? "Preparing…" : progress.currentName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text("\(progress.completedCount) of \(progress.totalCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Cancel") {
                controller.cancel()
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Operation progress, \(progress.completedCount) of \(progress.totalCount), current item \(progress.currentName)"
        )
        .modifier(StatusBarStyle())
    }

    private func completedStatus(_ result: FileOperationResult) -> some View {
        let summary = OperationStatusSummary(result: result)
        let details = OperationResultDetails(result: result)
        return HStack(spacing: 14) {
            HStack(spacing: 14) {
                Label("\(summary.succeeded) succeeded", systemImage: "checkmark.circle")
                if summary.recoveryNeeded > 0 {
                    Label(
                        "\(summary.recoveryNeeded) recovery needed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
                Label("\(summary.failed) failed", systemImage: "exclamationmark.triangle")
                Label("\(summary.skipped) skipped", systemImage: "forward.end")
                Label("\(summary.cancelled) cancelled", systemImage: "xmark.circle")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.accessibilityLabel)
            .accessibilityIdentifier(AccessibilityIdentifiers.operationStatus)
            if !details.items.isEmpty {
                Menu("Details") {
                    ForEach(details.items) { item in
                        Text("\(item.name): \(item.guidance)")
                    }
                }
                .accessibilityLabel("Operation details, \(details.accessibilityLabel)")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .modifier(StatusBarStyle())
    }
}

private struct StatusBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}
