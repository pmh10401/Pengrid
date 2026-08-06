import Foundation
import Testing
@testable import BloomFileManager

@Suite("RoutingArchiveOperationServiceTests")
struct RoutingArchiveOperationServiceTests {
    @Test @MainActor func literalRoutesPreserveProtectedAndOrdinaryKinds() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let archive = root.url.appending(path: "Archive.zip")
        let tar = root.url.appending(path: "Archive.tar")
        try Data("source".utf8).write(to: source)
        try Data("archive".utf8).write(to: archive)
        try Data("tar".utf8).write(to: tar)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let protectedCompression = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: root.url.appending(path: "Protected.zip"),
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let encryptedExtraction = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: root.url.appending(path: "Encrypted", directoryHint: .isDirectory),
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let ordinaryZIPExtraction = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: root.url.appending(path: "Ordinary", directoryHint: .isDirectory),
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let tarExtraction = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([tar]),
            finalDestination: root.url.appending(path: "Tar", directoryHint: .isDirectory),
            destinationParentIdentity: parentIdentity,
            format: .tar
        )
        let engine = RecordingRouteEngine()
        await engine.setInspections([
            ProtectedZIPInspection(hasEncryptedEntries: true),
            ProtectedZIPInspection()
        ])
        let protected = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: RecordingArchivePasswordProvider(passwords: []),
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )
        let ordinary = ArchiveOperationService(fileSystem: fileSystem, commandRunner: NoopArchiveCommandRunner())
        let router = RoutingArchiveOperationService(ordinary: ordinary, protected: protected)

        #expect(await router.route(for: protectedCompression) == .protected)
        #expect(await router.route(for: encryptedExtraction) == .protected)
        #expect(await router.route(for: ordinaryZIPExtraction) == .ordinary)
        #expect(await router.route(for: tarExtraction) == .ordinary)
    }

    @Test func mergingRetainsRequestOrderAndMetadata() {
        let first = URL(filePath: "/tmp/first")
        let second = URL(filePath: "/tmp/second")
        let destination = URL(filePath: "/tmp/output")
        let firstResult = FileOperationResult(
            outcomes: [.succeeded(source: first, destination: destination)],
            safeRelativePathsBySource: [first: try! ComparisonRelativePath(components: ["first"])],
            undoDestinationIdentities: [destination: FileIdentity(entryIdentifier: "a", resolvedIdentifier: "a")]
        )
        let secondResult = FileOperationResult(
            outcomes: [.failed(source: second, message: "safe")],
            safeRelativePathsBySource: [second: try! ComparisonRelativePath(components: ["second"])],
            undoDestinationFingerprints: [destination: SourceFingerprint(entries: [])]
        )

        let merged = firstResult.merging(secondResult)

        #expect(merged.outcomes == firstResult.outcomes + secondResult.outcomes)
        #expect(merged.safeRelativePath(for: first)?.components == ["first"])
        #expect(merged.safeRelativePath(for: second)?.components == ["second"])
        #expect(merged.undoDestinationIdentity(for: destination)?.entryIdentifier == "a")
        #expect(merged.undoDestinationFingerprint(for: destination)?.entries == Array<SourceFingerprint.Entry>())
    }

    @Test @MainActor func performPreservesRequestOrderAcrossRoutes() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let first = root.url.appending(path: "First.txt")
        let second = root.url.appending(path: "Second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let parentIdentity = try #require(await LiveFileSystemAccess().identity(of: root.url))
        let ordinary = Task8RecordingArchiveOperator(route: .ordinary)
        let protected = Task8RecordingProtectedOperator()
        let router = RoutingArchiveOperationService(
            ordinary: ordinary,
            protected: protected
        )
        let ordinaryRequest = ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([first]),
            finalDestination: root.url.appending(path: "First.zip"),
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let protectedRequest = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([second]),
            finalDestination: root.url.appending(path: "Second.zip"),
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))

        let result = await router.perform([ordinaryRequest, protectedRequest]) { _ in }

        #expect(result.outcomes.map { outcome in
            switch outcome {
            case let .succeeded(source, _): source.lastPathComponent
            default: "unexpected"
            }
        } == ["First.txt", "Second.txt"])
        #expect(await ordinary.sources == [first])
        #expect(await protected.sources == [second])
    }
}

private actor RecordingRouteEngine: ProtectedZIPEngine {
    private var inspections: [ProtectedZIPInspection]

    init(inspections: [ProtectedZIPInspection] = []) {
        self.inspections = inspections
    }

    func setInspections(_ values: [ProtectedZIPInspection]) {
        inspections = values
    }

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        inspections.isEmpty ? ProtectedZIPInspection() : inspections.removeFirst()
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection { ProtectedZIPInspection() }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}
}

private struct NoopArchiveCommandRunner: ArchiveCommandRunning {
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> FileIdentity { FileIdentity(entryIdentifier: "noop", resolvedIdentifier: "noop") }
}

private actor Task8RecordingArchiveOperator: ArchiveOperating {
    let route: ArchiveOperationRoute
    private(set) var sources: [URL] = []

    init(route: ArchiveOperationRoute) {
        self.route = route
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        for request in requests {
            sources.append(contentsOf: request.verifiedSources.map(\.url))
        }
        return FileOperationResult(outcomes: requests.map {
            .succeeded(source: $0.verifiedSources[0].url, destination: $0.finalDestination)
        })
    }
}

private actor Task8RecordingProtectedOperator: ProtectedZIPOperating {
    private(set) var sources: [URL] = []

    func classify(_ request: ArchiveRequest) async -> ArchiveOperationRoute {
        request.protection == .aes256 ? .protected : .ordinary
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        for request in requests {
            sources.append(contentsOf: request.verifiedSources.map(\.url))
        }
        return FileOperationResult(outcomes: requests.map {
            .succeeded(source: $0.verifiedSources[0].url, destination: $0.finalDestination)
        })
    }
}
