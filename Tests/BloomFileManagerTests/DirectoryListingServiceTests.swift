import Foundation
import Testing
@testable import BloomFileManager

@Test func listingPublishesMultipleBatchesWithFolderMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "Folder"), withIntermediateDirectories: false)
    for index in 0..<300 {
        try Data("x".utf8).write(to: root.appending(path: "file-\(index).txt"))
    }

    var batches: [[FileItem]] = []
    for try await batch in LiveDirectoryListingService(batchSize: 128).batches(in: root) {
        batches.append(batch)
    }

    #expect(batches.count == 3)
    #expect(batches.flatMap { $0 }.count == 301)
    #expect(batches.flatMap { $0 }.first(where: { $0.name == "Folder" })?.isDirectory == true)
}

@Test func listingMarksSymbolicLinksFromDirectoryMetadata() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let target = root.url.appending(path: "target.txt")
    let link = root.url.appending(path: "target-link.txt")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let items = try await LiveDirectoryListingService(batchSize: 8)
        .batches(in: root.url)
        .reduce(into: [FileItem]()) { $0 += $1 }

    #expect(items.first(where: { $0.name == "target-link.txt" })?.isSymbolicLink == true)
    #expect(items.first(where: { $0.name == "target.txt" })?.isSymbolicLink == false)
}

@Test func baselineVisibilityIncludesHiddenEntries() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    try Data([1]).write(to: root.url.appending(path: ".hidden"))
    try Data([1]).write(to: root.url.appending(path: "visible"))

    let service = LiveDirectoryListingService(visibility: .baseline)
    let names = try await service.batches(in: root.url).reduce(into: [String]()) {
        $0 += $1.map(\.name)
    }

    #expect(Set(names) == [".hidden", "visible"])
}

@Test func immediateCursorListsOnlyDirectChildren() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let directDirectory = root.url.appending(path: "direct-directory")
    let directFile = root.url.appending(path: "direct-file.txt")
    let grandchild = directDirectory.appending(path: "grandchild.txt")
    try FileManager.default.createDirectory(at: directDirectory, withIntermediateDirectories: false)
    try Data().write(to: directFile)
    try Data().write(to: grandchild)

    let names = try await LiveDirectoryListingService(batchSize: 8)
        .batches(in: root.url)
        .reduce(into: [String]()) { $0 += $1.map(\.name) }

    #expect(Set(names) == ["direct-directory", "direct-file.txt"])
    #expect(!names.contains("grandchild.txt"))
}

@Test func firstListingBatchDoesNotExhaustInjectedCursor() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    for index in 0..<300 {
        try Data().write(to: root.url.appending(path: "item-\(index)"))
    }
    let urls = (0..<300).map { root.url.appending(path: "item-\($0)") }
    let factory = CountingImmediateDirectoryEntryCursorFactory(urls: urls)
    let service = LiveDirectoryListingService(
        batchSize: 256,
        availabilityReader: ConstantAvailabilityReader(.availableLocally),
        cursorFactory: factory
    )
    var iterator = service.batches(in: URL(filePath: "/virtual")).makeAsyncIterator()
    #expect(try await iterator.next()?.count == 256)
    #expect(factory.nextCallCount == 256)
}

@Test func immediateCursorFailureTerminatesListingStream() async throws {
    let missingDirectory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    var iterator = LiveDirectoryListingService(batchSize: 8)
        .batches(in: missingDirectory)
        .makeAsyncIterator()

    await #expect(throws: (any Error).self) {
        _ = try await iterator.next()
    }
}

@Test func listingSurfacesEnumeratorErrorCapturedAfterCursorCreation() async throws {
    let sentinel = SentinelEnumerationError()
    let enumerator = ErrorInjectingImmediateDirectoryEnumerator(error: sentinel)
    let factory = LiveImmediateDirectoryEntryCursorFactory { _, _, _, errorHandler in
        enumerator.install(errorHandler)
        return enumerator
    }
    let service = LiveDirectoryListingService(
        batchSize: 8,
        cursorFactory: factory
    )
    var iterator = service.batches(in: URL(filePath: "/virtual")).makeAsyncIterator()

    await #expect(throws: SentinelEnumerationError.self) {
        _ = try await iterator.next()
    }
    #expect(enumerator.nextCallCount == 1)
}

@Test func cancelledAvailabilityDoesNotReturnStaleBatchAndFinishesScopedAccessOnce() async throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    try Data("listed".utf8).write(to: directory.url.appending(path: "file.txt"))
    let driver = RecordingDirectoryListingScopeDriver()
    let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
    coordinator.replaceManualRoots([directory.url])
    let availability = BlockingAvailabilityReader()
    let service = LiveDirectoryListingService(
        batchSize: 1,
        availabilityReader: availability,
        accessCoordinator: coordinator
    )
    let stream = service.batches(in: directory.url)
    let listing = Task { () throws -> [FileItem]? in
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()
    }
    await availability.waitUntilEntered()

    listing.cancel()
    await availability.release()

    await #expect(throws: CancellationError.self) {
        _ = try await listing.value
    }
    #expect(driver.startedURLs == [directory.url])
    #expect(driver.stoppedURLs == [directory.url])
}

private actor ConstantAvailabilityReader: CloudItemAvailabilityReading {
    let value: CloudItemAvailability
    init(_ value: CloudItemAvailability) { self.value = value }
    func availability(of url: URL) -> CloudItemAvailability { value }
}

private final class CountingImmediateDirectoryEntryCursorFactory:
    ImmediateDirectoryEntryCursorFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let urls: [URL]
    private var calls = 0
    init(urls: [URL]) { self.urls = urls }
    var nextCallCount: Int { lock.withLock { calls } }
    func makeCursor(
        in directory: URL,
        includingPropertiesForKeys keys: Set<URLResourceKey>,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> any ImmediateDirectoryEntryCursor {
        CountingImmediateDirectoryEntryCursor(urls: urls) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.calls += 1 }
        }
    }
}

private final class CountingImmediateDirectoryEntryCursor: ImmediateDirectoryEntryCursor {
    private let lock = NSLock()
    private let urls: [URL]
    private let onURL: () -> Void
    private var index = 0
    init(urls: [URL], onURL: @escaping () -> Void) {
        self.urls = urls
        self.onURL = onURL
    }
    func next() throws -> URL? {
        lock.withLock {
            guard urls.indices.contains(index) else { return nil }
            defer { index += 1; onURL() }
            return urls[index]
        }
    }
}

private struct SentinelEnumerationError: Error {}

private final class ErrorInjectingImmediateDirectoryEnumerator:
    ImmediateDirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error
    private var errorHandler: (@Sendable (URL, Error) -> Bool)?
    private var calls = 0

    init(error: Error) {
        self.error = error
    }

    var nextCallCount: Int { lock.withLock { calls } }

    func install(_ errorHandler: @escaping @Sendable (URL, Error) -> Bool) {
        lock.withLock { self.errorHandler = errorHandler }
    }

    func nextObject() -> Any? {
        let handler = lock.withLock { () -> (@Sendable (URL, Error) -> Bool)? in
            calls += 1
            return errorHandler
        }
        _ = handler?(URL(filePath: "/virtual"), error)
        return nil
    }
}

private actor BlockingAvailabilityReader: CloudItemAvailabilityReading {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func availability(of url: URL) async -> CloudItemAvailability {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            didEnter = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        return .availableLocally
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class RecordingDirectoryListingScopeDriver:
    SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []

    var startedURLs: [URL] { lock.withLock { started } }
    var stoppedURLs: [URL] { lock.withLock { stopped } }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { started.append(url) }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stopped.append(url) }
    }
}
