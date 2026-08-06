import Foundation
import Testing
@testable import BloomFileManager

@Suite("ArchiveOperationIntegrationTests")
struct ArchiveOperationIntegrationTests {
    @Test func compressionRefusesReplacementAfterOwnedOutputCreation() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Archive.zip")
        try Data("source".utf8).write(to: source)

        let replacement = Data("external replacement".utf8)
        let fileSystem = LiveFileSystemAccess(onAfterEmptyItemCreated: { created, _ in
            guard created == destination else { return }
            try FileManager.default.removeItem(at: created)
            try replacement.write(to: created, options: .withoutOverwriting)
        })
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let runner = LiveArchiveCommandRunner(fileSystem: fileSystem)

        await #expect(throws: ArchiveOperationError.recoveryRequired) {
            try await runner.run(
                kind: .compress,
                format: .zip,
                sources: identifiedArchiveTestSources([source]),
                destination: destination,
                destinationParentIdentity: parentIdentity
            )
        }
        #expect(try Data(contentsOf: destination) == replacement)
    }

    @Test func extractionRefusesAndDoesNotWriteIntoReplacementOutputDirectory() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let archive = root.url.appending(path: "Archive.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        let sentinel = destination.appending(path: "external.txt")
        try Data("source".utf8).write(to: source)
        try await LiveArchiveCommandRunner().run(
            kind: .compress,
            format: .zip,
            sources: [source],
            destination: archive
        )

        let fileSystem = LiveFileSystemAccess(onAfterEmptyItemCreated: { created, _ in
            guard created == destination else { return }
            try FileManager.default.removeItem(at: created)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
            try Data("external replacement".utf8).write(to: sentinel)
        })
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let runner = LiveArchiveCommandRunner(fileSystem: fileSystem)

        await #expect(throws: ArchiveOperationError.recoveryRequired) {
            try await runner.run(
                kind: .extract,
                format: .zip,
                sources: identifiedArchiveTestSources([archive]),
                destination: destination,
                destinationParentIdentity: parentIdentity
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data("external replacement".utf8))
        #expect(FileManager.default.fileExists(
            atPath: destination.appending(path: source.lastPathComponent).path
        ) == false)
    }

    @Test func compressionReportsMonotonicPreparationBeforeEncoding() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let firstSource = root.url.appending(path: "First.txt")
        let secondSource = root.url.appending(path: "Second File.txt")
        let archive = root.url.appending(path: "Archive.zip")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let phases = ArchivePhaseCollector()

        try await LiveArchiveCommandRunner().run(
            kind: .compress,
            format: .zip,
            sources: [firstSource, secondSource],
            destination: archive
        ) { phase in
            await phases.append(phase)
        }

        let phaseTransitions = await phases.values.reduce(
            into: [ArchiveOperationPhase]()
        ) { result, phase in
            if result.last != phase {
                result.append(phase)
            }
        }
        #expect(phaseTransitions == [
            .preparingSources(completedCount: 0, totalCount: 2),
            .preparingSources(completedCount: 1, totalCount: 2),
            .preparingSources(completedCount: 2, totalCount: 2),
            .encoding
        ])
        #expect(FileManager.default.fileExists(atPath: archive.path))
        try expectNoStagingDirectories(in: root.url)
    }

    @Test func extractionReportsOnlyEncodingBeforeLaunchingNativeCommand() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let archive = root.url.appending(path: "Archive.tar")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("source".utf8).write(to: source)
        let runner = LiveArchiveCommandRunner()
        try await runner.run(
            kind: .compress,
            format: .tar,
            sources: [source],
            destination: archive
        )
        let phases = ArchivePhaseCollector()

        try await runner.run(
            kind: .extract,
            format: .tar,
            sources: [archive],
            destination: extraction
        ) { phase in
            await phases.append(phase)
        }

        #expect(await phases.values == [.encoding])
        #expect(try Data(contentsOf: extraction.appending(path: "Source.txt"))
            == Data("source".utf8))
    }

    @Test func extractionSnapshotsOnlyTheCapturedArchiveIdentity() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let originalFile = root.url.appending(path: "Original.txt")
        let replacementFile = root.url.appending(path: "Replacement.txt")
        let archive = root.url.appending(path: "Archive.zip")
        let replacementArchive = root.url.appending(path: "Replacement.zip")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("original".utf8).write(to: originalFile)
        try Data("replacement".utf8).write(to: replacementFile)
        let builder = LiveArchiveCommandRunner()
        try await builder.run(
            kind: .compress,
            format: .zip,
            sources: [originalFile],
            destination: archive
        )
        try await builder.run(
            kind: .compress,
            format: .zip,
            sources: [replacementFile],
            destination: replacementArchive
        )
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: [archive],
            finalDestination: extraction
        )
        let fileSystem = LiveFileSystemAccess(onBeforeCopySourceEntryOpen: { opened in
            guard opened.standardizedFileURL == archive.standardizedFileURL else { return }
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.moveItem(at: replacementArchive, to: archive)
        })
        let service = ArchiveOperationService(fileSystem: fileSystem)

        let result = await service.perform([request]) { _ in }

        guard case let .failed(source, _) = result.outcomes.first else {
            Issue.record("Expected replaced archive input to fail closed")
            return
        }
        #expect(source == archive)
        #expect(FileManager.default.fileExists(atPath: extraction.path) == false)
        #expect(try Data(contentsOf: archive) != Data())
        try expectNoStagingDirectories(in: root.url)
    }

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
        try expectNoStagingDirectories(in: root.url)
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
        try expectNoStagingDirectories(in: root.url)
    }

    @Test(arguments: [
        (ArchiveFormat.tarGzip, ".tgz"),
        (ArchiveFormat.tarBzip2, ".tbz"),
        (ArchiveFormat.tarBzip2, ".tbz2"),
        (ArchiveFormat.tarXz, ".txz")
    ])
    func tarFamilyExtractionSupportsRenamedCompressedAliases(
        format: ArchiveFormat,
        aliasSuffix: String
    ) async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Alias fixture.txt")
        let canonicalArchive = root.url.appending(path: "Archive\(format.canonicalSuffix)")
        let aliasArchive = root.url.appending(path: "Archive\(aliasSuffix)")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        let expectedContent = Data("renamed TAR-family alias".utf8)
        try expectedContent.write(to: source)

        let runner = LiveArchiveCommandRunner()
        try await runner.run(
            kind: .compress,
            format: format,
            sources: [source],
            destination: canonicalArchive
        )
        try FileManager.default.moveItem(at: canonicalArchive, to: aliasArchive)
        try await runner.run(
            kind: .extract,
            format: format,
            sources: [aliasArchive],
            destination: extraction
        )

        #expect(try Data(contentsOf: extraction.appending(path: source.lastPathComponent))
            == expectedContent)
    }

    @Test(arguments: [
        ArchiveFormat.tar,
        ArchiveFormat.tarGzip,
        ArchiveFormat.tarBzip2,
        ArchiveFormat.tarXz
    ])
    func tarFamilyCompressionPreservesATopLevelSelectedSymbolicLink(
        format: ArchiveFormat
    ) async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let target = root.url.appending(path: "Target.txt")
        let selectedLink = root.url.appending(path: "Selected Link.txt")
        let archive = root.url.appending(path: "Link\(format.canonicalSuffix)")
        let extraction = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("target bytes must not be followed".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: selectedLink.path,
            withDestinationPath: target.lastPathComponent
        )

        let runner = LiveArchiveCommandRunner()
        try await runner.run(
            kind: .compress,
            format: format,
            sources: [selectedLink],
            destination: archive
        )
        try await runner.run(
            kind: .extract,
            format: format,
            sources: [archive],
            destination: extraction
        )

        let extractedLink = extraction.appending(path: selectedLink.lastPathComponent)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: extractedLink.path
        ) == target.lastPathComponent)
        #expect(FileManager.default.fileExists(
            atPath: extraction.appending(path: target.lastPathComponent).path
        ) == false)
    }

    @Test func hostileTarTraversalAndSymbolicLinkEscapeIsRejectedWithoutWritingOutside() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Hostile.tar")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        let outsideTarget = root.url.appending(path: "outside-target.txt")
        try writeHostileTarFixture(to: archive)

        let service = ArchiveOperationService(
            fileSystem: LiveFileSystemAccess(),
            commandRunner: LiveArchiveCommandRunner()
        )
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: [archive],
            finalDestination: destination,
            format: .tar
        )

        let result = await service.perform([request]) { _ in }

        guard case .failed = result.outcomes.first else {
            Issue.record("Expected hostile TAR extraction failure")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(FileManager.default.fileExists(atPath: outsideTarget.path) == false)
        try expectNoStagingDirectories(in: root.url)
    }

    @Test func malformedArchiveRemovesIdentityOwnedPartialOutput() async throws {
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
            Issue.record("Expected malformed archive extraction failure")
            return
        }
        #expect(source == malformedArchive)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        try expectNoStagingDirectories(in: root.url)
    }
}

private actor ArchivePhaseCollector {
    private(set) var values: [ArchiveOperationPhase] = []

    func append(_ phase: ArchiveOperationPhase) {
        values.append(phase)
    }
}

private func expectNoStagingDirectories(in directory: URL) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(children.contains { $0.lastPathComponent.hasPrefix(".bloom-staging-") } == false)
}

private func writeHostileTarFixture(to destination: URL) throws {
    let entries = [
        USTARFixtureEntry(name: "../direct-outside.txt", data: Data("direct escape".utf8)),
        USTARFixtureEntry(name: "escape", type: 0x32, linkName: ".."),
        USTARFixtureEntry(name: "escape/outside-target.txt", data: Data("symlink escape".utf8))
    ]
    var archive = Data()
    for entry in entries {
        archive.append(try entry.encoded())
    }
    archive.append(Data(repeating: 0, count: 1_024))
    try archive.write(to: destination)
}

private struct USTARFixtureEntry {
    let name: String
    var type: UInt8 = 0x30
    var linkName = ""
    var data = Data()

    func encoded() throws -> Data {
        precondition(name.utf8.count <= 100)
        precondition(linkName.utf8.count <= 100)
        precondition(data.count <= 512)

        var header = Data(repeating: 0, count: 512)
        header.writeUTF8(name, at: 0, maximumLength: 100)
        header.writeOctal(0o644, at: 100, length: 8)
        header.writeOctal(0, at: 108, length: 8)
        header.writeOctal(0, at: 116, length: 8)
        header.writeOctal(data.count, at: 124, length: 12)
        header.writeOctal(0, at: 136, length: 12)
        header.replaceSubrange(148..<156, with: Data(repeating: 0x20, count: 8))
        header[156] = type
        header.writeUTF8(linkName, at: 157, maximumLength: 100)
        header.writeUTF8("ustar", at: 257, maximumLength: 6)
        header.writeUTF8("00", at: 263, maximumLength: 2)
        header.writeUTF8("root", at: 265, maximumLength: 32)
        header.writeUTF8("root", at: 297, maximumLength: 32)
        let checksum = header.reduce(0) { $0 + Int($1) }
        header.writeOctal(checksum, at: 148, length: 8)

        var encoded = header
        encoded.append(data)
        let padding = (512 - data.count % 512) % 512
        encoded.append(Data(repeating: 0, count: padding))
        return encoded
    }
}

private extension Data {
    mutating func writeUTF8(_ value: String, at offset: Int, maximumLength: Int) {
        let bytes = Array(value.utf8)
        replaceSubrange(offset..<(offset + Swift.min(bytes.count, maximumLength)), with: bytes)
    }

    mutating func writeOctal(_ value: Int, at offset: Int, length: Int) {
        let digits = String(value, radix: 8)
        precondition(digits.count < length)
        let field = String(repeating: "0", count: length - 1 - digits.count)
            + digits + "\0"
        writeUTF8(field, at: offset, maximumLength: length)
    }
}
