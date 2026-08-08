import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Test func paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries() async throws {
    let sample = try await measurePaneSearchTrace(
        trace: .numeric,
        warmups: 0,
        samples: 1
    )

    #expect(sample.transitions.map(\.expectedCount) == [3_439, 299, 20, 1])
    #expect(sample.transitions.allSatisfy { $0.setterToAcceptanceSeconds >= 0 })
    #expect(sample.transitions.allSatisfy { $0.acceptanceToTableSeconds >= 0 })
    #expect(sample.transitions.allSatisfy { $0.endToEndSeconds >= 0 })
    #expect(sample.transitions.allSatisfy { $0.tableAppliedForAcceptedToken == true })
}

@MainActor
@Test func paneSearchProductionTableIsMountedOffscreenBeforeItsCallbackBoundary() throws {
    let probe = try PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.numeric.rawValue
    )
    #expect(probe.hasMountedProductionTableWindowForTesting())
}

@MainActor
@Test func paneSearchSynchronousPoolTeardownSeversTheMountedSessionBeforePoolExit() throws {
    let probe = try PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.completeLoad.rawValue
    )
    let evidence = probe.synchronousPoolOwnershipEvidenceForTesting()

    #expect(evidence.firstContentViewWasDetached)
    #expect(evidence.firstDocumentViewWasDetached)
    #expect(evidence.secondContentViewWasDetached)
    #expect(evidence.secondDocumentViewWasDetached)
    #expect(evidence.windowCountBefore == evidence.windowCountAfterPoolExit)
}

@MainActor
@Test func paneSearchCompleteLoadLifecycleReleasesTheSessionAfterItsMeasuredBoundary() async throws {
    let probe = try PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.completeLoad.rawValue
    )
    let evidence = try await probe.completeLoadLifecycleEvidenceForTesting()

    #expect(evidence.exactTableCallbackWasObserved)
    #expect(evidence.windowContentWasDetached)
    #expect(evidence.scrollDocumentWasDetached)
    #expect(evidence.sessionWasReleased)
    #expect(evidence.paneWasReleased)
    #expect(evidence.coordinatorWasReleased)
    #expect(evidence.acceptedObservationCancelledAndDrainedItsTimeout)
}

@MainActor
@Test func paneSearchMountedOrdinarySessionReleasesAfterItsExactTableCallback() async throws {
    let probe = try PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.completeLoad.rawValue
    )

    let evidence = try await probe.mountedProductionSessionLifetimeEvidenceForTesting(
        capturesProjectionTrace: false
    )

    #expect(evidence.callbackWasExact)
    #expect(evidence.traceWasExact == nil)
    #expect(evidence.didDeallocate)
}

@MainActor
@Test func paneSearchMountedTraceSessionReleasesAfterItsExactTableCallback() async throws {
    let probe = try PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.completeLoad.rawValue
    )

    let evidence = try await probe.mountedProductionSessionLifetimeEvidenceForTesting(
        capturesProjectionTrace: true
    )

    #expect(evidence.callbackWasExact)
    #expect(evidence.traceWasExact == true)
    #expect(evidence.didDeallocate)
}

@MainActor
@Test func paneSearchInstallsFullProjectionTraceOnlyForRapidStaleEvidence() throws {
    let probe = try PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.numeric.rawValue
    )
    #expect(!probe.hasProjectionTraceForTesting(capturesProjectionTrace: false))
    #expect(probe.hasProjectionTraceForTesting(capturesProjectionTrace: true))
}

@Test func paneSearchFixtureMakesEnglishAndKoreanPrefixTransitionsStrictlyNarrow() {
    let items = paneSearchFixture()
    let englishCounts = ["r", "re", "rep", "report"].map {
        PaneFilenameFilter(query: $0).apply(to: items).count
    }
    let koreanCounts = ["보", "보고", "보고서"].map {
        PaneFilenameFilter(query: $0).apply(to: items).count
    }

    #expect(PaneFilenameFilter(query: "report").apply(to: items).count == 5_000)
    #expect(zip(englishCounts, englishCounts.dropFirst()).allSatisfy { $0 > $1 })
    #expect(zip(koreanCounts, koreanCounts.dropFirst()).allSatisfy { $0 > $1 })
}

@Test func emptyReadyOrderUsesItsAcceptedOrderWithoutVisitingFilterCandidates() async throws {
    let items = paneSearchFixture(count: 256)
    let key = PaneProjectionKey(itemsRevision: 1, normalizedQuery: "", sort: .init())
    let projector = PaneItemProjector()
    let activeOrder = try #require(await projector.buildActiveOrder(
        items: items,
        directoryKey: "/scale",
        key: key
    ))
    let visitProbe = PaneProjectionWorkerVisitProbe()
    visitProbe.markCancellationRequested()

    let projection = try await projector.projectActiveOrder(.init(
        items: items,
        directoryKey: "/scale",
        key: key,
        activeOrder: activeOrder,
        previousSearch: nil,
        workerVisitProbe: visitProbe
    ))

    #expect(projection.items == FileSort().apply(to: PaneFilenameFilter(query: "").apply(to: items)))
    #expect(projection.diagnostics.path == .emptyActiveOrder)
    #expect(visitProbe.cancelledWorkerCandidateVisits == 0)
}

@MainActor
@Test func paneSearchCandidateReportIncludesPerTransitionAndLifecycleStatistics() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.numeric.rawValue,
        collectCandidateEvidence: true
    ).measureSelectedScenario()

    let transitionStatistics = try #require(report.transitionStatistics)
    #expect(transitionStatistics.count == 4)
    #expect(transitionStatistics.allSatisfy { $0.sampleCount == 1 })
    #expect(report.cancelledWorkerCandidateVisitStatistics == nil)
    #expect(report.rawSamples.allSatisfy { $0.matchingActiveOrderWasAccepted == true })
}

@MainActor
@Test func paneSearchRapidBurstProbeBoundsCancelledWorkerVisitsAtOneChunk() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.rapidBurst.rawValue,
        collectCandidateEvidence: true
    ).measureSelectedScenario()

    let cancelledVisits = report.rawSamples.map(\.cancelledWorkerCandidateVisits)
    if ProcessInfo.processInfo.environment["PENGRID_RAPID_BURST_DIAGNOSTICS"] == "1" {
        print("rapid-burst-cancellation-visits=\(cancelledVisits), maximum=\(cancelledVisits.max() ?? 0)")
    }
    #expect(
        cancelledVisits.allSatisfy { $0 <= PaneFilenameFilter.cancellationCheckStride },
        "rapid burst cancellation visits=\(cancelledVisits), maximum=\(cancelledVisits.max() ?? 0), stride=\(PaneFilenameFilter.cancellationCheckStride)"
    )
    #expect(report.cancelledWorkerCandidateVisitStatistics != nil)
    #expect(report.rawSamples.allSatisfy { $0.stalePublicationCount == 0 })
    #expect(report.rawSamples.allSatisfy { $0.tableAppliedForAcceptedToken == true })
}

@MainActor
@Test func paneSearchOrdinaryReportOmitsCandidateOnlyEvidence() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.numeric.rawValue
    ).measureSelectedScenario()

    #expect(report.transitionStatistics == nil)
    #expect(report.cancelledWorkerCandidateVisitStatistics == nil)
    #expect(report.rawSamples.allSatisfy {
        $0.matchingActiveOrderWasAccepted == nil
            && $0.matchesFullOracle == nil
            && $0.stalePublicationCount == nil
            && $0.tableAppliedForAcceptedToken == nil
    })
}

@MainActor
@Test func paneSearchOrdinaryRapidBurstPreservesItsSchemaV1QueryCount() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.rapidBurst.rawValue
    ).measureSelectedScenario()

    #expect(report.rapidBurstQueryCount == 20)
    #expect(report.transitionStatistics == nil)
    #expect(report.cancelledWorkerCandidateVisitStatistics == nil)
    #expect(report.rawSamples.allSatisfy {
        $0.stalePublicationCount == nil && $0.tableAppliedForAcceptedToken == nil
    })
}

@MainActor
@Test func paneSearchLiveProjectorCancellationProofIsNonVacuousAndDrains() async throws {
    let evidence = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: PaneSearchTrace.rapidBurst.rawValue,
        collectCandidateEvidence: true
    ).measureDeterministicLiveProjectorCancellationForTesting()

    #expect(evidence.cancellationWasRequested)
    #expect(evidence.cancelledWorkerCandidateVisits > 0)
    #expect(evidence.cancelledWorkerCandidateVisits <= PaneFilenameFilter.cancellationCheckStride)
    #expect(evidence.activeWorkerCountAfterDrain == 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_BENCHMARK"] == "1"))
func paneSearchReleaseBenchmark() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 3,
        sampleCount: 30,
        scenario: try #require(ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_SCENARIO"]),
        collectCandidateEvidence: ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_CANDIDATE"] == "1"
    ).measureSelectedScenario()
    try report.writeJSON(to: try #require(
        ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_REPORT"]
    ))
}

@MainActor
@Test func paneSearchTimingOrderCompleteLoad() async throws {
    try await assertExactTimingOrder(for: "completeLoad")
}

@MainActor
@Test func paneSearchTimingOrderRapidBurst() async throws {
    try await assertExactTimingOrder(for: "rapidBurst")
}

@MainActor
@Test func paneSearchTimingOrderSort() async throws {
    try await assertExactTimingOrder(for: "sort:name:ascending:10000")
}

@MainActor
@Test func paneSearchMeasuredTableTimingsEndAtProductionTableReturn() async throws {
    let configurations = [
        (scenario: "completeLoad", collectCandidateEvidence: false),
        (scenario: "numeric", collectCandidateEvidence: false),
        (scenario: "rapidBurst", collectCandidateEvidence: false),
        (scenario: "rapidBurst", collectCandidateEvidence: true),
        (scenario: "sort:name:ascending:10000", collectCandidateEvidence: false)
    ]

    for configuration in configurations {
        let recorder = PaneSearchTimingEventRecorder()
        let report = try await PaneSearchPerformanceProbe(
            warmupCount: 0,
            sampleCount: 1,
            scenario: configuration.scenario,
            timingRecorder: recorder,
            collectCandidateEvidence: configuration.collectCandidateEvidence
        ).measureSelectedScenario()
        let tableBegins = recorder.timedEvents.filter { $0.name == "table-begin" }
        let tableReturns = recorder.timedEvents.filter { $0.name == "table-finish" }

        #expect(tableBegins.count == report.rawSamples.count)
        #expect(tableReturns.count == report.rawSamples.count)
        #expect(zip(report.rawSamples, zip(tableBegins, tableReturns)).allSatisfy { sample, boundary in
            sample.acceptanceToTableSeconds == boundary.0.elapsedSeconds(to: boundary.1)
        })
    }
}

@MainActor
@Test func paneSearchProductEndToEndIsExactlyItsAcceptanceAndTableIntervals() async throws {
    let configurations = [
        "completeLoad",
        "numeric",
        "rapidBurst",
        "sort:name:ascending:10000"
    ]

    for scenario in configurations {
        let report = try await PaneSearchPerformanceProbe(
            warmupCount: 0,
            sampleCount: 1,
            scenario: scenario,
            collectCandidateEvidence: scenario == "rapidBurst"
        ).measureSelectedScenario()
        #expect(report.rawSamples.allSatisfy { sample in
            abs(sample.endToEndSeconds - (sample.setterToAcceptanceSeconds + sample.acceptanceToTableSeconds)) < 0.000_001
        }, "scenario=\(scenario)")
    }

    let normalizedReuse = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: "replacement",
        collectCandidateEvidence: true
    ).measureNormalizedEquivalentReuseForTesting()
    #expect(abs(
        normalizedReuse.endToEndSeconds
            - (normalizedReuse.setterToAcceptanceSeconds + normalizedReuse.acceptanceToTableSeconds)
    ) < 0.000_001)
}

@MainActor
@Test func paneSearchQueryTraceDurationsEqualTheSumOfTheirProductTransitions() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: "numeric"
    ).measureSelectedScenario()
    let transitionTotal = report.rawSamples.reduce(0) { $0 + $1.endToEndSeconds }

    #expect(report.traceEndToEndSeconds.count == 1)
    #expect(abs(report.traceEndToEndSeconds[0] - transitionTotal) < 0.000_001)
}

@MainActor
@Test func paneSearchTimingOrderWhitespaceReuse() async throws {
    let recorder = PaneSearchTimingEventRecorder()
    let sample = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: "replacement",
        timingRecorder: recorder,
        collectCandidateEvidence: true
    ).measureNormalizedEquivalentReuseForTesting()
    #expect(sample.tableAppliedForAcceptedToken == false)
    #expect(recorder.events == [
        "reuse-start",
        "reuse-operation",
        "reuse-setter-effect",
        "reuse-accepted",
        "reuse-table-begin",
        "reuse-table-finish"
    ])
}

@MainActor
private func assertExactTimingOrder(for scenario: String) async throws {
    let recorder = PaneSearchTimingEventRecorder()
    _ = try await PaneSearchPerformanceProbe(
        warmupCount: 0,
        sampleCount: 1,
        scenario: scenario,
        timingRecorder: recorder
    ).measureSelectedScenario()
    #expect(recorder.events == [
        "armed",
        "start",
        "operation",
        "accepted",
        "table-begin",
        "table-finish"
    ])
    #expect(recorder.armedMechanismsInstalled == [true])
}
