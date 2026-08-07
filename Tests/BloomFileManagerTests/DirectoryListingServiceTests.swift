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
