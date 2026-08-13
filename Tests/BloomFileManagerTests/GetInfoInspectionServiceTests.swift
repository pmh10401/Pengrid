import Foundation
import Testing
@testable import BloomFileManager

@Suite struct GetInfoInspectionServiceTests {
    @Test func regularFileMetadataProducesIdentityBoundChecksumRequest() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "note.txt")
        try Data("hello".utf8).write(to: file)
        let identity = FileIdentity(entryIdentifier: "entry", resolvedIdentifier: "entry")
        let service = LiveGetInfoInspectionService(identityLookup: { _ in identity })

        let report = try await service.inspect([.fixture(file)])
        let snapshot = try #require(report.successfulSnapshots.first)
        let request = try #require(snapshot.checksumRequest)

        #expect(snapshot.kind == .regularFile)
        #expect(snapshot.logicalByteSize == 5)
        #expect(request.url == file.standardizedFileURL)
        #expect(request.fingerprint.identity == identity)
        #expect(request.fingerprint.byteSize == 5)
        #expect(request.fingerprint.rawModifiedAt != nil)
    }

    @Test func openingInspectionNeverCallsChecksumOrMaterializer() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "note.txt")
        try Data("hello".utf8).write(to: file)

        let report = try await LiveGetInfoInspectionService().inspect([.fixture(file)])

        #expect(report.successfulSnapshots.count == 1)
        #expect(report.successfulSnapshots.first?.checksumRequest != nil)
    }

    @Test func symbolicLinkReportsItsDestinationAndCannotCalculateChecksum() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = directory.url.appending(path: "target.txt")
        let link = directory.url.appending(path: "shortcut")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let report = try await LiveGetInfoInspectionService().inspect([.fixture(link)])
        let snapshot = try #require(report.successfulSnapshots.first)

        #expect(snapshot.kind == .symbolicLink)
        #expect(snapshot.symbolicLinkDestination == target.path)
        #expect(snapshot.checksumRequest == nil)
        #expect(report.summary.checksumRequest == nil)
    }

    @Test func replacementBetweenMetadataAndFinalIdentityReturnsItemChanged() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "note.txt")
        try Data("hello".utf8).write(to: file)
        let identities = IdentitySequence([
            .init(entryIdentifier: "before", resolvedIdentifier: "before"),
            .init(entryIdentifier: "after", resolvedIdentifier: "after")
        ])
        let service = LiveGetInfoInspectionService(identityLookup: { _ in
            await identities.next()
        })

        let report = try await service.inspect([.fixture(file)])

        #expect(report.outcomes == [
            .failure(.init(url: file.standardizedFileURL, reason: .itemChanged))
        ])
    }

    @Test func scopedAccessBalancesForSuccessFailureAndCancellation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "note.txt")
        try Data("hello".utf8).write(to: file)
        let driver = GetInfoScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([directory.url])

        _ = try await LiveGetInfoInspectionService(accessCoordinator: coordinator).inspect([.fixture(file)])
        _ = try await LiveGetInfoInspectionService(accessCoordinator: coordinator).inspect([
            .fixture(directory.url.appending(path: "missing.txt"))
        ])

        let gate = GetInfoGate()
        let cancelledService = LiveGetInfoInspectionService(
            accessCoordinator: coordinator,
            identityLookup: { _ in
                await gate.opened()
                await gate.wait()
                try Task.checkCancellation()
                return nil
            }
        )
        let task = Task { try await cancelledService.inspect([.fixture(file)]) }
        await gate.waitUntilOpened()
        task.cancel()
        await gate.open()
        _ = try? await task.value

        #expect(driver.startedURLs == [directory.url, directory.url, directory.url])
        #expect(driver.stoppedURLs == [directory.url, directory.url, directory.url])
    }

    @Test func multipleOutcomesRemainInCapturedSelectionOrder() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let first = directory.url.appending(path: "first.txt")
        let third = directory.url.appending(path: "third.txt")
        try Data("first".utf8).write(to: first)
        try Data("third".utf8).write(to: third)
        let missing = directory.url.appending(path: "missing.txt")

        let report = try await LiveGetInfoInspectionService().inspect([
            .fixture(first), .fixture(missing), .fixture(third)
        ])

        #expect(report.outcomes.map { outcome in
            switch outcome {
            case let .success(snapshot): snapshot.url.lastPathComponent
            case let .failure(failure): failure.url.lastPathComponent
            }
        } == ["first.txt", "missing.txt", "third.txt"])
    }

    @Test func cancellationPropagatesInsteadOfPublishingPartialReport() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appending(path: "note.txt")
        try Data("hello".utf8).write(to: file)
        let gate = GetInfoGate()
        let service = LiveGetInfoInspectionService(identityLookup: { _ in
            await gate.opened()
            await gate.wait()
            try Task.checkCancellation()
            return nil
        })
        let task = Task { try await service.inspect([.fixture(file)]) }

        await gate.waitUntilOpened()
        task.cancel()
        await gate.open()

        switch await task.result {
        case .success:
            Issue.record("Cancellation must not produce a partial inspection report")
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }
}

private extension FileItem {
    static func fixture(_ url: URL) -> Self {
        .init(
            url: url,
            name: url.lastPathComponent,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "File"
        )
    }
}

private actor IdentitySequence {
    private var values: [FileIdentity]

    init(_ values: [FileIdentity]) {
        self.values = values
    }

    func next() -> FileIdentity? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private final class GetInfoScopeDriver: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops: [URL] = []

    var startedURLs: [URL] { lock.withLock { starts } }
    var stoppedURLs: [URL] { lock.withLock { stops } }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts.append(url) }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops.append(url) }
    }
}

private actor GetInfoGate {
    private var hasOpened = false
    private var mayProceed = false
    private var openedWaiters: [CheckedContinuation<Void, Never>] = []
    private var proceedWaiters: [CheckedContinuation<Void, Never>] = []

    func opened() {
        hasOpened = true
        let waiters = openedWaiters
        openedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilOpened() async {
        guard !hasOpened else { return }
        await withCheckedContinuation { openedWaiters.append($0) }
    }

    func wait() async {
        guard !mayProceed else { return }
        await withCheckedContinuation { proceedWaiters.append($0) }
    }

    func open() {
        mayProceed = true
        let waiters = proceedWaiters
        proceedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
