import Foundation
import Testing
@testable import BloomFileManager

@Suite @MainActor struct SpotlightMetadataQueryRunnerTests {
    @Test func contentPredicateRequiresEveryLiteralToken() throws {
        let predicate = try #require(SpotlightContentPredicate.make(tokens: ["annual", "report"]))

        #expect(predicate.evaluate(with: [NSMetadataItemTextContentKey: "Annual REPORT for 2026"]))
        #expect(!predicate.evaluate(with: [NSMetadataItemTextContentKey: "annual notes"]))
    }

    @Test func contentPredicateRejectsAnEmptyTokenList() {
        #expect(SpotlightContentPredicate.make(tokens: []) == nil)
    }

    @Test func finishedGatherSnapshotsOnlyURLsAndCleansUpExactlyOnce() async throws {
        let firstURL = URL(filePath: "/tmp/spotlight/../spotlight/annual.pdf")
        let secondURL = URL(filePath: "/tmp/spotlight/report.txt")
        let session = MetadataQuerySessionStub(
            results: [
                [NSMetadataItemURLKey: firstURL, NSMetadataItemTextContentKey: "must not be read"],
                [NSMetadataItemURLKey: "not a URL"],
                [NSMetadataItemURLKey: secondURL]
            ],
            finishOnStart: true
        )
        let runner = LiveSpotlightMetadataQueryRunner(sessionFactory: { session })
        let root = URL(filePath: "/tmp/spotlight/../spotlight", directoryHint: .isDirectory)

        let urls = try await runner.matchingURLs(tokens: ["annual", "report"], roots: [root])

        #expect(urls == [firstURL.standardizedFileURL, secondURL.standardizedFileURL])
        #expect(session.configuredRoots == [root.standardizedFileURL])
        #expect(session.configuredOperationQueue === OperationQueue.main)
        #expect(session.startCount == 1)
        #expect(session.disableUpdatesCount == 1)
        #expect(session.stopCount == 1)
        #expect(session.removeObserversCount == 1)
        #expect(session.requestedAttributes == [
            NSMetadataItemURLKey,
            NSMetadataItemURLKey,
            NSMetadataItemURLKey
        ])
    }

    @Test func rejectedStartRemovesObserverStopsAndThrows() async {
        let session = MetadataQuerySessionStub(startAccepted: false)
        let runner = LiveSpotlightMetadataQueryRunner(sessionFactory: { session })

        await #expect(throws: SpotlightMetadataQueryError.startRejected) {
            try await runner.matchingURLs(
                tokens: ["annual"],
                roots: [URL(filePath: "/tmp", directoryHint: .isDirectory)]
            )
        }

        #expect(session.startCount == 1)
        #expect(session.disableUpdatesCount == 1)
        #expect(session.stopCount == 1)
        #expect(session.removeObserversCount == 1)
    }

    @Test func cancellationStopsAndResumesWhenGatherNeverFinishes() async {
        let session = MetadataQuerySessionStub()
        let runner = LiveSpotlightMetadataQueryRunner(sessionFactory: { session })
        let task = Task { @MainActor in
            try await runner.matchingURLs(
                tokens: ["annual"],
                roots: [URL(filePath: "/tmp", directoryHint: .isDirectory)]
            )
        }
        while session.startCount == 0 {
            await Task.yield()
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(session.disableUpdatesCount == 1)
        #expect(session.stopCount == 1)
        #expect(session.removeObserversCount == 1)
    }

    @Test func emptyRootsAreRejectedBeforeStartingAQuery() async {
        let session = MetadataQuerySessionStub()
        let runner = LiveSpotlightMetadataQueryRunner(sessionFactory: { session })

        await #expect(throws: SpotlightMetadataQueryError.unavailable) {
            try await runner.matchingURLs(tokens: ["annual"], roots: [])
        }

        #expect(session.startCount == 0)
    }
}

@MainActor
private final class MetadataQuerySessionStub: SpotlightMetadataQuerySession {
    private let results: [[String: Any]]
    private let startAccepted: Bool
    private let finishOnStart: Bool
    private var didFinish: (@MainActor @Sendable () -> Void)?

    private(set) var configuredPredicate: NSPredicate?
    private(set) var configuredRoots: [URL] = []
    private(set) var configuredOperationQueue: OperationQueue?
    private(set) var requestedAttributes: [String] = []
    private(set) var startCount = 0
    private(set) var disableUpdatesCount = 0
    private(set) var stopCount = 0
    private(set) var removeObserversCount = 0

    init(
        results: [[String: Any]] = [],
        startAccepted: Bool = true,
        finishOnStart: Bool = false
    ) {
        self.results = results
        self.startAccepted = startAccepted
        self.finishOnStart = finishOnStart
    }

    func configure(
        predicate: NSPredicate,
        roots: [URL],
        operationQueue: OperationQueue
    ) {
        configuredPredicate = predicate
        configuredRoots = roots
        configuredOperationQueue = operationQueue
    }

    func installDidFinishObserver(_ handler: @escaping @MainActor @Sendable () -> Void) {
        didFinish = handler
    }

    func startQuery() -> Bool {
        startCount += 1
        if startAccepted, finishOnStart {
            didFinish?()
        }
        return startAccepted
    }

    func disableUpdates() {
        disableUpdatesCount += 1
    }

    func resultCount() -> Int {
        results.count
    }

    func value(forAttribute attribute: String, at index: Int) -> Any? {
        requestedAttributes.append(attribute)
        return results[index][attribute]
    }

    func stopQuery() {
        stopCount += 1
    }

    func removeObservers() {
        removeObserversCount += 1
        didFinish = nil
    }
}
