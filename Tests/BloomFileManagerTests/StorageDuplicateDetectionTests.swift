import Foundation
import Testing
@testable import BloomFileManager

@Suite struct StorageDuplicateDetectionTests {
    @Test func onlyFullDigestAndFinalLiveFingerprintCreateAGroup() async throws {
        let fixture = try StorageDuplicateFixture.equalSizeCandidates()
        let service = fixture.service()
        let events = try await service.collect(fixture.entries)

        #expect(events.groups.count == 1)
        #expect(events.groups[0].members.map(\.id) == fixture.equalContentIDs)
        #expect(events.groups[0].members.contains {
            $0.id == fixture.partialOnlyMatchID
        } == false)
    }

    @Test func replacementAfterFullReadIsExcludedAsUnstable() async throws {
        let fixture = try StorageDuplicateFixture.replacementBeforeFinalValidation()
        let events = try await fixture.service().collect(fixture.entries)

        #expect(events.exclusion(for: fixture.replacedID) == .unstable)
        #expect(events.groups.isEmpty)
    }

    @Test func partialAndFullReadsNeverExceedTwoWorkers() async throws {
        let fixture = try StorageDuplicateFixture.concurrencyProbe(count: 12)

        _ = try await fixture.service().collect(fixture.entries)

        #expect(await fixture.probe.highWater == 2)
        #expect(await fixture.probe.fullStartedWhilePartialsWereActive == false)
    }

    @Test func largeCandidateSetSpawnsOnlyTwoReusableWorkersPerStage() async throws {
        let fixture = try StorageDuplicateFixture.largeWorkerProbe(count: 512)

        let events = try await fixture.service().collect(fixture.entries)

        #expect(events.groups.first?.members.count == 512)
        #expect(await fixture.workerProbe.highWater == 2)
        #expect(await fixture.workerProbe.startsByStage == [
            .partial: 2,
            .full: 2,
            .live: 2
        ])
    }

    @Test func slowConsumerKeepsBufferBoundedAndReceivesEveryCriticalEvent() async throws {
        let fixture = try StorageDuplicateFixture.backpressureStress(count: 64)
        let bufferProbe = StorageEventBufferProbe(capacity: 4)
        let stream = fixture.service(
            eventBufferCapacity: 4,
            eventBufferObserver: bufferProbe
        ).events(for: fixture.entries)
        try await Task.sleep(for: .milliseconds(20))

        var completed: Set<StorageRelativePath> = []
        var exclusions: [StorageRelativePath: StorageVerificationState] = [:]
        var groups: [StorageDuplicateGroup] = []
        for try await event in stream {
            try await Task.sleep(for: .milliseconds(1))
            switch event {
            case let .state(id, .complete):
                completed.insert(id)
            case .state:
                break
            case let .excluded(id, state):
                exclusions[id] = state
            case let .group(group):
                groups.append(group)
            }
        }

        #expect(await bufferProbe.maximumDepth <= 4)
        #expect(await bufferProbe.criticalBackpressureCount > 0)
        #expect(exclusions == [fixture.replacedID: .unstable])
        #expect(completed == Set(fixture.entries.map(\.id)).subtracting([fixture.replacedID]))
        #expect(groups.count == 1)
        #expect(groups.first?.members.map(\.id) == completed.sorted())
    }
}

private struct CollectedStorageDuplicateEvents {
    let values: [StorageDuplicateDetectionEvent]

    var groups: [StorageDuplicateGroup] {
        values.compactMap { event in
            guard case let .group(group) = event else { return nil }
            return group
        }
    }

    func exclusion(for id: StorageRelativePath) -> StorageVerificationState? {
        let states: [StorageVerificationState] = values.compactMap { event in
            guard case let .excluded(path, state) = event, path == id else {
                return nil
            }
            return state
        }
        return states.last
    }
}

private extension StorageDuplicateDetecting {
    func collect(_ entries: [StorageEntry]) async throws -> CollectedStorageDuplicateEvents {
        var values: [StorageDuplicateDetectionEvent] = []
        for try await event in events(for: entries) {
            values.append(event)
        }
        return CollectedStorageDuplicateEvents(values: values)
    }
}

private enum StorageDuplicateFixtureError: Error {
    case missingDigest
}

private actor StorageContentReadProbe {
    enum Stage {
        case partial
        case full
    }

    private(set) var highWater = 0
    private(set) var fullStartedWhilePartialsWereActive = false
    private var active = 0
    private var activePartials = 0

    func enter(_ stage: Stage) {
        active += 1
        highWater = max(highWater, active)
        switch stage {
        case .partial:
            activePartials += 1
        case .full:
            if activePartials > 0 {
                fullStartedWhilePartialsWereActive = true
            }
        }
    }

    func leave(_ stage: Stage) {
        active -= 1
        if stage == .partial {
            activePartials -= 1
        }
    }
}

private actor StorageWorkerProbe: StorageDuplicateWorkerObserving {
    private(set) var highWater = 0
    private(set) var startsByStage: [StorageDuplicateWorkerStage: Int] = [:]
    private var active = 0

    func workerStarted(stage: StorageDuplicateWorkerStage) {
        active += 1
        highWater = max(highWater, active)
        startsByStage[stage, default: 0] += 1
    }

    func workerFinished(stage _: StorageDuplicateWorkerStage) {
        active -= 1
    }
}

private actor StorageEventBufferProbe: StorageDuplicateEventBufferObserving {
    private let capacity: Int
    private(set) var maximumDepth = 0
    private(set) var criticalBackpressureCount = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    func eventEnqueued(remainingCapacity: Int) {
        maximumDepth = max(maximumDepth, capacity - remainingCapacity)
    }

    func eventBackpressured(isCritical: Bool) {
        if isCritical {
            criticalBackpressureCount += 1
        }
    }
}

private actor ScriptedStoragePartialFingerprinter: StoragePartialFingerprinting {
    private let digests: [StorageRelativePath: Data]
    private let probe: StorageContentReadProbe
    private let delay: Duration

    init(
        digests: [StorageRelativePath: Data],
        probe: StorageContentReadProbe,
        delay: Duration = .milliseconds(10)
    ) {
        self.digests = digests
        self.probe = probe
        self.delay = delay
    }

    func fingerprint(
        for entry: StorageEntry,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> StoragePartialFingerprint {
        await probe.enter(.partial)
        do {
            try await Task.sleep(for: delay)
            await progress(1)
            guard let digest = digests[entry.id] else {
                throw StorageDuplicateFixtureError.missingDigest
            }
            await probe.leave(.partial)
            return StoragePartialFingerprint(digest: digest)
        } catch {
            await probe.leave(.partial)
            throw error
        }
    }
}

private actor ScriptedStorageChecksumService: ChecksumService {
    private let digests: [StorageRelativePath: Data]
    private let paths: [URL: StorageRelativePath]
    private let probe: StorageContentReadProbe
    private let delay: Duration

    init(
        entries: [StorageEntry],
        digests: [StorageRelativePath: Data],
        probe: StorageContentReadProbe,
        delay: Duration = .milliseconds(10)
    ) {
        self.digests = digests
        paths = Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0.id) })
        self.probe = probe
        self.delay = delay
    }

    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        guard let id = paths[request.url] else {
            throw StorageDuplicateFixtureError.missingDigest
        }
        await probe.enter(.full)
        do {
            try await Task.sleep(for: delay)
            await progress(1)
            guard let digest = digests[id] else {
                throw StorageDuplicateFixtureError.missingDigest
            }
            await probe.leave(.full)
            return ChecksumResult(digest: digest)
        } catch {
            await probe.leave(.full)
            throw error
        }
    }
}

private actor ScriptedStorageFingerprintReader: StorageEntryFingerprintReading {
    private let current: [URL: ComparisonFingerprint]

    init(current: [URL: ComparisonFingerprint]) {
        self.current = current
    }

    func fingerprint(of url: URL) async throws -> ComparisonFingerprint {
        guard let fingerprint = current[url] else {
            throw StorageDuplicateFixtureError.missingDigest
        }
        return fingerprint
    }
}

private struct StorageDuplicateFixture {
    let entries: [StorageEntry]
    let partials: ScriptedStoragePartialFingerprinter
    let checksums: ScriptedStorageChecksumService
    let fingerprints: ScriptedStorageFingerprintReader
    let probe: StorageContentReadProbe
    let workerProbe: StorageWorkerProbe
    let equalContentIDs: [StorageRelativePath]
    let partialOnlyMatchID: StorageRelativePath
    let replacedID: StorageRelativePath

    func service() -> LiveStorageDuplicateDetectionService {
        LiveStorageDuplicateDetectionService(
            partials: partials,
            checksums: checksums,
            fingerprints: fingerprints,
            workerObserver: workerProbe
        )
    }

    func service(
        eventBufferCapacity: Int,
        eventBufferObserver: any StorageDuplicateEventBufferObserving
    ) -> LiveStorageDuplicateDetectionService {
        LiveStorageDuplicateDetectionService(
            partials: partials,
            checksums: checksums,
            fingerprints: fingerprints,
            workerObserver: workerProbe,
            eventBufferCapacity: eventBufferCapacity,
            eventBufferObserver: eventBufferObserver
        )
    }

    static func equalSizeCandidates() throws -> Self {
        let entries = try makeEntries(names: ["a.bin", "b.bin", "partial-only.bin"])
        return make(
            entries: entries,
            partialDigests: dictionary(entries, values: [[1], [1], [1]]),
            fullDigests: dictionary(entries, values: [[9], [9], [8]]),
            equalContentIDs: [entries[0].id, entries[1].id],
            partialOnlyMatchID: entries[2].id
        )
    }

    static func replacementBeforeFinalValidation() throws -> Self {
        let entries = try makeEntries(names: ["original.bin", "copy.bin"])
        var current = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.url, $0.fingerprint)
        })
        current[entries[0].url] = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "replacement-entry",
                resolvedIdentifier: "replacement-resolved"
            ),
            byteSize: entries[0].fingerprint.byteSize,
            modifiedAt: entries[0].fingerprint.modifiedAt,
            rawModifiedAt: entries[0].fingerprint.rawModifiedAt
        )
        return make(
            entries: entries,
            partialDigests: dictionary(entries, values: [[1], [1]]),
            fullDigests: dictionary(entries, values: [[2], [2]]),
            current: current,
            equalContentIDs: entries.map(\.id),
            partialOnlyMatchID: entries[0].id,
            replacedID: entries[0].id
        )
    }

    static func concurrencyProbe(count: Int) throws -> Self {
        let entries = try makeEntries(
            names: (0 ..< count).map { "candidate-\($0).bin" }
        )
        let probe = StorageContentReadProbe()
        return make(
            entries: entries,
            partialDigests: dictionary(
                entries,
                values: Array(repeating: [1], count: count)
            ),
            fullDigests: dictionary(
                entries,
                values: Array(repeating: [2], count: count)
            ),
            probe: probe,
            delay: .milliseconds(25),
            equalContentIDs: entries.map(\.id).sorted(),
            partialOnlyMatchID: entries[0].id
        )
    }

    static func largeWorkerProbe(count: Int) throws -> Self {
        let entries = try makeEntries(
            names: (0 ..< count).map { "large-candidate-\($0).bin" }
        )
        return make(
            entries: entries,
            partialDigests: dictionary(
                entries,
                values: Array(repeating: [1], count: count)
            ),
            fullDigests: dictionary(
                entries,
                values: Array(repeating: [2], count: count)
            ),
            delay: .zero,
            equalContentIDs: entries.map(\.id).sorted(),
            partialOnlyMatchID: entries[0].id
        )
    }

    static func backpressureStress(count: Int) throws -> Self {
        let entries = try makeEntries(
            names: (0 ..< count).map { "buffered-candidate-\($0).bin" }
        )
        var current = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.url, $0.fingerprint)
        })
        current[entries[0].url] = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "buffered-replacement-entry",
                resolvedIdentifier: "buffered-replacement-resolved"
            ),
            byteSize: entries[0].fingerprint.byteSize,
            modifiedAt: entries[0].fingerprint.modifiedAt,
            rawModifiedAt: entries[0].fingerprint.rawModifiedAt
        )
        return make(
            entries: entries,
            partialDigests: dictionary(
                entries,
                values: Array(repeating: [1], count: count)
            ),
            fullDigests: dictionary(
                entries,
                values: Array(repeating: [2], count: count)
            ),
            current: current,
            delay: .zero,
            equalContentIDs: entries.dropFirst().map(\.id).sorted(),
            partialOnlyMatchID: entries[0].id,
            replacedID: entries[0].id
        )
    }

    private static func make(
        entries: [StorageEntry],
        partialDigests: [StorageRelativePath: Data],
        fullDigests: [StorageRelativePath: Data],
        current: [URL: ComparisonFingerprint]? = nil,
        probe: StorageContentReadProbe = StorageContentReadProbe(),
        delay: Duration = .milliseconds(10),
        equalContentIDs: [StorageRelativePath],
        partialOnlyMatchID: StorageRelativePath,
        replacedID: StorageRelativePath? = nil
    ) -> Self {
        Self(
            entries: entries,
            partials: ScriptedStoragePartialFingerprinter(
                digests: partialDigests,
                probe: probe,
                delay: delay
            ),
            checksums: ScriptedStorageChecksumService(
                entries: entries,
                digests: fullDigests,
                probe: probe,
                delay: delay
            ),
            fingerprints: ScriptedStorageFingerprintReader(
                current: current ?? Dictionary(
                    uniqueKeysWithValues: entries.map { ($0.url, $0.fingerprint) }
                )
            ),
            probe: probe,
            workerProbe: StorageWorkerProbe(),
            equalContentIDs: equalContentIDs,
            partialOnlyMatchID: partialOnlyMatchID,
            replacedID: replacedID ?? entries[0].id
        )
    }

    private static func makeEntries(names: [String]) throws -> [StorageEntry] {
        try names.enumerated().map { index, name in
            let path = try StorageRelativePath(components: [name])
            return StorageEntry(
                relativePath: path,
                url: URL(filePath: "/storage-duplicate-fixture/\(name)"),
                kind: .regularFile,
                category: .other,
                fingerprint: ComparisonFingerprint(
                    identity: FileIdentity(
                        entryIdentifier: "entry-\(name)",
                        resolvedIdentifier: "resolved-\(name)"
                    ),
                    byteSize: 100,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                    rawModifiedAt: ComparisonModificationTimestamp(
                        seconds: Int64(index + 1),
                        nanoseconds: Int64(index)
                    )
                ),
                typeDescription: "Data"
            )
        }
    }

    private static func dictionary(
        _ entries: [StorageEntry],
        values: [[UInt8]]
    ) -> [StorageRelativePath: Data] {
        Dictionary(uniqueKeysWithValues: zip(entries, values).map {
            ($0.id, Data($1))
        })
    }
}
