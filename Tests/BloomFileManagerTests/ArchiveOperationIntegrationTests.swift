import Foundation
import Testing
@testable import BloomFileManager

@Suite("ArchiveOperationIntegrationTests")
struct ArchiveOperationIntegrationTests {
    @Test func dittoCompressionArchivesMultipleSelectedItemsAtTheZIPRoot() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let firstSource = root.url.appending(path: "First.txt")
        let secondSource = root.url.appending(path: "Second File.txt")
        let archive = root.url.appending(path: "Archive.zip")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("first selection".utf8).write(to: firstSource)
        try Data("second selection".utf8).write(to: secondSource)

        let runner = LiveArchiveCommandRunner()
        try await runner.run(
            kind: .compress,
            format: .zip,
            sources: [firstSource, secondSource],
            destination: archive
        )
        try expectNoAggregateSourceDirectories(in: root.url)
        try await runner.run(kind: .extract, format: .zip, sources: [archive], destination: extraction)

        #expect(try Data(contentsOf: extraction.appending(path: "First.txt"))
            == Data("first selection".utf8))
        #expect(try Data(contentsOf: extraction.appending(path: "Second File.txt"))
            == Data("second selection".utf8))
        #expect(FileManager.default.fileExists(
            atPath: extraction.appending(path: root.url.lastPathComponent).path
        ) == false)
    }

    @Test func dittoCompressionPreservesATopLevelSelectedSymbolicLink() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let target = root.url.appending(path: "Target.txt")
        let selectedLink = root.url.appending(path: "Selected Link.txt")
        let archive = root.url.appending(path: "Link.zip")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("target bytes must not be followed".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: selectedLink.path,
            withDestinationPath: target.lastPathComponent
        )

        let runner = LiveArchiveCommandRunner()
        try await runner.run(
            kind: .compress,
            format: .zip,
            sources: [selectedLink],
            destination: archive
        )
        try await runner.run(kind: .extract, format: .zip, sources: [archive], destination: extraction)

        let extractedLink = extraction.appending(path: selectedLink.lastPathComponent)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: extractedLink.path
        ) == target.lastPathComponent)
        #expect(FileManager.default.fileExists(
            atPath: extraction.appending(path: target.lastPathComponent).path
        ) == false)
    }

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
        try await runner.run(kind: .compress, format: .zip, sources: [keptParent], destination: archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0)

        try await runner.run(kind: .extract, format: .zip, sources: [archive], destination: extraction)

        let extractedFile = extraction
            .appending(path: "Kept Parent", directoryHint: .isDirectory)
            .appending(path: "Report with spaces.txt")
        #expect(FileManager.default.fileExists(atPath: extractedFile.path))
        #expect(try Data(contentsOf: extractedFile) == expectedContent)
    }

    @Test(arguments: [
        ArchiveFormat.tar,
        ArchiveFormat.tarGzip,
        ArchiveFormat.tarBzip2,
        ArchiveFormat.tarXz
    ])
    func tarFamilyRoundTripArchivesMultipleSpacedSourcesAtTheArchiveRoot(
        format: ArchiveFormat
    ) async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sources = [
            ("First Source.txt", Data("first tar selection".utf8)),
            ("Second Source.txt", Data("second tar selection".utf8)),
            ("Third Source.txt", Data("third tar selection".utf8)),
            ("Fourth Source.txt", Data("fourth tar selection".utf8)),
            ("Fifth Source.txt", Data("fifth tar selection".utf8))
        ]
        let sourceURLs = sources.map { root.url.appending(path: $0.0) }
        let archive = root.url.appending(path: "Archive\(format.canonicalSuffix)")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        for (source, content) in zip(sourceURLs, sources.map(\.1)) {
            try content.write(to: source)
        }

        let runner = LiveArchiveCommandRunner()
        try await runner.run(
            kind: .compress,
            format: format,
            sources: sourceURLs,
            destination: archive
        )
        try await runner.run(
            kind: .extract,
            format: format,
            sources: [archive],
            destination: extraction
        )

        for (name, content) in sources {
            #expect(try Data(contentsOf: extraction.appending(path: name)) == content)
        }
        let extractedNames = try FileManager.default.contentsOfDirectory(
            at: extraction,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(Set(extractedNames) == Set(sources.map(\.0)))
        try expectNoAggregateSourceDirectories(in: root.url)
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

private func expectNoAggregateSourceDirectories(in directory: URL) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(children.contains {
        $0.lastPathComponent.hasPrefix(".archive-source-")
    } == false)
}
