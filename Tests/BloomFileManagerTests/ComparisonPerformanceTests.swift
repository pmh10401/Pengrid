import Foundation
import Testing
@testable import BloomFileManager

// This is a hang-prevention watchdog, not a product performance SLA.
private let performanceTestWatchdog = Duration.seconds(10)

@MainActor
@Suite struct ComparisonPerformanceTests {
    @Test(.timeLimit(.minutes(1)))
    func fiftyThousandEntriesPublishProgressivelyCompleteAndStopPromptly() async throws {
        let fixture = ComparisonPerformanceFixture(entryCount: 50_000, batchSize: 256)
        fixture.coordinator.start(workspace: fixture.workspace)
        #expect(await fixture.waitForRowCount(atLeast: 256))
        #expect(fixture.coordinator.phase == .comparing)
        await fixture.listing.release()
        #expect(await fixture.waitForCompletion(expectedCount: 50_000))
        #expect(await fixture.listing.generatedCount == 50_000)
        #expect(fixture.coordinator.rows.count == 50_000)
        #expect(fixture.coordinator.phase == .upToDate)

        let clock = ContinuousClock()
        let started = clock.now
        fixture.coordinator.stop()
        #expect(started.duration(to: clock.now) < .milliseconds(250))
        #expect(fixture.coordinator.rows.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func listingStalledAfterTwoBatchesCancelsAndStopsPromptly() async throws {
        let fixture = ComparisonPerformanceFixture(entryCount: 50_000, batchSize: 256)
        fixture.coordinator.start(workspace: fixture.workspace)
        #expect(await fixture.waitForGeneratedCount(1_024))
        #expect(fixture.coordinator.phase == .comparing)

        let clock = ContinuousClock()
        let started = clock.now
        fixture.coordinator.stop()
        #expect(started.duration(to: clock.now) < .milliseconds(250))
        #expect(fixture.coordinator.rows.isEmpty)
        #expect(await fixture.listing.waitForCancellation())
    }

    @Test(.timeLimit(.minutes(1)))
    func oneHundredChecksumsStayAtTwoInvalidateBoundedCacheAndCancel() async throws {
        let probe = ChecksumConcurrencyProbe()
        let service = InMemoryChecksumService(probe: probe)
        let requests = performanceChecksumRequests(count: 100)
        let tasks = requests.map { request in
            Task { try await service.checksum(for: request, progress: { _ in }) }
        }

        let clock = ContinuousClock()
        let highWaterDeadline = clock.now.advanced(by: performanceTestWatchdog)
        while await probe.highWater != 2, clock.now < highWaterDeadline {
            await Task.yield()
        }
        #expect(await probe.highWater == 2)
        tasks.forEach { $0.cancel() }
        let cancellationStarted = clock.now
        for task in tasks { _ = try? await task.value }
        #expect(cancellationStarted.duration(to: clock.now) < .seconds(1))
        #expect(await probe.highWater == 2)

        let cache = ChecksumCache(limit: 8)
        for (index, request) in requests.enumerated() {
            await cache.insert(.init(digest: Data([UInt8(index % 255)])), for: request)
        }
        #expect(await cache.count == 8)
        #expect(await cache.value(for: requests[0]) == nil)
        let current = requests[99]
        let changedFingerprint = ChecksumRequest(
            url: current.url,
            fingerprint: .init(
                identity: .init(entryIdentifier: "replacement:99", resolvedIdentifier: "replacement:99"),
                byteSize: current.fingerprint.byteSize,
                modifiedAt: current.fingerprint.modifiedAt
            )
        )
        #expect(await cache.value(for: current) != nil)
        #expect(await cache.value(for: changedFingerprint) == nil)
        await cache.insert(.init(digest: Data([0xFF])), for: changedFingerprint)
        #expect(await cache.count == 8)
        await cache.removeAll()
        #expect(await cache.count == 0)
    }
}

@MainActor
private final class ComparisonPerformanceFixture {
    let workspace: WorkspaceState
    let listing: PerformanceComparisonListingService
    let coordinator: ComparisonCoordinator

    init(entryCount: Int, batchSize: Int) {
        let left = URL(filePath: "/comparison/performance-left", directoryHint: .isDirectory)
        let right = URL(filePath: "/comparison/performance-right", directoryHint: .isDirectory)
        workspace = WorkspaceState(
            leftURL: left,
            rightURL: right,
            listingService: StubDirectoryListingService(values: [:])
        )
        listing = PerformanceComparisonListingService(
            roots: [.left: left, .right: right],
            entryCount: entryCount,
            batchSize: batchSize
        )
        coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: PerformanceNoopChecksumService(),
            monitor: InMemoryComparisonTreeMonitor()
        )
    }

    func waitForRowCount(atLeast count: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: performanceTestWatchdog
        )
        while coordinator.rows.count < count, clock.now < deadline {
            await Task.yield()
        }
        return coordinator.rows.count >= count
    }

    func waitForGeneratedCount(_ count: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: performanceTestWatchdog
        )
        while await listing.generatedCount < count, clock.now < deadline {
            await Task.yield()
        }
        return await listing.generatedCount == count
    }

    func waitForCompletion(expectedCount: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: performanceTestWatchdog
        )
        while clock.now < deadline {
            if await listing.generatedCount == expectedCount,
               coordinator.rows.count == expectedCount,
               coordinator.phase == .upToDate {
                return true
            }
            await Task.yield()
        }
        return await listing.generatedCount == expectedCount
            && coordinator.rows.count == expectedCount
            && coordinator.phase == .upToDate
    }
}

private actor PerformanceComparisonListingService: ComparisonListingService {
    let roots: [ComparisonSide: URL]
    let entryCount: Int
    let batchSize: Int
    private(set) var generatedCount = 0
    private var cancelledSides: Set<ComparisonSide> = []
    private var released = false

    init(roots: [ComparisonSide: URL], entryCount: Int, batchSize: Int) {
        self.roots = roots
        self.entryCount = entryCount
        self.batchSize = batchSize
    }

    func identity(of root: URL) -> FileIdentity {
        let token = "performance:\(root.path)"
        return .init(entryIdentifier: token, resolvedIdentifier: token)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        guard let side = roots.first(where: { $0.value == request.root })?.key else {
            return AsyncThrowingStream { $0.finish() }
        }
        let producer = PerformanceBatchProducer(owner: self, side: side, root: request.root)
        return AsyncThrowingStream(unfolding: { try await producer.next() })
    }

    func recordGenerated(_ count: Int) { generatedCount += count }
    func recordCancellation(_ side: ComparisonSide) { cancelledSides.insert(side) }
    func release() { released = true }
    func isReleased() -> Bool { released }
    func waitForCancellation() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while cancelledSides.count < 2, clock.now < deadline { await Task.yield() }
        return cancelledSides.count == 2
    }
}

private actor PerformanceBatchProducer {
    let owner: PerformanceComparisonListingService
    let side: ComparisonSide
    let root: URL
    var cursor = 0

    init(owner: PerformanceComparisonListingService, side: ComparisonSide, root: URL) {
        self.owner = owner
        self.side = side
        self.root = root
    }

    func next() async throws -> ComparisonListingBatch? {
        do {
            try Task.checkCancellation()
            let perSide = owner.entryCount / 2
            let batchSize = owner.batchSize
            guard cursor < perSide else { return nil }
            if cursor >= batchSize * 2 {
                while !(await owner.isReleased()) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let end = min(cursor + batchSize, perSide)
            let records = try (cursor ..< end).map { index -> ComparisonListingRecord in
                let prefix = side == .left ? "left" : "right"
                let name = String(format: "%@-%06d.dat", prefix, index)
                let path = try ComparisonRelativePath(components: [name])
                return .entry(ComparisonEntry(
                    relativePath: path,
                    url: root.appending(path: name),
                    kind: .regularFile,
                    fingerprint: .init(
                        identity: .init(entryIdentifier: "\(prefix):\(index)", resolvedIdentifier: "\(prefix):\(index)"),
                        byteSize: 1,
                        modifiedAt: Date(timeIntervalSince1970: 1)
                    ),
                    symbolicLinkTarget: nil,
                    typeDescription: "Data"
                ))
            }
            cursor = end
            await owner.recordGenerated(records.count)
            return .init(records: records)
        } catch {
            await owner.recordCancellation(side)
            throw error
        }
    }
}

private actor PerformanceNoopChecksumService: ChecksumService {
    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        .init(digest: Data(request.url.path.utf8))
    }
}

private func performanceChecksumRequests(count: Int) -> [ChecksumRequest] {
    (0 ..< count).map { index in
        ChecksumRequest(
            url: URL(filePath: "/memory/checksum-\(index)"),
            fingerprint: .init(
                identity: .init(entryIdentifier: "1:\(index)", resolvedIdentifier: "1:\(index)"),
                byteSize: 1,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        )
    }
}
