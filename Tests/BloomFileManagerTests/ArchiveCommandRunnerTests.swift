import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ArchiveCommandRunnerTests {
    @Test func directCompressionArgumentsKeepASpacedSourcePathSeparate() throws {
        let source = URL(filePath: "/tmp/Project Notes")
        let destination = URL(filePath: "/tmp/Archive.zip")

        let arguments = try LiveArchiveCommandRunner.arguments(
            kind: .compress,
            format: .zip,
            sources: [source],
            destination: destination
        )

        #expect(arguments == [
            "-c",
            "-k",
            "--keepParent",
            "--sequesterRsrc",
            "/tmp/Project Notes",
            "/tmp/Archive.zip"
        ])
    }

    @Test func directCompressionArgumentsRejectMultipleDittoArchiveSources() {
        #expect(throws: ArchiveOperationError.invalidRequest) {
            try LiveArchiveCommandRunner.arguments(
                kind: .compress,
                format: .zip,
                sources: [
                    URL(filePath: "/tmp/First.txt"),
                    URL(filePath: "/tmp/Second.txt")
                ],
                destination: URL(filePath: "/tmp/Archive.zip")
            )
        }
    }

    @Test func extractionArgumentsKeepArchivePathSeparate() throws {
        let source = URL(filePath: "/tmp/Project Archive.zip")
        let destination = URL(filePath: "/tmp/Project Archive")

        let arguments = try LiveArchiveCommandRunner.arguments(
            kind: .extract,
            format: .zip,
            sources: [source],
            destination: destination
        )

        #expect(arguments == [
            "-x",
            "-k",
            "/tmp/Project Archive.zip",
            "/tmp/Project Archive"
        ])
    }

    @Test(arguments: [
        (ArchiveFormat.tar, []),
        (ArchiveFormat.tarGzip, ["-z"]),
        (ArchiveFormat.tarBzip2, ["-j"]),
        (ArchiveFormat.tarXz, ["-J"])
    ])
    func tarCompressionArgumentsUseTheAggregateSourceRoot(
        format: ArchiveFormat,
        compressionFlag: [String]
    ) throws {
        let aggregateRoot = URL(filePath: "/tmp/.archive-source")
        let destination = URL(filePath: "/tmp/Archive\(format.canonicalSuffix)")

        let arguments = try LiveArchiveCommandRunner.arguments(
            kind: .compress,
            format: format,
            sources: [aggregateRoot],
            destination: destination
        )

        #expect(arguments == ["-c"] + compressionFlag + [
            "-f",
            destination.path,
            "-C",
            aggregateRoot.path,
            "."
        ])
    }

    @Test(arguments: [
        (ArchiveFormat.zip, ["-c", "-k", "--sequesterRsrc"]),
        (ArchiveFormat.tar, ["-c"]),
        (ArchiveFormat.tarGzip, ["-c", "-z"]),
        (ArchiveFormat.tarBzip2, ["-c", "-j"]),
        (ArchiveFormat.tarXz, ["-c", "-J"])
    ])
    func preparedMultiSourceCompressionUsesOneAggregateSource(
        format: ArchiveFormat,
        prefix: [String]
    ) {
        let aggregateRoot = URL(filePath: "/tmp/.archive-source")
        let destination = URL(filePath: "/tmp/Archive\(format.canonicalSuffix)")

        let arguments = LiveArchiveCommandRunner.preparedCompressionArguments(
            format: format,
            aggregateRoot: aggregateRoot,
            destination: destination
        )

        if format == .zip {
            #expect(arguments == prefix + [aggregateRoot.path, destination.path])
        } else {
            #expect(arguments == prefix + [
                "-f", destination.path,
                "-C", aggregateRoot.path,
                "."
            ])
        }
    }

    @Test(arguments: [
        (sourceCount: 2, processorCount: 16, expected: 2),
        (sourceCount: 9, processorCount: 8, expected: 4),
        (sourceCount: 9, processorCount: 3, expected: 3),
        (sourceCount: 9, processorCount: 1, expected: 1),
        (sourceCount: 9, processorCount: 0, expected: 1)
    ])
    func aggregatePreparationWorkerCountCapsSourcesAndProcessors(
        sourceCount: Int,
        processorCount: Int,
        expected: Int
    ) {
        #expect(LiveArchiveCommandRunner.aggregatePreparationWorkerCount(
            sourceCount: sourceCount,
            activeProcessorCount: processorCount
        ) == expected)
    }

    @Test(arguments: [
        (ArchiveFormat.tar, []),
        (ArchiveFormat.tarGzip, ["-z"]),
        (ArchiveFormat.tarBzip2, ["-j"]),
        (ArchiveFormat.tarXz, ["-J"])
    ])
    func tarExtractionArgumentsUseTheRequestedCompressionFlag(
        format: ArchiveFormat,
        compressionFlag: [String]
    ) throws {
        let archive = URL(filePath: "/tmp/Archive\(format.canonicalSuffix)")
        let destination = URL(filePath: "/tmp/Extracted")

        let arguments = try LiveArchiveCommandRunner.arguments(
            kind: .extract,
            format: format,
            sources: [archive],
            destination: destination
        )

        #expect(arguments == ["-x"] + compressionFlag + [
            "-k",
            "-f",
            archive.path,
            "-C",
            destination.path
        ])
    }

    @Test(arguments: [
        (
            ArchiveOperationKind.compress,
            ArchiveFormat.zip,
            ["-c", "source", "/tmp/output.zip"],
            ["-c", "source", "/dev/fd/1"]
        ),
        (
            ArchiveOperationKind.compress,
            ArchiveFormat.tar,
            ["-c", "-f", "/tmp/output.tar", "-C", "source", "."],
            ["-c", "-f", "-", "-C", "source", "."]
        ),
        (
            ArchiveOperationKind.extract,
            ArchiveFormat.zip,
            ["-x", "archive.zip", "/tmp/output"],
            ["-x", "archive.zip", "."]
        ),
        (
            ArchiveOperationKind.extract,
            ArchiveFormat.tar,
            ["-x", "-f", "archive.tar", "-C", "/tmp/output"],
            ["-x", "-f", "archive.tar", "-C", "."]
        )
    ])
    func nativeArgumentsBindOutputToOpenedDescriptor(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        input: [String],
        expected: [String]
    ) {
        #expect(LiveArchiveCommandRunner.argumentsBoundToOpenedOutput(
            input,
            kind: kind,
            format: format
        ) == expected)
    }
}
