import Foundation
import Testing
@testable import BloomFileManager

@Suite("GetInfoPresentationTests")
struct GetInfoPresentationTests {
    @Test func singleSelectionSummaryUsesTheInspectedItemName() {
        let snapshot = presentationSnapshot(name: "Budget.numbers", kind: .regularFile)
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [.success(snapshot)]))

        #expect(details.title == "Budget.numbers")
        #expect(details.summary == "1 item inspected")
        #expect(details.checksumEligible)
    }

    @Test func multiSelectionSummaryUsesDerivedCountsAndOrderedOutcomes() {
        let success = presentationSnapshot(name: "first.txt", kind: .regularFile)
        let failure = GetInfoInspectionFailure(
            url: URL(fileURLWithPath: "/tmp/GetInfoPresentationTests/missing.txt"),
            reason: .accessDenied
        )
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [
            .success(success), .failure(failure)
        ]))

        #expect(details.title == "2 items")
        #expect(details.summary == "2 selected · 1 inspected · 1 unavailable")
        #expect(details.outcomes == [
            .success(name: "first.txt"),
            .failure(name: "missing.txt", message: "Access denied")
        ])
    }

    @Test func multiSelectionExposesKnownTotalsCommonParentAndDistinctSuccessfulTypes() {
        let first = presentationSnapshot(
            name: "first.txt",
            kind: .regularFile,
            parentPath: "/tmp/GetInfoPresentationTests/Shared",
            typeDescription: "Plain text",
            logicalByteSize: 1_024,
            allocatedByteSize: 4_096
        )
        let second = presentationSnapshot(
            name: "second.pdf",
            kind: .regularFile,
            parentPath: "/tmp/GetInfoPresentationTests/Shared",
            typeDescription: "PDF document",
            logicalByteSize: 2_048,
            allocatedByteSize: 8_192
        )
        let duplicateType = presentationSnapshot(
            name: "third.txt",
            kind: .regularFile,
            parentPath: "/tmp/GetInfoPresentationTests/Shared",
            typeDescription: "Plain text",
            logicalByteSize: nil,
            allocatedByteSize: nil
        )
        let failure = GetInfoInspectionFailure(
            url: URL(fileURLWithPath: "/tmp/GetInfoPresentationTests/Shared/unreadable.data"),
            reason: .metadataUnavailable
        )

        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [
            .success(first), .failure(failure), .success(second), .success(duplicateType)
        ]))

        #expect(details.rows == [
            .init(label: "Known logical size", value: "3 KB"),
            .init(label: "Known allocated size", value: "12 KB"),
            .init(label: "Common parent", value: "/tmp/GetInfoPresentationTests/Shared"),
            .init(label: "Types", value: "Plain text, PDF document")
        ])
    }

    @Test func singleFailureUsesASingularSelectionTitle() {
        let failure = GetInfoInspectionFailure(
            url: URL(fileURLWithPath: "/tmp/GetInfoPresentationTests/vanished.txt"),
            reason: .itemChanged
        )

        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [.failure(failure)]))

        #expect(details.title == "1 item")
    }

    @Test func directorySizeRowsAreLabeledAsEntrySizes() {
        let directory = presentationSnapshot(name: "Projects", kind: .directory)
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [.success(directory)]))

        #expect(details.rows.contains(.init(label: "Entry size", value: "1 KB")))
        #expect(details.rows.contains(.init(label: "Allocated entry size", value: "4 KB")))
        #expect(!details.rows.contains(where: { $0.label == "File size" }))
    }

    @Test func failedOutcomesAreShownAsFailureRows() {
        let failure = GetInfoInspectionFailure(
            url: URL(fileURLWithPath: "/tmp/GetInfoPresentationTests/vanished.txt"),
            reason: .itemChanged
        )
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [.failure(failure)]))

        #expect(details.outcomes == [.failure(name: "vanished.txt", message: "Item changed")])
        #expect(details.rows.isEmpty)
    }

    @Test func ineligibleSelectionsHideChecksumControls() {
        let directory = presentationSnapshot(name: "Projects", kind: .directory)
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [.success(directory)]))

        #expect(!details.checksumEligible)
        #expect(GetInfoInspectorPresentation.checksumControls(
            for: details,
            phase: .unavailable
        ) == .hidden)
    }

    @Test func eligibleSelectionsExposeExplicitChecksumAndCopyControls() {
        let file = presentationSnapshot(name: "Budget.numbers", kind: .regularFile)
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [.success(file)]))

        #expect(GetInfoInspectorPresentation.checksumControls(for: details, phase: .ready) == .calculate)
        #expect(GetInfoInspectorPresentation.checksumControls(
            for: details,
            phase: .complete(hexDigest: "ab007f")
        ) == .copy(hexDigest: "ab007f"))
    }

    @Test func failedChecksumExposesFailureMessageAndRetryAction() {
        let file = presentationSnapshot(name: "Budget.numbers", kind: .regularFile)
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [.success(file)]))

        #expect(GetInfoInspectorPresentation.checksumControls(
            for: details,
            phase: .failed
        ) == .retry(message: "Unable to calculate SHA-256."))
    }

    @Test func loadedContentAccessibilitySemanticsHaveStableIDsLabelsValuesAndHints() {
        let details = GetInfoInspectorPresentation.details(for: .init(outcomes: [
            .success(presentationSnapshot(name: "first.txt", kind: .regularFile)),
            .success(presentationSnapshot(name: "second.txt", kind: .regularFile))
        ]))

        #expect(GetInfoAccessibilityPresentation.loaded(details) == [
            .init(
                identifier: "getInfo.inspector",
                label: "Get Info inspector",
                value: "2 selected · 2 inspected · 0 unavailable",
                hint: "Displays read-only metadata for the inspected selection."
            ),
            .init(
                identifier: "getInfo.title",
                label: "Inspected selection",
                value: "2 items",
                hint: nil
            ),
            .init(
                identifier: "getInfo.status",
                label: "Inspection status",
                value: "2 selected · 2 inspected · 0 unavailable",
                hint: "Reports inspected and unavailable item counts."
            ),
            .init(
                identifier: "getInfo.details",
                label: "Selection metadata",
                value: "4 summary fields",
                hint: "Contains read-only file metadata."
            ),
            .init(
                identifier: "getInfo.outcomes",
                label: "Inspection outcomes",
                value: "2 successful, 0 unavailable",
                hint: "Lists each inspected or unavailable item in selection order."
            )
        ])
    }

    @Test func checksumAccessibilitySemanticsCoverReadyProgressDigestFailureAndRetry() {
        #expect(GetInfoAccessibilityPresentation.checksum(.calculate) == [
            .init(
                identifier: "getInfo.checksum.calculate",
                label: "Calculate SHA-256",
                value: "Ready",
                hint: "Reads the selected file to calculate its SHA-256 checksum."
            )
        ])
        #expect(GetInfoAccessibilityPresentation.checksum(.calculating(progress: 0.42)) == [
            .init(
                identifier: "getInfo.checksum.progress",
                label: "SHA-256 calculation progress",
                value: "42 percent",
                hint: "Checksum calculation is in progress."
            )
        ])
        #expect(GetInfoAccessibilityPresentation.checksum(.copy(hexDigest: "ab007f")) == [
            .init(
                identifier: "getInfo.checksum.digest",
                label: "SHA-256 digest",
                value: "ab007f",
                hint: "The calculated lowercase hexadecimal checksum."
            ),
            .init(
                identifier: "getInfo.checksum.copy",
                label: "Copy SHA-256 digest",
                value: "ab007f",
                hint: "Copies the SHA-256 digest to the clipboard."
            )
        ])
        #expect(GetInfoAccessibilityPresentation.checksum(
            .retry(message: "Unable to calculate SHA-256.")
        ) == [
            .init(
                identifier: "getInfo.checksum.failure",
                label: "SHA-256 calculation status",
                value: "Unable to calculate SHA-256.",
                hint: "The checksum was not calculated."
            ),
            .init(
                identifier: "getInfo.checksum.retry",
                label: "Retry SHA-256 calculation",
                value: "Available",
                hint: "Retries calculating the selected file's SHA-256 checksum."
            )
        ])
    }

    @Test func inspectionAccessibilitySemanticsCoverProgressAndFailure() {
        #expect(GetInfoAccessibilityPresentation.inspectionProgress == .init(
            identifier: "getInfo.inspection.progress",
            label: "Get Info inspection status",
            value: "Inspecting selection",
            hint: "Metadata inspection is in progress."
        ))
        #expect(GetInfoAccessibilityPresentation.inspectionFailure == .init(
            identifier: "getInfo.inspection.failure",
            label: "Get Info inspection status",
            value: "Information unavailable",
            hint: "Close Get Info and try inspecting the selection again."
        ))
    }
}

private func presentationSnapshot(
    name: String,
    kind: GetInfoEntryKind,
    parentPath: String = "/tmp/GetInfoPresentationTests",
    typeDescription: String? = nil,
    logicalByteSize: Int64? = 1_024,
    allocatedByteSize: Int64? = 4_096
) -> GetInfoItemSnapshot {
    let url = URL(fileURLWithPath: parentPath).appending(path: name)
    let identity = FileIdentity(entryIdentifier: name, resolvedIdentifier: name)
    return .init(
        url: url,
        name: name,
        kind: kind,
        typeDescription: typeDescription ?? (kind == .directory ? "Folder" : "Numbers document"),
        typeIdentifier: "public.data",
        logicalByteSize: logicalByteSize,
        allocatedByteSize: allocatedByteSize,
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 1),
        ownerID: 501,
        groupID: 20,
        posixMode: 0o755,
        finderTags: ["Work", "Finance"],
        symbolicLinkDestination: nil,
        availability: .availableLocally,
        identity: identity,
        checksumRequest: kind == .regularFile ? .init(
            url: url,
            fingerprint: .init(identity: identity, byteSize: 1_024, modifiedAt: Date(timeIntervalSince1970: 1))
        ) : nil
    )
}
