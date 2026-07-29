import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CloudMaterializationTests {
    @Test func availableFilesReturnWithoutCoordinatingARead() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "local.txt")
        try Data("local".utf8).write(to: file)
        let request = try await identifiedRequest(file)
        let coordinator = RecordingCloudReadCoordinator()
        let service = makeService(
            availability: ScriptedCloudItemAvailabilityReader(defaultValue: .availableLocally),
            coordinator: coordinator
        )

        let result = await service.materialize([request], purpose: .open) { _ in }

        #expect(result.isReady)
        #expect(result.preparedRequests == [request])
        #expect(result.failures.isEmpty)
        #expect(await coordinator.coordinatedURLs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func onlineOnlyFileCoordinatesReadingAndWaitsUntilAvailable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "cloud.txt")
        try Data("cloud".utf8).write(to: file)
        let request = try await identifiedRequest(file)
        let availability = ScriptedCloudItemAvailabilityReader(
            values: [file: [.onlineOnly, .downloading(progress: 0.5), .availableLocally]]
        )
        let coordinator = RecordingCloudReadCoordinator()
        let service = makeService(availability: availability, coordinator: coordinator)

        let result = await service.materialize([request], purpose: .quickLook) { _ in }

        #expect(result.isReady)
        #expect(await coordinator.coordinatedURLs() == [file])
        #expect(await availability.requestCount(for: file) == 3)
    }

    @Test func cancellationReturnsBeforeDownstreamDispatch() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "cancel.txt")
        try Data().write(to: file)
        let request = try await identifiedRequest(file)
        let coordinator = RecordingCloudReadCoordinator()
        let service = makeService(
            availability: ScriptedCloudItemAvailabilityReader(defaultValue: .onlineOnly),
            coordinator: coordinator
        )

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.materialize([request], purpose: .transfer) { _ in }
        }.value

        #expect(result.wasCancelled)
        #expect(!result.isReady)
        #expect(result.preparedRequests.isEmpty)
        #expect(await coordinator.coordinatedURLs().isEmpty)
    }

    @Test func cancellationWhileReportingFinalProgressReturnsCancelledResult() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "progress-cancel.txt")
        try Data().write(to: file)
        let request = try await identifiedRequest(file)
        let gate = SuspendedCloudProgress()
        let service = makeService(
            availability: ScriptedCloudItemAvailabilityReader(defaultValue: .availableLocally),
            coordinator: RecordingCloudReadCoordinator()
        )

        let task = Task {
            await service.materialize([request], purpose: .open) { _ in
                await gate.suspend()
            }
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.resume()
        let result = await task.value

        #expect(result.wasCancelled)
        #expect(!result.isReady)
        #expect(result.preparedRequests.isEmpty)
    }

    @Test func replacementAfterDownloadFailsIdentityValidation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "replace.txt")
        try Data("before".utf8).write(to: file)
        let request = try await identifiedRequest(file)
        let availability = ScriptedCloudItemAvailabilityReader(
            values: [file: [.onlineOnly, .availableLocally]]
        )
        let coordinator = RecordingCloudReadCoordinator { coordinatedURL in
            try Data("replacement".utf8).write(to: coordinatedURL, options: .atomic)
        }
        let service = makeService(availability: availability, coordinator: coordinator)

        let result = await service.materialize([request], purpose: .open) { _ in }

        #expect(!result.isReady)
        #expect(result.preparedRequests.isEmpty)
        #expect(result.failures == [
            CloudMaterializationFailure(name: "replace.txt", reason: .itemChanged)
        ])
    }

    @Test func directoryPreparationMaterializesRegularDescendantsWithoutFollowingSymlinks() async throws {
        let fixture = try DirectoryMaterializationFixture()
        defer { fixture.remove() }
        let request = try await identifiedRequest(fixture.root)
        let targets = [fixture.firstFile, fixture.secondFile, fixture.package]
        let availability = ScriptedCloudItemAvailabilityReader(
            values: Dictionary(uniqueKeysWithValues: targets.map {
                ($0, [.onlineOnly, .availableLocally])
            }),
            defaultValue: .availableLocally
        )
        let coordinator = RecordingCloudReadCoordinator()
        let service = makeService(availability: availability, coordinator: coordinator)

        let result = await service.materialize([request], purpose: .transfer) { _ in }
        let coordinated = Set(await coordinator.coordinatedURLs())
        let standardizedTargets = Set(targets.map(\.standardizedFileURL))

        #expect(result.isReady)
        #expect(coordinated == standardizedTargets)
        #expect(!coordinated.contains(fixture.symlink.standardizedFileURL))
        #expect(!coordinated.contains(fixture.externalTarget.standardizedFileURL))
        #expect(!coordinated.contains(fixture.packageChild.standardizedFileURL))
    }

    @Test func replacedDirectoryTargetIsRejectedBeforeCoordinatingARead() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appending(path: "cloud.txt")
        let external = directory.url.appending(path: "outside.txt")
        try Data().write(to: file)
        try Data("outside".utf8).write(to: external)
        let request = try await identifiedRequest(root)
        let availability = ReplacingCloudItemAvailabilityReader(
            target: file.standardizedFileURL,
            replacementDestination: external
        )
        let coordinator = RecordingCloudReadCoordinator()
        let service = LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: availability,
            coordinator: coordinator,
            maximumPollAttempts: 1,
            pollInterval: .zero
        )

        let result = await service.materialize([request], purpose: .transfer) { _ in }

        #expect(await availability.didReplaceTarget())
        #expect(await coordinator.coordinatedURLs().isEmpty)
        #expect(result.failures == [
            CloudMaterializationFailure(name: "Folder", reason: .itemChanged)
        ])
    }

    @Test func changedDirectoryManifestFailsValidation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appending(path: "cloud.txt")
        try Data().write(to: file)
        let request = try await identifiedRequest(root)
        let availability = ScriptedCloudItemAvailabilityReader(
            values: [file: [.onlineOnly, .availableLocally]],
            defaultValue: .availableLocally
        )
        let coordinator = RecordingCloudReadCoordinator { _ in
            try Data().write(to: root.appending(path: "raced-in.txt"))
        }
        let service = makeService(availability: availability, coordinator: coordinator)

        let result = await service.materialize([request], purpose: .transfer) { _ in }

        #expect(result.failures == [
            CloudMaterializationFailure(name: "Folder", reason: .itemChanged)
        ])
    }

    @Test func insufficientSpaceAndProviderErrorsAreCategorized() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let outOfSpace = directory.url.appending(path: "large.bin")
        let provider = directory.url.appending(path: "provider.bin")
        try Data().write(to: outOfSpace)
        try Data().write(to: provider)
        let requests = try await [outOfSpace, provider].asyncMap(identifiedRequest)
        let availability = ScriptedCloudItemAvailabilityReader(defaultValue: .onlineOnly)
        let coordinator = RecordingCloudReadCoordinator(errors: [
            outOfSpace: CocoaError(.fileWriteOutOfSpace) as NSError,
            provider: NSError(domain: "ProviderFixture", code: 42)
        ])
        let service = makeService(availability: availability, coordinator: coordinator)

        let result = await service.materialize(requests, purpose: .transfer) { _ in }

        #expect(result.failures == [
            CloudMaterializationFailure(name: "large.bin", reason: .insufficientLocalStorage),
            CloudMaterializationFailure(name: "provider.bin", reason: .providerFailure)
        ])
    }

    @Test func progressNeverIncludesAnAbsolutePath() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "private-name.txt")
        try Data().write(to: file)
        let request = try await identifiedRequest(file)
        let progress = CloudProgressRecorder()
        let service = makeService(
            availability: ScriptedCloudItemAvailabilityReader(
                values: [file: [.onlineOnly, .availableLocally]]
            ),
            coordinator: RecordingCloudReadCoordinator()
        )

        _ = await service.materialize([request], purpose: .checksum) {
            await progress.append($0)
        }

        let updates = await progress.values()
        #expect(updates.map(\.currentName) == ["private-name.txt"])
        #expect(updates.allSatisfy { !$0.currentName.contains(directory.url.path) })
        #expect(updates.allSatisfy { !$0.currentName.hasPrefix("/") })
    }

    @Test func pollingIsBoundedWhenProviderNeverMakesBytesAvailable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "stuck.txt")
        try Data().write(to: file)
        let request = try await identifiedRequest(file)
        let availability = ScriptedCloudItemAvailabilityReader(defaultValue: .onlineOnly)
        let service = LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: availability,
            coordinator: RecordingCloudReadCoordinator(),
            maximumPollAttempts: 3,
            pollInterval: .zero
        )

        let result = await service.materialize([request], purpose: .open) { _ in }

        #expect(result.failures == [
            CloudMaterializationFailure(name: "stuck.txt", reason: .providerFailure)
        ])
        #expect(await availability.requestCount(for: file) == 4)
    }

    @Test func unknownProviderIsNotReadyWhenCoordinatedContentReadFails() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "generic-provider.txt")
        try Data().write(to: file)
        let request = try await identifiedRequest(file)
        let availability = ScriptedCloudItemAvailabilityReader(defaultValue: .unknown)
        let coordinator = RecordingCloudReadCoordinator(
            contentReadError: CocoaError(.fileReadUnknown) as NSError
        )
        let service = LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: availability,
            coordinator: coordinator,
            maximumPollAttempts: 1,
            pollInterval: .zero
        )

        let result = await service.materialize([request], purpose: .open) { _ in }

        #expect(!result.isReady)
        #expect(result.failures == [
            CloudMaterializationFailure(name: "generic-provider.txt", reason: .providerFailure)
        ])
        #expect(await coordinator.coordinatedURLs() == [file])
        #expect(await availability.requestCount(for: file) == 1)
    }

    @Test func unknownProviderIsReadyAfterLiveCoordinatorReadsContent() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "generic-provider.txt")
        try Data(repeating: 0xA5, count: 2_100_000).write(to: file)
        let request = try await identifiedRequest(file)
        let availability = ScriptedCloudItemAvailabilityReader(defaultValue: .unknown)
        let service = LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: availability,
            coordinator: LiveCloudReadCoordinator(),
            maximumPollAttempts: 1,
            pollInterval: .zero
        )

        let result = await service.materialize([request], purpose: .open) { _ in }

        #expect(result.isReady)
        #expect(result.failures.isEmpty)
        #expect(await availability.requestCount(for: file) == 1)
    }

    @Test func accessorSymlinkSwapIsRejectedByNoFollowDescriptorRead() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "cloud.txt")
        let external = directory.url.appending(path: "external.txt")
        try Data("cloud".utf8).write(to: file)
        try Data("external".utf8).write(to: external)
        let request = try await identifiedRequest(file)
        let coordinator = LiveCloudReadCoordinator(beforeAccessor: { _ in
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        })
        let service = LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: ScriptedCloudItemAvailabilityReader(defaultValue: .unknown),
            coordinator: coordinator,
            maximumPollAttempts: 1,
            pollInterval: .zero
        )

        let result = await service.materialize([request], purpose: .open) { _ in }

        #expect(!result.isReady)
        #expect(result.failures == [
            CloudMaterializationFailure(name: "cloud.txt", reason: .itemChanged)
        ])
        #expect(try Data(contentsOf: external) == Data("external".utf8))
    }

    @Test func symlinkTargetReplacementDoesNotChangeDirectoryManifest() async throws {
        let fixture = try DirectoryMaterializationFixture()
        defer { fixture.remove() }
        let request = try await identifiedRequest(fixture.root)
        let availability = ScriptedCloudItemAvailabilityReader(
            values: [fixture.firstFile: [.onlineOnly, .availableLocally]],
            defaultValue: .availableLocally
        )
        let coordinator = RecordingCloudReadCoordinator { _ in
            try Data("new target".utf8).write(to: fixture.externalTarget, options: .atomic)
        }
        let service = makeService(availability: availability, coordinator: coordinator)

        let result = await service.materialize([request], purpose: .transfer) { _ in }

        #expect(result.isReady)
    }

    private func makeService(
        availability: ScriptedCloudItemAvailabilityReader,
        coordinator: RecordingCloudReadCoordinator
    ) -> LiveCloudMaterializationService {
        LiveCloudMaterializationService(
            fileSystem: LiveFileSystemAccess(),
            availabilityReader: availability,
            coordinator: coordinator,
            maximumPollAttempts: 8,
            pollInterval: .zero
        )
    }

    private func identifiedRequest(_ url: URL) async throws -> IdentifiedFileRequest {
        let identity = try #require(try await LiveFileSystemAccess().identity(of: url))
        return IdentifiedFileRequest(url: url, identity: identity)
    }
}

private actor ScriptedCloudItemAvailabilityReader: CloudItemAvailabilityReading {
    private var values: [URL: [CloudItemAvailability]]
    private let defaultValue: CloudItemAvailability
    private var counts: [URL: Int] = [:]

    init(
        values: [URL: [CloudItemAvailability]] = [:],
        defaultValue: CloudItemAvailability = .availableLocally
    ) {
        self.values = Dictionary(uniqueKeysWithValues: values.map {
            ($0.key.standardizedFileURL, $0.value)
        })
        self.defaultValue = defaultValue
    }

    func availability(of url: URL) -> CloudItemAvailability {
        let key = url.standardizedFileURL
        counts[key, default: 0] += 1
        guard var sequence = values[key], !sequence.isEmpty else {
            return defaultValue
        }
        let value = sequence.removeFirst()
        values[key] = sequence
        return value
    }

    func requestCount(for url: URL) -> Int {
        counts[url.standardizedFileURL, default: 0]
    }
}

private actor RecordingCloudReadCoordinator: CloudReadCoordinating {
    private let action: @Sendable (URL) throws -> Void
    private let errors: [URL: NSError]
    private let contentReadError: NSError?
    private var urls: [URL] = []

    init(
        errors: [URL: NSError] = [:],
        contentReadError: NSError? = nil,
        action: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.errors = errors
        self.contentReadError = contentReadError
        self.action = action
    }

    func coordinateReading(
        at url: URL,
        expectedIdentity: FileIdentity,
        kind: CloudCoordinatedReadKind
    ) throws {
        urls.append(url)
        if let error = errors[url] {
            throw error
        }
        try action(url)
        if let contentReadError {
            throw contentReadError
        }
    }

    func coordinatedURLs() -> [URL] {
        urls
    }
}

private actor CloudProgressRecorder {
    private var recorded: [CloudMaterializationProgress] = []

    func append(_ progress: CloudMaterializationProgress) {
        recorded.append(progress)
    }

    func values() -> [CloudMaterializationProgress] {
        recorded
    }
}

private actor SuspendedCloudProgress {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

private actor ReplacingCloudItemAvailabilityReader: CloudItemAvailabilityReading {
    private let target: URL
    private let replacementDestination: URL
    private var replaced = false

    init(target: URL, replacementDestination: URL) {
        self.target = target
        self.replacementDestination = replacementDestination
    }

    func availability(of url: URL) -> CloudItemAvailability {
        guard url.standardizedFileURL == target, !replaced else {
            return .availableLocally
        }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.createSymbolicLink(
            at: target,
            withDestinationURL: replacementDestination
        )
        replaced = true
        return .onlineOnly
    }

    func didReplaceTarget() -> Bool {
        replaced
    }
}

private struct DirectoryMaterializationFixture {
    let temporaryDirectory: TemporaryDirectory
    let root: URL
    let firstFile: URL
    let secondFile: URL
    let symlink: URL
    let externalTarget: URL
    let package: URL
    let packageChild: URL

    init() throws {
        temporaryDirectory = try TemporaryDirectory()
        root = temporaryDirectory.url.appending(path: "Folder", directoryHint: .isDirectory)
        firstFile = root.appending(path: "first.txt")
        let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
        secondFile = nested.appending(path: "second.txt")
        externalTarget = temporaryDirectory.url.appending(path: "outside.txt")
        symlink = root.appending(path: "outside-link")
        package = root.appending(path: "Sample.app", directoryHint: .isDirectory)
        packageChild = package.appending(path: "Contents/data.bin")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: packageChild.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: firstFile)
        try Data().write(to: secondFile)
        try Data().write(to: externalTarget)
        try Data().write(to: packageChild)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: externalTarget)
    }

    func remove() {
        temporaryDirectory.remove()
    }
}

private extension Array {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
