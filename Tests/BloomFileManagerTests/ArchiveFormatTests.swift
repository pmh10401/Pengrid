import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ArchiveFormatTests {
    @Test(arguments: [
        (ArchiveFormat.zip, ".zip"),
        (.tar, ".tar"),
        (.tarGzip, ".tar.gz"),
        (.tarBzip2, ".tar.bz2"),
        (.tarXz, ".tar.xz")
    ])
    func canonicalSuffixesMatchArchiveConventions(
        format: ArchiveFormat,
        expectedSuffix: String
    ) {
        #expect(format.canonicalSuffix == expectedSuffix)
    }

    @Test(arguments: [
        ("backup.TGZ", ArchiveFormat.tarGzip),
        ("backup.TBZ", .tarBzip2),
        ("backup.TBZ2", .tarBzip2),
        ("backup.TXZ", .tarXz),
        ("backup.TAR.GZ", .tarGzip)
    ])
    func detectionRecognizesCaseInsensitiveTarAliases(
        filename: String,
        expectedFormat: ArchiveFormat
    ) {
        #expect(ArchiveFormat.detect(filename: filename) == expectedFormat)
    }

    @Test func detectionRejectsUnknownSuffixes() {
        #expect(ArchiveFormat.detect(filename: "backup.rar") == nil)
    }

    @Test func archiveRequestAndProgressDefaultToZip() {
        let request = ArchiveRequest(
            kind: .compress,
            verifiedSources: [URL(filePath: "/tmp/report.txt")],
            finalDestination: URL(filePath: "/tmp/report.zip")
        )
        let progress = ArchiveOperationProgress(
            kind: .compress,
            currentDisplayName: "report.zip"
        )

        #expect(request.format == .zip)
        #expect(request.protection == .none)
        #expect(progress.format == .zip)
    }

    @Test func compressionPlansTarGzipDestinationName() {
        let source = fileItem(named: "report")

        let plan = ArchiveDestinationPlanner.compression(
            selectedItems: [source],
            in: URL(filePath: "/tmp"),
            occupiedNames: [],
            format: .tarGzip
        )

        #expect(plan?.destinations.map(\.lastPathComponent) == ["report.tar.gz"])
        #expect(plan?.formats == [.tarGzip])
    }

    @Test func extractionPlansMixedFormatDestinations() {
        let zip = fileItem(named: "photos.zip")
        let tarGzip = fileItem(named: "source.TGZ")
        let tarXz = fileItem(named: "logs.tar.xz")

        let plan = ArchiveDestinationPlanner.extraction(
            selectedItems: [zip, tarGzip, tarXz],
            in: URL(filePath: "/tmp"),
            occupiedNames: []
        )

        #expect(plan?.destinations.map(\.lastPathComponent) == ["photos", "source", "logs"])
        #expect(plan?.formats == [.zip, .tarGzip, .tarXz])
    }

    private func fileItem(named name: String) -> FileItem {
        FileItem(
            url: URL(filePath: "/tmp/\(name)"),
            name: name,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Archive"
        )
    }
}
