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
        case retry(message: String)
    }

    static func details(for report: GetInfoInspectionReport) -> Details {
        let summary = report.summary
        let isSingleSuccess = report.outcomes.count == 1 && report.successfulSnapshots.count == 1
        let title: String
        if isSingleSuccess, let snapshot = report.successfulSnapshots.first {
            title = snapshot.name
        } else {
            let noun = summary.selectedCount == 1 ? "item" : "items"
            title = "\(summary.selectedCount) \(noun)"
        }

        let summaryText: String
        if summary.selectedCount == 1, summary.inspectedCount == 1 {
            summaryText = "1 item inspected"
        } else {
            summaryText = "\(summary.selectedCount) selected · \(summary.inspectedCount) inspected · \(summary.failedCount) unavailable"
        }

        let rows: [Row]
        if isSingleSuccess {
            rows = detailRows(for: report.successfulSnapshots[0])
        } else if report.outcomes.count > 1 {
            rows = summaryRows(for: report)
        } else {
            rows = []
        }
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
            ChecksumControls.retry(message: "Unable to calculate SHA-256.")
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

    private static func summaryRows(for report: GetInfoInspectionReport) -> [Row] {
        let summary = report.summary
        var rows = [
            Row(label: "Known logical size", value: byteCount(summary.knownLogicalByteTotal)),
            Row(label: "Known allocated size", value: byteCount(summary.knownAllocatedByteTotal))
        ]
        if let commonParentURL = summary.commonParentURL {
            rows.append(.init(label: "Common parent", value: commonParentURL.path))
        }

        var seenTypes: Set<String> = []
        let distinctTypes = report.successfulSnapshots.compactMap { snapshot in
            seenTypes.insert(snapshot.typeDescription).inserted ? snapshot.typeDescription : nil
        }
        rows.append(.init(
            label: "Types",
            value: distinctTypes.isEmpty ? "—" : distinctTypes.joined(separator: ", ")
        ))
        return rows
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
        VStack {
            Group {
                switch model.phase {
                case .idle:
                    ContentUnavailableView("Get Info", systemImage: "info.circle")
                case .loading:
                    ProgressView("Inspecting selection…")
                        .getInfoAccessibility(GetInfoAccessibilityPresentation.inspectionProgress)
                case .failed:
                    ContentUnavailableView("Information unavailable", systemImage: "exclamationmark.triangle")
                        .getInfoAccessibility(GetInfoAccessibilityPresentation.inspectionFailure)
                case .loaded:
                    if let report = model.report {
                        details(for: report)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 460)
        .accessibilityElement(children: .contain)
        .getInfoAccessibilitySemantics(GetInfoAccessibilityPresentation.inspector(value: accessibilityStatus))
    }

    @ViewBuilder
    private func details(for report: GetInfoInspectionReport) -> some View {
        let details = GetInfoInspectorPresentation.details(for: report)
        let controls = GetInfoInspectorPresentation.checksumControls(for: details, phase: model.checksumPhase)
        let titleAccessibility = GetInfoAccessibilityPresentation.title(details)
        let statusAccessibility = GetInfoAccessibilityPresentation.status(details)
        let metadataAccessibility = GetInfoAccessibilityPresentation.metadata(details)
        let outcomesAccessibility = GetInfoAccessibilityPresentation.outcomes(details)
        VStack(alignment: .leading, spacing: 12) {
            Text(details.title)
                .font(.headline)
                .accessibilityElement(children: .ignore)
                .getInfoAccessibility(titleAccessibility)
            Text(details.summary)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .getInfoAccessibility(statusAccessibility)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(details.rows, id: \.label) { row in
                            LabeledContent(row.label, value: row.value)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(row.label)
                                .accessibilityValue(row.value)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .getInfoAccessibility(metadataAccessibility)

                    if details.outcomes.count > 1 || details.rows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(details.outcomes, id: \.self) { outcome in
                                outcomeRow(outcome)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .getInfoAccessibility(outcomesAccessibility)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            checksumControls(controls)
        }
    }

    @ViewBuilder
    private func outcomeRow(_ outcome: GetInfoInspectorPresentation.Outcome) -> some View {
        switch outcome {
        case let .success(name):
            Text(name)
                .accessibilityLabel("Inspected item")
                .accessibilityValue(name)
        case let .failure(name, message):
            LabeledContent(name, value: message)
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Unavailable item \(name)")
                .accessibilityValue(message)
        }
    }

    @ViewBuilder
    private func checksumControls(_ controls: GetInfoInspectorPresentation.ChecksumControls) -> some View {
        switch controls {
        case .hidden:
            EmptyView()
        case .calculate:
            let accessibility = GetInfoAccessibilityPresentation.checksumCalculate
            Button("Calculate SHA-256") {
                model.calculateSHA256()
            }
            .getInfoAccessibility(accessibility)
        case let .retry(message):
            let failureAccessibility = GetInfoAccessibilityPresentation.checksumFailure(message)
            let retryAccessibility = GetInfoAccessibilityPresentation.checksumRetry
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityElement(children: .ignore)
                    .getInfoAccessibility(failureAccessibility)
                Button("Try Again") {
                    model.calculateSHA256()
                }
                .getInfoAccessibility(retryAccessibility)
            }
        case let .calculating(progress):
            let accessibility = GetInfoAccessibilityPresentation.checksumProgress(progress)
            ProgressView(value: progress) {
                Text("Calculating SHA-256")
            }
            .getInfoAccessibility(accessibility)
        case let .copy(hexDigest):
            let digestAccessibility = GetInfoAccessibilityPresentation.checksumDigest(hexDigest)
            let copyAccessibility = GetInfoAccessibilityPresentation.checksumCopy(hexDigest)
            HStack {
                Text(hexDigest)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .getInfoAccessibility(digestAccessibility)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hexDigest, forType: .string)
                }
                .getInfoAccessibility(copyAccessibility)
            }
        }
    }

    private var accessibilityStatus: String {
        switch model.phase {
        case .idle: "No selection inspected"
        case .loading: "Inspecting selection"
        case .failed: "Information unavailable"
        case .loaded: model.report.map { GetInfoInspectorPresentation.details(for: $0).summary } ?? "Loaded"
        }
    }
}

private extension View {
    func getInfoAccessibility(
        _ semantics: GetInfoAccessibilityPresentation.Element
    ) -> some View {
        getInfoAccessibilitySemantics(semantics)
            .accessibilityIdentifier(semantics.identifier)
    }

    func getInfoAccessibilitySemantics(
        _ semantics: GetInfoAccessibilityPresentation.Element
    ) -> some View {
        self
            .accessibilityLabel(semantics.label)
            .accessibilityValue(semantics.value)
            .accessibilityHint(semantics.hint ?? "")
    }
}
