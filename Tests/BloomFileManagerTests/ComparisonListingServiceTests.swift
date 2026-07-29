import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ComparisonListingServiceTests {
    @Test func shallowRequestUsesSeedAndExcludesHiddenNames() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url
        let visibleURL = root.appending(path: "a.txt")
        let hiddenURL = root.appending(path: ".DS_Store")
        try Data("visible".utf8).write(to: visibleURL)
        try Data("hidden".utf8).write(to: hiddenURL)
        let visible = FileItem.fixture(url: visibleURL)
        let hidden = FileItem.fixture(url: hiddenURL)
        let service = LiveComparisonListingService(batchSize: 1)
        let request = ComparisonListingRequest(
            root: root, seed: [visible, hidden], subtree: nil,
            options: ComparisonOptions(includeSubfolders: false, includeHiddenItems: false)
        )

        let records = try await service.collect(request)

        #expect(records.compactMap(\.entry).map(\.relativePath.string) == ["a.txt"])
    }

    @Test func recursionDoesNotFollowSymlinkOrPackage() async throws {
        let fixture = try ComparisonTreeFixture.makeSymlinkAndPackage()
        defer { fixture.temporary.remove() }
        let service = LiveComparisonListingService(batchSize: 2)

        let records = try await service.collect(.recursive(root: fixture.root))

        #expect(records.containsEntry("folder/kept.txt", kind: .regularFile))
        #expect(records.containsEntry("link", kind: .symbolicLink))
        #expect(records.containsEntry("broken-link", kind: .symbolicLink))
        #expect(records.entry(at: "link")?.symbolicLinkTarget == fixture.target.path)
        #expect(records.entry(at: "broken-link")?.symbolicLinkTarget == "missing-target")
        #expect(records.containsEntry("Sample.app", kind: .package))
        #expect(!records.containsPathPrefix("link/"))
        #expect(!records.containsPathPrefix("Sample.app/"))
    }

    @Test func unreadableChildYieldsFailureAndContinuesSiblings() async throws {
        let fixture = try ComparisonTreeFixture.makeUnreadableChild()
        let records = try await LiveComparisonListingService(batchSize: 1)
            .collect(.recursive(root: fixture.root))

        #expect(records.containsFailure("blocked"))
        #expect(records.containsEntry("ok.txt", kind: .regularFile))
    }

    @Test func recursiveListingPublishesBeforeScanningLaterDirectoryContents() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url
        let laterDirectory = root.appending(path: "later", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: laterDirectory, withIntermediateDirectories: false)

        let records = try await recordsAfterFirstBatchWithinOneSecond(
            from: LiveComparisonListingService(batchSize: 1).batches(for: .recursive(root: root)),
            afterFirstBatch: {
                try Data("appeared".utf8).write(to: laterDirectory.appending(path: "appeared.txt"))
            }
        )

        #expect(records.containsEntry("later", kind: .directory))
        #expect(records.containsEntry("later/appeared.txt", kind: .regularFile))
    }

    @Test func hiddenDirectoryAndHiddenSymlinkAreExcludedAndOpaque() async throws {
        let fixture = try ComparisonTreeFixture.makeHiddenItems()
        defer { fixture.temporary.remove() }

        let records = try await LiveComparisonListingService(batchSize: 1)
            .collect(.recursive(root: fixture.root))

        #expect(!records.containsPathPrefix(".hidden-directory"))
        #expect(!records.containsPathPrefix(".hidden-link"))
        #expect(records.containsEntry("visible.txt", kind: .regularFile))
    }

    @Test func subtreeListingKeepsRootRelativePathsAndExcludesSiblings() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url
        let subtree = try ComparisonRelativePath(components: ["A"])
        let nested = root.appending(path: "A", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: root.appending(path: "B", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        try Data("inside".utf8).write(to: nested.appending(path: "inside.txt"))
        try Data("outside".utf8).write(to: root.appending(path: "B/outside.txt"))
        let request = ComparisonListingRequest(
            root: root,
            seed: nil,
            subtree: subtree,
            options: .init(includeSubfolders: true, includeHiddenItems: false)
        )

        let records = try await LiveComparisonListingService().collect(request)

        #expect(records.containsEntry("A/inside.txt", kind: .regularFile))
        #expect(!records.containsPathPrefix("B/"))
    }

    @Test func cancellationBeforeFirstBatchEndsConsumerWithinOneSecond() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url
        let ready = FirstBatchGate()
        let proceed = FirstBatchGate()
        let consumer = Task { () throws -> ComparisonListingBatch? in
            var iterator = LiveComparisonListingService(batchSize: 1)
                .batches(for: .recursive(root: root))
                .makeAsyncIterator()
            await ready.open()
            await proceed.wait()
            return try await iterator.next()
        }

        try await completesWithinOneSecond { await ready.wait() }
        consumer.cancel()
        await proceed.open()
        try await completesWithinOneSecond { _ = await consumer.result }
        let result = await consumer.result
        switch result {
        case let .success(batch):
            #expect(batch == nil)
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }

    @Test func inMemoryServicePublishesConfiguredBatchesAndRecordsRequest() async throws {
        let root = URL(filePath: "/tmp/in-memory-comparison-root")
        let path = try ComparisonRelativePath(components: ["blocked"])
        let expected = ComparisonListingBatch(records: [.failure(path: path, message: "denied")])
        let service = InMemoryComparisonListingService([root: [expected]])
        let request = ComparisonListingRequest(
            root: root,
            seed: nil,
            subtree: nil,
            options: .init()
        )

        let records = try await service.collect(request)

        #expect(records.containsFailure("blocked"))
        #expect((await service.requests).map(\.root) == [root])
    }
}

private extension FileItem {
    static func fixture(url: URL) -> Self {
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

private final class ComparisonTreeFixture {
    let temporary: TemporaryDirectory
    let root: URL
    let target: URL

    init(temporary: TemporaryDirectory, root: URL, target: URL? = nil) {
        self.temporary = temporary
        self.root = root
        self.target = target ?? root
    }

    static func makeSymlinkAndPackage() throws -> Self {
        let temporary = try TemporaryDirectory()
        let root = temporary.url
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        let package = root.appending(path: "Sample.app", directoryHint: .isDirectory)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("kept".utf8).write(to: folder.appending(path: "kept.txt"))
        try Data("private".utf8).write(to: package.appending(path: "Contents.txt"))
        try Data("linked".utf8).write(to: target.appending(path: "linked.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"),
            withDestinationURL: target
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "broken-link").path,
            withDestinationPath: "missing-target"
        )
        return .init(temporary: temporary, root: root, target: target)
    }

    static func makeUnreadableChild() throws -> Self {
        let temporary = try TemporaryDirectory()
        let root = temporary.url
        let blocked = root.appending(path: "blocked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("ok".utf8).write(to: root.appending(path: "ok.txt"))
        guard Darwin.chmod(blocked.path, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return .init(temporary: temporary, root: root)
    }

    static func makeHiddenItems() throws -> Self {
        let temporary = try TemporaryDirectory()
        let root = temporary.url
        let hiddenDirectory = root.appending(path: ".hidden-directory", directoryHint: .isDirectory)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: hiddenDirectory.appending(path: "secret.txt"))
        try Data("target".utf8).write(to: target.appending(path: "target.txt"))
        try Data("visible".utf8).write(to: root.appending(path: "visible.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: ".hidden-link"),
            withDestinationURL: target
        )
        return .init(temporary: temporary, root: root, target: target)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        temporary.remove()
    }
}

private extension Array where Element == ComparisonListingRecord {
    func containsEntry(_ path: String, kind: ComparisonEntryKind) -> Bool {
        contains { $0.entry?.relativePath.string == path && $0.entry?.kind == kind }
    }

    func containsPathPrefix(_ prefix: String) -> Bool {
        compactMap(\.entry).contains { $0.relativePath.string.hasPrefix(prefix) }
    }

    func containsFailure(_ path: String) -> Bool {
        contains {
            if case let .failure(relativePath, _) = $0 {
                return relativePath.string == path
            }
            return false
        }
    }

    func entry(at path: String) -> ComparisonEntry? {
        compactMap(\.entry).first { $0.relativePath.string == path }
    }
}

private enum ComparisonListingTestError: Error {
    case timedOut
    case streamFinished
}

private actor FirstBatchGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private func recordsAfterFirstBatchWithinOneSecond(
    from stream: AsyncThrowingStream<ComparisonListingBatch, Error>,
    afterFirstBatch: @escaping @Sendable () throws -> Void
) async throws -> [ComparisonListingRecord] {
    try await withThrowingTaskGroup(of: [ComparisonListingRecord].self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let batch = try await iterator.next() else {
                throw ComparisonListingTestError.streamFinished
            }
            try afterFirstBatch()
            var records = batch.records
            while let batch = try await iterator.next() {
                records += batch.records
            }
            return records
        }
        group.addTask {
            try await Task.sleep(for: .seconds(1))
            throw ComparisonListingTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw ComparisonListingTestError.streamFinished
        }
        return first
    }
}

private func completesWithinOneSecond(
    _ operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(1))
            throw ComparisonListingTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw ComparisonListingTestError.streamFinished
        }
        return first
    }
}
