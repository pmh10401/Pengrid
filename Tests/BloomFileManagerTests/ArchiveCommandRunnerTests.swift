import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ArchiveCommandRunnerTests {
    @Test func directCompressionArgumentsKeepASpacedSourcePathSeparate() throws {
        let source = URL(filePath: "/tmp/Project Notes")
        let destination = URL(filePath: "/tmp/Archive.zip")

        let arguments = try LiveArchiveCommandRunner.arguments(
            kind: .compress,
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
}
