import AppKit
import Observation
import SwiftUI

enum GetInfoInspectorPresentation {
    struct Row: Equatable, Hashable, Sendable {
        let label: String
        let value: String
    }

    enum Outcome: Equatable, Hashable, Sendable {
        case success(name: String)
        case failure(name: String, message: String)
    }

    struct Details: Equatable, Sendable {
        let title: String
        let summary: String
        let rows: [Row]
        let outcomes: [Outcome]
        let checksumEligible: Bool
    }

    enum ChecksumControls: Equatable, Sendable {
        case hidden
        case calculate
        case calculating(progress: Double)
        case copy(hexDigest: String)
        case retry
    }

    static func details(for report: GetInfoInspectionReport) -> Details {
        let summary = report.summary
        let isSingleSuccess = report.outcomes.count == 1 && report.successfulSnapshots.count == 1
        let title: String
        if isSingleSuccess, let snapshot = report.successfulSnapshots.first {
            title = snapshot.name
        } else {
            title = "\(summary.selectedCount) items"
        }

        let summaryText: String
        if summary.selectedCount == 1, summary.inspectedCount == 1 {
            summaryText = "1 item inspected"
        } else {
            summaryText = "\(summary.selectedCount) selected · \(summary.inspectedCount) inspected · \(summary.failedCount) unavailable"
        }

        let rows = isSingleSuccess ? detailRows(for: report.successfulSnapshots[0]) : []
        let outcomes: [Outcome] = report.outcomes.map { outcome in
            switch outcome {
            case let .success(snapshot): Outcome.success(name: snapshot.name)
            case let .failure(failure): Outcome.failure(
                name: failure.url.lastPathComponent,
                message: failureMessage(for: failure.reason)
            )
            }
        }
        return .init(
            title: title,
            summary: summaryText,
            rows: rows,
            outcomes: outcomes,
            checksumEligible: summary.checksumRequest != nil
        )
    }

    static func checksumControls(for details: Details, phase: GetInfoChecksumPhase) -> ChecksumControls {
        guard details.checksumEligible else { return .hidden }
        return switch phase {
        case .unavailable:
            ChecksumControls.hidden
        case .ready:
            ChecksumControls.calculate
        case let .calculating(progress):
            ChecksumControls.calculating(progress: progress)
        case let .complete(hexDigest):
            ChecksumControls.copy(hexDigest: hexDigest)
        case .failed:
            ChecksumControls.retry
        }
    }

    private static func detailRows(for snapshot: GetInfoItemSnapshot) -> [Row] {
        let isEntry = snapshot.kind == .directory || snapshot.kind == .package
        let logicalSizeLabel = isEntry ? "Entry size" : "File size"
        let allocatedSizeLabel = isEntry ? "Allocated entry size" : "Allocated file size"
        return [
            .init(label: "Basename", value: snapshot.name),
            .init(label: "Path", value: snapshot.url.path),
            .init(label: "Type", value: snapshot.typeDescription),
            .init(label: "Type identifier", value: snapshot.typeIdentifier ?? "—"),
            .init(label: "Entry kind", value: entryKindDescription(snapshot.kind)),
            .init(label: logicalSizeLabel, value: byteCount(snapshot.logicalByteSize)),
            .init(label: allocatedSizeLabel, value: byteCount(snapshot.allocatedByteSize)),
            .init(label: "Created", value: dateDescription(snapshot.createdAt)),
            .init(label: "Modified", value: dateDescription(snapshot.modifiedAt)),
            .init(label: "Owner ID", value: String(snapshot.ownerID)),
            .init(label: "Group ID", value: String(snapshot.groupID)),
            .init(label: "Mode", value: String(format: "%04o", snapshot.posixMode)),
            .init(label: "Tags", value: snapshot.finderTags.isEmpty ? "—" : snapshot.finderTags.joined(separator: ", ")),
            .init(label: "Availability", value: availabilityDescription(snapshot.availability)),
            .init(label: "Symlink destination", value: snapshot.symbolicLinkDestination ?? "—")
        ]
    }

    private static func entryKindDescription(_ kind: GetInfoEntryKind) -> String {
        switch kind {
        case .regularFile: "File"
        case .directory: "Folder"
        case .package: "Package"
        case .symbolicLink: "Symbolic link"
        case .special: "Special"
        }
    }

    private static func byteCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func dateDescription(_ value: Date?) -> String {
        value?.formatted(date: .abbreviated, time: .standard) ?? "—"
    }

    private static func availabilityDescription(_ availability: CloudItemAvailability) -> String {
        switch availability {
        case .availableLocally: "Available locally"
        case .onlineOnly: "Online only"
        case let .downloading(progress):
            progress.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading"
        case .unavailable(.offline): "Unavailable offline"
        case .unavailable(.insufficientLocalStorage): "Unavailable: insufficient local storage"
        case .unavailable(.permissionDenied): "Unavailable: permission denied"
        case .unavailable(.itemChanged): "Unavailable: item changed"
        case .unavailable(.providerFailure): "Unavailable"
        case .unknown: "Unknown"
        }
    }

    private static func failureMessage(for reason: GetInfoInspectionFailure.Reason) -> String {
        switch reason {
        case .itemChanged: "Item changed"
        case .accessDenied: "Access denied"
        case .metadataUnavailable: "Metadata unavailable"
        }
    }
}

struct GetInfoInspectorView: View {
    @Bindable var model: GetInfoInspectorModel

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                ContentUnavailableView("Get Info", systemImage: "info.circle")
            case .loading:
                ProgressView("Inspecting selection…")
            case .failed:
                ContentUnavailableView("Information unavailable", systemImage: "exclamationmark.triangle")
            case .loaded:
                if let report = model.report {
                    details(for: report)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 460)
        .accessibilityIdentifier(GetInfoAccessibilityIdentifiers.panel)
    }

    @ViewBuilder
    private func details(for report: GetInfoInspectionReport) -> some View {
        let details = GetInfoInspectorPresentation.details(for: report)
        let controls = GetInfoInspectorPresentation.checksumControls(for: details, phase: model.checksumPhase)
        VStack(alignment: .leading, spacing: 12) {
            Text(details.title)
                .font(.headline)
                .accessibilityIdentifier(GetInfoAccessibilityIdentifiers.title)
            Text(details.summary)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(GetInfoAccessibilityIdentifiers.status)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(details.rows, id: \.label) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    if details.outcomes.count > 1 || details.rows.isEmpty {
                        ForEach(details.outcomes, id: \.self) { outcome in
                            outcomeRow(outcome)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(GetInfoAccessibilityIdentifiers.details)
            }

            checksumControls(controls)
        }
    }

    @ViewBuilder
    private func outcomeRow(_ outcome: GetInfoInspectorPresentation.Outcome) -> some View {
        switch outcome {
        case let .success(name):
            Text(name)
        case let .failure(name, message):
            LabeledContent(name, value: message)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func checksumControls(_ controls: GetInfoInspectorPresentation.ChecksumControls) -> some View {
        switch controls {
        case .hidden:
            EmptyView()
        case .calculate, .retry:
            Button("Calculate SHA-256") {
                model.calculateSHA256()
            }
            .accessibilityIdentifier(GetInfoAccessibilityIdentifiers.checksumCalculate)
        case let .calculating(progress):
            ProgressView(value: progress) {
                Text("Calculating SHA-256")
            }
        case let .copy(hexDigest):
            HStack {
                Text(hexDigest)
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hexDigest, forType: .string)
                }
                .accessibilityIdentifier(GetInfoAccessibilityIdentifiers.checksumCopy)
            }
        }
    }
}
