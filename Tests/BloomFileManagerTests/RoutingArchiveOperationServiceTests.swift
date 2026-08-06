import Foundation
import Testing
import Darwin
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

    @Test @MainActor func routerClassifiesOriginalThenProtectedServiceReinspectsStagedCopy() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let engine = RecordingRouteEngine(inspections: [
            ProtectedZIPInspection(hasEncryptedEntries: true),
            ProtectedZIPInspection(hasEncryptedEntries: true)
        ])
        let protected = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: RecordingArchivePasswordProvider(passwords: ["route-passphrase"]),
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )
        let ordinary = ArchiveOperationService(
            fileSystem: fileSystem,
            commandRunner: NoopArchiveCommandRunner()
        )
        let router = RoutingArchiveOperationService(ordinary: ordinary, protected: protected)

        let result = await router.perform([request]) { _ in }

        #expect(result.outcomes == [.succeeded(source: archive, destination: destination)])
        #expect(await engine.events == ["inspect", "inspect", "preflight"])
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

    @Test @MainActor func unsupportedRouteReturnsOneRedactedFailureWithoutPerformingEitherService() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Unsupported.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("unsupported fixture".utf8).write(to: archive)
        let parentIdentity = try #require(await LiveFileSystemAccess().identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let ordinary = Task8CountingArchiveOperator()
        let protected = Task8UnsupportedProtectedOperator()
        let router = RoutingArchiveOperationService(ordinary: ordinary, protected: protected)

        let result = await router.perform([request]) { _ in }

        #expect(result.outcomes.count == 1)
        guard case let .failed(source, message) = result.outcomes[0] else {
            Issue.record("unsupported route must return one failed safe outcome")
            return
        }
        #expect(source == archive)
        #expect(message == ProtectedZIPError.unsupportedEncryption.errorDescription!)
        #expect(message.contains("raw-route-sentinel") == false)
        #expect(await ordinary.performCount == 0)
        #expect(await protected.performCount == 0)
    }

    @Test @MainActor func mixedActualRouterPerformMergesOutcomesAndUndoMetadataInInputOrder() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let firstSource = root.url.appending(path: "First.txt")
        let secondSource = root.url.appending(path: "Second.txt")
        let firstDestination = root.url.appending(path: "First.zip")
        let secondDestination = root.url.appending(path: "Second.zip")
        let firstSafePath = try! ComparisonRelativePath(components: ["ordinary", "First.txt"])
        let secondSafePath = try! ComparisonRelativePath(components: ["protected", "Second.txt"])
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let ordinaryRequest = ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([firstSource]),
            finalDestination: firstDestination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let protectedRequest = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([secondSource]),
            finalDestination: secondDestination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let ordinaryService = ArchiveOperationService(
            fileSystem: fileSystem,
            commandRunner: Task8WritingArchiveCommandRunner(fileSystem: fileSystem)
        )
        let ordinary = Task8SafePathArchiveService(
            base: ordinaryService,
            safePaths: [firstSource: firstSafePath]
        )
        let protectedService = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            sourcePreparer: LiveArchiveSourcePreparationService(fileSystem: fileSystem),
            passwordProvider: RecordingArchivePasswordProvider(
                passwords: ["mixed-protected-passphrase"]
            ),
            engine: RoutingFactoryEngine(),
            logger: RecordingProtectedZIPLogger()
        )
        let protected = Task8SafePathProtectedService(
            base: protectedService,
            safePaths: [secondSource: secondSafePath]
        )
        let router = RoutingArchiveOperationService(ordinary: ordinary, protected: protected)

        let result = await router.perform([ordinaryRequest, protectedRequest]) { _ in }

        let expectedOutcomes: [FileOperationItemOutcome] = [
            .succeeded(source: firstSource, destination: firstDestination),
            .succeeded(source: secondSource, destination: secondDestination)
        ]
        #expect(result.outcomes == expectedOutcomes)
        #expect(result.undoDestinationIdentity(for: firstDestination) != nil)
        #expect(result.undoDestinationIdentity(for: secondDestination) != nil)
        #expect(result.undoDestinationFingerprint(for: firstDestination) != nil)
        #expect(result.undoDestinationFingerprint(for: secondDestination) != nil)
        #expect(result.safeRelativePath(for: firstSource) == firstSafePath)
        #expect(result.safeRelativePath(for: secondSource) == secondSafePath)
        #expect(FileManager.default.fileExists(atPath: firstDestination.path))
        #expect(FileManager.default.fileExists(atPath: secondDestination.path))
    }

    @Test @MainActor func routerClassificationAndProtectedPerformUseDistinctStagedArchiveIdentity() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let archive = root.url.appending(path: "Encrypted.zip")
        let destination = root.url.appending(path: "Extracted", directoryHint: .isDirectory)
        try Data("encrypted fixture".utf8).write(to: archive)
        let fileSystem = LiveFileSystemAccess()
        let sourceIdentity = try #require(await fileSystem.identity(of: archive))
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = ArchiveRequest(
            kind: .extract,
            verifiedSources: identifiedArchiveTestSources([archive]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip
        )
        let engine = Task8IdentityRecordingEngine()
        let protected = ProtectedZIPOperationService(
            fileSystem: fileSystem,
            passwordProvider: RecordingArchivePasswordProvider(
                passwords: ["staged-identity-passphrase"]
            ),
            engine: engine,
            logger: RecordingProtectedZIPLogger()
        )
        let router = RoutingArchiveOperationService(
            ordinary: ArchiveOperationService(
                fileSystem: fileSystem,
                commandRunner: NoopArchiveCommandRunner()
            ),
            protected: protected
        )

        let result = await router.perform([request]) { _ in }
        let observations = await engine.observations

        #expect(result.outcomes == [.succeeded(source: archive, destination: destination)])
        #expect(observations.count == 4)
        #expect(observations[0].phase == "inspect")
        #expect(observations[0].identity == sourceIdentity)
        #expect(URL(filePath: observations[0].path).resolvingSymlinksInPath().path
            == archive.resolvingSymlinksInPath().path)
        #expect(observations[1].phase == "inspect")
        #expect(observations[1].identity != sourceIdentity)
        #expect(URL(filePath: observations[1].path).resolvingSymlinksInPath().path
            != archive.resolvingSymlinksInPath().path)
        #expect(observations[2].phase == "preflight")
        #expect(observations[2].identity == observations[1].identity)
        #expect(observations[3].phase == "extract")
        #expect(observations[3].identity == observations[1].identity)
    }

    @Test @MainActor func factoryInjectsProtectedDependenciesAndRetainsThemThroughPublish() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let destination = root.url.appending(path: "Factory.zip")
        try Data("source".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let request = try #require(ArchiveRequest(
            kind: .compress,
            verifiedSources: identifiedArchiveTestSources([source]),
            finalDestination: destination,
            destinationParentIdentity: parentIdentity,
            format: .zip,
            protection: .aes256
        ))
        let provider = RecordingArchivePasswordProvider(passwords: ["factory-passphrase"])
        let engine = RoutingFactoryEngine()
        let logger = RecordingProtectedZIPLogger()
        let fileOperationService = FileOperationService(fileSystem: fileSystem)
        let router = fileOperationService.makeRoutingArchiveOperationService(
            passwordProvider: provider,
            protectedEngine: engine,
            protectedLogger: logger
        )

        let result = await router.perform([request]) { _ in }

        #expect(result.outcomes == [.succeeded(source: source, destination: destination)])
        #expect(provider.requestCount == 1)
        #expect(await engine.createCount == 1)
        #expect(await logger.events.last?.category == .compression)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}

private actor RecordingRouteEngine: ProtectedZIPEngine {
    private var inspections: [ProtectedZIPInspection]
    private(set) var events: [String] = []

    init(inspections: [ProtectedZIPInspection] = []) {
        self.inspections = inspections
    }

    func setInspections(_ values: [ProtectedZIPInspection]) {
        inspections = values
    }

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        events.append("inspect")
        return inspections.isEmpty ? ProtectedZIPInspection() : inspections.removeFirst()
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        events.append("preflight")
        return ProtectedZIPInspection()
    }

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

private struct Task8WritingArchiveCommandRunner: ArchiveCommandRunning {
    let fileSystem: any FileSystemAccess

    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [IdentifiedFileRequest],
        destination: URL,
        destinationParentIdentity: FileIdentity
    ) async throws -> FileIdentity {
        try Data("ordinary archive output".utf8).write(to: destination)
        return try #require(await fileSystem.identity(of: destination))
    }
}

private struct Task8SafePathArchiveService: ArchiveOperating {
    let base: any ArchiveOperating
    let safePaths: [URL: ComparisonRelativePath]

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        await base.perform(requests, progress: progress)
            .addingSafeRelativePaths(safePaths)
    }
}

private struct Task8SafePathProtectedService: ProtectedZIPOperating {
    let base: any ProtectedZIPOperating
    let safePaths: [URL: ComparisonRelativePath]

    func classify(_ request: ArchiveRequest) async -> ArchiveOperationRoute {
        await base.classify(request)
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        await base.perform(requests, progress: progress)
            .addingSafeRelativePaths(safePaths)
    }
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

private actor Task8CountingArchiveOperator: ArchiveOperating {
    private(set) var performCount = 0

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        performCount += 1
        return FileOperationResult(outcomes: requests.map {
            .failed(source: $0.verifiedSources[0].url, message: "raw-route-sentinel")
        })
    }
}

private actor Task8UnsupportedProtectedOperator: ProtectedZIPOperating {
    private(set) var performCount = 0

    func classify(_ request: ArchiveRequest) async -> ArchiveOperationRoute {
        .unsupported
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler
    ) async -> FileOperationResult {
        performCount += 1
        return FileOperationResult(outcomes: requests.map {
            .failed(source: $0.verifiedSources[0].url, message: "raw-route-sentinel")
        })
    }
}

private struct Task8ArchiveObservation: Sendable, Equatable {
    let phase: String
    let identity: FileIdentity
    let path: String
}

private actor Task8IdentityRecordingEngine: ProtectedZIPEngine {
    private(set) var observations: [Task8ArchiveObservation] = []

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        observations.append(observation("inspect", archive: archive))
        return ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        observations.append(observation("preflight", archive: archive))
        return ProtectedZIPInspection(hasEncryptedEntries: true, strongestAESStrength: 256)
    }

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
    ) async throws {
        observations.append(observation("extract", archive: archive))
    }

    private func observation(
        _ phase: String,
        archive: OpenedFileSystemItem
    ) -> Task8ArchiveObservation {
        let path = (try? archive.withUnsafeDescriptor { descriptor in
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard Darwin.fcntl(descriptor, F_GETPATH, &path) == 0 else {
                return ""
            }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }) ?? ""
        return Task8ArchiveObservation(
            phase: phase,
            identity: archive.identity,
            path: path
        )
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

private actor RoutingFactoryEngine: ProtectedZIPEngine {
    private(set) var createCount = 0

    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection()
    }

    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection {
        ProtectedZIPInspection()
    }

    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {
        createCount += 1
    }

    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws {}
}
