import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ArchiveCommandRunnerTests {
    @Test func compressionArgumentsKeepSourcePathsSeparate() throws {
        let sources = [
            URL(filePath: "/tmp/Project Notes"),
            URL(filePath: "/tmp/photo.jpg")
        ]
        let destination = URL(filePath: "/tmp/Archive.zip")

        let arguments = try LiveArchiveCommandRunner.arguments(
            kind: .compress,
            sources: sources,
            destination: destination
        )

        #expect(arguments == [
            "-c",
            "-k",
            "--keepParent",
            "--sequesterRsrc",
            "/tmp/Project Notes",
            "/tmp/photo.jpg",
            "/tmp/Archive.zip"
        ])
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
