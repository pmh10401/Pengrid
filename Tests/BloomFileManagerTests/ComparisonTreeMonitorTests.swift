import CoreServices
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct ComparisonTreeMonitorTests {
    @Test func eventsAreRootRelativeAndCoalesced() async throws {
        let event = try await withLiveMonitor(latency: 0.2) { fixture, stream in
            try await Task.sleep(for: .milliseconds(50))
            for name in ["a.txt", "b.txt", "c.txt"] {
                try Data(name.utf8).write(to: fixture.left.appending(path: name))
            }
            return try await firstEvent(in: stream) {
                $0.side == .left && $0.relativePaths.count >= 3
            }
        }

        #expect(event.side == .left)
        #expect(event.relativePaths == Set(try ["a.txt", "b.txt", "c.txt"].map {
            try ComparisonRelativePath(components: [$0])
        }))
    }

    @Test func longestCanonicalRootOwnsNestedEvents() async throws {
        let event = try await withLiveMonitor(
            nestedRightRoot: true,
            latency: 0.1
        ) { fixture, stream in
            try await Task.sleep(for: .milliseconds(50))
            try Data("nested".utf8).write(to: fixture.right.appending(path: "nested.txt"))
            return try await firstEvent(in: stream) {
                $0.relativePaths.contains(try! ComparisonRelativePath(components: ["nested.txt"]))
            }
        }

        #expect(event.side == .right)
        #expect(event.relativePaths == [try ComparisonRelativePath(components: ["nested.txt"])])
    }

    @Test func removingAWatchRootProducesRootChangedForThatSide() async throws {
        let event = try await withLiveMonitor(latency: 0.1) { fixture, stream in
            try await Task.sleep(for: .milliseconds(50))
            try FileManager.default.removeItem(at: fixture.right)
            return try await firstEvent(in: stream) {
                $0.side == .right && $0.rootChanged
            }
        }

        #expect(event.rootChanged)
        #expect(event.relativePaths.isEmpty)
    }

    @Test func cancellingIterationStopsAndReleasesTheStreamOwner() async throws {
        try await withLiveMonitor(latency: 0.1) { _, stream in
            await consumeUntilCancelled(stream)
        }
    }

    @Test func manualAccessIsRetainedUntilComparisonStreamCancellation() async throws {
        let fixture = try ComparisonMonitorFixture()
        defer { fixture.remove() }
        let stopped = OwnerStopSignal()
        let driver = ComparisonMonitorSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([fixture.left, fixture.right])
        let monitor = LiveComparisonTreeMonitor(
            latency: 0.1,
            onOwnerStopped: { stopped.signal() },
            accessCoordinator: accessCoordinator
        )
        let stream: AsyncStream<ComparisonTreeEvent>
        switch await monitor.start(roots: [.left: fixture.left, .right: fixture.right]) {
        case let .started(startedStream):
            stream = startedStream
        case .failed:
            throw MonitorTestError.startupFailed
        }

        #expect(driver.startedURLs == [fixture.left, fixture.right])
        #expect(driver.stoppedURLs.isEmpty)

        let reader = Task { for await _ in stream {} }
        reader.cancel()
        reader.cancel()
        await reader.value
        await stopped.wait()
        try await Task.sleep(for: .milliseconds(30))

        #expect(driver.stoppedURLs == [fixture.left, fixture.right])
    }

    @Test func droppingComparisonStreamNormallyReleasesEachManualLeaseOnce() async throws {
        let fixture = try ComparisonMonitorFixture()
        defer { fixture.remove() }
        let stopped = OwnerStopSignal()
        let driver = ComparisonMonitorSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([fixture.left, fixture.right])
        let monitor = LiveComparisonTreeMonitor(
            latency: 0.1,
            onOwnerStopped: { stopped.signal() },
            accessCoordinator: accessCoordinator
        )
        var stream: AsyncStream<ComparisonTreeEvent>?
        switch await monitor.start(roots: [.left: fixture.left, .right: fixture.right]) {
        case let .started(startedStream):
            stream = startedStream
        case .failed:
            throw MonitorTestError.startupFailed
        }

        #expect(stream != nil)
        #expect(driver.stoppedURLs.isEmpty)

        stream = nil
        await stopped.wait()
        try await Task.sleep(for: .milliseconds(30))

        #expect(driver.stoppedURLs == [fixture.left, fixture.right])
    }

    @Test func scopedAccessStartupFailureReleasesAnEarlierComparisonLease() async throws {
        let fixture = try ComparisonMonitorFixture()
        defer { fixture.remove() }
        let driver = ComparisonMonitorSecurityScopeDriver(deniedURL: fixture.right)
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        accessCoordinator.replaceManualRoots([fixture.left, fixture.right])
        let monitor = LiveComparisonTreeMonitor(accessCoordinator: accessCoordinator)

        let result = await monitor.start(roots: [.left: fixture.left, .right: fixture.right])

        guard case .failed = result else {
            Issue.record("Expected scoped-access denial to fail monitor startup")
            return
        }
        #expect(driver.startedURLs == [fixture.left, fixture.right])
        #expect(driver.stoppedURLs == [fixture.left])
    }

    @Test func discoveredComparisonRootsDoNotRequestScopedAccess() async throws {
        let fixture = try ComparisonMonitorFixture()
        defer { fixture.remove() }
        let stopped = OwnerStopSignal()
        let driver = ComparisonMonitorSecurityScopeDriver()
        let monitor = LiveComparisonTreeMonitor(
            latency: 0.1,
            onOwnerStopped: { stopped.signal() },
            accessCoordinator: CloudLocationScopedAccessCoordinator(driver: driver)
        )
        let stream: AsyncStream<ComparisonTreeEvent>
        switch await monitor.start(roots: [.left: fixture.left, .right: fixture.right]) {
        case let .started(startedStream):
            stream = startedStream
        case .failed:
            throw MonitorTestError.startupFailed
        }

        await consumeUntilCancelled(stream)
        await stopped.wait()

        #expect(driver.startedURLs.isEmpty)
        #expect(driver.stoppedURLs.isEmpty)
    }

    @Test(arguments: [
        FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
        FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
        FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
        FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
    ])
    func lossFlagsRequireAFullScanOfTheMappedRoot(
        flag: FSEventStreamEventFlags
    ) throws {
        let mapper = ComparisonTreeEventMapper(roots: [
            .left: URL(filePath: "/left", directoryHint: .isDirectory),
            .right: URL(filePath: "/right", directoryHint: .isDirectory)
        ])

        let events = mapper.events(
            paths: ["/left"],
            flags: [flag],
            eventIDs: [42]
        )

        let event = try #require(events.first)
        #expect(event.side == .left)
        #expect(event.requiresFullScan)
        #expect(event.relativePaths.isEmpty)
        #expect(!event.rootChanged)
    }

    @Test func unattributedLossRequiresAFullScanOfBothRoots() throws {
        let mapper = ComparisonTreeEventMapper(roots: [
            .left: URL(filePath: "/left", directoryHint: .isDirectory),
            .right: URL(filePath: "/right", directoryHint: .isDirectory)
        ])

        let events = mapper.events(
            paths: ["/outside"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)],
            eventIDs: [43]
        )

        #expect(Set(events.map(\.side)) == Set<ComparisonSide>([.left, .right]))
        #expect(events.allSatisfy { $0.requiresFullScan })
    }

    @Test func globalLossAtFilesystemRootRequiresAFullScanOfEveryWatchedRoot() {
        let mapper = ComparisonTreeEventMapper(roots: [
            .left: URL(filePath: "/", directoryHint: .isDirectory),
            .right: URL(filePath: "/Volumes/Nested", directoryHint: .isDirectory)
        ])

        let events = mapper.events(
            paths: ["/"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)],
            eventIDs: [44]
        )

        #expect(Set(events.map(\.side)) == Set<ComparisonSide>([.left, .right]))
        #expect(events.allSatisfy { $0.requiresFullScan && $0.relativePaths.isEmpty })
    }

    @Test func nonIncreasingEventIDRequiresAFullScanOfTheMappedRoot() throws {
        let mapper = ComparisonTreeEventMapper(roots: [
            .left: URL(filePath: "/left", directoryHint: .isDirectory),
            .right: URL(filePath: "/right", directoryHint: .isDirectory)
        ])
        _ = mapper.events(
            paths: ["/left/first.txt"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)],
            eventIDs: [50]
        )

        let events = mapper.events(
            paths: ["/left/second.txt"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)],
            eventIDs: [50]
        )

        let event = try #require(events.first)
        #expect(event.side == .left)
        #expect(event.requiresFullScan)
        #expect(event.relativePaths.isEmpty)
    }

    @Test func filesystemRootAndNestedRootUseLongestComponentMatch() throws {
        let mapper = ComparisonTreeEventMapper(roots: [
            .left: URL(filePath: "/", directoryHint: .isDirectory),
            .right: URL(filePath: "/Volumes/Nested", directoryHint: .isDirectory)
        ])

        let events = mapper.events(
            paths: ["/private/example.txt", "/Volumes/Nested/child.txt"],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            ],
            eventIDs: [1, 2]
        )

        let left = try #require(events.first { $0.side == .left })
        let right = try #require(events.first { $0.side == .right })
        #expect(left.relativePaths == [
            try ComparisonRelativePath(components: ["private", "example.txt"])
        ])
        #expect(right.relativePaths == [
            try ComparisonRelativePath(components: ["child.txt"])
        ])
    }

    @Test func slowConsumerReceivesMoreThanSixteenCoalescedBatches() async throws {
        let channel = ComparisonTreeEventChannel.make()
        let paths = try (0 ..< 32).map {
            try ComparisonRelativePath(components: ["batch-\($0).txt"])
        }
        for path in paths {
            channel.continuation.yield(.init(
                side: .left,
                relativePaths: [path],
                rootChanged: false
            ))
        }
        channel.continuation.finish()

        var received: Set<ComparisonRelativePath> = []
        for await event in channel.stream {
            try await Task.sleep(for: .milliseconds(1))
            received.formUnion(event.relativePaths)
        }

        #expect(received == Set(paths))
    }
}

@MainActor
@Suite struct ComparisonTreeCoordinatorTests {
    @Test func recursiveChildChangeRelistsOnlyItsParentSubtree() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.options.includeSubfolders = true
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let initialRequestCount = await fixture.listing.requestCount

        fixture.monitor.send(.left, paths: [try .init(components: ["A", "file.txt"])])

        #expect(await waitFor {
            await fixture.listing.requestCount == initialRequestCount + 1
        })
        let request = try #require(await fixture.listing.lastRequest)
        #expect(request.root == fixture.left)
        #expect(request.subtree?.string == "A")
    }

    @Test func rapidRecursiveChangesCoalesceOverlappingParentSubtrees() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.options.includeSubfolders = true
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let initialRequestCount = await fixture.listing.requestCount

        fixture.monitor.send(.left, paths: [try .init(components: ["A", "file.txt"])])
        fixture.monitor.send(.left, paths: [try .init(components: ["A", "B", "nested.txt"])])

        #expect(await waitFor {
            await fixture.listing.requestCount == initialRequestCount + 1
        })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await fixture.listing.requestCount == initialRequestCount + 1)
        #expect(await fixture.listing.lastRequest?.subtree?.string == "A")
    }

    @Test func nonRecursiveChangeRefreshesTheChangedSideAtRoot() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let initialRequestCount = await fixture.listing.requestCount

        fixture.monitor.send(.right, paths: [try .init(components: ["child.txt"])])

        #expect(await waitFor {
            await fixture.listing.requestCount == initialRequestCount + 1
        })
        let request = try #require(await fixture.listing.lastRequest)
        #expect(request.root == fixture.right)
        #expect(request.subtree == nil)
        #expect(!request.options.includeSubfolders)
    }

    @Test func lossRecoveryRelistsTheEntireMappedSideEvenWithoutPaths() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.options.includeSubfolders = true
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let initialRequestCount = await fixture.listing.requestCount

        fixture.monitor.send(
            .left,
            paths: [],
            requiresFullScan: true
        )

        #expect(await waitFor {
            await fixture.listing.requestCount == initialRequestCount + 1
        })
        let request = try #require(await fixture.listing.lastRequest)
        #expect(request.root == fixture.left)
        #expect(request.subtree == nil)
        #expect(request.options.includeSubfolders)
    }

    @Test func failedInitialMonitorStartDisconnectsBeforeBecomingUnwatched() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let previousRows = fixture.coordinator.rows
        let previousRequestCount = await fixture.listing.requestCount
        fixture.monitor.failNextStart()

        fixture.coordinator.start(workspace: fixture.workspace)

        #expect(await waitFor(timeout: .seconds(1)) {
            fixture.coordinator.phase == .disconnected
        })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.coordinator.phase == .disconnected)
        #expect(fixture.coordinator.rows == previousRows)
        #expect(await fixture.listing.requestCount == previousRequestCount)
        #expect(!fixture.coordinator.actionsAreEnabled)
        #expect(fixture.monitor.activeStreamCount == 0)
    }

    @Test func initialListingWaitsForProducerStartupOutcome() async throws {
        let roots = try ComparisonMonitorFixture()
        let left = try monitorEntry("kept.txt", root: roots.left, identity: "kept")
        let listing = ImmediateIdentityListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            records: [roots.left: [.entry(left)], roots.right: []]
        )
        let monitor = ControlledProducerStartupMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.failStart()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true

        coordinator.start(workspace: workspace)

        #expect(await waitFor { monitor.startRequestCount == 1 })
        let listedBeforeStartupOutcome = await waitFor(timeout: .milliseconds(100)) {
            listing.requestCount > 0
        }
        #expect(!listedBeforeStartupOutcome)

        monitor.failStart()

        #expect(await waitFor(timeout: .seconds(1)) {
            coordinator.phase == .disconnected
        })
        #expect(listing.requestCount == 0)
        #expect(!coordinator.actionsAreEnabled)
    }

    @Test func currentMonitorCompletionDisconnectsAndRejectsLateListingAndChecksum() async throws {
        let roots = try ComparisonMonitorFixture()
        for root in [roots.left, roots.right] {
            let folder = root.appending(path: "A", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("same".utf8).write(to: folder.appending(path: "kept.txt"))
        }
        let stableDate = Date(timeIntervalSince1970: 1)
        for root in [roots.left, roots.right] {
            try FileManager.default.setAttributes(
                [.modificationDate: stableDate],
                ofItemAtPath: root.appending(path: "A/kept.txt").path
            )
        }
        let listing = ControlledTreeReconciliationListingService()
        let checksums = ValidationFreezeChecksumService()
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: checksums,
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        let previousRows = coordinator.rows
        let path = try ComparisonRelativePath(components: ["A", "kept.txt"])

        monitor.send(.left, paths: [path])
        #expect(await waitFor { await listing.targetedRequestCount == 1 })
        coordinator.verifyAll()
        #expect(await waitFor { await checksums.requestCount == 2 })

        monitor.finish()

        #expect(await waitFor(timeout: .seconds(1)) { coordinator.phase == .disconnected })
        #expect(coordinator.rows == previousRows)
        #expect(!coordinator.actionsAreEnabled)
        await listing.releaseTargeted(
            request: 0,
            record: .entry(try monitorEntry(
                "A/kept.txt", root: roots.left, identity: "late-listing"
            ))
        )
        await checksums.releaseAll()
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.rows == previousRows)
        #expect(!coordinator.actionsAreEnabled)
    }

    @Test func failedReplacementMonitorStartInvalidatesValidation() async throws {
        let roots = try ComparisonMonitorFixture()
        let left = try monitorEntry("kept.txt", root: roots.left, identity: "kept")
        let listing = FinalGateIdentityListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            records: [roots.left: [.entry(left)], roots.right: []]
        )
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        let previousRows = coordinator.rows
        let oldGeneration = try #require(coordinator.session?.generation)
        monitor.failNextStart()

        monitor.sendRootChanged(.left)

        #expect(await waitFor(timeout: .seconds(1)) {
            coordinator.phase == .disconnected
        })
        if await listing.finalGateIsStalled {
            await listing.releaseFinalGate(leftIdentity: "left-old")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.rows == previousRows)
        #expect(coordinator.session?.generation == oldGeneration)
        #expect(await listing.requestCount == 2)
        #expect(!coordinator.actionsAreEnabled)
    }

    @Test func replacementStartFailureIsObservedBeforeFastFinalCapture() async throws {
        let roots = try ComparisonMonitorFixture()
        let left = try monitorEntry("kept.txt", root: roots.left, identity: "kept")
        let listing = ImmediateIdentityListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            records: [roots.left: [.entry(left)], roots.right: []]
        )
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        let previousRows = coordinator.rows
        let oldGeneration = try #require(coordinator.session?.generation)
        #expect(listing.requestCount == 2)
        monitor.failNextStart()

        monitor.sendRootChanged(.left)

        #expect(await waitFor(timeout: .seconds(1)) {
            coordinator.phase == .disconnected
        })
        #expect(coordinator.rows == previousRows)
        #expect(coordinator.session?.generation == oldGeneration)
        #expect(listing.requestCount == 2)
        #expect(!coordinator.actionsAreEnabled)
    }

    @Test func staleMonitorCompletionFromIntentionalRestartDoesNotDisconnectNewSession() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let oldGeneration = try #require(fixture.coordinator.session?.generation)

        fixture.coordinator.start(workspace: fixture.workspace)

        #expect(await waitFor {
            fixture.coordinator.phase == .upToDate
                && fixture.coordinator.session?.generation != oldGeneration
                && fixture.monitor.activeStreamCount == 1
        })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.coordinator.phase == .upToDate)
        #expect(fixture.coordinator.actionsAreEnabled)
    }

    @Test func lateStartupSuccessFromIntentionalRestartDoesNotOutliveNewSession() async throws {
        let roots = try ComparisonMonitorFixture()
        let left = try monitorEntry("kept.txt", root: roots.left, identity: "kept")
        let listing = ImmediateIdentityListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            records: [roots.left: [.entry(left)], roots.right: []]
        )
        let monitor = ControlledProducerStartupMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }

        coordinator.start(workspace: workspace)
        #expect(await waitFor { monitor.startRequestCount == 1 })

        coordinator.start(workspace: workspace)
        #expect(await waitFor { monitor.startRequestCount == 2 })

        monitor.succeedStart()
        monitor.succeedStart()

        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount >= 1
        })
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.activeStreamCount == 1)
        #expect(coordinator.actionsAreEnabled)
    }

    @Test func disconnectedRootKeepsRowsAndDisablesEveryAction() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.options.includeSubfolders = true
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let previousRows = fixture.coordinator.rows
        fixture.coordinator.selection = Set(previousRows.map(\.id))

        try FileManager.default.removeItem(at: fixture.right)
        fixture.monitor.sendRootChanged(.right)

        #expect(await waitFor { fixture.coordinator.phase == .disconnected })
        #expect(fixture.coordinator.rows == previousRows)
        #expect(!fixture.coordinator.actionsAreEnabled)
        #expect(!fixture.coordinator.canVerifySelected)
    }

    @Test func samePathReplacementDoesNotAttachToTheOldGeneration() async throws {
        let fixture = try await LiveCoordinatorFixture.make()
        defer { fixture.stopAndRemove() }
        fixture.coordinator.options.includeSubfolders = true
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let oldSession = try #require(fixture.coordinator.session)

        try FileManager.default.removeItem(at: fixture.right)
        try FileManager.default.createDirectory(at: fixture.right, withIntermediateDirectories: false)
        fixture.monitor.sendRootChanged(.right)

        #expect(await waitFor { fixture.coordinator.phase == .disconnected })
        #expect(fixture.coordinator.session?.generation == oldSession.generation)
        #expect(fixture.coordinator.session?.rightRootIdentity == oldSession.rightRootIdentity)

        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitUntilReady()
        let newSession = try #require(fixture.coordinator.session)
        #expect(newSession.generation != oldSession.generation)
        #expect(newSession.rightRootIdentity != oldSession.rightRootIdentity)
    }

    @Test func newerEventRejectsAnOlderInFlightReconciliationResult() async throws {
        let roots = try ComparisonMonitorFixture()
        let folder = roots.left.appending(path: "A", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: folder.appending(path: "file.txt"))
        let listing = ControlledTreeReconciliationListingService()
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        let originalIdentity = try #require(
            coordinator.rows.first { $0.id.string == "A/file.txt" }
        ).left?.fingerprint.identity

        let changedPath = try ComparisonRelativePath(components: ["A", "file.txt"])
        monitor.send(.left, paths: [changedPath])
        #expect(await waitFor { await listing.targetedRequestCount == 1 })
        monitor.send(.left, paths: [changedPath])
        await listing.releaseTargeted(
            request: 0,
            record: try .entry(monitorEntry(
                "A/file.txt", root: roots.left, identity: "stale-reconciliation"
            ))
        )

        try await Task.sleep(for: .milliseconds(100))
        #expect(
            coordinator.rows.first { $0.id.string == "A/file.txt" }?.left?.fingerprint.identity
                == originalIdentity
        )
        #expect(await waitFor { await listing.targetedRequestCount == 2 })
        await listing.releaseTargeted(
            request: 1,
            record: try .entry(monitorEntry(
                "A/file.txt", root: roots.left, identity: "fresh-reconciliation"
            ))
        )
        #expect(await waitFor {
            coordinator.rows.first { $0.id.string == "A/file.txt" }?
                .left?.fingerprint.identity.entryIdentifier == "fresh-reconciliation"
        })
    }

    @Test func cancelledHashFromInvalidatedPathCannotPublishAnError() async throws {
        let roots = try ComparisonMonitorFixture()
        let leftFile = roots.left.appending(path: "ambiguous.txt")
        let rightFile = roots.right.appending(path: "ambiguous.txt")
        try Data("left".utf8).write(to: leftFile)
        try Data("rght".utf8).write(to: rightFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: leftFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: rightFile.path
        )
        let monitor = InMemoryComparisonTreeMonitor()
        let checksums = CancellationObservingChecksumService()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: LiveComparisonListingService(),
            checksums: checksums,
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            let requestCount = await checksums.requestCount
            return coordinator.phase == .verifying && requestCount == 2
        })

        monitor.send(.left, paths: [try .init(components: ["ambiguous.txt"])])

        #expect(await waitFor { await checksums.cancellationCount == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            coordinator.rows.first?.status != .error("Cancelled")
        )
    }

    @Test func replacementBetweenRootRecheckAndRecaptureDisconnectsWithoutRelisting() async throws {
        let roots = try ComparisonMonitorFixture()
        let leftEntry = try monitorEntry("kept.txt", root: roots.left, identity: "kept")
        let listing = TwoStageIdentityListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            leftIdentities: ["left-old", "left-old", "left-replacement"],
            rightIdentities: ["right-old", "right-old"],
            records: [roots.left: [.entry(leftEntry)], roots.right: []]
        )
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        let oldGeneration = try #require(coordinator.session?.generation)
        let previousRows = coordinator.rows
        #expect(await listing.requestCount == 2)

        monitor.sendRootChanged(.left)

        #expect(await waitFor(timeout: .seconds(1)) {
            let requestCount = await listing.requestCount
            return coordinator.phase == .disconnected || requestCount > 2
        })
        try #require(coordinator.phase == .disconnected)
        #expect(coordinator.rows == previousRows)
        #expect(coordinator.session?.generation == oldGeneration)
        #expect(await listing.requestCount == 2)

        coordinator.start(workspace: workspace)
        #expect(await waitFor { coordinator.phase == .upToDate })
        #expect(coordinator.session?.generation != oldGeneration)
        #expect(coordinator.session?.leftRootIdentity.entryIdentifier == "left-replacement")
        #expect(await listing.requestCount == 4)
    }

    @Test func rootChangeImmediatelyFreezesEveryOldPublisherWhileIdentityStalls() async throws {
        let roots = try ComparisonMonitorFixture()
        let left = try monitorEntry("A/kept.txt", root: roots.left, identity: "left-old")
        let right = try monitorEntry("A/kept.txt", root: roots.right, identity: "right-old")
        let listing = ValidationFreezeListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            records: [roots.left: [.entry(left)], roots.right: [.entry(right)]]
        )
        let checksums = ValidationFreezeChecksumService()
        let projections = ValidationFreezeProjectionBuilder()
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: checksums,
            projections: projections,
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        await projections.armStalling()
        let previousRows = coordinator.rows
        let path = try ComparisonRelativePath(components: ["A", "kept.txt"])

        monitor.send(.left, paths: [path])
        #expect(await waitFor { await listing.targetedRequestCount == 1 })
        await listing.releaseTargeted(
            request: 0,
            record: .entry(try monitorEntry(
                "A/kept.txt", root: roots.left, identity: "projection-replacement"
            ))
        )
        #expect(await waitFor { await projections.stalledRequestCount == 1 })

        coordinator.verifyAll()
        #expect(await waitFor { await checksums.requestCount == 2 })
        monitor.send(.left, paths: [path])
        #expect(await waitFor { await listing.targetedRequestCount == 2 })

        monitor.sendRootChanged(.left)
        #expect(await waitFor { await listing.validationCheckIsStalled })
        #expect(coordinator.phase == .paused)
        #expect(!coordinator.actionsAreEnabled)

        await listing.releaseTargeted(
            request: 1,
            record: .entry(try monitorEntry(
                "A/kept.txt", root: roots.left, identity: "reconciliation-replacement"
            ))
        )
        let maliciousLeft = try monitorEntry(
            "A/kept.txt", root: roots.left, identity: "projection-published"
        )
        await projections.releaseStalled(
            request: 0,
            rows: [.init(
                relativePath: path,
                left: maliciousLeft,
                right: right,
                status: .metadataChanged
            )]
        )
        await checksums.releaseAll()
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.rows == previousRows)
        #expect(coordinator.phase == .paused)
        #expect(!coordinator.actionsAreEnabled)

        await listing.failValidationCheck()
        #expect(await waitFor { coordinator.phase == .disconnected })
    }

    @Test func replacementAtFinalIdentityGateDisconnectsWithoutResetOrRelist() async throws {
        let roots = try ComparisonMonitorFixture()
        let left = try monitorEntry("kept.txt", root: roots.left, identity: "kept")
        let listing = FinalGateIdentityListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            records: [roots.left: [.entry(left)], roots.right: []]
        )
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        let previousRows = coordinator.rows
        let oldGeneration = try #require(coordinator.session?.generation)

        monitor.sendRootChanged(.left)

        #expect(await waitFor {
            let finalGateIsStalled = await listing.finalGateIsStalled
            let requestCount = await listing.requestCount
            return finalGateIsStalled || requestCount > 2
        })
        let reachedFinalGate = await listing.finalGateIsStalled
        #expect(reachedFinalGate)
        if reachedFinalGate {
            #expect(monitor.activeStreamCount == 1)
            await listing.releaseFinalGate(leftIdentity: "left-replacement")
        }
        #expect(await waitFor { coordinator.phase == .disconnected })
        #expect(coordinator.rows == previousRows)
        #expect(coordinator.session?.generation == oldGeneration)
        #expect(await listing.requestCount == 2)
    }

    @Test func monitorEventDuringFinalIdentityGateInvalidatesStaleValidation() async throws {
        let roots = try ComparisonMonitorFixture()
        let left = try monitorEntry("kept.txt", root: roots.left, identity: "kept")
        let listing = FinalGateIdentityListingService(
            leftRoot: roots.left,
            rightRoot: roots.right,
            records: [roots.left: [.entry(left)], roots.right: []]
        )
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        defer {
            coordinator.stop()
            monitor.finish()
            roots.remove()
        }
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await waitFor {
            coordinator.phase == .upToDate && monitor.activeStreamCount == 1
        })
        let previousRows = coordinator.rows

        monitor.sendRootChanged(.left)
        #expect(await waitFor { await listing.finalGateIsStalled })
        #expect(monitor.activeStreamCount == 1)

        monitor.send(
            .left,
            paths: [try ComparisonRelativePath(components: ["changed-during-validation.txt"])]
        )
        #expect(await waitFor { coordinator.phase == .disconnected })
        await listing.releaseFinalGate(leftIdentity: "left-old")
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.phase == .disconnected)
        #expect(coordinator.rows == previousRows)
        #expect(await listing.requestCount == 2)
    }
}

private final class ComparisonMonitorFixture: @unchecked Sendable {
    let base: URL
    let left: URL
    let right: URL

    init(nestedRightRoot: Bool = false) throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "bloom-tree-monitor-\(UUID().uuidString)", directoryHint: .isDirectory)
        left = base.appending(path: "left", directoryHint: .isDirectory)
        right = nestedRightRoot
            ? left.appending(path: "nested-root", directoryHint: .isDirectory)
            : base.appending(path: "right", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class ComparisonMonitorSecurityScopeDriver:
    SecurityScopedResourceAccessing,
    @unchecked Sendable {
    private let lock = NSLock()
    private let deniedPath: String?
    private var starts: [URL] = []
    private var stops: [URL] = []

    init(deniedURL: URL? = nil) {
        deniedPath = deniedURL?.standardizedFileURL.path
    }

    var startedURLs: [URL] {
        lock.withLock { starts }
    }

    var stoppedURLs: [URL] {
        lock.withLock { stops }
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts.append(url) }
        return url.standardizedFileURL.path != deniedPath
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops.append(url) }
    }
}

@MainActor
private final class LiveCoordinatorFixture {
    let roots: ComparisonMonitorFixture
    let listing: RecordingLiveComparisonListingService
    let monitor: InMemoryComparisonTreeMonitor
    let workspace: WorkspaceState
    let coordinator: ComparisonCoordinator

    var left: URL { roots.left }
    var right: URL { roots.right }

    private init(
        roots: ComparisonMonitorFixture,
        listing: RecordingLiveComparisonListingService,
        monitor: InMemoryComparisonTreeMonitor,
        workspace: WorkspaceState,
        coordinator: ComparisonCoordinator
    ) {
        self.roots = roots
        self.listing = listing
        self.monitor = monitor
        self.workspace = workspace
        self.coordinator = coordinator
    }

    static func make() async throws -> LiveCoordinatorFixture {
        let roots = try ComparisonMonitorFixture()
        let folder = roots.left.appending(path: "A", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("left".utf8).write(to: folder.appending(path: "file.txt"))
        try Data("right".utf8).write(to: roots.right.appending(path: "right.txt"))
        let listing = RecordingLiveComparisonListingService()
        let monitor = InMemoryComparisonTreeMonitor()
        let workspace = WorkspaceState(
            leftURL: roots.left,
            rightURL: roots.right,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        return LiveCoordinatorFixture(
            roots: roots,
            listing: listing,
            monitor: monitor,
            workspace: workspace,
            coordinator: coordinator
        )
    }

    func waitUntilReady() async throws {
        guard await waitFor({
            self.coordinator.phase == .upToDate && self.monitor.activeStreamCount == 1
        }) else {
            throw MonitorTestError.timedOut
        }
    }

    func stopAndRemove() {
        coordinator.stop()
        monitor.finish()
        roots.remove()
    }
}

private actor RecordingLiveComparisonListingService: ComparisonListingService {
    private let live = LiveComparisonListingService(batchSize: 8)
    private(set) var requests: [ComparisonListingRequest] = []

    var requestCount: Int { requests.count }
    var lastRequest: ComparisonListingRequest? { requests.last }

    func identity(of root: URL) async throws -> FileIdentity {
        try await live.identity(of: root)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        let source = live.batches(for: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.record(request)
                do {
                    for try await batch in source {
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ request: ComparisonListingRequest) {
        requests.append(request)
    }
}

private actor ControlledTreeReconciliationListingService: ComparisonListingService {
    private struct TargetedRequest {
        let continuation: AsyncThrowingStream<ComparisonListingBatch, Error>.Continuation
    }

    private let live = LiveComparisonListingService(batchSize: 8)
    private var targetedRequests: [TargetedRequest] = []

    var targetedRequestCount: Int { targetedRequests.count }

    func identity(of root: URL) async throws -> FileIdentity {
        try await live.identity(of: root)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        guard request.subtree != nil else { return live.batches(for: request) }
        return AsyncThrowingStream { continuation in
            Task { await self.register(continuation) }
        }
    }

    func releaseTargeted(request index: Int, record: ComparisonListingRecord) {
        guard targetedRequests.indices.contains(index) else { return }
        targetedRequests[index].continuation.yield(.init(records: [record]))
        targetedRequests[index].continuation.finish()
    }

    private func register(
        _ continuation: AsyncThrowingStream<ComparisonListingBatch, Error>.Continuation
    ) {
        targetedRequests.append(.init(continuation: continuation))
    }
}

private actor CancellationObservingChecksumService: ChecksumService {
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0

    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        requestCount += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return .init(digest: Data(request.url.path.utf8))
        } catch {
            cancellationCount += 1
            throw error
        }
    }
}

private actor TwoStageIdentityListingService: ComparisonListingService {
    private let leftRoot: URL
    private let rightRoot: URL
    private let leftIdentities: [String]
    private let rightIdentities: [String]
    private let records: [URL: [ComparisonListingRecord]]
    private var identityCalls: [URL: Int] = [:]
    private(set) var requestCount = 0

    init(
        leftRoot: URL,
        rightRoot: URL,
        leftIdentities: [String],
        rightIdentities: [String],
        records: [URL: [ComparisonListingRecord]]
    ) {
        self.leftRoot = leftRoot
        self.rightRoot = rightRoot
        self.leftIdentities = leftIdentities
        self.rightIdentities = rightIdentities
        self.records = records
    }

    func identity(of root: URL) -> FileIdentity {
        let values = root == leftRoot ? leftIdentities : rightIdentities
        let call = identityCalls[root, default: 0]
        identityCalls[root] = call + 1
        let value = values[min(call, values.count - 1)]
        return .init(entryIdentifier: value, resolvedIdentifier: value)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let records = await self.register(request)
                if !records.isEmpty {
                    continuation.yield(.init(records: records))
                }
                continuation.finish()
            }
        }
    }

    private func register(_ request: ComparisonListingRequest) -> [ComparisonListingRecord] {
        requestCount += 1
        return records[request.root, default: []]
    }
}

private actor ValidationFreezeListingService: ComparisonListingService {
    private struct TargetedRequest {
        let continuation: AsyncThrowingStream<ComparisonListingBatch, Error>.Continuation
    }

    private let leftRoot: URL
    private let rightRoot: URL
    private let records: [URL: [ComparisonListingRecord]]
    private var identityCalls: [URL: Int] = [:]
    private var validationContinuation: CheckedContinuation<FileIdentity, Error>?
    private var targetedRequests: [TargetedRequest] = []

    var targetedRequestCount: Int { targetedRequests.count }
    var validationCheckIsStalled: Bool { validationContinuation != nil }

    init(
        leftRoot: URL,
        rightRoot: URL,
        records: [URL: [ComparisonListingRecord]]
    ) {
        self.leftRoot = leftRoot
        self.rightRoot = rightRoot
        self.records = records
    }

    func identity(of root: URL) async throws -> FileIdentity {
        let call = identityCalls[root, default: 0]
        identityCalls[root] = call + 1
        if root == leftRoot, call == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                validationContinuation = continuation
            }
        }
        let value = root == leftRoot ? "left-old" : "right-old"
        return .init(entryIdentifier: value, resolvedIdentifier: value)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if request.subtree == nil {
                    let records = self.records[request.root, default: []]
                    if !records.isEmpty {
                        continuation.yield(.init(records: records))
                    }
                    continuation.finish()
                } else {
                    await self.registerTargeted(continuation)
                }
            }
        }
    }

    func releaseTargeted(request index: Int, record: ComparisonListingRecord) {
        guard targetedRequests.indices.contains(index) else { return }
        targetedRequests[index].continuation.yield(.init(records: [record]))
        targetedRequests[index].continuation.finish()
    }

    func failValidationCheck() {
        validationContinuation?.resume(throwing: MonitorTestError.validationFailed)
        validationContinuation = nil
    }

    private func registerTargeted(
        _ continuation: AsyncThrowingStream<ComparisonListingBatch, Error>.Continuation
    ) {
        targetedRequests.append(.init(continuation: continuation))
    }
}

private actor ValidationFreezeChecksumService: ChecksumService {
    private var continuations: [CheckedContinuation<ChecksumResult, Error>] = []

    var requestCount: Int { continuations.count }

    func checksum(
        for _: ChecksumRequest,
        progress _: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        let values = continuations
        continuations.removeAll()
        for (index, continuation) in values.enumerated() {
            continuation.resume(returning: .init(digest: Data("digest-\(index)".utf8)))
        }
    }
}

private actor ValidationFreezeProjectionBuilder: ComparisonProjectionBuilding {
    private struct StalledRequest {
        let continuation: CheckedContinuation<[ComparisonRow], Error>
    }

    private var shouldStall = false
    private var stalledRequests: [StalledRequest] = []

    var stalledRequestCount: Int { stalledRequests.count }

    func armStalling() {
        shouldStall = true
    }

    func rows(
        left: [ComparisonEntry],
        right: [ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        if !shouldStall {
            return try ComparisonProjectionBuilder.rows(
                left: left,
                right: right,
                errors: errors,
                overrides: overrides,
                leftRoot: leftRoot,
                rightRoot: rightRoot
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            stalledRequests.append(.init(continuation: continuation))
        }
    }

    func releaseStalled(request index: Int, rows: [ComparisonRow]) {
        guard stalledRequests.indices.contains(index) else { return }
        stalledRequests[index].continuation.resume(returning: rows)
    }
}

private actor FinalGateIdentityListingService: ComparisonListingService {
    private let leftRoot: URL
    private let rightRoot: URL
    private let records: [URL: [ComparisonListingRecord]]
    private var identityCalls: [URL: Int] = [:]
    private var finalGateContinuation: CheckedContinuation<FileIdentity, Error>?
    private(set) var requestCount = 0

    var finalGateIsStalled: Bool { finalGateContinuation != nil }

    init(
        leftRoot: URL,
        rightRoot: URL,
        records: [URL: [ComparisonListingRecord]]
    ) {
        self.leftRoot = leftRoot
        self.rightRoot = rightRoot
        self.records = records
    }

    func identity(of root: URL) async throws -> FileIdentity {
        let call = identityCalls[root, default: 0]
        identityCalls[root] = call + 1
        if root == leftRoot, call == 3 {
            return try await withCheckedThrowingContinuation { continuation in
                finalGateContinuation = continuation
            }
        }
        let value = root == leftRoot ? "left-old" : "right-old"
        return .init(entryIdentifier: value, resolvedIdentifier: value)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let records = await self.register(request)
                if !records.isEmpty {
                    continuation.yield(.init(records: records))
                }
                continuation.finish()
            }
        }
    }

    func releaseFinalGate(leftIdentity: String) {
        finalGateContinuation?.resume(returning: .init(
            entryIdentifier: leftIdentity,
            resolvedIdentifier: leftIdentity
        ))
        finalGateContinuation = nil
    }

    private func register(_ request: ComparisonListingRequest) -> [ComparisonListingRecord] {
        requestCount += 1
        return records[request.root, default: []]
    }
}

private final class ImmediateIdentityListingService: ComparisonListingService, @unchecked Sendable {
    private let leftRoot: URL
    private let rightRoot: URL
    private let records: [URL: [ComparisonListingRecord]]
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    init(
        leftRoot: URL,
        rightRoot: URL,
        records: [URL: [ComparisonListingRecord]]
    ) {
        self.leftRoot = leftRoot
        self.rightRoot = rightRoot
        self.records = records
    }

    func identity(of root: URL) async throws -> FileIdentity {
        let value = root == leftRoot ? "left-old" : "right-old"
        return .init(entryIdentifier: value, resolvedIdentifier: value)
    }

    func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        let records = lock.withLock {
            requests += 1
            return self.records[request.root, default: []]
        }
        return AsyncThrowingStream { continuation in
            if !records.isEmpty {
                continuation.yield(.init(records: records))
            }
            continuation.finish()
        }
    }
}

private final class ControlledProducerStartupMonitor: ComparisonTreeMonitor, @unchecked Sendable {
    private struct Subscriber {
        let id: UUID
        let continuation: AsyncStream<ComparisonTreeEvent>.Continuation
    }

    private let lock = NSLock()
    private var requestCount = 0
    private var startups: [CheckedContinuation<ComparisonTreeMonitorStart, Never>] = []
    private var subscribers: [Subscriber] = []

    var startRequestCount: Int { lock.withLock { requestCount } }
    var activeStreamCount: Int { lock.withLock { subscribers.count } }

    func start(roots _: [ComparisonSide: URL]) async -> ComparisonTreeMonitorStart {
        await withCheckedContinuation { startup in
            lock.withLock {
                requestCount += 1
                startups.append(startup)
            }
        }
    }

    func failStart() {
        let startup = lock.withLock {
            startups.isEmpty ? nil : startups.removeFirst()
        }
        startup?.resume(returning: .failed)
    }

    func succeedStart() {
        let startup = lock.withLock {
            startups.isEmpty ? nil : startups.removeFirst()
        }
        guard let startup else { return }
        let stream = AsyncStream<ComparisonTreeEvent> { continuation in
            let id = UUID()
            lock.withLock {
                subscribers.append(.init(id: id, continuation: continuation))
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }
        }
        startup.resume(returning: .started(stream))
    }

    func finish() {
        let continuations = lock.withLock { subscribers.map(\.continuation) }
        continuations.forEach { $0.finish() }
        while true {
            let startup = lock.withLock {
                startups.isEmpty ? nil : startups.removeFirst()
            }
            guard let startup else { return }
            startup.resume(returning: .failed)
        }
    }

    private func remove(id: UUID) {
        lock.withLock { subscribers.removeAll { $0.id == id } }
    }
}

private final class OwnerStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let continuations = lock.withLock {
            guard !stopped else { return [CheckedContinuation<Void, Never>]() }
            stopped = true
            let values = self.waiters
            self.waiters.removeAll()
            return values
        }
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if lock.withLock({ stopped }) { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if stopped { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}

private enum MonitorTestError: Error {
    case timedOut
    case validationFailed
    case startupFailed
}

private func monitorEntry(
    _ relative: String,
    root: URL,
    identity: String
) throws -> ComparisonEntry {
    let path = try ComparisonRelativePath(
        components: relative.split(separator: "/").map(String.init)
    )
    return ComparisonEntry(
        relativePath: path,
        url: path.components.reduce(root) { $0.appending(path: $1) },
        kind: .regularFile,
        fingerprint: .init(
            identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
            byteSize: 3,
            modifiedAt: Date(timeIntervalSince1970: 1)
        ),
        symbolicLinkTarget: nil,
        typeDescription: "File"
    )
}

private func firstEvent(
    in stream: AsyncStream<ComparisonTreeEvent>,
    matching predicate: @escaping @Sendable (ComparisonTreeEvent) -> Bool
) async throws -> ComparisonTreeEvent {
    try await withThrowingTaskGroup(of: ComparisonTreeEvent.self) { group in
        group.addTask {
            for await event in stream where predicate(event) { return event }
            throw MonitorTestError.timedOut
        }
        group.addTask {
            try await Task.sleep(for: .seconds(4))
            throw MonitorTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let event = try await group.next() else { throw MonitorTestError.timedOut }
        return event
    }
}

private func consumeUntilCancelled(_ stream: AsyncStream<ComparisonTreeEvent>) async {
    let task = Task {
        for await _ in stream {}
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await task.value
}

private func withLiveMonitor<Result>(
    nestedRightRoot: Bool = false,
    latency: CFTimeInterval,
    operation: (ComparisonMonitorFixture, AsyncStream<ComparisonTreeEvent>) async throws -> Result
) async throws -> Result {
    let fixture = try ComparisonMonitorFixture(nestedRightRoot: nestedRightRoot)
    let stopped = OwnerStopSignal()
    let monitor = LiveComparisonTreeMonitor(
        latency: latency,
        onOwnerStopped: { stopped.signal() }
    )
    var stream: AsyncStream<ComparisonTreeEvent>?
    switch await monitor.start(roots: [.left: fixture.left, .right: fixture.right]) {
    case let .started(startedStream):
        stream = startedStream
    case .failed:
        fixture.remove()
        throw MonitorTestError.startupFailed
    }

    do {
        let result = try await operation(fixture, stream!)
        stream = nil
        await stopped.wait()
        fixture.remove()
        return result
    } catch {
        stream = nil
        await stopped.wait()
        fixture.remove()
        throw error
    }
}

@MainActor
private func waitFor(
    timeout: Duration = .seconds(4),
    _ predicate: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await predicate()), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}
