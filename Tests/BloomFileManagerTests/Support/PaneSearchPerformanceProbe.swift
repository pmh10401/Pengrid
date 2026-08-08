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
    /// `nil` preserves the Task 1 baseline schema. Candidate ready-order
    /// samples set this only after the accepted empty/active-order state was
    /// observed before dispatching the measured setter.
    let matchingActiveOrderWasAccepted: Bool?
    /// Every successful sample has compared identities and order with the
    /// full filter/sort oracle before it is emitted.
    let matchesFullOracle: Bool?
    /// Set only for the rapid-burst lifecycle trace, where the recorder
    /// independently observes every scheduled, accepted, and table-applied
    /// token. Ordinary latency samples deliberately leave this unset rather
    /// than implying that a zero was independently measured.
    let stalePublicationCount: Int?
    /// The mounted production `FileTableView` reported the accepted token.
    let tableAppliedForAcceptedToken: Bool?
}

struct PaneSearchStatistics: Codable, Sendable {
    let medianSeconds: Double
    let p95Seconds: Double
}

struct PaneSearchIntegerStatistics: Codable, Sendable {
    let median: Int
    let p95: Int
}

struct PaneSearchTransitionStatistics: Codable, Sendable {
    let trace: String
    let fromQuery: String
    let toQuery: String
    let sortKey: String?
    let sortDirection: String?
    let cardinality: Int
    let sampleCount: Int
    let setterToAcceptanceStatistics: PaneSearchStatistics
    let acceptanceToTableStatistics: PaneSearchStatistics
    let endToEndStatistics: PaneSearchStatistics
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
    let transitionStatistics: [PaneSearchTransitionStatistics]?
    let cancelledWorkerCandidateVisitStatistics: PaneSearchIntegerStatistics?

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

struct PaneSearchCancellationLifecycleEvidence: Sendable {
    let cancellationWasRequested: Bool
    let cancelledWorkerCandidateVisits: Int
    let activeWorkerCountAfterDrain: Int
}

struct PaneSearchSessionLifetimeEvidence: Sendable {
    let callbackWasExact: Bool
    let traceWasExact: Bool?
    let didDeallocate: Bool
}

struct PaneSearchSynchronousPoolOwnershipEvidence: Sendable {
    let firstContentViewWasDetached: Bool
    let firstDocumentViewWasDetached: Bool
    let secondContentViewWasDetached: Bool
    let secondDocumentViewWasDetached: Bool
    let windowCountBefore: Int
    let windowCountAfterPoolExit: Int
}

struct PaneSearchCompleteLoadLifecycleEvidence: Sendable {
    let exactTableCallbackWasObserved: Bool
    let windowContentWasDetached: Bool
    let scrollDocumentWasDetached: Bool
    let sessionWasReleased: Bool
    let paneWasReleased: Bool
    let coordinatorWasReleased: Bool
    let acceptedObservationCancelledAndDrainedItsTimeout: Bool
}

struct PaneSearchTimedEvent {
    let name: String
    let instant: ContinuousClock.Instant

    func elapsedSeconds(to other: PaneSearchTimedEvent) -> Double {
        seconds(from: instant, to: other.instant)
    }
}

@MainActor
final class PaneSearchTimingEventRecorder {
    private(set) var events: [String] = []
    private(set) var timedEvents: [PaneSearchTimedEvent] = []
    private(set) var armedMechanismsInstalled: [Bool] = []

    func record(_ event: String) {
        record(event, at: ContinuousClock().now)
    }

    func record(_ event: String, at instant: ContinuousClock.Instant) {
        events.append(event)
        timedEvents.append(.init(name: event, instant: instant))
    }

    func recordArmed(handlerInstalled: Bool, observationInstalled: Bool) {
        record("armed")
        armedMechanismsInstalled.append(handlerInstalled && observationInstalled)
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
        timedEvents.removeAll(keepingCapacity: true)
        armedMechanismsInstalled.removeAll(keepingCapacity: true)
    }
}

@MainActor
private final class PaneSearchTableCallbackRecorder {
    private(set) var events: [(token: PaneProjectionToken, instant: ContinuousClock.Instant)] = []

    func record(_ token: PaneProjectionToken) {
        events.append((token, ContinuousClock().now))
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
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

func nearestRankIntegerStatistics(_ values: [Int]) -> PaneSearchIntegerStatistics {
    precondition(!values.isEmpty, "A benchmark scenario must have at least one recorded sample")
    let ordered = values.sorted()
    let medianIndex = (ordered.count - 1) / 2
    let p95Index = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
    return PaneSearchIntegerStatistics(median: ordered[medianIndex], p95: ordered[p95Index])
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
        scenario: trace.rawValue,
        collectCandidateEvidence: true
    ).measureSelectedScenario()
    return PaneSearchTraceMeasurement(transitions: report.rawSamples)
}

@MainActor
final class PaneSearchPerformanceProbe {
    private let warmupCount: Int
    private let sampleCount: Int
    private let scenario: PaneSearchScenario
    private let timingRecorder: PaneSearchTimingEventRecorder?
    private let collectCandidateEvidence: Bool
    private var completeLoadLifecycleRecorder: PaneSearchCompleteLoadLifecycleRecorder?

    init(
        warmupCount: Int,
        sampleCount: Int,
        scenario: String,
        timingRecorder: PaneSearchTimingEventRecorder? = nil,
        collectCandidateEvidence: Bool = false
    ) throws {
        precondition(warmupCount >= 0)
        precondition(sampleCount > 0)
        self.warmupCount = warmupCount
        self.sampleCount = sampleCount
        self.scenario = try PaneSearchScenario(rawValue: scenario)
        self.timingRecorder = timingRecorder
        self.collectCandidateEvidence = collectCandidateEvidence
    }

    func measureSelectedScenario() async throws -> PaneSearchScenarioReport {
        let reusableSession = try await makeReusableSession()
        defer { reusableSession?.tearDown() }
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
            rapidBurstQueryCount: scenario.trace == .rapidBurst ? 20 : nil,
            transitionStatistics: collectCandidateEvidence ? transitionStatistics(for: rawSamples) : nil,
            cancelledWorkerCandidateVisitStatistics: collectCandidateEvidence && scenario.trace == .rapidBurst
                ? nearestRankIntegerStatistics(rawSamples.map(\.cancelledWorkerCandidateVisits))
                : nil
        )
    }

    func measureNormalizedEquivalentReuseForTesting() async throws -> PaneSearchTransitionSample {
        let session = try await makeWarmSession()
        defer { session.tearDown() }
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
        // Mount the current accepted token before measuring the normalized
        // no-op, so its production table update has no new token to report.
        applyProductionTable(session)
        session.tableCallbackRecorder.reset()
        timingRecorder?.reset()
        return try await measureQueryTransition(
            trace: .replacement,
            sampleIndex: 0,
            fromQuery: fromQuery,
            toQuery: toQuery,
            session: session
        ).sample
    }

    func hasMountedProductionTableWindowForTesting() -> Bool {
        let session = makeSession(items: paneSearchFixture(count: 1))
        defer { session.tearDown() }
        return session.table.window === session.window
    }

    func hasProjectionTraceForTesting(capturesProjectionTrace: Bool) -> Bool {
        let session = makeSession(
            items: paneSearchFixture(count: 1),
            capturesProjectionTrace: capturesProjectionTrace
        )
        defer { session.tearDown() }
        return session.pane.projectionTraceRecorder != nil
    }

    func measureDeterministicLiveProjectorCancellationForTesting() async throws -> PaneSearchCancellationLifecycleEvidence {
        let session = try await makeWarmSession(capturesWorkerVisits: true)
        defer { session.tearDown() }
        guard let workerVisitRecorder = session.workerVisitRecorder else {
            throw PaneSearchProbeError.missingWorkerLifecycleRecorder
        }
        try await waitForWorkerDrain(session)
        workerVisitRecorder.reset()
        let gate = PaneSearchFirstCandidateGate()
        workerVisitRecorder.setTestProbeFactory {
            PaneProjectionWorkerVisitProbe(candidateVisitHook: {
                await gate.pauseAfterFirstCandidateVisit()
            })
        }

        session.pane.updateFilterQuery("report")
        guard try await waitForFirstCandidateGate(gate) else {
            throw PaneSearchProbeError.candidateTraversalDidNotBegin
        }

        session.pane.updateFilterQuery("report-1999")
        guard workerVisitRecorder.cancelledWorkerCount > 0 else {
            await gate.release()
            throw PaneSearchProbeError.cancellationWasNotRequested
        }
        await gate.release()

        let expected = oracle(items: session.items, query: "report-1999", sort: session.pane.sort)
        for _ in 0..<10_000 {
            if session.pane.visibleItems.map(\.url) == expected.map(\.url) { break }
            await Task.yield()
        }
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        try await waitForWorkerDrain(session)
        workerVisitRecorder.setTestProbeFactory(nil)

        let visits = workerVisitRecorder.maximumCancelledWorkerCandidateVisits
        guard visits > 0 else { throw PaneSearchProbeError.cancellationProbeWasVacant }
        return PaneSearchCancellationLifecycleEvidence(
            cancellationWasRequested: workerVisitRecorder.cancelledWorkerCount > 0,
            cancelledWorkerCandidateVisits: visits,
            activeWorkerCountAfterDrain: workerVisitRecorder.activeWorkerCount
        )
    }

    func synchronousPoolOwnershipEvidenceForTesting() -> PaneSearchSynchronousPoolOwnershipEvidence {
        let application = NSApplication.shared
        let before = application.windows.count
        var firstContentViewWasDetached = false
        var firstDocumentViewWasDetached = false
        var secondContentViewWasDetached = false
        var secondDocumentViewWasDetached = false

        autoreleasepool {
            let session = makeSession(items: paneSearchFixture(count: 1))
            applyProductionTable(session)
            session.tearDown()
            firstContentViewWasDetached = session.window.contentView == nil
            firstDocumentViewWasDetached = session.scroll.documentView == nil
            session.tearDown()
            secondContentViewWasDetached = session.window.contentView == nil
            secondDocumentViewWasDetached = session.scroll.documentView == nil
        }

        return PaneSearchSynchronousPoolOwnershipEvidence(
            firstContentViewWasDetached: firstContentViewWasDetached,
            firstDocumentViewWasDetached: firstDocumentViewWasDetached,
            secondContentViewWasDetached: secondContentViewWasDetached,
            secondDocumentViewWasDetached: secondDocumentViewWasDetached,
            windowCountBefore: before,
            windowCountAfterPoolExit: application.windows.count
        )
    }

    func completeLoadLifecycleEvidenceForTesting() async throws -> PaneSearchCompleteLoadLifecycleEvidence {
        let recorder = PaneSearchCompleteLoadLifecycleRecorder()
        completeLoadLifecycleRecorder = recorder
        defer { completeLoadLifecycleRecorder = nil }
        _ = try await measureCompleteLoad(sampleIndex: 0)
        for _ in 0..<1_000 {
            if recorder.timeoutRecorder.wasCancelledAndDrained { break }
            await Task.yield()
        }
        return recorder.evidence
    }

    func mountedProductionSessionLifetimeEvidenceForTesting(
        capturesProjectionTrace: Bool
    ) async throws -> PaneSearchSessionLifetimeEvidence {
        let reference = PaneSearchWeakSessionReference()
        let callbackEvidence = try await mountVerifyAndReleaseSessionForTesting(
            reference: reference,
            capturesProjectionTrace: capturesProjectionTrace
        )
        return PaneSearchSessionLifetimeEvidence(
            callbackWasExact: callbackEvidence.callbackWasExact,
            traceWasExact: callbackEvidence.traceWasExact,
            didDeallocate: reference.session == nil
        )
    }

    private func mountVerifyAndReleaseSessionForTesting(
        reference: PaneSearchWeakSessionReference,
        capturesProjectionTrace: Bool
    ) async throws -> (callbackWasExact: Bool, traceWasExact: Bool?) {
        let session = try await makeWarmSession(capturesProjectionTrace: capturesProjectionTrace)
        reference.session = session
        _ = try tableCallbackEvidence(for: session)
        let traceWasExact: Bool?
        if capturesProjectionTrace {
            _ = try traceEvidence(for: session)
            traceWasExact = true
        } else {
            traceWasExact = nil
        }
        session.tearDown()
        return (callbackWasExact: true, traceWasExact: traceWasExact)
    }

    private func makeReusableSession() async throws -> PaneSearchSession? {
        switch scenario {
        case .trace(.completeLoad):
            return nil
        case .trace(.rapidBurst):
            return try await makeWarmSession(
                capturesWorkerVisits: collectCandidateEvidence,
                capturesProjectionTrace: collectCandidateEvidence
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
        let expected = oracle(items: items, query: "", sort: FileSort())
        let session = makeSession(items: items)
        completeLoadLifecycleRecorder?.capture(session)
        defer {
            session.tearDown()
            completeLoadLifecycleRecorder?.recordTeardown(of: session)
        }
        session.tableCallbackRecorder.reset()
        let clock = ContinuousClock()
        var start: ContinuousClock.Instant?
        _ = try await observeVisibleItemsChange(
            in: session.pane,
            sampleIndex: sampleIndex,
            boundary: "complete-load acceptance",
            recorder: timingRecorder,
            timeoutRecorder: completeLoadLifecycleRecorder?.timeoutRecorder,
        ) {
            start = clock.now
            self.timingRecorder?.record("start")
            self.timingRecorder?.record("operation")
            session.navigationTask = session.pane.beginNavigation(to: session.directory, recordHistory: false)
        }
        // The projection handler fires before the navigation task has finished
        // establishing the current table-application state. Treat completion
        // of that task as the complete-load acceptance boundary.
        await session.navigationTask?.value
        let acceptedAt = clock.now
        let acceptedSeconds = seconds(from: start!, to: acceptedAt)
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin", at: tableStart)
        applyProductionTable(session)
        let finish = clock.now
        let tableSeconds = seconds(from: tableStart, to: finish)
        let peakResidentBytes = residentBytes()
        self.timingRecorder?.record("table-finish", at: finish)
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        _ = try tableCallbackEvidence(for: session)
        completeLoadLifecycleRecorder?.recordExactTableCallback()
        let sample = PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: PaneSearchTrace.completeLoad.rawValue,
            fromQuery: "<unloaded>",
            toQuery: "",
            expectedCount: expected.count,
            sortKey: FileSortKey.name.rawValue,
            sortDirection: SortDirection.ascending.rawValue,
            cardinality: expected.count,
            projectionPath: projectionPath(session.pane.acceptedProjectionDiagnostics.path),
            setterToAcceptanceSeconds: acceptedSeconds,
            acceptanceToTableSeconds: tableSeconds,
            endToEndSeconds: acceptedSeconds + tableSeconds,
            peakResidentBytes: peakResidentBytes,
            cancelledWorkerCandidateVisits: 0,
            matchingActiveOrderWasAccepted: nil,
            matchesFullOracle: collectCandidateEvidence ? true : nil,
            stalePublicationCount: nil,
            tableAppliedForAcceptedToken: collectCandidateEvidence ? true : nil
        )
        return PaneSearchRun(transitions: [sample], duration: sample.endToEndSeconds)
    }

    private func measureQueryTrace(
        _ trace: PaneSearchTrace,
        session: PaneSearchSession,
        sampleIndex: Int
    ) async throws -> PaneSearchRun {
        try await reset(session: session, query: "", sort: FileSort(), sampleIndex: sampleIndex)
        var transitions: [PaneSearchTransitionSample] = []
        var currentQuery = ""
        for query in queries(for: trace) {
            let measuredTransition = try await measureQueryTransition(
                trace: trace,
                sampleIndex: sampleIndex,
                fromQuery: currentQuery,
                toQuery: query,
                session: session
            )
            transitions.append(measuredTransition.sample)
            currentQuery = query
        }
        return PaneSearchRun(
            transitions: transitions,
            duration: transitions.reduce(0) { $0 + $1.endToEndSeconds }
        )
    }

    private func measureQueryTransition(
        trace: PaneSearchTrace,
        sampleIndex: Int,
        fromQuery: String,
        toQuery: String,
        session: PaneSearchSession
    ) async throws -> PaneSearchMeasuredTransition {
        let expected = oracle(items: session.items, query: toQuery, sort: session.pane.sort)
        let requiresReadyActiveOrder = requiresReadyActiveOrder(for: trace)
        let matchingActiveOrderWasAccepted = collectCandidateEvidence && requiresReadyActiveOrder
            ? hasMatchingAcceptedActiveOrder(in: session)
            : nil
        let clock = ContinuousClock()
        var start: ContinuousClock.Instant?
        if PaneFilenameFilter.normalize(fromQuery) == PaneFilenameFilter.normalize(toQuery) {
            session.tableCallbackRecorder.reset()
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
            let tableStart = clock.now
            self.timingRecorder?.record("reuse-table-begin")
            applyProductionTable(session)
            let finish = clock.now
            let setterToAcceptanceSeconds = seconds(from: start!, to: acceptedAt)
            let acceptanceToTableSeconds = seconds(from: tableStart, to: finish)
            let peakResidentBytes = residentBytes()
            self.timingRecorder?.record("reuse-table-finish", at: finish)
            try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
            try verifyNoProjectionTableCallback(in: session)
            return PaneSearchMeasuredTransition(
                sample: PaneSearchTransitionSample(sampleIndex: sampleIndex, trace: trace.rawValue, fromQuery: fromQuery, toQuery: toQuery, expectedCount: expected.count, sortKey: session.pane.sort.key.rawValue, sortDirection: session.pane.sort.direction.rawValue, cardinality: expected.count, projectionPath: "accepted-projection-reuse", setterToAcceptanceSeconds: setterToAcceptanceSeconds, acceptanceToTableSeconds: acceptanceToTableSeconds, endToEndSeconds: setterToAcceptanceSeconds + acceptanceToTableSeconds, peakResidentBytes: peakResidentBytes, cancelledWorkerCandidateVisits: 0, matchingActiveOrderWasAccepted: matchingActiveOrderWasAccepted, matchesFullOracle: collectCandidateEvidence ? true : nil, stalePublicationCount: nil, tableAppliedForAcceptedToken: collectCandidateEvidence ? false : nil)
            )
        }
        session.tableCallbackRecorder.reset()
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
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin", at: tableStart)
        applyProductionTable(session)
        let finish = clock.now
        let setterToAcceptanceSeconds = seconds(from: start!, to: acceptedAt)
        let acceptanceToTableSeconds = seconds(from: tableStart, to: finish)
        let peakResidentBytes = residentBytes()
        self.timingRecorder?.record("table-finish", at: finish)
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        _ = try tableCallbackEvidence(for: session)
        return PaneSearchMeasuredTransition(sample: PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: trace.rawValue,
            fromQuery: fromQuery,
            toQuery: toQuery,
            expectedCount: expected.count,
            sortKey: session.pane.sort.key.rawValue,
            sortDirection: session.pane.sort.direction.rawValue,
            cardinality: expected.count,
            projectionPath: projectionPath(session.pane.acceptedProjectionDiagnostics.path),
            setterToAcceptanceSeconds: setterToAcceptanceSeconds,
            acceptanceToTableSeconds: acceptanceToTableSeconds,
            endToEndSeconds: setterToAcceptanceSeconds + acceptanceToTableSeconds,
            peakResidentBytes: peakResidentBytes,
            cancelledWorkerCandidateVisits: 0,
            matchingActiveOrderWasAccepted: matchingActiveOrderWasAccepted,
            matchesFullOracle: collectCandidateEvidence ? true : nil,
            stalePublicationCount: nil,
            tableAppliedForAcceptedToken: collectCandidateEvidence ? true : nil
        ))
    }

    private func measureRapidBurst(
        session: PaneSearchSession,
        sampleIndex: Int
    ) async throws -> PaneSearchRun {
        try await reset(session: session, query: "", sort: FileSort(), sampleIndex: sampleIndex)
        if collectCandidateEvidence {
            guard let workerVisitRecorder = session.workerVisitRecorder else {
                throw PaneSearchProbeError.missingWorkerLifecycleRecorder
            }
            guard let traceRecorder = session.traceRecorder else {
                throw PaneSearchProbeError.missingProjectionTraceRecorder
            }
            try await waitForWorkerDrain(session)
            workerVisitRecorder.reset()
            traceRecorder.reset()
        }
        session.tableCallbackRecorder.reset()
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
                session.pane.updateFilterQuery(query)
            }
        }
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin", at: tableStart)
        applyProductionTable(session)
        let finish = clock.now
        let setterToAcceptanceSeconds = seconds(from: start!, to: acceptedAt)
        let acceptanceToTableSeconds = seconds(from: tableStart, to: finish)
        let peakResidentBytes = residentBytes()
        self.timingRecorder?.record("table-finish", at: finish)
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        let stalePublicationCount: Int?
        let cancelledWorkerCandidateVisits: Int
        if collectCandidateEvidence {
            let traceEvidence = try traceEvidence(for: session)
            stalePublicationCount = traceEvidence.stalePublicationCount
            try await waitForWorkerDrain(session)
            cancelledWorkerCandidateVisits = session.workerVisitRecorder?.maximumCancelledWorkerCandidateVisits ?? 0
        } else {
            _ = try tableCallbackEvidence(for: session)
            stalePublicationCount = nil
            cancelledWorkerCandidateVisits = 0
        }
        let sample = PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: PaneSearchTrace.rapidBurst.rawValue,
            fromQuery: "",
            toQuery: finalQuery,
            expectedCount: expected.count,
            sortKey: session.pane.sort.key.rawValue,
            sortDirection: session.pane.sort.direction.rawValue,
            cardinality: expected.count,
            projectionPath: projectionPath(session.pane.acceptedProjectionDiagnostics.path),
            setterToAcceptanceSeconds: setterToAcceptanceSeconds,
            acceptanceToTableSeconds: acceptanceToTableSeconds,
            endToEndSeconds: setterToAcceptanceSeconds + acceptanceToTableSeconds,
            peakResidentBytes: peakResidentBytes,
            cancelledWorkerCandidateVisits: cancelledWorkerCandidateVisits,
            matchingActiveOrderWasAccepted: nil,
            matchesFullOracle: collectCandidateEvidence ? true : nil,
            stalePublicationCount: stalePublicationCount,
            tableAppliedForAcceptedToken: collectCandidateEvidence ? true : nil,
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
        session.tableCallbackRecorder.reset()
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
        let tableStart = clock.now
        self.timingRecorder?.record("table-begin", at: tableStart)
        applyProductionTable(session)
        let finish = clock.now
        let setterToAcceptanceSeconds = seconds(from: start!, to: acceptedAt)
        let acceptanceToTableSeconds = seconds(from: tableStart, to: finish)
        let peakResidentBytes = residentBytes()
        self.timingRecorder?.record("table-finish", at: finish)
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        _ = try tableCallbackEvidence(for: session)
        let sample = PaneSearchTransitionSample(
            sampleIndex: sampleIndex,
            trace: PaneSearchTrace.sortChange.rawValue,
            fromQuery: query,
            toQuery: query,
            expectedCount: expected.count,
            sortKey: key.rawValue,
            sortDirection: direction.rawValue,
            cardinality: cardinality,
            projectionPath: projectionPath(session.pane.acceptedProjectionDiagnostics.path),
            setterToAcceptanceSeconds: setterToAcceptanceSeconds,
            acceptanceToTableSeconds: acceptanceToTableSeconds,
            endToEndSeconds: setterToAcceptanceSeconds + acceptanceToTableSeconds,
            peakResidentBytes: peakResidentBytes,
            cancelledWorkerCandidateVisits: 0,
            matchingActiveOrderWasAccepted: nil,
            matchesFullOracle: collectCandidateEvidence ? true : nil,
            stalePublicationCount: nil,
            tableAppliedForAcceptedToken: collectCandidateEvidence ? true : nil
        )
        return PaneSearchRun(transitions: [sample], duration: sample.endToEndSeconds)
    }

    private func makeWarmSession(
        sort: FileSort = FileSort(),
        projector: any PaneItemProjecting = LivePaneItemProjector(),
        capturesWorkerVisits: Bool = false,
        capturesProjectionTrace: Bool = false
    ) async throws -> PaneSearchSession {
        let session = makeSession(
            items: paneSearchFixture(),
            sort: sort,
            projector: projector,
            capturesWorkerVisits: capturesWorkerVisits,
            capturesProjectionTrace: capturesProjectionTrace
        )
        await session.pane.navigate(to: session.directory, recordHistory: false)
        let expected = oracle(items: session.items, query: "", sort: sort)
        try verifyAcceptedItems(session.pane.visibleItems, expected: expected)
        applyProductionTable(session)
        return session
    }

    private func makeSession(
        items: [FileItem],
        sort: FileSort = FileSort(),
        projector: any PaneItemProjecting = LivePaneItemProjector(),
        capturesWorkerVisits: Bool = false,
        capturesProjectionTrace: Bool = false
    ) -> PaneSearchSession {
        let directory = URL(filePath: "/pane-search", directoryHint: .isDirectory)
        let pane = FilePaneState(
            directory: directory,
            sort: sort,
            listingService: StubDirectoryListingService(values: [directory: items]),
            projector: projector
        )
        let traceRecorder = capturesProjectionTrace ? PaneSearchProjectionTraceRecorder() : nil
        let tableCallbackRecorder = PaneSearchTableCallbackRecorder()
        let workerVisitRecorder = capturesWorkerVisits ? PaneProjectionWorkerVisitRecorder() : nil
        pane.projectionTraceRecorder = traceRecorder
        pane.projectionWorkerVisitRecorder = workerVisitRecorder
        let onProjectionApplied: (PaneProjectionToken) -> Void = { token in
            tableCallbackRecorder.record(token)
            pane.recordTableApplicationCompleted(token)
        }
        let view: FileTableView
        if capturesProjectionTrace {
            view = FileTableView(
                items: [],
                selection: .constant([]),
                projectionToken: nil,
                itemIndexByURL: pane.visibleIndexByURL,
                sort: sort,
                directory: directory,
                onActivatePane: {},
                onOpen: { _ in },
                onSortChange: { _ in },
                onProjectionApplicationAttempt: { pane.recordTableApplicationAttempt($0) },
                onProjectionApplied: onProjectionApplied
            )
        } else {
            view = FileTableView(
                items: [],
                selection: .constant([]),
                projectionToken: nil,
                itemIndexByURL: pane.visibleIndexByURL,
                sort: sort,
                directory: directory,
                onActivatePane: {},
                onOpen: { _ in },
                onSortChange: { _ in },
                onProjectionApplied: onProjectionApplied
            )
        }
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        let window = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderOut(nil)
        let table = scroll.documentView as! NSTableView
        table.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        return PaneSearchSession(
            directory: directory,
            items: items,
            pane: pane,
            coordinator: coordinator,
            table: table,
            scroll: scroll,
            window: window,
            traceRecorder: traceRecorder,
            tableCallbackRecorder: tableCallbackRecorder,
            workerVisitRecorder: workerVisitRecorder
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
        applyProductionTable(session)
    }
}

private func transitionStatistics(
    for samples: [PaneSearchTransitionSample]
) -> [PaneSearchTransitionStatistics] {
    let groups = Dictionary(grouping: samples) { sample in
        [
            sample.trace,
            sample.fromQuery,
            sample.toQuery,
            sample.sortKey ?? "<nil>",
            sample.sortDirection ?? "<nil>",
            String(sample.cardinality),
        ].joined(separator: "\u{1F}")
    }
    return groups.values.map { samples in
        let exemplar = samples[0]
        return PaneSearchTransitionStatistics(
            trace: exemplar.trace,
            fromQuery: exemplar.fromQuery,
            toQuery: exemplar.toQuery,
            sortKey: exemplar.sortKey,
            sortDirection: exemplar.sortDirection,
            cardinality: exemplar.cardinality,
            sampleCount: samples.count,
            setterToAcceptanceStatistics: nearestRankStatistics(samples.map(\.setterToAcceptanceSeconds)),
            acceptanceToTableStatistics: nearestRankStatistics(samples.map(\.acceptanceToTableSeconds)),
            endToEndStatistics: nearestRankStatistics(samples.map(\.endToEndSeconds))
        )
    }.sorted { lhs, rhs in
        [lhs.trace, lhs.fromQuery, lhs.toQuery, lhs.sortKey ?? "", lhs.sortDirection ?? "", String(lhs.cardinality)]
            .joined(separator: "\u{1F}")
            < [rhs.trace, rhs.fromQuery, rhs.toQuery, rhs.sortKey ?? "", rhs.sortDirection ?? "", String(rhs.cardinality)]
                .joined(separator: "\u{1F}")
    }
}

private func requiresReadyActiveOrder(for trace: PaneSearchTrace) -> Bool {
    switch trace {
    case .numeric, .english, .korean:
        true
    case .completeLoad, .firstQuery, .reverseDeletion, .replacement, .rapidBurst, .sortChange:
        false
    }
}

@MainActor
private func hasMatchingAcceptedActiveOrder(in session: PaneSearchSession) -> Bool {
    switch session.pane.acceptedProjectionDiagnostics.path {
    case .emptyActiveOrder, .activeOrderFullScan, .activeOrderNarrowedASCII:
        true
    case .fallbackFilterThenSort, .sortedVisibleSubset:
        false
    }
}

private func projectionPath(_ path: PaneProjectionPath) -> String {
    switch path {
    case .fallbackFilterThenSort: "fallback-filter-then-sort"
    case .activeOrderFullScan: "active-order-full-scan"
    case .activeOrderNarrowedASCII: "active-order-narrowed-ascii"
    case .emptyActiveOrder: "empty-active-order"
    case .sortedVisibleSubset: "sorted-visible-subset"
    }
}

@MainActor
private func applyProductionTable(_ session: PaneSearchSession) {
    let pane = session.pane
    let tableCallbackRecorder = session.tableCallbackRecorder
    let onProjectionApplied: (PaneProjectionToken) -> Void = { token in
        tableCallbackRecorder.record(token)
        pane.recordTableApplicationCompleted(token)
    }
    let view: FileTableView
    if session.traceRecorder != nil {
        view = FileTableView(
            items: session.pane.visibleItems,
            selection: .constant([]),
            projectionToken: session.pane.acceptedProjectionToken,
            itemIndexByURL: session.pane.visibleIndexByURL,
            sort: session.pane.sort,
            directory: session.directory,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onProjectionApplicationAttempt: { pane.recordTableApplicationAttempt($0) },
            onProjectionApplied: onProjectionApplied
        )
    } else {
        view = FileTableView(
            items: session.pane.visibleItems,
            selection: .constant([]),
            projectionToken: session.pane.acceptedProjectionToken,
            itemIndexByURL: session.pane.visibleIndexByURL,
            sort: session.pane.sort,
            directory: session.directory,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in },
            onProjectionApplied: onProjectionApplied
        )
    }
    view.updateNSView(session.scroll, coordinator: session.coordinator)
    session.scroll.layoutSubtreeIfNeeded()
}

private struct PaneSearchTraceEvidence {
    let tableAppliedAt: ContinuousClock.Instant
    let stalePublicationCount: Int
}

private struct PaneSearchTableCallbackEvidence {
    let tableAppliedAt: ContinuousClock.Instant
}

@MainActor
private func tableCallbackEvidence(for session: PaneSearchSession) throws -> PaneSearchTableCallbackEvidence {
    guard let expectedToken = session.pane.acceptedProjectionToken else {
        throw PaneSearchProbeError.missingAcceptedProjectionToken
    }
    let events = session.tableCallbackRecorder.events
    guard events.count == 1, events[0].token == expectedToken else {
        throw PaneSearchProbeError.incompleteProductionTableCallback(
            expectedToken: expectedToken,
            callbackCount: events.count
        )
    }
    return .init(tableAppliedAt: events[0].instant)
}

@MainActor
private func traceEvidence(for session: PaneSearchSession) throws -> PaneSearchTraceEvidence {
    guard let traceRecorder = session.traceRecorder else {
        throw PaneSearchProbeError.missingProjectionTraceRecorder
    }
    guard let expectedToken = session.pane.acceptedProjectionToken else {
        throw PaneSearchProbeError.missingAcceptedProjectionToken
    }

    let aggregateEvents = traceRecorder.events.compactMap { recorded -> PaneSearchRecordedProjectionTraceEvent? in
        guard case .aggregateAccepted = recorded.event else { return nil }
        return recorded
    }
    let tableEvents = traceRecorder.events.compactMap { recorded -> PaneSearchRecordedProjectionTraceEvent? in
        guard case .tableApplied = recorded.event else { return nil }
        return recorded
    }
    let acceptedExpectedCount = aggregateEvents.reduce(into: 0) { count, recorded in
        if case .aggregateAccepted(let token, _) = recorded.event, token == expectedToken { count += 1 }
    }
    let expectedTableEvents = tableEvents.filter { recorded in
        guard case .tableApplied(let token) = recorded.event else { return false }
        return token == expectedToken
    }
    guard acceptedExpectedCount == 1, expectedTableEvents.count == 1 else {
        throw PaneSearchProbeError.incompleteProductionTableTrace(
            expectedToken: expectedToken,
            aggregateCount: acceptedExpectedCount,
            tableCount: expectedTableEvents.count
        )
    }

    var latestRequestToken: PaneProjectionToken?
    let stalePublicationCount = traceRecorder.events.reduce(into: 0) { count, recorded in
        switch recorded.event {
        case .requestScheduled(let token, _):
            latestRequestToken = token
        case .tableApplicationAttempted(let token):
            if let latestRequestToken, latestRequestToken.isNewer(than: token) { count += 1 }
        case .setterEntry, .aggregateAccepted, .tableApplied:
            break
        }
    }
    return PaneSearchTraceEvidence(
        tableAppliedAt: expectedTableEvents[0].instant,
        stalePublicationCount: stalePublicationCount
    )
}

@MainActor
private func verifyNoProjectionTableCallback(in session: PaneSearchSession) throws {
    guard session.tableCallbackRecorder.events.isEmpty else {
        throw PaneSearchProbeError.unexpectedNoOpTableCallback
    }
}

@MainActor
private func waitForWorkerDrain(_ session: PaneSearchSession) async throws {
    guard let workerVisitRecorder = session.workerVisitRecorder else {
        throw PaneSearchProbeError.missingWorkerLifecycleRecorder
    }
    for _ in 0..<2_000 {
        if workerVisitRecorder.activeWorkerCount == 0 { return }
        await Task.yield()
    }
    throw PaneSearchProbeError.workerDrainTimedOut
}

private struct PaneSearchMeasuredTransition {
    let sample: PaneSearchTransitionSample
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
    let scroll: NSScrollView
    let window: NSWindow
    let traceRecorder: PaneSearchProjectionTraceRecorder?
    let tableCallbackRecorder: PaneSearchTableCallbackRecorder
    let workerVisitRecorder: PaneProjectionWorkerVisitRecorder?
    var navigationTask: Task<Void, Never>?
    private var didTearDown = false

    init(
        directory: URL,
        items: [FileItem],
        pane: FilePaneState,
        coordinator: FileTableView.Coordinator,
        table: NSTableView,
        scroll: NSScrollView,
        window: NSWindow,
        traceRecorder: PaneSearchProjectionTraceRecorder?,
        tableCallbackRecorder: PaneSearchTableCallbackRecorder,
        workerVisitRecorder: PaneProjectionWorkerVisitRecorder?
    ) {
        self.directory = directory
        self.items = items
        self.pane = pane
        self.coordinator = coordinator
        self.table = table
        self.scroll = scroll
        self.window = window
        self.traceRecorder = traceRecorder
        self.tableCallbackRecorder = tableCallbackRecorder
        self.workerVisitRecorder = workerVisitRecorder
    }

    func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        navigationTask?.cancel()
        navigationTask = nil
        FileTableView.dismantleNSView(scroll, coordinator: coordinator)
        scroll.documentView = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class PaneSearchWeakSessionReference {
    weak var session: PaneSearchSession?
}

@MainActor
private final class PaneSearchCompleteLoadLifecycleRecorder {
    weak var session: PaneSearchSession?
    weak var pane: FilePaneState?
    weak var coordinator: FileTableView.Coordinator?
    weak var window: NSWindow?
    weak var scroll: NSScrollView?
    private var exactTableCallbackWasObserved = false
    private var windowContentWasDetached = false
    private var scrollDocumentWasDetached = false
    let timeoutRecorder = PaneSearchAcceptanceTimeoutRecorder()

    func capture(_ session: PaneSearchSession) {
        self.session = session
        pane = session.pane
        coordinator = session.coordinator
        window = session.window
        scroll = session.scroll
    }

    func recordExactTableCallback() {
        exactTableCallbackWasObserved = true
    }

    func recordTeardown(of session: PaneSearchSession) {
        windowContentWasDetached = session.window.contentView == nil
        scrollDocumentWasDetached = session.scroll.documentView == nil
    }

    var evidence: PaneSearchCompleteLoadLifecycleEvidence {
        PaneSearchCompleteLoadLifecycleEvidence(
            exactTableCallbackWasObserved: exactTableCallbackWasObserved,
            windowContentWasDetached: windowContentWasDetached,
            scrollDocumentWasDetached: scrollDocumentWasDetached,
            sessionWasReleased: session == nil,
            paneWasReleased: pane == nil,
            coordinatorWasReleased: coordinator == nil,
            acceptedObservationCancelledAndDrainedItsTimeout: timeoutRecorder.wasCancelledAndDrained
        )
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
    case missingAcceptedProjectionToken
    case incompleteProductionTableTrace(
        expectedToken: PaneProjectionToken,
        aggregateCount: Int,
        tableCount: Int
    )
    case incompleteProductionTableCallback(expectedToken: PaneProjectionToken, callbackCount: Int)
    case missingProjectionTraceRecorder
    case workerDrainTimedOut
    case unexpectedNoOpTableCallback
    case candidateTraversalDidNotBegin
    case cancellationWasNotRequested
    case cancellationProbeWasVacant
    case missingWorkerLifecycleRecorder

    var errorDescription: String? {
        switch self {
        case .invalidScenario(let scenario): "Invalid pane-search benchmark scenario: \(scenario)"
        case .incorrectProjection: "Accepted pane projection differed from the full filter/sort oracle"
        case .missingReusableSession: "The selected scenario did not receive its reusable pane-search session"
        case .filterQuerySetterDidNotTakeEffect: "The normalized-reuse setter did not update the pane query"
        case .acceptanceTimedOut(let sampleIndex, let boundary):
            "Pane-search sample \(sampleIndex) timed out waiting for \(boundary)"
        case .missingAcceptedProjectionToken:
            "Pane-search sample did not have an accepted projection token"
        case .incompleteProductionTableTrace(let token, let aggregateCount, let tableCount):
            "Pane-search token \(token) had \(aggregateCount) accepted and \(tableCount) table-applied trace events"
        case .incompleteProductionTableCallback(let token, let callbackCount):
            "Pane-search token \(token) had \(callbackCount) production table callbacks"
        case .missingProjectionTraceRecorder:
            "This pane-search session was not configured for stale-publication trace evidence"
        case .workerDrainTimedOut:
            "Pane-search projection workers did not drain before the sample deadline"
        case .unexpectedNoOpTableCallback:
            "A normalized-equivalent query unexpectedly reported a new table projection token"
        case .candidateTraversalDidNotBegin:
            "The deterministic LivePaneItemProjector candidate traversal did not start"
        case .cancellationWasNotRequested:
            "The deterministic LivePaneItemProjector worker was not cancellation-signalled"
        case .cancellationProbeWasVacant:
            "The cancellation probe recorded no post-cancellation candidate visits"
        case .missingWorkerLifecycleRecorder:
            "This pane-search session was not configured for worker lifecycle instrumentation"
        }
    }
}

@MainActor
private func observeVisibleItemsChange(
    in pane: FilePaneState,
    sampleIndex: Int,
    boundary: String,
    recorder: PaneSearchTimingEventRecorder? = nil,
    timeoutRecorder: PaneSearchAcceptanceTimeoutRecorder? = nil,
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
        let timeoutTask = Task { [weak pane] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                timeoutRecorder?.recordDrained()
                return
            } catch {
                timeoutRecorder?.recordDrained()
                return
            }
            guard gate.claimTimeout() else {
                timeoutRecorder?.recordDrained()
                return
            }
            await MainActor.run {
                pane?.projectionAcceptanceHandler = previousHandler
            }
            continuation.resume(throwing: PaneSearchProbeError.acceptanceTimedOut(
                sampleIndex: sampleIndex,
                boundary: boundary
            ))
            timeoutRecorder?.recordDrained()
        }
        gate.register(timeoutTask: timeoutTask, recorder: timeoutRecorder)
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

private final class PaneSearchAcceptanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var timeoutTask: Task<Void, Never>?
    private var timeoutRecorder: PaneSearchAcceptanceTimeoutRecorder?

    func claim() -> Bool {
        claim(cancellingRegisteredTimeout: true)
    }

    func claimTimeout() -> Bool {
        claim(cancellingRegisteredTimeout: false)
    }

    func register(
        timeoutTask: Task<Void, Never>,
        recorder: PaneSearchAcceptanceTimeoutRecorder?
    ) {
        lock.lock()
        if claimed {
            lock.unlock()
            recorder?.recordCancelled()
            timeoutTask.cancel()
            return
        }
        self.timeoutTask = timeoutTask
        timeoutRecorder = recorder
        lock.unlock()
    }

    private func claim(cancellingRegisteredTimeout: Bool) -> Bool {
        lock.lock()
        guard !claimed else {
            lock.unlock()
            return false
        }
        claimed = true
        let registeredTimeoutTask = timeoutTask
        timeoutTask = nil
        let registeredTimeoutRecorder = timeoutRecorder
        timeoutRecorder = nil
        lock.unlock()
        if cancellingRegisteredTimeout, let registeredTimeoutTask {
            registeredTimeoutRecorder?.recordCancelled()
            // A timeout that has already woken can claim itself; cancelling that
            // completed task is harmless and keeps the ownership path uniform.
            registeredTimeoutTask.cancel()
        }
        return true
    }
}

private final class PaneSearchAcceptanceTimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var wasCancelled = false
    private var wasDrained = false

    func recordCancelled() {
        lock.withLock { wasCancelled = true }
    }

    func recordDrained() {
        lock.withLock { wasDrained = true }
    }

    var wasCancelledAndDrained: Bool {
        lock.withLock { wasCancelled && wasDrained }
    }
}

private actor PaneSearchFirstCandidateGate {
    private var didBlock = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pauseAfterFirstCandidateVisit() async {
        guard !didBlock else { return }
        didBlock = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    var hasBlocked: Bool { didBlock }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func waitForFirstCandidateGate(_ gate: PaneSearchFirstCandidateGate) async throws -> Bool {
    for _ in 0..<10_000 {
        if await gate.hasBlocked { return true }
        await Task.yield()
    }
    return await gate.hasBlocked
}

@MainActor
private final class PaneSearchProjectionTraceRecorder: PaneProjectionTraceRecording {
    private(set) var events: [PaneSearchRecordedProjectionTraceEvent] = []

    func record(_ event: PaneProjectionTraceEvent) {
        events.append(.init(event: event, instant: ContinuousClock().now))
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
    }
}

private struct PaneSearchRecordedProjectionTraceEvent {
    let event: PaneProjectionTraceEvent
    let instant: ContinuousClock.Instant
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
