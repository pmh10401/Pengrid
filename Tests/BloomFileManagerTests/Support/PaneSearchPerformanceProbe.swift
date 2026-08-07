import AppKit
import Darwin.Mach
import Foundation
import Observation
import SwiftUI
@testable import BloomFileManager

enum PaneSearchTrace: String, CaseIterable, Sendable {
    case completeLoad
    case firstQuery
    case numeric
    case english
    case korean
    case reverseDeletion
    case replacement
    case rapidBurst
    case sortChange
}

struct PaneSearchTransitionSample: Codable, Sendable {
    let sampleIndex: Int
    let trace: String
    let fromQuery: String
    let toQuery: String
    let expectedCount: Int
    let sortKey: String?
    let sortDirection: String?
    let cardinality: Int
    let projectionPath: String?
    let setterToAcceptanceSeconds: Double
    let acceptanceToTableSeconds: Double
    let endToEndSeconds: Double
    let peakResidentBytes: UInt64
    let cancelledWorkerCandidateVisits: Int
}

struct PaneSearchStatistics: Codable, Sendable {
    let medianSeconds: Double
    let p95Seconds: Double
}

struct PaneSearchScenarioReport: Codable, Sendable {
    let scenario: String
    let warmupCount: Int
    let sampleCount: Int
    let fixtureCount: Int
    let rawSamples: [PaneSearchTransitionSample]
    let endToEndStatistics: PaneSearchStatistics
    let traceEndToEndSeconds: [Double]
    let rapidBurstQueryCount: Int?

    func writeJSON(to path: String) throws {
        let url = URL(filePath: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct PaneSearchTraceMeasurement: Sendable {
    let transitions: [PaneSearchTransitionSample]
}

@MainActor
final class PaneSearchTimingEventRecorder {
    private(set) var events: [String] = []
    private(set) var armedMechanismsInstalled: [Bool] = []

    func record(_ event: String) {
        events.append(event)
    }

    func recordArmed(handlerInstalled: Bool, observationInstalled: Bool) {
        events.append("armed")
        armedMechanismsInstalled.append(handlerInstalled && observationInstalled)
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
        armedMechanismsInstalled.removeAll(keepingCapacity: true)
    }
}

func nearestRankStatistics(_ values: [Double]) -> PaneSearchStatistics {
    precondition(!values.isEmpty, "A benchmark scenario must have at least one recorded sample")
    let ordered = values.sorted()
    let medianIndex = (ordered.count - 1) / 2
    let p95Index = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
    return PaneSearchStatistics(
        medianSeconds: ordered[medianIndex],
        p95Seconds: ordered[p95Index]
    )
}

@MainActor
func measurePaneSearchTrace(
    trace: PaneSearchTrace,
    warmups: Int,
    samples: Int
) async throws -> PaneSearchTraceMeasurement {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: warmups,
        sampleCount: samples,
        scenario: trace.rawValue
    ).measureSelectedScenario()
    return PaneSearchTraceMeasurement(transitions: report.rawSamples)
}

@MainActor
final class PaneSearchPerformanceProbe {
    private let warmupCount: Int
    private let sampleCount: Int
    private let scenario: PaneSearchScenario
    private let timingRecorder: PaneSearchTimingEventRecorder?

    init(warmupCount: Int, sampleCount: Int, scenario: String, timingRecorder: PaneSearchTimingEventRecorder? = nil) throws {
        precondition(warmupCount >= 0)
        precondition(sampleCount > 0)
        self.warmupCount = warmupCount
        self.sampleCount = sampleCount
        self.scenario = try PaneSearchScenario(rawValue: scenario)
        self.timingRecorder = timingRecorder
    }

    func measureSelectedScenario() async throws -> PaneSearchScenarioReport {
        let reusableSession = try await makeReusableSession()
        for _ in 0..<warmupCount {
            _ = try await measureRun(sampleIndex: -1, reusableSession: reusableSession)
        }

        var rawSamples: [PaneSearchTransitionSample] = []
        var traceDurations: [Double] = []
        for sampleIndex in 0..<sampleCount {
            let run = try await measureRun(sampleIndex: sampleIndex, reusableSession: reusableSession)
            rawSamples.append(contentsOf: run.transitions)
            traceDurations.append(run.duration)
        }

        return PaneSearchScenarioReport(
            scenario: scenario.rawValue,
            warmupCount: warmupCount,
            sampleCount: sampleCount,
            fixtureCount: 10_000,
            rawSamples: rawSamples,
            endToEndStatistics: nearestRankStatistics(traceDurations),
            traceEndToEndSeconds: traceDurations,
            rapidBurstQueryCount: scenario.trace == .rapidBurst ? 20 : nil
        )
    }

    func measureNormalizedEquivalentReuseForTesting() async throws -> PaneSearchTransitionSample {
        let session = try await makeWarmSession()
        let fromQuery = "report-1999"
        let toQuery = " \n report-1999 \t"
        _ = try await observeVisibleItemsChange(
            in: session.pane,
            sampleIndex: 0,
            boundary: "normalized-reuse setup"
        ) {
            session.pane.updateFilterQuery(fromQuery)
        }
        try verifyAcceptedItems(
            session.pane.visibleItems,
            expected: oracle(items: session.items, query: fromQuery, sort: session.pane.sort)
        )
        timingRecorder?.reset()
        return try await measureQueryTransition(
            trace: .replacement,
            sampleIndex: 0,
            fromQuery: fromQuery,
            toQuery: toQuery,
            session: session
        )
    }

    private func makeReusableSession() async throws -> PaneSearchSession? {
        switch scenario {
        case .trace(.completeLoad):
            return nil
        case .trace(.rapidBurst):
            let tracker = PaneSearchSupersessionTracker()
            return try await makeWarmSession(
                projector: CountingBaselinePaneItemProjector(tracker: tracker),
                supersessionTracker: tracker
            )
        case .trace:
            return try await makeWarmSession()
        case .sort(let key, let direction, _):
            return try await makeWarmSession(sort: opposite(of: FileSort(key: key, direction: direction)))
        }
    }

    private func measureRun(
        sampleIndex: Int,
        reusableSession: PaneSearchSession?
    ) async throws -> PaneSearchRun {
        switch scenario {
        case .trace(.completeLoad):
            return try await measureCompleteLoad(sampleIndex: sampleIndex)
        case .trace(.rapidBurst):
            guard let reusableSession else { throw PaneSearchProbeError.missingReusableSession }
            return try await measureRapidBurst(
                session: reusableSession,
                sampleIndex: sampleIndex
            )
        case .trace(let trace):
            guard let reusableSession else { throw PaneSearchProbeError.missingReusableSession }
            return try await measureQueryTrace(
                trace,
                session: reusableSession,
                sampleIndex: sampleIndex
            )
        case .sort(let key, let direction, let cardinality):
            guard let reusableSession else { throw PaneSearchProbeError.missingReusableSession }
            return try await measureSortCell(
                key: key,
                direction: direction,
                cardinality: cardinality,
                session: reusableSession,
                sampleIndex: sampleIndex
            )
        }
    }

    private func measureCompleteLoad(sampleIndex: Int) async throws -> PaneSearchRun {
        let items = paneSearchFixture()
        let session = makeSession(items: items)
        let clock = ContinuousClock()
        var start: ContinuousClock.Instant?
        let acceptedAt = try await observeVisibleItemsChange(
            in: session.pane,
            sampleIndex: sampleIndex,
            boundary: "complete-load acceptance",
            recorder: timingRecorder,
        ) {
            start = clock.now
            self.timingRecorder?.record("start")
            self.timingRecorder?.record("operation")
            session.navigationTask = session.pane.beginNavigation(to: session.directory, recordHistory: false)
        }
        await session.navigationTask?.value
        let expected = oracle(items: items, query: "", sort: FileSort())
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        let acceptedSeconds = seconds(from: start!, to: acceptedAt)
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin")
        session.coordinator.apply(items: session.pane.visibleItems, selection: [], to: session.table)
        session.table.layoutSubtreeIfNeeded()
        self.timingRecorder?.record("table-finish")
        let finish = clock.now
        let sample = PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: PaneSearchTrace.completeLoad.rawValue,
            fromQuery: "<unloaded>",
            toQuery: "",
            expectedCount: expected.count,
            sortKey: FileSortKey.name.rawValue,
            sortDirection: SortDirection.ascending.rawValue,
            cardinality: expected.count,
            projectionPath: "baseline-full-filter-sort",
            setterToAcceptanceSeconds: acceptedSeconds,
            acceptanceToTableSeconds: seconds(from: tableStart, to: finish),
            endToEndSeconds: seconds(from: start!, to: finish),
            peakResidentBytes: residentBytes(),
            cancelledWorkerCandidateVisits: 0
        )
        return PaneSearchRun(transitions: [sample], duration: sample.endToEndSeconds)
    }

    private func measureQueryTrace(
        _ trace: PaneSearchTrace,
        session: PaneSearchSession,
        sampleIndex: Int
    ) async throws -> PaneSearchRun {
        try await reset(session: session, query: "", sort: FileSort(), sampleIndex: sampleIndex)
        let clock = ContinuousClock()
        let traceStart = clock.now
        var transitions: [PaneSearchTransitionSample] = []
        var currentQuery = ""
        for query in queries(for: trace) {
            let transition = try await measureQueryTransition(
                trace: trace,
                sampleIndex: sampleIndex,
                fromQuery: currentQuery,
                toQuery: query,
                session: session
            )
            transitions.append(transition)
            currentQuery = query
        }
        return PaneSearchRun(
            transitions: transitions,
            duration: seconds(from: traceStart, to: clock.now)
        )
    }

    private func measureQueryTransition(
        trace: PaneSearchTrace,
        sampleIndex: Int,
        fromQuery: String,
        toQuery: String,
        session: PaneSearchSession
    ) async throws -> PaneSearchTransitionSample {
        let expected = oracle(items: session.items, query: toQuery, sort: session.pane.sort)
        let clock = ContinuousClock()
        var start: ContinuousClock.Instant?
        if PaneFilenameFilter.normalize(fromQuery) == PaneFilenameFilter.normalize(toQuery) {
            start = clock.now
            self.timingRecorder?.record("reuse-start")
            self.timingRecorder?.record("reuse-operation")
            session.pane.updateFilterQuery(toQuery)
            guard session.pane.filterQuery == toQuery else {
                throw PaneSearchProbeError.filterQuerySetterDidNotTakeEffect
            }
            self.timingRecorder?.record("reuse-setter-effect")
            let acceptedAt = clock.now
            self.timingRecorder?.record("reuse-accepted")
            try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
            let tableStart = clock.now
            self.timingRecorder?.record("reuse-table-begin")
            session.coordinator.apply(items: session.pane.visibleItems, selection: [], to: session.table)
            session.table.layoutSubtreeIfNeeded()
            self.timingRecorder?.record("reuse-table-finish")
            let finish = clock.now
            return PaneSearchTransitionSample(sampleIndex: sampleIndex, trace: trace.rawValue, fromQuery: fromQuery, toQuery: toQuery, expectedCount: expected.count, sortKey: session.pane.sort.key.rawValue, sortDirection: session.pane.sort.direction.rawValue, cardinality: expected.count, projectionPath: "accepted-projection-reuse", setterToAcceptanceSeconds: seconds(from: start!, to: acceptedAt), acceptanceToTableSeconds: seconds(from: tableStart, to: finish), endToEndSeconds: seconds(from: start!, to: finish), peakResidentBytes: residentBytes(), cancelledWorkerCandidateVisits: 0)
        }
        let acceptedAt = try await observeVisibleItemsChange(
            in: session.pane,
            sampleIndex: sampleIndex,
            boundary: "\(trace.rawValue) query acceptance",
            recorder: timingRecorder,
        ) {
            start = clock.now
            self.timingRecorder?.record("start")
            self.timingRecorder?.record("operation")
            session.pane.updateFilterQuery(toQuery)
        }
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin")
        session.coordinator.apply(items: session.pane.visibleItems, selection: [], to: session.table)
        session.table.layoutSubtreeIfNeeded()
        self.timingRecorder?.record("table-finish")
        let finish = clock.now
        return PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: trace.rawValue,
            fromQuery: fromQuery,
            toQuery: toQuery,
            expectedCount: expected.count,
            sortKey: session.pane.sort.key.rawValue,
            sortDirection: session.pane.sort.direction.rawValue,
            cardinality: expected.count,
            projectionPath: "baseline-full-filter-sort",
            setterToAcceptanceSeconds: seconds(from: start!, to: acceptedAt),
            acceptanceToTableSeconds: seconds(from: tableStart, to: finish),
            endToEndSeconds: seconds(from: start!, to: finish),
            peakResidentBytes: residentBytes(),
            cancelledWorkerCandidateVisits: 0
        )
    }

    private func measureRapidBurst(
        session: PaneSearchSession,
        sampleIndex: Int
    ) async throws -> PaneSearchRun {
        guard let tracker = session.supersessionTracker else {
            throw PaneSearchProbeError.missingReusableSession
        }
        tracker.reset()
        try await reset(session: session, query: "", sort: FileSort(), sampleIndex: sampleIndex)
        let queries = (0..<20).map { "report-\($0)" }
        let finalQuery = queries[19]
        let expected = oracle(items: session.items, query: finalQuery, sort: session.pane.sort)
        let clock = ContinuousClock()
        var start: ContinuousClock.Instant?
        let acceptedAt = try await observeVisibleItemsChange(
            in: session.pane,
            sampleIndex: sampleIndex,
            boundary: "rapid-burst final-query acceptance",
            recorder: timingRecorder,
        ) {
            start = clock.now
            self.timingRecorder?.record("start")
            self.timingRecorder?.record("operation")
            for query in queries {
                tracker.publish(query)
                session.pane.updateFilterQuery(query)
            }
        }
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin")
        session.coordinator.apply(items: session.pane.visibleItems, selection: [], to: session.table)
        session.table.layoutSubtreeIfNeeded()
        self.timingRecorder?.record("table-finish")
        let finish = clock.now
        let sample = PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: PaneSearchTrace.rapidBurst.rawValue,
            fromQuery: "",
            toQuery: finalQuery,
            expectedCount: expected.count,
            sortKey: session.pane.sort.key.rawValue,
            sortDirection: session.pane.sort.direction.rawValue,
            cardinality: expected.count,
            projectionPath: "baseline-counting-filter-sort",
            setterToAcceptanceSeconds: seconds(from: start!, to: acceptedAt),
            acceptanceToTableSeconds: seconds(from: tableStart, to: finish),
            endToEndSeconds: seconds(from: start!, to: finish),
            peakResidentBytes: residentBytes(),
            cancelledWorkerCandidateVisits: tracker.cancelledCandidateVisits,
        )
        return PaneSearchRun(transitions: [sample], duration: sample.endToEndSeconds)
    }

    private func measureSortCell(
        key: FileSortKey,
        direction: SortDirection,
        cardinality: Int,
        session: PaneSearchSession,
        sampleIndex: Int
    ) async throws -> PaneSearchRun {
        let query = query(forCardinality: cardinality)
        let target = FileSort(key: key, direction: direction)
        try await reset(session: session, query: query, sort: opposite(of: target), sampleIndex: sampleIndex)
        let expected = oracle(items: session.items, query: query, sort: target)
        let clock = ContinuousClock()
        var start: ContinuousClock.Instant?
        let acceptedAt = try await observeVisibleItemsChange(
            in: session.pane,
            sampleIndex: sampleIndex,
            boundary: "sort acceptance",
            recorder: timingRecorder,
        ) {
            start = clock.now
            self.timingRecorder?.record("start")
            self.timingRecorder?.record("operation")
            session.pane.sort = target
        }
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin")
        session.coordinator.apply(items: session.pane.visibleItems, selection: [], to: session.table)
        session.table.layoutSubtreeIfNeeded()
        self.timingRecorder?.record("table-finish")
        let finish = clock.now
        let sample = PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: PaneSearchTrace.sortChange.rawValue,
            fromQuery: query,
            toQuery: query,
            expectedCount: expected.count,
            sortKey: key.rawValue,
            sortDirection: direction.rawValue,
            cardinality: cardinality,
            projectionPath: "baseline-full-filter-sort",
            setterToAcceptanceSeconds: seconds(from: start!, to: acceptedAt),
            acceptanceToTableSeconds: seconds(from: tableStart, to: finish),
            endToEndSeconds: seconds(from: start!, to: finish),
            peakResidentBytes: residentBytes(),
            cancelledWorkerCandidateVisits: 0
        )
        return PaneSearchRun(transitions: [sample], duration: sample.endToEndSeconds)
    }

    private func makeWarmSession(
        sort: FileSort = FileSort(),
        projector: any PaneItemProjecting = LivePaneItemProjector(),
        supersessionTracker: PaneSearchSupersessionTracker? = nil
    ) async throws -> PaneSearchSession {
        let session = makeSession(
            items: paneSearchFixture(),
            sort: sort,
            projector: projector,
            supersessionTracker: supersessionTracker
        )
        await session.pane.navigate(to: session.directory, recordHistory: false)
        let expected = oracle(items: session.items, query: "", sort: sort)
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        session.coordinator.apply(items: session.pane.visibleItems, selection: [], to: session.table)
        session.table.layoutSubtreeIfNeeded()
        return session
    }

    private func makeSession(
        items: [FileItem],
        sort: FileSort = FileSort(),
        projector: any PaneItemProjecting = LivePaneItemProjector(),
        supersessionTracker: PaneSearchSupersessionTracker? = nil
    ) -> PaneSearchSession {
        let directory = URL(filePath: "/pane-search", directoryHint: .isDirectory)
        let pane = FilePaneState(
            directory: directory,
            sort: sort,
            listingService: StubDirectoryListingService(values: [directory: items]),
            projector: projector
        )
        let view = FileTableView(
            items: [],
            selection: .constant([]),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        table.dataSource = coordinator
        table.delegate = coordinator
        table.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        return PaneSearchSession(
            directory: directory,
            items: items,
            pane: pane,
            coordinator: coordinator,
            table: table,
            supersessionTracker: supersessionTracker
        )
    }

    private func reset(
        session: PaneSearchSession,
        query: String,
        sort: FileSort,
        sampleIndex: Int
    ) async throws {
        if session.pane.sort != sort {
            _ = try await observeVisibleItemsChange(
                in: session.pane,
                sampleIndex: sampleIndex,
                boundary: "pre-state sort acceptance"
            ) {
                session.pane.sort = sort
            }
        }
        if session.pane.filterQuery != query {
            _ = try await observeVisibleItemsChange(
                in: session.pane,
                sampleIndex: sampleIndex,
                boundary: "pre-state query acceptance"
            ) {
                session.pane.updateFilterQuery(query)
            }
        }
        let expected = oracle(items: session.items, query: query, sort: sort)
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        session.coordinator.apply(items: session.pane.visibleItems, selection: [], to: session.table)
        session.table.layoutSubtreeIfNeeded()
    }
}

private struct PaneSearchRun {
    let transitions: [PaneSearchTransitionSample]
    let duration: Double
}

@MainActor
private final class PaneSearchSession {
    let directory: URL
    let items: [FileItem]
    let pane: FilePaneState
    let coordinator: FileTableView.Coordinator
    let table: NSTableView
    let supersessionTracker: PaneSearchSupersessionTracker?
    var navigationTask: Task<Void, Never>?

    init(
        directory: URL,
        items: [FileItem],
        pane: FilePaneState,
        coordinator: FileTableView.Coordinator,
        table: NSTableView,
        supersessionTracker: PaneSearchSupersessionTracker?
    ) {
        self.directory = directory
        self.items = items
        self.pane = pane
        self.coordinator = coordinator
        self.table = table
        self.supersessionTracker = supersessionTracker
    }
}

private enum PaneSearchScenario: Sendable {
    case trace(PaneSearchTrace)
    case sort(FileSortKey, SortDirection, Int)

    init(rawValue: String) throws {
        if let trace = PaneSearchTrace(rawValue: rawValue), trace != .sortChange {
            self = .trace(trace)
            return
        }
        let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "sort",
              let key = FileSortKey(rawValue: String(components[1])),
              let direction = SortDirection(rawValue: String(components[2])),
              let cardinality = Int(components[3]),
              [10_000, 3_439, 299, 20, 1].contains(cardinality)
        else {
            throw PaneSearchProbeError.invalidScenario(rawValue)
        }
        self = .sort(key, direction, cardinality)
    }

    var rawValue: String {
        switch self {
        case .trace(let trace): trace.rawValue
        case .sort(let key, let direction, let cardinality): "sort:\(key.rawValue):\(direction.rawValue):\(cardinality)"
        }
    }

    var trace: PaneSearchTrace? {
        guard case .trace(let trace) = self else { return .sortChange }
        return trace
    }
}

private enum PaneSearchProbeError: LocalizedError {
    case invalidScenario(String)
    case incorrectProjection
    case missingReusableSession
    case filterQuerySetterDidNotTakeEffect
    case acceptanceTimedOut(sampleIndex: Int, boundary: String)

    var errorDescription: String? {
        switch self {
        case .invalidScenario(let scenario): "Invalid pane-search benchmark scenario: \(scenario)"
        case .incorrectProjection: "Accepted pane projection differed from the full filter/sort oracle"
        case .missingReusableSession: "The selected scenario did not receive its reusable pane-search session"
        case .filterQuerySetterDidNotTakeEffect: "The normalized-reuse setter did not update the pane query"
        case .acceptanceTimedOut(let sampleIndex, let boundary):
            "Pane-search sample \(sampleIndex) timed out waiting for \(boundary)"
        }
    }
}

@MainActor
private func observeVisibleItemsChange(
    in pane: FilePaneState,
    sampleIndex: Int,
    boundary: String,
    recorder: PaneSearchTimingEventRecorder? = nil,
    perform operation: @escaping @MainActor () -> Void
) async throws -> ContinuousClock.Instant {
    try await withCheckedThrowingContinuation { continuation in
        let gate = PaneSearchAcceptanceGate()
        var observationInstalled = false
        let previousHandler = pane.projectionAcceptanceHandler
        pane.projectionAcceptanceHandler = { _ in
            guard gate.claim() else { return }
            pane.projectionAcceptanceHandler = previousHandler
            recorder?.record("accepted")
            continuation.resume(returning: ContinuousClock().now)
        }
        withObservationTracking {
            _ = pane.visibleItems
        } onChange: {
            Task { @MainActor in
                guard gate.claim() else { return }
                pane.projectionAcceptanceHandler = previousHandler
                recorder?.record("accepted")
                continuation.resume(returning: ContinuousClock().now)
            }
        }
        observationInstalled = true
        recorder?.recordArmed(
            handlerInstalled: pane.projectionAcceptanceHandler != nil,
            observationInstalled: observationInstalled
        )
        operation()
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard gate.claim() else { return }
            await MainActor.run { pane.projectionAcceptanceHandler = previousHandler }
            continuation.resume(throwing: PaneSearchProbeError.acceptanceTimedOut(
                sampleIndex: sampleIndex,
                boundary: boundary
            ))
        }
    }
}

private func oracle(items: [FileItem], query: String, sort: FileSort) -> [FileItem] {
    PaneItemProjector().project(
        items: items,
        key: PaneProjectionKey(itemsRevision: 1, normalizedQuery: query, sort: sort)
    ).items
}

private func verifyAcceptedItems(_ actual: [FileItem], expected: [FileItem]) throws {
    guard actual.map(\.url) == expected.map(\.url) else {
        throw PaneSearchProbeError.incorrectProjection
    }
}

private func queries(for trace: PaneSearchTrace) -> [String] {
    switch trace {
    case .firstQuery: ["report"]
    case .numeric: ["1", "19", "199", "1999"]
    case .english: ["r", "re", "rep", "report", "report-1999"]
    case .korean: ["보", "보고", "보고서", "보고서-1998"]
    case .reverseDeletion: ["1999", "199", "19", "1", ""]
    case .replacement: ["report-1999", "보고서-1998", " \n report-1999 \t"]
    case .completeLoad, .rapidBurst, .sortChange: preconditionFailure("Trace does not use sequential queries")
    }
}

private func query(forCardinality cardinality: Int) -> String {
    switch cardinality {
    case 10_000: ""
    case 3_439: "1"
    case 299: "19"
    case 20: "199"
    case 1: "1999"
    default: preconditionFailure("Unsupported sort-cell cardinality")
    }
}

private func opposite(of sort: FileSort) -> FileSort {
    FileSort(
        key: sort.key,
        direction: sort.direction == .ascending ? .descending : .ascending
    )
}

private func seconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> Double {
    Double(start.duration(to: end).components.attoseconds) / 1_000_000_000_000_000_000
        + Double(start.duration(to: end).components.seconds)
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { infoPointer in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                infoPointer,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private final class PaneSearchSupersessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var latestQuery = ""
    private var visits = 0

    func publish(_ query: String) {
        lock.lock()
        latestQuery = query
        lock.unlock()
    }

    func reset() {
        lock.lock()
        latestQuery = ""
        visits = 0
        lock.unlock()
    }

    func recordCandidateVisit(for query: String) {
        lock.lock()
        if query != latestQuery { visits += 1 }
        lock.unlock()
    }

    var cancelledCandidateVisits: Int {
        lock.lock()
        defer { lock.unlock() }
        return visits
    }
}

private final class PaneSearchAcceptanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private struct CountingBaselinePaneItemProjector: PaneItemProjecting {
    let tracker: PaneSearchSupersessionTracker

    func project(items: [FileItem], key: PaneProjectionKey) async -> PaneItemProjection {
        await Task.yield()
        let query = key.normalizedQuery
        let filtered = items.filter { item in
            tracker.recordCandidateVisit(for: query)
            return query.isEmpty || item.name.localizedStandardContains(query)
        }
        let projected = key.sort.apply(to: filtered)
        var indexByURL: [URL: Int] = [:]
        var urlByEntryPath: [String: URL] = [:]
        for (index, item) in projected.enumerated() {
            let url = item.url.standardizedFileURL
            indexByURL[url] = index
            urlByEntryPath[PaneEntryPath.normalize(url)] = url
        }
        return PaneItemProjection(
            key: key,
            items: projected,
            indexByURL: indexByURL,
            urlByEntryPath: urlByEntryPath
        )
    }
}

func paneSearchFixture(count: Int = 10_000) -> [FileItem] {
    let root = URL(filePath: "/scale", directoryHint: .isDirectory)
    return (0..<count).map { index in
        let isDirectory = index.isMultiple(of: 10)
        let name: String
        if index.isMultiple(of: 2) {
            name = switch index % 8 {
            case 0: "보고서-road-\(index)"
            case 2: "보고서-read-\(index)"
            case 4: "보고서-repair-\(index)"
            default: "보고서-\(index)"
            }
        } else {
            name = switch index % 8 {
            case 1: "보관-report-\(index)"
            case 3: "보고용-report-\(index)"
            case 5: "보고서-report-\(index)"
            default: "report-\(index)"
            }
        }
        return FileItem(
            url: root.appending(path: name),
            name: name,
            isDirectory: isDirectory,
            isPackage: false,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            byteSize: isDirectory ? nil : Int64(index * 17),
            typeDescription: isDirectory ? "Folder" : "Text"
        )
    }
}
