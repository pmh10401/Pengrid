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
        #expect(LiveArchiveSourcePreparationService.aggregatePreparationWorkerCount(
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

    @Test func postProcessIdentityLookupErrorCleansOutputAndPreparedSources() async {
        let destination = URL(filePath: "/tmp/runner-verification-error.zip")
        let parentIdentity = FileIdentity(
            entryIdentifier: "parent",
            resolvedIdentifier: "parent"
        )
        let outputIdentity = FileIdentity(
            entryIdentifier: "output",
            resolvedIdentifier: "output"
        )
        let fileSystem = RunnerVerificationFileSystem(
            destination: destination,
            parentIdentity: parentIdentity,
            outputIdentity: outputIdentity,
            identityError: .lookupFailed
        )
        let sourcePreparer = RecordingArchiveSourcePreparer(
            prepared: PreparedArchiveSources.fixture()
        )
        let runner = LiveArchiveCommandRunner(
            fileSystem: fileSystem,
            sourcePreparer: sourcePreparer,
            nativeProcess: { _, _, _, _ in }
        )

        await #expect(throws: RunnerVerificationError.lookupFailed) {
            try await runner.run(
                kind: .compress,
                format: .zip,
                sources: [IdentifiedFileRequest(
                    url: URL(filePath: "/tmp/source.txt"),
                    identity: outputIdentity
                )],
                destination: destination,
                destinationParentIdentity: parentIdentity
            )
        }
        #expect(await fileSystem.removedOutputIdentities == [outputIdentity])
        #expect(await sourcePreparer.cleanupCount == 1)
    }

    @Test func postProcessIdentityLookupCleanupFailureRequiresRecovery() async {
        let destination = URL(filePath: "/tmp/runner-verification-cleanup-error.zip")
        let parentIdentity = FileIdentity(
            entryIdentifier: "parent",
            resolvedIdentifier: "parent"
        )
        let outputIdentity = FileIdentity(
            entryIdentifier: "output",
            resolvedIdentifier: "output"
        )
        let fileSystem = RunnerVerificationFileSystem(
            destination: destination,
            parentIdentity: parentIdentity,
            outputIdentity: outputIdentity,
            identityError: .lookupFailed
        )
        let sourcePreparer = RecordingArchiveSourcePreparer(
            prepared: PreparedArchiveSources.fixture(),
            cleanupError: .cleanupFailed
        )
        let runner = LiveArchiveCommandRunner(
            fileSystem: fileSystem,
            sourcePreparer: sourcePreparer,
            nativeProcess: { _, _, _, _ in }
        )

        await #expect(throws: ArchiveOperationError.recoveryRequired) {
            try await runner.run(
                kind: .compress,
                format: .zip,
                sources: [IdentifiedFileRequest(
                    url: URL(filePath: "/tmp/source.txt"),
                    identity: outputIdentity
                )],
                destination: destination,
                destinationParentIdentity: parentIdentity
            )
        }
        #expect(await fileSystem.removedOutputIdentities == [outputIdentity])
        #expect(await sourcePreparer.cleanupCount == 1)
    }

    @Test func spawnWorkingDirectoryUsesTheMacOS15SDKCompatibleFunction() throws {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appending(
            path: "Sources/BloomFileManager/Services/ArchiveCommandRunner.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("posix_spawn_file_actions_addfchdir_np("))
        #expect(!source.contains("posix_spawn_file_actions_addfchdir("))
    }
}

private enum RunnerVerificationError: Error, Equatable {
    case lookupFailed
    case cleanupFailed
}

private actor RecordingArchiveSourcePreparer: ArchiveSourcePreparing {
    let prepared: PreparedArchiveSources
    let cleanupError: RunnerVerificationError?
    private(set) var cleanupCount = 0

    init(
        prepared: PreparedArchiveSources,
        cleanupError: RunnerVerificationError? = nil
    ) {
        self.prepared = prepared
        self.cleanupError = cleanupError
    }

    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources {
        prepared
    }

    func cleanup(_ prepared: PreparedArchiveSources) async throws {
        cleanupCount += 1
        if let cleanupError {
            throw cleanupError
        }
    }
}

private actor RunnerVerificationFileSystem: FileSystemAccess {
    let destination: URL
    let parentIdentity: FileIdentity
    let outputIdentity: FileIdentity
    let identityError: RunnerVerificationError?
    private(set) var removedOutputIdentities: [FileIdentity] = []

    init(
        destination: URL,
        parentIdentity: FileIdentity,
        outputIdentity: FileIdentity,
        identityError: RunnerVerificationError?
    ) {
        self.destination = destination
        self.parentIdentity = parentIdentity
        self.outputIdentity = outputIdentity
        self.identityError = identityError
    }

    func exists(_ url: URL) async -> Bool { false }

    func createDirectory(_ url: URL) async throws {}

    func createEmptyItemAndCaptureIdentity(
        _ url: URL,
        kind: EmptyFileSystemItemKind,
        parentIdentifiedBy expectedParentIdentity: FileIdentity
    ) async throws -> OpenedEmptyFileSystemItem {
        guard url == destination, expectedParentIdentity == parentIdentity else {
            throw RunnerVerificationError.lookupFailed
        }
        return OpenedEmptyFileSystemItem(identity: outputIdentity, descriptor: -1)
    }

    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity {
        outputIdentity
    }

    func move(_ source: URL, to destination: URL) async throws {}

    func moveExclusively(_ source: URL, to destination: URL) async throws {}

    func remove(_ url: URL) async throws {}

    func replace(_ destination: URL, with stagedItem: URL) async throws {}

    func identity(of url: URL) async throws -> FileIdentity? {
        if url == destination, let identityError {
            throw identityError
        }
        return parentIdentity
    }

    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws {}

    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        if url == destination {
            removedOutputIdentities.append(identity)
        }
    }

    func replace(
        _ destination: URL,
        identifiedBy destinationIdentity: FileIdentity,
        with stagedItem: URL,
        identifiedBy stagedIdentity: FileIdentity
    ) async throws {}

    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation {
        PreparedArchiveSources.fixture().reservation
    }

    func removeStagingDirectory(_ reservation: StagingReservation) async throws {}

    func fingerprint(of source: URL) async throws -> SourceFingerprint {
        SourceFingerprint(entries: [])
    }

    func trash(_ url: URL) async throws {}

    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws {}

    func trashAndReturnResultingURL(
        _ url: URL,
        identifiedBy identity: FileIdentity
    ) async throws -> URL? { nil }

    func quarantineForTrash(
        _ url: URL,
        identifiedBy identity: FileIdentity
    ) async throws -> StorageTrashQuarantine {
        fatalError("unused")
    }

    func moveTrashQuarantineAtomically(
        _ quarantine: StorageTrashQuarantine
    ) async throws -> URL {
        fatalError("unused")
    }

    func names(in directory: URL) async throws -> Set<String> { [] }

    func volumeIdentifier(for url: URL) async throws -> String { "test" }

    func byteSize(of url: URL) async throws -> Int64? { nil }

    func availableCapacity(at url: URL) async throws -> Int64? { nil }

    func prepareDirectoryHierarchy(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        relativeComponents: [String]
    ) async throws -> PreparedDirectoryHierarchy {
        fatalError("unused")
    }

    func removeEmptyOwnedDirectories(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        directories: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) async throws {}
}

private extension PreparedArchiveSources {
    static func fixture() -> PreparedArchiveSources {
        let root = URL(filePath: "/tmp/prepared-archive-sources")
        let identity = FileIdentity(
            entryIdentifier: "staging",
            resolvedIdentifier: "staging"
        )
        return PreparedArchiveSources(
            root: root,
            reservation: StagingReservation(
                directory: root,
                directoryIdentity: identity,
                item: root.appending(path: "payload")
            ),
            copiedEntries: []
        )
    }
}
