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
}

private func presentationSnapshot(name: String, kind: GetInfoEntryKind) -> GetInfoItemSnapshot {
    let url = URL(fileURLWithPath: "/tmp/GetInfoPresentationTests/\(name)")
    let identity = FileIdentity(entryIdentifier: name, resolvedIdentifier: name)
    return .init(
        url: url,
        name: name,
        kind: kind,
        typeDescription: kind == .directory ? "Folder" : "Numbers document",
        typeIdentifier: "public.data",
        logicalByteSize: 1_024,
        allocatedByteSize: 4_096,
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
