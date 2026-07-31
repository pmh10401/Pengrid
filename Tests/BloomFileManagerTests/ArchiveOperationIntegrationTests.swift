import Foundation
import Testing
@testable import BloomFileManager

@Suite("ArchiveOperationIntegrationTests")
struct ArchiveOperationIntegrationTests {
    @Test func dittoRoundTripPreservesSpacedFileNameAndContentUnderKeptParent() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let keptParent = root.url.appending(path: "Kept Parent", directoryHint: .isDirectory)
        let source = keptParent.appending(path: "Report with spaces.txt")
        let archive = root.url.appending(path: "Round Trip.zip")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        let expectedContent = Data("native ZIP round trip".utf8)
        try FileManager.default.createDirectory(at: keptParent, withIntermediateDirectories: false)
        try expectedContent.write(to: source)

        let runner = LiveArchiveCommandRunner()
        try await runner.run(kind: .compress, sources: [keptParent], destination: archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0)

        try await runner.run(kind: .extract, sources: [archive], destination: extraction)

        let extractedFile = extraction
            .appending(path: "Kept Parent", directoryHint: .isDirectory)
            .appending(path: "Report with spaces.txt")
        #expect(FileManager.default.fileExists(atPath: extractedFile.path))
        #expect(try Data(contentsOf: extractedFile) == expectedContent)
    }

    @Test func malformedArchiveFailureLeavesNoStagingDirectoryOrPartialDestination() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let malformedArchive = root.url.appending(path: "Broken.zip")
        let destination = root.url.appending(path: "Broken", directoryHint: .isDirectory)
        try Data("this is not a ZIP archive".utf8).write(to: malformedArchive)
        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: LiveArchiveCommandRunner()
        )
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: [malformedArchive],
            finalDestination: destination
        )

        let result = await service.perform([request]) { _ in }

        guard case let .failed(source, _) = result.outcomes.first else {
            Issue.record("Expected malformed archive extraction to fail")
            return
        }
        #expect(source == malformedArchive)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        try expectNoStagingDirectories(in: root.url)
    }
}

private func expectNoStagingDirectories(in directory: URL) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(children.contains { $0.lastPathComponent.hasPrefix(".bloom-staging-") } == false)
}
