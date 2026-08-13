import Foundation
import Testing
@testable import BloomFileManager

@Suite struct GetInfoModelsTests {
    @Test func selectionSummaryUsesKnownEntryBytesAndPreservesFailures() {
        let report = GetInfoInspectionReport(
            outcomes: [
                .success(.fixture(name: "a.txt", logicalByteSize: 10, allocatedByteSize: 512)),
                .failure(.init(url: URL(filePath: "/tmp/b.txt"), reason: .itemChanged))
            ]
        )

        #expect(report.summary.selectedCount == 2)
        #expect(report.summary.inspectedCount == 1)
        #expect(report.summary.failedCount == 1)
        #expect(report.summary.knownLogicalByteTotal == 10)
        #expect(report.summary.knownAllocatedByteTotal == 512)
    }

    @Test func summaryReturnsCommonParentOnlyForSuccessfulItemsInOneFolder() {
        let parent = URL(filePath: "/tmp/parent", directoryHint: .isDirectory)
        let report = GetInfoInspectionReport(outcomes: [
            .success(.fixture(url: parent.appending(path: "a.txt"))),
            .failure(.init(url: URL(filePath: "/tmp/other.txt"), reason: .accessDenied)),
            .success(.fixture(url: parent.appending(path: "b.txt")))
        ])
        let splitParentReport = GetInfoInspectionReport(outcomes: [
            .success(.fixture(url: parent.appending(path: "a.txt"))),
            .success(.fixture(url: URL(filePath: "/tmp/elsewhere/b.txt")))
        ])

        #expect(report.summary.commonParentURL == parent)
        #expect(splitParentReport.summary.commonParentURL == nil)
    }

    @Test func summaryExposesChecksumOnlyForOneSuccessfulRegularFile() {
        let request = ChecksumRequest(
            url: URL(filePath: "/tmp/a.txt"),
            fingerprint: .init(
                identity: .init(entryIdentifier: "a", resolvedIdentifier: "a"),
                byteSize: 10,
                modifiedAt: nil
            )
        )
        let eligible = GetInfoInspectionReport(outcomes: [
            .success(.fixture(name: "a.txt", checksumRequest: request))
        ])
        let multiple = GetInfoInspectionReport(outcomes: [
            .success(.fixture(name: "a.txt", checksumRequest: request)),
            .success(.fixture(name: "b.txt", checksumRequest: request))
        ])
        let directory = GetInfoInspectionReport(outcomes: [
            .success(.fixture(name: "folder", kind: .directory, checksumRequest: request))
        ])

        #expect(eligible.summary.checksumRequest == request)
        #expect(multiple.summary.checksumRequest == nil)
        #expect(directory.summary.checksumRequest == nil)
    }
}

private extension GetInfoItemSnapshot {
    static func fixture(
        name: String,
        logicalByteSize: Int64? = 10,
        allocatedByteSize: Int64? = 512,
        kind: GetInfoEntryKind = .regularFile,
        checksumRequest: ChecksumRequest? = nil
    ) -> Self {
        fixture(
            url: URL(filePath: "/tmp/\(name)"),
            name: name,
            logicalByteSize: logicalByteSize,
            allocatedByteSize: allocatedByteSize,
            kind: kind,
            checksumRequest: checksumRequest
        )
    }

    static func fixture(
        url: URL,
        name: String? = nil,
        logicalByteSize: Int64? = 10,
        allocatedByteSize: Int64? = 512,
        kind: GetInfoEntryKind = .regularFile,
        checksumRequest: ChecksumRequest? = nil
    ) -> Self {
        let name = name ?? url.lastPathComponent
        return .init(
            url: url,
            name: name,
            kind: kind,
            typeDescription: "Text document",
            typeIdentifier: "public.plain-text",
            logicalByteSize: logicalByteSize,
            allocatedByteSize: allocatedByteSize,
            createdAt: nil,
            modifiedAt: nil,
            ownerID: 501,
            groupID: 20,
            posixMode: 0o644,
            finderTags: [],
            symbolicLinkDestination: nil,
            availability: .availableLocally,
            identity: .init(entryIdentifier: "entry-\(name)", resolvedIdentifier: "entry-\(name)"),
            checksumRequest: checksumRequest
        )
    }
}
