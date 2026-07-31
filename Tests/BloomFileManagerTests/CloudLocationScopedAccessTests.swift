import Foundation
import Testing
@testable import BloomFileManager

struct CloudLocationScopedAccessTests {
    @Test func manualAccessBalancesSuccessfulConsumption() async throws {
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let root = URL(filePath: "/Cloud/Manual", directoryHint: .isDirectory)
        coordinator.replaceManualRoots([root])

        let value = try await coordinator.withAccess(
            to: root.appending(path: "file.txt")
        ) {
            "consumed"
        }

        #expect(value == "consumed")
        #expect(driver.startedURLs == [root])
        #expect(driver.stoppedURLs == [root])
    }

    @Test func manualAccessBalancesThrowingConsumption() async {
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let root = URL(filePath: "/Cloud/Manual", directoryHint: .isDirectory)
        coordinator.replaceManualRoots([root])

        await #expect(throws: ScopedAccessTestError.failed) {
            try await coordinator.withAccess(to: root) {
                throw ScopedAccessTestError.failed
            }
        }

        #expect(driver.startedURLs == [root])
        #expect(driver.stoppedURLs == [root])
    }

    @Test func manualAccessBalancesCancelledConsumption() async {
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let root = URL(filePath: "/Cloud/Manual", directoryHint: .isDirectory)
        coordinator.replaceManualRoots([root])
        let gate = ScopedAccessCancellationGate()
        let operation = Task {
            try await coordinator.withAccess(to: root) {
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        await gate.waitUntilEntered()

        operation.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(driver.startedURLs == [root])
        #expect(driver.stoppedURLs == [root])
    }

    @Test func discoveredRootsDoNotRequestSecurityScopedAccess() async throws {
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let discovered = URL(filePath: "/Cloud/Discovered", directoryHint: .isDirectory)

        try await coordinator.withAccess(to: discovered) {}

        #expect(driver.startedURLs.isEmpty)
        #expect(driver.stoppedURLs.isEmpty)
    }

    @Test func accessStartsOnTheOriginalResolvedBookmarkURL() async throws {
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let resolvedBookmarkURL = URL(
            filePath: "/Cloud/Parent/../Manual",
            directoryHint: .isDirectory
        )
        let child = resolvedBookmarkURL.standardizedFileURL.appending(path: "child.txt")
        coordinator.replaceManualRoots([resolvedBookmarkURL])

        try await coordinator.withAccess(to: child) {}

        #expect(driver.startedURLs == [resolvedBookmarkURL])
        #expect(driver.stoppedURLs == [resolvedBookmarkURL])
    }

    @Test func directoryListingHoldsAccessUntilTheStreamFinishes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data("listed".utf8).write(to: directory.url.appending(path: "file.txt"))
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([directory.url])
        let service = LiveDirectoryListingService(accessCoordinator: coordinator)

        var items: [FileItem] = []
        for try await batch in service.batches(in: directory.url) {
            items += batch
        }

        #expect(items.map(\.name) == ["file.txt"])
        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @Test func materializationHoldsAccessUntilPreparationFinishes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "materialize.txt")
        try Data("materialized".utf8).write(to: file)
        let identity = try #require(try await LiveFileSystemAccess().identity(of: file))
        let request = IdentifiedFileRequest(url: file, identity: identity)
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([directory.url])
        let service = LiveCloudMaterializationService(accessCoordinator: coordinator)

        let result = await service.materialize([request], purpose: .open) { _ in }

        #expect(result.isReady)
        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @Test func checksumHoldsAccessAcrossPreparationAndByteReads() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "checksum.txt")
        try Data("checksum".utf8).write(to: file)
        let listed = try await LiveComparisonListingService().collect(.init(
            root: directory.url,
            seed: nil,
            subtree: nil,
            options: .init()
        ))
        let entry = try #require(listed.compactMap(\.entry).first { $0.url == file })
        let request = ChecksumRequest(
            url: file,
            fingerprint: entry.fingerprint
        )
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([directory.url])
        let service = LiveChecksumService(
            materializer: InMemoryCloudMaterializer(),
            accessCoordinator: coordinator
        )

        _ = try await service.checksum(for: request) { _ in }

        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @Test func fileOperationHoldsAccessUntilMutationFinishes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([directory.url])
        let service = FileOperationService(
            fileSystem: LiveFileSystemAccess(),
            accessCoordinator: coordinator
        )

        let created = try await service.createFolder(in: directory.url, named: "Created")

        #expect(created.lastPathComponent == "Created")
        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @MainActor
    @Test func runtimeDependenciesShareStoreRegistrationWithListingServices() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data("shared".utf8).write(to: directory.url.appending(path: "shared.txt"))
        let driver = RecordingSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let dependencies = CloudRuntimeDependencies(
            accessCoordinator: accessCoordinator
        )
        let store = CloudLocationsStore(
            storageURL: directory.url.appending(path: "cloud-locations.json"),
            discovery: EmptyScopedAccessDiscovery(),
            bookmarking: InMemoryCloudLocationBookmarking(),
            accessCoordinator: dependencies.accessCoordinator
        )
        try store.addManualLocation(directory.url)

        var items: [FileItem] = []
        for try await batch in dependencies.makeDirectoryListingService().batches(
            in: directory.url
        ) {
            items += batch
        }

        #expect(items.map(\.name).contains("shared.txt"))
        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @MainActor
    @Test func runtimeDependenciesShareOneFileSystemWithMaterializerAndCommands() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "shared-runtime.txt")
        try Data("shared".utf8).write(to: file)
        let identity = FileIdentity(
            entryIdentifier: "shared-runtime",
            resolvedIdentifier: "shared-runtime"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [file],
            identities: [file: identity]
        )
        let accessCoordinator = CloudLocationScopedAccessCoordinator()
        let dependencies = CloudRuntimeDependencies(
            accessCoordinator: accessCoordinator,
            fileSystem: fileSystem
        )
        let storage = StorageAnalysisStore(
            scanner: RuntimeWiringStorageScanner(),
            duplicates: RuntimeWiringDuplicateDetector(),
            locationPolicy: RuntimeWiringLocationPolicy()
        )
        let cleanup = StorageCleanupController(
            fingerprints: RuntimeWiringFingerprintReader()
        )
        let operations = FileOperationController(
            service: dependencies.makeFileOperationService(),
            materializer: dependencies.materializer
        )
        let commands = WorkspaceCommands(
            quickLookController: QuickLookController(),
            operationController: operations,
            storage: storage,
            storageCleanupController: cleanup,
            materializer: dependencies.materializer,
            fileSystem: dependencies.fileSystem,
            accessCoordinator: accessCoordinator
        )
        let request = IdentifiedFileRequest(url: file, identity: identity)
        let workspace = WorkspaceState(
            leftURL: directory.url,
            rightURL: directory.url,
            listingService: StubDirectoryListingService(values: [:])
        )

        let result = await dependencies.materializer.materialize(
            [request],
            purpose: .quickLook,
            progress: { _ in }
        )
        let materializationIdentityCount = await fileSystem.events.filter {
            $0 == "identity:\(file.path)"
        }.count
        let commandRequests = await WorkspaceOpenActions.identifiedRequests(
            for: [file],
            fileSystem: commands.fileSystem,
            accessCoordinator: commands.accessCoordinator
        )
        let afterCommandIdentityCount = await fileSystem.events.filter {
            $0 == "identity:\(file.path)"
        }.count
        #expect(operations.trash([request], workspace: workspace))
        while operations.isRunning {
            await Task.yield()
        }

        #expect(result.preparedRequests == [request])
        #expect(materializationIdentityCount >= 2)
        #expect(commandRequests == [request])
        #expect(afterCommandIdentityCount == materializationIdentityCount + 1)
        #expect(operations.lastResult?.hasFailures == false)
        #expect(await fileSystem.events.contains("trash:\(file.path)"))
    }

    @MainActor
    @Test func runtimeDependenciesShareRegisteredAccessWithArchiveOperations() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appending(path: "Selected.txt")
        let otherDirectory = directory.url.appending(
            path: "Other",
            directoryHint: .isDirectory
        )
        try Data("selected".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: otherDirectory,
            withIntermediateDirectories: false
        )
        let driver = RecordingSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([directory.url])
        let dependencies = CloudRuntimeDependencies(
            accessCoordinator: accessCoordinator
        )
        let workspace = WorkspaceState(
            leftURL: directory.url,
            rightURL: otherDirectory,
            listingService: StubDirectoryListingService(values: [
                directory.url: [
                    FileItem(
                        url: source,
                        name: source.lastPathComponent,
                        isDirectory: false,
                        isPackage: false,
                        modifiedAt: nil,
                        byteSize: 8,
                        typeDescription: "Text"
                    )
                ],
                otherDirectory: []
            ])
        )
        await workspace.loadInitialDirectories()
        workspace.left.selection = [source]
        let operations = FileOperationController(
            service: dependencies.makeFileOperationService(),
            materializer: dependencies.materializer
        )

        #expect(await operations.compressSelection(workspace))
        while operations.isRunning {
            await Task.yield()
        }

        let destination = directory.url.appending(path: "Selected.txt.zip")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(operations.lastResult == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: destination)
        ]))
        #expect(driver.startedURLs == Array(repeating: directory.url, count: 4))
        #expect(driver.stoppedURLs == driver.startedURLs)
    }

    @MainActor
    @Test func workspaceOpenAndRequestCaptureHoldAccessBeforeMaterialization() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "open.txt")
        try Data("open".utf8).write(to: file)
        let driver = RecordingSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([directory.url])
        let opener = ScopedAccessWorkspaceOpener()
        let pane = FilePaneState(
            directory: directory.url,
            listingService: StubDirectoryListingService(values: [:])
        )
        let item = FileItem(
            url: file,
            name: "open.txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 4,
            typeDescription: "Text"
        )

        await WorkspaceOpenActions.open(
            [item],
            in: pane,
            fileSystem: LiveFileSystemAccess(),
            materializer: InMemoryCloudMaterializer(),
            opener: opener,
            accessCoordinator: coordinator
        )
        let captured = await WorkspaceOpenActions.identifiedRequests(
            for: [file],
            fileSystem: LiveFileSystemAccess(),
            accessCoordinator: coordinator
        )

        #expect(opener.openedURLs == [file])
        #expect(captured?.map(\.url) == [file])
        #expect(driver.startedURLs == [directory.url, directory.url])
        #expect(driver.stoppedURLs == [directory.url, directory.url])
    }

    @MainActor
    @Test func storageQuickLookHoldsManualAccessThroughPresentation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "preview.txt")
        try Data("preview".utf8).write(to: file)
        let fileSystem = LiveFileSystemAccess()
        let identity = try #require(try await fileSystem.identity(of: file))
        let driver = RecordingSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([directory.url])
        var presented: [URL] = []
        let controller = QuickLookController { presented = $0 }
        let entry = try storageQuickLookEntry(url: file, identity: identity)

        await StorageInspectorItemActions.quickLook(
            entry: entry,
            controller: controller,
            materializer: InMemoryCloudMaterializer(),
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator
        )

        #expect(presented == [file])
        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @MainActor
    @Test func storageQuickLookBalancesAccessWhenIdentityChanged() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "changed.txt")
        try Data("changed".utf8).write(to: file)
        let driver = RecordingSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([directory.url])
        var presented: [URL] = []
        let entry = try storageQuickLookEntry(
            url: file,
            identity: FileIdentity(
                entryIdentifier: "reviewed",
                resolvedIdentifier: "reviewed"
            )
        )

        await StorageInspectorItemActions.quickLook(
            entry: entry,
            controller: QuickLookController { presented = $0 },
            materializer: InMemoryCloudMaterializer(),
            fileSystem: LiveFileSystemAccess(),
            accessCoordinator: accessCoordinator
        )

        #expect(presented.isEmpty)
        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @Test func recursiveComparisonListingHoldsAccessUntilEnumerationFinishes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data("comparison".utf8).write(to: directory.url.appending(path: "compared.txt"))
        let driver = RecordingSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([directory.url])
        let dependencies = CloudRuntimeDependencies(
            accessCoordinator: accessCoordinator
        )

        let records = try await dependencies.makeComparisonListingService().collect(.init(
            root: directory.url,
            seed: nil,
            subtree: nil,
            options: .init()
        ))

        #expect(records.compactMap(\.entry).map(\.url.lastPathComponent) == ["compared.txt"])
        #expect(driver.startedURLs == [directory.url])
        #expect(driver.stoppedURLs == [directory.url])
    }

    @MainActor
    @Test func runtimeDependenciesShareStoreRegistrationWithLongLivedMonitors() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let left = directory.url.appending(path: "left", directoryHint: .isDirectory)
        let right = directory.url.appending(path: "right", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: false)
        let driver = RecordingSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let dependencies = CloudRuntimeDependencies(accessCoordinator: accessCoordinator)
        let store = CloudLocationsStore(
            storageURL: directory.url.appending(path: "cloud-locations.json"),
            discovery: EmptyScopedAccessDiscovery(),
            bookmarking: InMemoryCloudLocationBookmarking(),
            accessCoordinator: dependencies.accessCoordinator
        )
        try store.addManualLocation(left)
        try store.addManualLocation(right)

        let directoryStream = dependencies.makeDirectoryMonitor().events(for: left)
        #expect(driver.startedURLs == [left])
        #expect(driver.stoppedURLs.isEmpty)

        let comparisonStream: AsyncStream<ComparisonTreeEvent>
        switch await dependencies.makeComparisonTreeMonitor().start(roots: [
            .left: left,
            .right: right
        ]) {
        case let .started(stream):
            comparisonStream = stream
        case .failed:
            Issue.record("Expected app-owned comparison monitor to start")
            return
        }
        #expect(driver.startedURLs == [left, left, right])
        #expect(driver.stoppedURLs.isEmpty)

        let directoryReader = Task { for await _ in directoryStream {} }
        directoryReader.cancel()
        await directoryReader.value
        #expect(await scopedAccessWait { driver.stoppedURLs.count == 1 })

        let comparisonReader = Task { for await _ in comparisonStream {} }
        comparisonReader.cancel()
        await comparisonReader.value
        #expect(await scopedAccessWait { driver.stoppedURLs.count == 3 })
        #expect(driver.stoppedURLs.sorted { $0.path < $1.path } == [left, left, right])
    }
}

private func storageQuickLookEntry(
    url: URL,
    identity: FileIdentity
) throws -> StorageEntry {
    StorageEntry(
        relativePath: try StorageRelativePath(components: [url.lastPathComponent]),
        url: url,
        kind: .regularFile,
        category: .document,
        fingerprint: ComparisonFingerprint(
            identity: identity,
            byteSize: 7,
            modifiedAt: nil
        ),
        typeDescription: "Text"
    )
}

private struct RuntimeWiringStorageScanner: StorageScanning {
    func identity(of root: URL) async throws -> FileIdentity {
        FileIdentity(entryIdentifier: root.path, resolvedIdentifier: root.path)
    }

    func batches(for _: StorageScanRequest)
        -> AsyncThrowingStream<StorageScanBatch, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct RuntimeWiringDuplicateDetector: StorageDuplicateDetecting {
    func events(for _: [StorageEntry])
        -> AsyncThrowingStream<StorageDuplicateDetectionEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private struct RuntimeWiringLocationPolicy: StorageScanLocationValidating {
    func decision(for root: URL) -> StorageScanLocationDecision {
        .allowed(StorageScanAdmissionToken(
            root: root.standardizedFileURL,
            rootIdentity: FileIdentity(
                entryIdentifier: root.path,
                resolvedIdentifier: root.path
            ),
            rootKind: .directory,
            volumeClassification: .local,
            authorization: .init(
                isProtectedLocation: false,
                protectedScanAuthorized: true,
                cleanupAuthorized: true
            )
        ))
    }
}

private actor RuntimeWiringFingerprintReader: StorageEntryFingerprintReading {
    func fingerprint(of _: URL) async throws -> ComparisonFingerprint {
        throw CancellationError()
    }
}

private enum ScopedAccessTestError: Error {
    case failed
}

private actor EmptyScopedAccessDiscovery: CloudLocationDiscovering {
    func discover() async -> [StorageLocation] {
        []
    }
}

@MainActor
private final class ScopedAccessWorkspaceOpener: WorkspaceOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

private final class RecordingSecurityScopeDriver: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []

    var startedURLs: [URL] {
        lock.withLock { started }
    }

    var stoppedURLs: [URL] {
        lock.withLock { stopped }
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { started.append(url) }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stopped.append(url) }
    }
}

private actor ScopedAccessCancellationGate {
    private var entered = false
    private var released = false

    func wait() async {
        entered = true
        while !released {
            await Task.yield()
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        released = true
    }
}

@MainActor
private func scopedAccessWait(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
