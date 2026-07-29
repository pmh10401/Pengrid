import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct ComparisonCoordinatorTests {
    @Test func fiftyThousandRowDenseReconciliationCompletesWithinWatchdog() async throws {
        let fixture = try await Task.detached {
            try DenseReconciliationFixture.make()
        }.value
        let builder = GatedLiveReconciliationBuilder()
        let heartbeatProbe = MainActorHeartbeatProbe()
        let heartbeat = Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(4))
            while !heartbeatProbe.isStopped, clock.now < deadline {
                heartbeatProbe.count += 1
                await Task.yield()
            }
        }
        let reconciliation = Task {
            try await builder.reconciledRows(
                fixture.rows,
                left: fixture.left,
                right: fixture.right,
                errors: fixture.errors,
                overrides: fixture.overrides,
                leftRoot: fixture.leftRoot,
                rightRoot: fixture.rightRoot
            )
        }
        #expect(await waitUntil { await builder.hasStarted })
        let heartbeatAtStart = heartbeatProbe.count
        let reconciled = try await valueWithinFourSeconds {
            await builder.release()
            return try await reconciliation.value
        }
        let heartbeatAtCompletion = heartbeatProbe.count
        heartbeatProbe.isStopped = true
        await heartbeat.value

        #expect(reconciled.count == 55_000)
        #expect(reconciled[0].status == .error("left existing error"))
        #expect(reconciled[12_000].status == .unstable)
        #expect(reconciled[15_000].status == .checking(nil))
        #expect(zip(reconciled, reconciled.dropFirst()).allSatisfy { $0.id < $1.id })
        let missingLeft = try #require(reconciled.first { $0.id == fixture.missingPaths[0] })
        let missingRight = try #require(reconciled.first { $0.id == fixture.missingPaths[1] })
        let missingBoth = try #require(reconciled.first { $0.id == fixture.missingPaths[2] })
        #expect(missingLeft.left?.kind == .special && missingLeft.right == nil)
        #expect(missingRight.left == nil && missingRight.right?.kind == .special)
        #expect(missingBoth.left?.kind == .special && missingBoth.right?.kind == .special)
        #expect(heartbeatAtCompletion > heartbeatAtStart)
    }

    @Test func fiftyThousandRowProjectionCompletesOffMainActorWithinWatchdog() async throws {
        let roots = (
            URL(filePath: "/comparison/performance-left", directoryHint: .isDirectory),
            URL(filePath: "/comparison/performance-right", directoryHint: .isDirectory)
        )
        let entries = try await Task.detached {
            var left: [ComparisonEntry] = []
            var right: [ComparisonEntry] = []
            left.reserveCapacity(50_000)
            right.reserveCapacity(1)
            func letters(_ value: Int) -> String {
                var value = value
                var scalars = [UnicodeScalar](repeating: "a", count: 4)
                for index in scalars.indices.reversed() {
                    scalars[index] = UnicodeScalar(97 + value % 26)!
                    value /= 26
                }
                return String(String.UnicodeScalarView(scalars))
            }
            for index in 0 ..< 49_998 {
                left.append(try entry(
                    "f\(letters(index))",
                    root: roots.0.path,
                    identity: "l-f-\(index)"
                ))
            }
            let leftDirectory = try entry(
                "z", root: roots.0.path, identity: "l-directory", kind: .directory
            )
            let rightDirectory = try entry(
                "z", root: roots.1.path, identity: "r-directory", kind: .directory
            )
            left.append(leftDirectory)
            right.append(rightDirectory)
            left.append(try entry("z/child", root: roots.0.path, identity: "l-child"))
            return (left, right)
        }.value
        let completion = AsyncFlag()
        let heartbeat = Task { @MainActor in
            var count = 0
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(4))
            while !(await completion.value), clock.now < deadline {
                count += 1
                await Task.yield()
            }
            return count
        }

        let projectionStarted = ContinuousClock().now
        let projectedRows = try await valueWithinFourSeconds {
            defer { Task { await completion.set() } }
            return try await LiveComparisonProjectionBuilder().rows(
                left: entries.0,
                right: entries.1,
                errors: [.left: [:], .right: [:]],
                overrides: [:],
                leftRoot: roots.0,
                rightRoot: roots.1
            )
        }
        #expect(projectionStarted.duration(to: ContinuousClock().now) < .seconds(4))
        let heartbeatCount = await heartbeat.value

        #expect(projectedRows.count == 50_000)
        #expect(projectedRows.first(where: { $0.id.string == "z" })?.descendantDifferenceCount == 1)
        #expect(heartbeatCount > 1)
    }

    @Test func startPublishesQuickRowsBeforeSecondBatch() async throws {
        let fixture = try CoordinatorFixture.twoBatchListing()

        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitForStreams(left: 1, right: 1)
        await fixture.listing.releaseNext(root: fixture.leftRoot)

        #expect(await waitUntil { fixture.coordinator.rows.count == 1 })
        #expect(fixture.coordinator.phase == .comparing)

        await fixture.listing.releaseNext(root: fixture.leftRoot)
        await fixture.listing.finish(root: fixture.leftRoot)
        await fixture.listing.finish(root: fixture.rightRoot)

        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })
        #expect(fixture.coordinator.rows.map(\.id.string) == ["first.txt", "second.txt"])
    }

    @Test func rapidBatchesPublishEarlyPrefixThenCoalesceToLatestProjection() async throws {
        let leftRoot = URL(filePath: "/comparison/revision-left", directoryHint: .isDirectory)
        let rightRoot = URL(filePath: "/comparison/revision-right", directoryHint: .isDirectory)
        let first = try entry("first.txt", root: leftRoot.path, identity: "revision-first")
        let second = try entry("second.txt", root: leftRoot.path, identity: "revision-second")
        let third = try entry("third.txt", root: leftRoot.path, identity: "revision-third")
        let listing = ManualComparisonListingService(
            batches: [leftRoot: [[.entry(first)], [.entry(second)], [.entry(third)]], rightRoot: []],
            identities: [leftRoot: "revision-left-root", rightRoot: "revision-right-root"]
        )
        let projections = ControlledProjectionBuilder()
        let workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: ManualChecksumService(),
            logger: RecordingComparisonLogger(),
            projections: projections
        )
        coordinator.start(workspace: workspace)
        #expect(await waitUntil {
            let leftCount = await listing.streamCount(root: leftRoot)
            let rightCount = await listing.streamCount(root: rightRoot)
            return leftCount == 1 && rightCount == 1
        })

        await listing.releaseNext(root: leftRoot)
        #expect(await waitUntil { await projections.requestCount == 1 })
        await listing.releaseNext(root: leftRoot)
        await listing.releaseNext(root: leftRoot)
        #expect(await remainsTrueForOneSecond { await projections.requestCount == 1 })

        await projections.release(request: 0)
        #expect(await waitUntil { coordinator.rows.map(\.id.string) == ["first.txt"] })
        #expect(await waitUntil { await projections.requestCount == 2 })
        #expect(await projections.leftEntryCount(request: 1) == 3)
        await projections.release(request: 1)
        #expect(await waitUntil {
            coordinator.rows.map(\.id.string) == ["first.txt", "second.txt", "third.txt"]
        })
        coordinator.stop()
    }

    @Test func projectionFailurePausesAndRecordsAnError() async throws {
        let leftRoot = URL(filePath: "/comparison/projection-error-left", directoryHint: .isDirectory)
        let rightRoot = URL(filePath: "/comparison/projection-error-right", directoryHint: .isDirectory)
        let item = try entry("item.txt", root: leftRoot.path, identity: "projection-error-item")
        let listing = ManualComparisonListingService(
            batches: [leftRoot: [[.entry(item)]], rightRoot: []],
            identities: [leftRoot: "projection-error-left", rightRoot: "projection-error-right"]
        )
        let logger = RecordingComparisonLogger()
        let coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: ManualChecksumService(),
            logger: logger,
            projections: ThrowingProjectionBuilder()
        )
        let workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )

        coordinator.start(workspace: workspace)
        #expect(await waitUntil {
            let leftCount = await listing.streamCount(root: leftRoot)
            let rightCount = await listing.streamCount(root: rightRoot)
            return leftCount == 1 && rightCount == 1
        })
        await listing.releaseNext(root: leftRoot)

        #expect(await waitUntil { coordinator.phase == .paused })
        #expect(await waitUntil { await logger.events.count == 1 })
        let event = try #require(await logger.events.first)
        #expect(event.errorCount == 1)
        #expect(!event.wasCancelled)
    }

    @Test func restartedGenerationRejectsLateListingBatch() async throws {
        let fixture = try CoordinatorFixture.lateListing()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitForStreams(left: 1, right: 1)
        let oldGeneration = try #require(fixture.coordinator.session?.generation)

        await fixture.workspace.left.navigate(to: fixture.otherLeft)
        fixture.coordinator.rootsDidChange(workspace: fixture.workspace)
        #expect(await waitUntil { fixture.coordinator.session?.generation != oldGeneration })
        try await fixture.waitForStreams(left: 1, right: 2, leftRoot: fixture.otherLeft)

        await fixture.listing.releaseNext(root: fixture.leftRoot, stream: 0)
        await fixture.listing.finish(root: fixture.leftRoot, stream: 0)
        await fixture.listing.finish(root: fixture.rightRoot, stream: 0)
        await fixture.listing.finish(root: fixture.otherLeft, stream: 0)
        await fixture.listing.finish(root: fixture.rightRoot, stream: 1)

        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })
        #expect(!fixture.coordinator.rows.contains { $0.id.string == "old.txt" })
    }

    @Test func navigationCancelsOldGenerationAndRejectsLateHash() async throws {
        let fixture = try CoordinatorFixture.stalledChecksum()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.releaseAllAndWaitForChecksum()
        let oldGeneration = try #require(fixture.coordinator.session?.generation)

        await fixture.workspace.left.navigate(to: fixture.otherLeft)
        fixture.coordinator.rootsDidChange(workspace: fixture.workspace)
        #expect(await waitUntil { fixture.coordinator.session?.generation != oldGeneration })
        try await fixture.waitForStreams(left: 1, right: 2, leftRoot: fixture.otherLeft)
        await fixture.listing.finish(root: fixture.otherLeft)
        await fixture.listing.finish(root: fixture.rightRoot, stream: 1)
        await fixture.checksums.succeed(request: 0, digest: Data("same".utf8))

        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })
        #expect(!fixture.coordinator.rows.contains { $0.status == .metadataChanged })
    }

    @Test func changedFingerprintRejectsLateChecksumWithinGeneration() async throws {
        let fixture = try CoordinatorFixture.changedFingerprint()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitForStreams(left: 1, right: 1)
        await fixture.listing.releaseNext(root: fixture.leftRoot)
        await fixture.listing.releaseNext(root: fixture.rightRoot)
        #expect(await waitUntil { await fixture.checksums.requestCount == 2 })

        await fixture.listing.releaseNext(root: fixture.leftRoot)
        await fixture.listing.releaseNext(root: fixture.rightRoot)
        await fixture.checksums.succeed(request: 0, digest: Data("same".utf8))
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))

        #expect(await waitUntil {
            fixture.coordinator.rows.first?.left?.fingerprint.identity.entryIdentifier == "left-new"
        })
        #expect(fixture.coordinator.rows.first?.status == .checking(nil))
        fixture.coordinator.stop()
    }

    @Test func listingErrorDuringChecksumSurvivesProgressCompletionAndForcedVerification() async throws {
        let fixture = try CoordinatorFixture.errorDuringChecksum()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitForStreams(left: 1, right: 1)
        await fixture.listing.releaseNext(root: fixture.leftRoot)
        await fixture.listing.releaseNext(root: fixture.rightRoot)
        #expect(await waitUntil { await fixture.checksums.requestCount == 2 })

        await fixture.listing.releaseNext(root: fixture.leftRoot)
        await fixture.listing.finish(root: fixture.leftRoot)
        await fixture.listing.finish(root: fixture.rightRoot)
        #expect(await waitUntil {
            fixture.coordinator.rows.first?.status == .error("became unreadable")
        })

        await fixture.checksums.succeed(request: 0, digest: Data("same".utf8))
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))
        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })
        #expect(fixture.coordinator.rows.first?.status == .error("became unreadable"))

        fixture.coordinator.verifyAll()
        #expect(await fixture.checksums.requestCount == 2)
        #expect(fixture.coordinator.rows.first?.status == .error("became unreadable"))
    }

    @Test func checksumSuccessSurvivesLaterProjection() async throws {
        let projections = ControlledProjectionBuilder()
        let fixture = try CoordinatorFixture.checksumFollowedByBatch(projections: projections)
        try await fixture.beginControlledChecksum(projections: projections)

        await fixture.checksums.succeed(request: 0, digest: Data("same".utf8))
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))
        #expect(await waitUntil { fixture.coordinator.rows.first?.status == .metadataChanged })

        try await fixture.releaseLaterProjection(projections: projections)
        #expect(fixture.coordinator.rows.first { $0.id.string == "ambiguous.txt" }?.status == .metadataChanged)
    }

    @Test func changedFingerprintsInvalidatePersistedChecksumStatus() async throws {
        let projections = ControlledProjectionBuilder()
        let fixture = try CoordinatorFixture.checksumThenFingerprintChange(projections: projections)
        try await fixture.beginControlledChecksum(projections: projections)

        await fixture.checksums.succeed(request: 0, digest: Data("same".utf8))
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))
        #expect(await waitUntil { fixture.coordinator.rows.first?.status == .metadataChanged })
        #expect(await waitUntil { await projections.requestCount == 3 })

        await fixture.listing.releaseNext(root: fixture.leftRoot)
        await fixture.listing.releaseNext(root: fixture.rightRoot)
        #expect(await remainsTrueForOneSecond { await projections.requestCount == 3 })
        await projections.release(request: 2)
        #expect(await waitUntil { await projections.requestCount == 4 })
        await projections.release(request: 3)

        #expect(await waitUntil {
            guard let row = fixture.coordinator.rows.first,
                  row.left?.fingerprint.identity.entryIdentifier == "left-new"
            else { return false }
            if case .checking = row.status { return true }
            return false
        })
        #expect(await waitUntil { await fixture.checksums.requestCount == 4 })
    }

    @Test func unstableChecksumSurvivesLaterProjectionWithoutRescheduling() async throws {
        let projections = ControlledProjectionBuilder()
        let fixture = try CoordinatorFixture.checksumFollowedByBatch(projections: projections)
        try await fixture.beginControlledChecksum(projections: projections)
        let leftRequest = try #require(await fixture.checksums.firstRequestIndex(for: fixture.leftRoot))
        let rightRequest = try #require(await fixture.checksums.firstRequestIndex(for: fixture.rightRoot))

        await fixture.checksums.fail(request: leftRequest, error: ChecksumError.identityChanged)
        #expect(await waitUntil { await fixture.checksums.requestCount == 3 })
        await fixture.checksums.fail(request: 2, error: ChecksumError.identityChanged)
        await fixture.checksums.succeed(request: rightRequest, digest: Data("same".utf8))
        #expect(await waitUntil { fixture.coordinator.rows.first?.status == .unstable })

        try await fixture.releaseLaterProjection(projections: projections)
        #expect(fixture.coordinator.rows.first { $0.id.string == "ambiguous.txt" }?.status == .unstable)
        #expect(await fixture.checksums.requestCount == 3)
    }

    @Test func checksumErrorSurvivesLaterProjectionWithoutRescheduling() async throws {
        let projections = ControlledProjectionBuilder()
        let fixture = try CoordinatorFixture.checksumFollowedByBatch(projections: projections)
        try await fixture.beginControlledChecksum(projections: projections)

        await fixture.checksums.fail(request: 0, error: CoordinatorTestError.checksumFailed)
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))
        #expect(await waitUntil {
            fixture.coordinator.rows.first?.status == .error("checksum failed")
        })

        try await fixture.releaseLaterProjection(projections: projections)
        #expect(fixture.coordinator.rows.first { $0.id.string == "ambiguous.txt" }?.status
            == .error("checksum failed"))
        #expect(await fixture.checksums.requestCount == 2)
    }

    @Test(arguments: StaleProjectionTerminalCase.allCases)
    private func staleActiveProjectionCannotRegressTerminalChecksumStatus(
        terminalCase: StaleProjectionTerminalCase
    ) async throws {
        let projections = ControlledProjectionBuilder()
        let fixture = try CoordinatorFixture.terminalChecksumRace(
            quickIdentical: terminalCase == .checksumIdentical,
            projections: projections
        )
        try await fixture.beginTerminalChecksumRace(
            projections: projections,
            forced: terminalCase == .checksumIdentical
        )

        let leftRequest = try #require(await fixture.checksums.firstRequestIndex(for: fixture.leftRoot))
        let rightRequest = try #require(await fixture.checksums.firstRequestIndex(for: fixture.rightRoot))
        switch terminalCase {
        case .checksumIdentical:
            await fixture.checksums.succeed(request: leftRequest, digest: Data("same".utf8))
            await fixture.checksums.succeed(request: rightRequest, digest: Data("same".utf8))
        case .unstable:
            await fixture.checksums.fail(request: leftRequest, error: ChecksumError.identityChanged)
            #expect(await waitUntil { await fixture.checksums.requestCount == 3 })
            await fixture.checksums.fail(request: 2, error: ChecksumError.identityChanged)
            await fixture.checksums.succeed(request: rightRequest, digest: Data("same".utf8))
        case .error:
            await fixture.checksums.fail(request: leftRequest, error: CoordinatorTestError.checksumFailed)
            await fixture.checksums.succeed(request: rightRequest, digest: Data("same".utf8))
        }
        #expect(await waitUntil { terminalCase.matches(fixture.coordinator.rows.first?.status) })

        let expectedChecksumCount = terminalCase == .unstable ? 3 : 2
        #expect(await projections.requestCount == 3)
        await projections.release(request: 2)
        #expect(await waitUntil { await projections.requestCount == 4 })
        #expect(await remainsTrueForOneSecond {
            let checksumCount = await fixture.checksums.requestCount
            return terminalCase.matches(fixture.coordinator.rows.first?.status)
                && checksumCount == expectedChecksumCount
        })

        await projections.release(request: 3)
        #expect(await waitUntil { await projections.completedCount == 4 })
        #expect(await remainsTrueForOneSecond {
            let checksumCount = await fixture.checksums.requestCount
            return terminalCase.matches(fixture.coordinator.rows.first?.status)
                && checksumCount == expectedChecksumCount
        })
    }

    @Test func presentationChangesDuringReconciliationRejectStaleOutput() async throws {
        let projections = ControlledReconciliationProjectionBuilder()
        let fixture = try CoordinatorFixture.reconciliationPresentationRace(projections: projections)
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitForStreams(left: 1, right: 1)

        await fixture.listing.releaseNext(root: fixture.leftRoot)
        #expect(await waitUntil { await projections.reconciliationRequestCount == 1 })
        await projections.releaseReconciliation(request: 0)
        #expect(await waitUntil { fixture.coordinator.rows.count == 1 })

        await fixture.listing.releaseNext(root: fixture.rightRoot)
        #expect(await waitUntil { await projections.reconciliationRequestCount == 2 })
        await projections.releaseReconciliation(request: 1)
        #expect(await waitUntil { await fixture.checksums.requestCount == 2 })

        await fixture.listing.releaseNext(root: fixture.leftRoot)
        #expect(await waitUntil { await projections.reconciliationRequestCount == 3 })
        await fixture.checksums.fail(request: 0, error: CoordinatorTestError.checksumFailed)
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))
        #expect(await waitUntil {
            fixture.coordinator.rows.first { $0.id.string == "ambiguous.txt" }?.status
                == .error("checksum failed")
        })
        await fixture.listing.releaseNext(root: fixture.leftRoot)
        #expect(await remainsTrueForOneSecond {
            let requestCount = await projections.reconciliationRequestCount
            return requestCount == 3
                && fixture.coordinator.rows.first { $0.id.string == "ambiguous.txt" }?.status
                == .error("checksum failed")
        })

        await projections.releaseReconciliation(request: 2)
        #expect(await waitUntil { await projections.reconciliationRequestCount == 4 })
        #expect(await remainsTrueForOneSecond {
            let checksumCount = await fixture.checksums.requestCount
            return fixture.coordinator.rows.first { $0.id.string == "ambiguous.txt" }?.status
                == .error("checksum failed") && checksumCount == 2
        })

        await projections.releaseReconciliation(request: 3)
        #expect(await waitUntil {
            fixture.coordinator.rows.first { $0.id.string == "ambiguous.txt" }?.status
                == .error("listing changed")
        })
        #expect(await fixture.checksums.requestCount == 2)
    }

    @Test func fatalListingErrorKeepsPausedDominantOverLateProjectionAndChecksums() async throws {
        let projections = ControlledProjectionBuilder()
        let fixture = try CoordinatorFixture.checksumFollowedByBatch(projections: projections)
        try await fixture.beginControlledChecksum(projections: projections)
        await fixture.listing.releaseNext(root: fixture.leftRoot)
        #expect(await waitUntil { await projections.requestCount == 3 })

        await fixture.listing.fail(
            root: fixture.rightRoot,
            error: CoordinatorTestError.listingFailed
        )
        #expect(await waitUntil { fixture.coordinator.phase == .paused })

        await projections.release(request: 2)
        await fixture.checksums.succeed(request: 0, digest: Data("same".utf8))
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))
        #expect(await waitUntil { await fixture.checksums.completedCount == 2 })
        fixture.coordinator.verifyAll()

        #expect(await remainsTrueForOneSecond {
            let requestCount = await fixture.checksums.requestCount
            return fixture.coordinator.phase == .paused && requestCount == 2
        })
        #expect(await waitUntil { await fixture.logger.events.count == 1 })
    }

    @Test func stopClearsProjectionSelectionAndRejectsLateChecksum() async throws {
        let fixture = try CoordinatorFixture.stalledChecksum()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.releaseAllAndWaitForChecksum()
        fixture.coordinator.selection = [try path("ambiguous.txt")]
        let oldRequests = try [
            #require(await fixture.checksums.request(at: 0)),
            #require(await fixture.checksums.request(at: 1))
        ]

        fixture.coordinator.stop()
        await fixture.checksums.succeed(request: 0, digest: Data("left".utf8))
        await fixture.checksums.succeed(request: 1, digest: Data("right".utf8))

        #expect(!fixture.coordinator.isActive)
        #expect(fixture.coordinator.phase == .idle)
        #expect(fixture.coordinator.rows.isEmpty)
        #expect(fixture.coordinator.visibleRows.isEmpty)
        #expect(fixture.coordinator.selection.isEmpty)
        #expect(await waitUntil { await fixture.checksums.completedCount == 2 })
        #expect(await remainsTrueForOneSecond {
            for request in oldRequests {
                if await fixture.cache.value(for: request) != nil { return false }
            }
            return fixture.coordinator.rows.isEmpty
        })
    }

    @Test func restartAndRepeatedStopRecordEachGenerationExactlyOnce() async throws {
        let fixture = try CoordinatorFixture.lateListing()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.waitForStreams(left: 1, right: 1)

        fixture.coordinator.rootsDidChange(workspace: fixture.workspace)
        try await fixture.waitForStreams(left: 2, right: 2)
        fixture.coordinator.stop()
        fixture.coordinator.stop()

        #expect(await waitUntil { await fixture.logger.events.count == 2 })
        let events = await fixture.logger.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.wasCancelled })
    }

    @Test func stalledNonCooperativeChecksumsDoNotRetainCoordinator() async throws {
        let leftRoot = URL(filePath: "/comparison/release-left", directoryHint: .isDirectory)
        let rightRoot = URL(filePath: "/comparison/release-right", directoryHint: .isDirectory)
        let left = try entry(
            "ambiguous.txt", root: leftRoot.path, identity: "release-left",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let right = try entry(
            "ambiguous.txt", root: rightRoot.path, identity: "release-right",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let listing = ManualComparisonListingService(
            batches: [leftRoot: [[.entry(left)]], rightRoot: [[.entry(right)]]],
            identities: [leftRoot: "release-left-root", rightRoot: "release-right-root"]
        )
        let checksums = ManualChecksumService()
        let workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )
        weak var releasedCoordinator: ComparisonCoordinator?
        var coordinator: ComparisonCoordinator? = ComparisonCoordinator(
            listings: listing,
            checksums: checksums,
            logger: RecordingComparisonLogger()
        )
        releasedCoordinator = coordinator
        coordinator?.start(workspace: workspace)
        #expect(await waitUntil {
            let leftCount = await listing.streamCount(root: leftRoot)
            let rightCount = await listing.streamCount(root: rightRoot)
            return leftCount == 1 && rightCount == 1
        })
        await listing.releaseAll(root: leftRoot)
        await listing.releaseAll(root: rightRoot)
        await listing.finish(root: leftRoot)
        await listing.finish(root: rightRoot)
        #expect(await waitUntil { await checksums.requestCount == 2 })

        coordinator = nil

        #expect(await waitUntil { releasedCoordinator == nil })
        #expect(await checksums.pendingCount == 2)
    }

    @Test func descendantDifferencesAggregateWithoutOverwritingDirectConflict() async throws {
        let fixture = try CoordinatorFixture.directoryWithChangedChildren()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.releaseAllListings()

        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })
        let folder = try #require(fixture.coordinator.rows.first { $0.id.string == "Folder" })
        let nested = try #require(fixture.coordinator.rows.first { $0.id.string == "Folder/Nested" })
        #expect(folder.status == .typeConflict)
        #expect(folder.descendantDifferenceCount == 2)
        #expect(nested.descendantDifferenceCount == 1)
    }

    @Test func optionsFiltersSelectionAndForcedVerificationAreProjected() async throws {
        let fixture = try CoordinatorFixture.policyRows()
        fixture.coordinator.options = .init(includeSubfolders: true, includeHiddenItems: true)
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.releaseAllListings()
        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })

        let requests = await fixture.listing.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.options.includeSubfolders && $0.options.includeHiddenItems })
        #expect(fixture.coordinator.visibleRows.map(\.id.string) == ["left-only.txt"])

        fixture.coordinator.filter = .all
        #expect(fixture.coordinator.visibleRows.count == 2)
        let identical = try path("identical.txt")
        fixture.coordinator.selection = [identical, try path("missing.txt")]
        fixture.coordinator.verifySelected()

        #expect(fixture.coordinator.canVerifySelected)
        #expect(await waitUntil { await fixture.checksums.requestCount == 2 })
        #expect(fixture.coordinator.selection == [identical])
        await fixture.checksums.succeed(request: 0, digest: Data("same".utf8))
        await fixture.checksums.succeed(request: 1, digest: Data("same".utf8))
        #expect(await waitUntil {
            fixture.coordinator.rows.first(where: { $0.id == identical })?.status == .identical(.checksum)
        })
    }

    @Test func equalResolvedRootsAreRejectedBeforeListing() async throws {
        let fixture = try CoordinatorFixture.equalRoots()
        fixture.coordinator.start(workspace: fixture.workspace)

        #expect(await waitUntil { fixture.coordinator.phase == .paused })
        #expect(fixture.coordinator.session == nil)
        #expect(await fixture.listing.requests.isEmpty)
        #expect(fixture.coordinator.rows.isEmpty)
    }

    @Test func changedDuringReadRetriesOnceThenMarksRowUnstable() async throws {
        let fixture = try CoordinatorFixture.stalledChecksum()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.releaseAllAndWaitForChecksum()

        let leftRequest = try #require(await fixture.checksums.firstRequestIndex(for: fixture.leftRoot))
        await fixture.checksums.fail(request: leftRequest, error: ChecksumError.identityChanged)
        #expect(await waitUntil { await fixture.checksums.requestCount == 3 })
        await fixture.checksums.fail(request: 2, error: ChecksumError.identityChanged)
        let rightRequest = try #require(await fixture.checksums.firstRequestIndex(for: fixture.rightRoot))
        await fixture.checksums.succeed(request: rightRequest, digest: Data("same".utf8))

        #expect(await waitUntil { fixture.coordinator.rows.first?.status == .unstable })
        #expect(await fixture.checksums.attemptCount(for: fixture.leftRoot) == 2)
    }

    @Test func errorsOverlayRowsAndContributeToPrivacyPreservingMetrics() async throws {
        let fixture = try CoordinatorFixture.errorRows()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.releaseAllListings()
        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })

        let retained = try #require(fixture.coordinator.rows.first { $0.id.string == "retained.txt" })
        let synthetic = try #require(fixture.coordinator.rows.first { $0.id.string == "unreadable" })
        #expect(retained.left != nil)
        #expect(retained.status == .error("changed permissions"))
        #expect(synthetic.left?.kind == .special)
        #expect(synthetic.left?.url == fixture.leftRoot.appending(path: "unreadable"))
        #expect(synthetic.right == nil)
        #expect(synthetic.status == .error("permission denied"))
        fixture.coordinator.selection = [synthetic.id]
        #expect(!fixture.coordinator.canVerifySelected)

        fixture.coordinator.stop()
        #expect(await waitUntil { await fixture.logger.events.count == 1 })
        let event = try #require(await fixture.logger.events.last)
        #expect(event.discoveredCount == 1)
        #expect(event.errorCount == 2)
        #expect(!event.wasCancelled)
        let labels = Set(Mirror(reflecting: event).children.compactMap(\.label))
        #expect(labels == ["duration", "discoveredCount", "checksumCount", "errorCount", "wasCancelled"])
        #expect(labels.allSatisfy { !$0.localizedCaseInsensitiveContains("path") })
    }

    @Test func syntheticFailuresRepresentTheFailedSideOrBothSides() async throws {
        let fixture = try CoordinatorFixture.syntheticFailureSides()
        fixture.coordinator.start(workspace: fixture.workspace)
        try await fixture.releaseAllListings()
        #expect(await waitUntil { fixture.coordinator.phase == .upToDate })

        let leftOnly = try #require(fixture.coordinator.rows.first { $0.id.string == "left-failure" })
        let rightOnly = try #require(fixture.coordinator.rows.first { $0.id.string == "right-failure" })
        let both = try #require(fixture.coordinator.rows.first { $0.id.string == "both-failed" })
        #expect(leftOnly.left?.kind == .special && leftOnly.right == nil)
        #expect(rightOnly.left == nil && rightOnly.right?.kind == .special)
        #expect(both.left?.kind == .special && both.right?.kind == .special)
        #expect([leftOnly, rightOnly, both].allSatisfy {
            if case .error = $0.status { return true }
            return false
        })
    }
}

private enum CoordinatorTestError: Error {
    case timedOut(String)
    case checksumFailed
    case listingFailed
    case projectionFailed
}

private enum StaleProjectionTerminalCase: CaseIterable, Sendable {
    case checksumIdentical
    case unstable
    case error

    func matches(_ status: ComparisonStatus?) -> Bool {
        switch self {
        case .checksumIdentical: status == .identical(.checksum)
        case .unstable: status == .unstable
        case .error: status == .error("checksum failed")
        }
    }
}

extension CoordinatorTestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .checksumFailed: "checksum failed"
        case .listingFailed: "listing failed"
        case .projectionFailed: "projection failed"
        case let .timedOut(message): message
        }
    }
}

private actor AsyncFlag {
    private(set) var value = false
    func set() { value = true }
}

@MainActor
private final class MainActorHeartbeatProbe {
    var count = 0
    var isStopped = false
}

private actor GatedLiveReconciliationBuilder {
    private let live = LiveComparisonProjectionBuilder()
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false

    func reconciledRows(
        _ rows: [ComparisonRow],
        left: [ComparisonRelativePath: ComparisonEntry],
        right: [ComparisonRelativePath: ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        hasStarted = true
        await withCheckedContinuation { gate = $0 }
        return try await live.reconciledRows(
            rows,
            left: left,
            right: right,
            errors: errors,
            overrides: overrides,
            leftRoot: leftRoot,
            rightRoot: rightRoot
        )
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

private struct DenseReconciliationFixture: Sendable {
    let rows: [ComparisonRow]
    let left: [ComparisonRelativePath: ComparisonEntry]
    let right: [ComparisonRelativePath: ComparisonEntry]
    let errors: [ComparisonSide: [ComparisonRelativePath: String]]
    let overrides: [ComparisonRelativePath: ComparisonStatusOverride]
    let missingPaths: [ComparisonRelativePath]
    let leftRoot: URL
    let rightRoot: URL

    static func make() throws -> Self {
        let leftRoot = URL(filePath: "/comparison/reconcile-left", directoryHint: .isDirectory)
        let rightRoot = URL(filePath: "/comparison/reconcile-right", directoryHint: .isDirectory)
        var rows: [ComparisonRow] = []
        var left: [ComparisonRelativePath: ComparisonEntry] = [:]
        var right: [ComparisonRelativePath: ComparisonEntry] = [:]
        rows.reserveCapacity(50_000)
        left.reserveCapacity(50_000)
        right.reserveCapacity(50_000)

        for index in 0 ..< 50_000 {
            let name = "f\(letters(index))"
            let leftEntry = try entry(
                name, root: leftRoot.path, identity: "dense-left-\(index)",
                modifiedAt: Date(timeIntervalSince1970: 1)
            )
            let rightEntry = try entry(
                name, root: rightRoot.path, identity: "dense-right-\(index)",
                modifiedAt: Date(timeIntervalSince1970: 2)
            )
            rows.append(ComparisonRow(
                relativePath: leftEntry.relativePath,
                left: leftEntry,
                right: rightEntry,
                status: .checking(nil)
            ))
            left[leftEntry.relativePath] = leftEntry
            right[rightEntry.relativePath] = rightEntry
        }

        var overrides: [ComparisonRelativePath: ComparisonStatusOverride] = [:]
        overrides.reserveCapacity(20_000)
        for index in 0 ..< 20_000 {
            let row = rows[index]
            overrides[row.id] = ComparisonStatusOverride(
                leftFingerprint: row.left!.fingerprint,
                rightFingerprint: row.right!.fingerprint,
                status: .unstable
            )
        }
        let invalidPath = rows[15_000].id
        overrides[invalidPath] = ComparisonStatusOverride(
            leftFingerprint: rows[0].left!.fingerprint,
            rightFingerprint: rows[0].right!.fingerprint,
            status: .unstable
        )

        var leftErrors: [ComparisonRelativePath: String] = [:]
        var rightErrors: [ComparisonRelativePath: String] = [:]
        for index in 0 ..< 10_000 {
            let path = rows[index].id
            switch index % 3 {
            case 0: leftErrors[path] = "left existing error"
            case 1: rightErrors[path] = "right existing error"
            default:
                leftErrors[path] = "left existing error"
                rightErrors[path] = "right existing error"
            }
        }

        var missingPaths: [ComparisonRelativePath] = []
        missingPaths.reserveCapacity(5_000)
        for index in 0 ..< 5_000 {
            let path = try ComparisonRelativePath(components: ["z\(letters(index))"])
            missingPaths.append(path)
            switch index % 3 {
            case 0: leftErrors[path] = "left missing error"
            case 1: rightErrors[path] = "right missing error"
            default:
                leftErrors[path] = "left missing error"
                rightErrors[path] = "right missing error"
            }
        }

        return Self(
            rows: rows,
            left: left,
            right: right,
            errors: [.left: leftErrors, .right: rightErrors],
            overrides: overrides,
            missingPaths: missingPaths,
            leftRoot: leftRoot,
            rightRoot: rightRoot
        )
    }

    private static func letters(_ value: Int) -> String {
        var value = value
        var scalars = [UnicodeScalar](repeating: "a", count: 4)
        for index in scalars.indices.reversed() {
            scalars[index] = UnicodeScalar(97 + value % 26)!
            value /= 26
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

private actor ControlledProjectionBuilder: ComparisonProjectionBuilding {
    private struct Request {
        let left: [ComparisonEntry]
        let right: [ComparisonEntry]
        let errors: [ComparisonSide: [ComparisonRelativePath: String]]
        let overrides: [ComparisonRelativePath: ComparisonStatusOverride]
        let leftRoot: URL
        let rightRoot: URL
        let continuation: CheckedContinuation<[ComparisonRow], Error>
    }

    private var requests: [Request] = []
    private(set) var completedCount = 0
    var requestCount: Int { requests.count }

    func leftEntryCount(request index: Int) -> Int? {
        requests[safe: index]?.left.count
    }

    func rows(
        left: [ComparisonEntry],
        right: [ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        defer { completedCount += 1 }
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(
                left: left,
                right: right,
                errors: errors,
                overrides: overrides,
                leftRoot: leftRoot,
                rightRoot: rightRoot,
                continuation: continuation
            ))
        }
    }

    func release(request index: Int) {
        guard requests.indices.contains(index) else { return }
        do {
            let request = requests[index]
            request.continuation.resume(returning: try ComparisonProjectionBuilder.rows(
                left: request.left,
                right: request.right,
                errors: request.errors,
                overrides: request.overrides,
                leftRoot: request.leftRoot,
                rightRoot: request.rightRoot
            ))
        } catch {
            requests[index].continuation.resume(throwing: error)
        }
    }
}

private actor ControlledReconciliationProjectionBuilder: ComparisonProjectionBuilding {
    private struct ReconciliationRequest {
        let rows: [ComparisonRow]
        let left: [ComparisonRelativePath: ComparisonEntry]
        let right: [ComparisonRelativePath: ComparisonEntry]
        let errors: [ComparisonSide: [ComparisonRelativePath: String]]
        let overrides: [ComparisonRelativePath: ComparisonStatusOverride]
        let leftRoot: URL
        let rightRoot: URL
        let continuation: CheckedContinuation<[ComparisonRow], Error>
    }

    private var reconciliations: [ReconciliationRequest] = []
    var reconciliationRequestCount: Int { reconciliations.count }

    func rows(
        left: [ComparisonEntry],
        right: [ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        try ComparisonProjectionBuilder.rows(
            left: left,
            right: right,
            errors: errors,
            overrides: overrides,
            leftRoot: leftRoot,
            rightRoot: rightRoot
        )
    }

    func reconciledRows(
        _ rows: [ComparisonRow],
        left: [ComparisonRelativePath: ComparisonEntry],
        right: [ComparisonRelativePath: ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        try await withCheckedThrowingContinuation { continuation in
            reconciliations.append(ReconciliationRequest(
                rows: rows,
                left: left,
                right: right,
                errors: errors,
                overrides: overrides,
                leftRoot: leftRoot,
                rightRoot: rightRoot,
                continuation: continuation
            ))
        }
    }

    func releaseReconciliation(request index: Int) {
        guard reconciliations.indices.contains(index) else { return }
        let request = reconciliations[index]
        do {
            request.continuation.resume(returning: try ComparisonProjectionBuilder.reconcilingCurrentState(
                request.rows,
                left: request.left,
                right: request.right,
                errors: request.errors,
                overrides: request.overrides,
                leftRoot: request.leftRoot,
                rightRoot: request.rightRoot
            ))
        } catch {
            request.continuation.resume(throwing: error)
        }
    }
}

private struct ThrowingProjectionBuilder: ComparisonProjectionBuilding {
    func rows(
        left: [ComparisonEntry],
        right: [ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        throw CoordinatorTestError.projectionFailed
    }
}

@MainActor
private final class CoordinatorFixture {
    let leftRoot: URL
    let rightRoot: URL
    let otherLeft: URL
    let listing: ManualComparisonListingService
    let checksums: ManualChecksumService
    let cache: ChecksumCache
    let logger: RecordingComparisonLogger
    let workspace: WorkspaceState
    let coordinator: ComparisonCoordinator

    init(
        leftBatches: [[ComparisonListingRecord]],
        rightBatches: [[ComparisonListingRecord]],
        otherLeftBatches: [[ComparisonListingRecord]] = [],
        equalRoots: Bool = false,
        projections: any ComparisonProjectionBuilding = LiveComparisonProjectionBuilder()
    ) {
        leftRoot = URL(filePath: "/comparison/left", directoryHint: .isDirectory)
        rightRoot = URL(filePath: "/comparison/right", directoryHint: .isDirectory)
        otherLeft = URL(filePath: "/comparison/other-left", directoryHint: .isDirectory)
        listing = ManualComparisonListingService(
            batches: [leftRoot: leftBatches, rightRoot: rightBatches, otherLeft: otherLeftBatches],
            identities: [
                leftRoot: equalRoots ? "shared" : "left-root",
                rightRoot: equalRoots ? "shared" : "right-root",
                otherLeft: "other-left-root"
            ]
        )
        checksums = ManualChecksumService()
        cache = ChecksumCache()
        logger = RecordingComparisonLogger()
        workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )
        coordinator = ComparisonCoordinator(
            listings: listing,
            checksums: checksums,
            cache: cache,
            logger: logger,
            projections: projections
        )
    }

    static func twoBatchListing() throws -> CoordinatorFixture {
        let first = try entry("first.txt", root: "/comparison/left", identity: "first")
        let second = try entry("second.txt", root: "/comparison/left", identity: "second")
        return CoordinatorFixture(
            leftBatches: [[.entry(first)], [.entry(second)]],
            rightBatches: []
        )
    }

    static func lateListing() throws -> CoordinatorFixture {
        let old = try entry("old.txt", root: "/comparison/left", identity: "old")
        return CoordinatorFixture(leftBatches: [[.entry(old)]], rightBatches: [])
    }

    static func stalledChecksum() throws -> CoordinatorFixture {
        let left = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-file",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let right = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-file",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        return CoordinatorFixture(leftBatches: [[.entry(left)]], rightBatches: [[.entry(right)]])
    }

    static func changedFingerprint() throws -> CoordinatorFixture {
        let leftOld = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-old",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let rightOld = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-old",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let leftNew = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-new",
            modifiedAt: Date(timeIntervalSince1970: 3)
        )
        let rightNew = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-new",
            modifiedAt: Date(timeIntervalSince1970: 4)
        )
        return CoordinatorFixture(
            leftBatches: [[.entry(leftOld)], [.entry(leftNew)]],
            rightBatches: [[.entry(rightOld)], [.entry(rightNew)]]
        )
    }

    static func errorDuringChecksum() throws -> CoordinatorFixture {
        let left = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-file",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let right = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-file",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        return CoordinatorFixture(
            leftBatches: [[.entry(left)], [
                .failure(path: try path("ambiguous.txt"), message: "became unreadable")
            ]],
            rightBatches: [[.entry(right)]]
        )
    }

    static func checksumFollowedByBatch(
        projections: any ComparisonProjectionBuilding
    ) throws -> CoordinatorFixture {
        let left = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-file",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let right = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-file",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let later = try entry("later.txt", root: "/comparison/left", identity: "later")
        return CoordinatorFixture(
            leftBatches: [[.entry(left)], [.entry(later)]],
            rightBatches: [[.entry(right)]],
            projections: projections
        )
    }

    static func terminalChecksumRace(
        quickIdentical: Bool,
        projections: any ComparisonProjectionBuilding
    ) throws -> CoordinatorFixture {
        let left = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-file",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let right = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-file",
            modifiedAt: Date(timeIntervalSince1970: quickIdentical ? 1 : 2)
        )
        let later = try entry("later.txt", root: "/comparison/left", identity: "later")
        return CoordinatorFixture(
            leftBatches: [[.entry(left)], [.entry(later)]],
            rightBatches: [[.entry(right)]],
            projections: projections
        )
    }

    static func reconciliationPresentationRace(
        projections: any ComparisonProjectionBuilding
    ) throws -> CoordinatorFixture {
        let left = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-file",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let right = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-file",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let later = try entry("later.txt", root: "/comparison/left", identity: "later")
        return CoordinatorFixture(
            leftBatches: [
                [.entry(left)],
                [.entry(later)],
                [.failure(path: try path("ambiguous.txt"), message: "listing changed")]
            ],
            rightBatches: [[.entry(right)]],
            projections: projections
        )
    }

    static func checksumThenFingerprintChange(
        projections: any ComparisonProjectionBuilding
    ) throws -> CoordinatorFixture {
        let leftOld = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-old",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let rightOld = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-old",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let leftNew = try entry(
            "ambiguous.txt", root: "/comparison/left", identity: "left-new",
            modifiedAt: Date(timeIntervalSince1970: 3)
        )
        let rightNew = try entry(
            "ambiguous.txt", root: "/comparison/right", identity: "right-new",
            modifiedAt: Date(timeIntervalSince1970: 4)
        )
        return CoordinatorFixture(
            leftBatches: [[.entry(leftOld)], [.entry(leftNew)]],
            rightBatches: [[.entry(rightOld)], [.entry(rightNew)]],
            projections: projections
        )
    }

    static func directoryWithChangedChildren() throws -> CoordinatorFixture {
        let leftFolder = try entry("Folder", root: "/comparison/left", identity: "lf", kind: .directory)
        let rightFolder = try entry("Folder", root: "/comparison/right", identity: "rf", kind: .regularFile)
        let leftNested = try entry("Folder/Nested", root: "/comparison/left", identity: "ln", kind: .directory)
        let rightNested = try entry("Folder/Nested", root: "/comparison/right", identity: "rn", kind: .directory)
        let leftChanged = try entry("Folder/Nested/changed", root: "/comparison/left", identity: "lc", size: 1)
        let rightChanged = try entry("Folder/Nested/changed", root: "/comparison/right", identity: "rc", size: 2)
        let leftOnly = try entry("Folder/left-only", root: "/comparison/left", identity: "lo")
        return CoordinatorFixture(
            leftBatches: [[.entry(leftFolder), .entry(leftNested), .entry(leftChanged), .entry(leftOnly)]],
            rightBatches: [[.entry(rightFolder), .entry(rightNested), .entry(rightChanged)]]
        )
    }

    static func policyRows() throws -> CoordinatorFixture {
        let leftIdentical = try entry("identical.txt", root: "/comparison/left", identity: "li")
        let rightIdentical = try entry("identical.txt", root: "/comparison/right", identity: "ri")
        let leftOnly = try entry("left-only.txt", root: "/comparison/left", identity: "lo")
        return CoordinatorFixture(
            leftBatches: [[.entry(leftIdentical), .entry(leftOnly)]],
            rightBatches: [[.entry(rightIdentical)]]
        )
    }

    static func equalRoots() throws -> CoordinatorFixture {
        CoordinatorFixture(leftBatches: [], rightBatches: [], equalRoots: true)
    }

    static func errorRows() throws -> CoordinatorFixture {
        let retained = try entry("retained.txt", root: "/comparison/left", identity: "retained")
        return CoordinatorFixture(
            leftBatches: [[
                .entry(retained),
                .failure(path: try path("retained.txt"), message: "changed permissions"),
                .failure(path: try path("unreadable"), message: "permission denied")
            ]],
            rightBatches: []
        )
    }

    static func syntheticFailureSides() throws -> CoordinatorFixture {
        CoordinatorFixture(
            leftBatches: [[
                .failure(path: try path("left-failure"), message: "left denied"),
                .failure(path: try path("both-failed"), message: "left denied")
            ]],
            rightBatches: [[
                .failure(path: try path("right-failure"), message: "right denied"),
                .failure(path: try path("both-failed"), message: "right denied")
            ]]
        )
    }

    func waitForStreams(
        left: Int,
        right: Int,
        leftRoot: URL? = nil
    ) async throws {
        let actualLeftRoot = leftRoot ?? self.leftRoot
        guard await waitUntil({
            let leftCount = await self.listing.streamCount(root: actualLeftRoot)
            let rightCount = await self.listing.streamCount(root: self.rightRoot)
            return leftCount >= left && rightCount >= right
        }) else {
            throw CoordinatorTestError.timedOut("listing stream registration")
        }
    }

    func releaseAllListings() async throws {
        try await waitForStreams(left: 1, right: 1)
        await listing.releaseAll(root: leftRoot)
        await listing.releaseAll(root: rightRoot)
        await listing.finish(root: leftRoot)
        await listing.finish(root: rightRoot)
    }

    func releaseAllAndWaitForChecksum() async throws {
        try await releaseAllListings()
        guard await waitUntil({ await self.checksums.requestCount == 2 }) else {
            throw CoordinatorTestError.timedOut("checksum requests")
        }
    }

    func beginControlledChecksum(projections: ControlledProjectionBuilder) async throws {
        coordinator.start(workspace: workspace)
        try await waitForStreams(left: 1, right: 1)
        await listing.releaseNext(root: leftRoot)
        guard await waitUntil({ await projections.requestCount == 1 }) else {
            throw CoordinatorTestError.timedOut("initial projection")
        }
        await projections.release(request: 0)
        guard await waitUntil({ self.coordinator.rows.count == 1 }) else {
            throw CoordinatorTestError.timedOut("left prefix projection")
        }
        await listing.releaseNext(root: rightRoot)
        guard await waitUntil({ await projections.requestCount == 2 }) else {
            throw CoordinatorTestError.timedOut("paired projection")
        }
        await projections.release(request: 1)
        guard await waitUntil({ await self.checksums.requestCount == 2 }) else {
            throw CoordinatorTestError.timedOut("initial checksums")
        }
    }

    func beginTerminalChecksumRace(
        projections: ControlledProjectionBuilder,
        forced: Bool
    ) async throws {
        coordinator.start(workspace: workspace)
        try await waitForStreams(left: 1, right: 1)
        await listing.releaseNext(root: leftRoot)
        guard await waitUntil({ await projections.requestCount == 1 }) else {
            throw CoordinatorTestError.timedOut("left projection")
        }
        await projections.release(request: 0)
        guard await waitUntil({ self.coordinator.rows.count == 1 }) else {
            throw CoordinatorTestError.timedOut("left prefix")
        }
        await listing.releaseNext(root: rightRoot)
        guard await waitUntil({ await projections.requestCount == 2 }) else {
            throw CoordinatorTestError.timedOut("paired projection")
        }
        await projections.release(request: 1)
        guard await waitUntil({ self.coordinator.rows.first?.right != nil }) else {
            throw CoordinatorTestError.timedOut("paired row")
        }
        if forced { coordinator.verifyAll() }
        guard await waitUntil({ await self.checksums.requestCount == 2 }) else {
            throw CoordinatorTestError.timedOut("initial checksum requests")
        }
        await listing.releaseNext(root: leftRoot)
        guard await waitUntil({ await projections.requestCount == 3 }) else {
            throw CoordinatorTestError.timedOut("stale active projection")
        }
    }

    func releaseLaterProjection(projections: ControlledProjectionBuilder) async throws {
        guard await waitUntil({ await projections.requestCount == 3 }) else {
            throw CoordinatorTestError.timedOut("checksum-derived projection")
        }
        await projections.release(request: 2)
        guard await waitUntil({ await projections.completedCount == 3 }) else {
            throw CoordinatorTestError.timedOut("checksum-derived publication")
        }
        await listing.releaseNext(root: leftRoot)
        guard await waitUntil({ await projections.requestCount == 4 }) else {
            throw CoordinatorTestError.timedOut("later projection")
        }
        await projections.release(request: 3)
        guard await waitUntil({ self.coordinator.rows.contains { $0.id.string == "later.txt" } }) else {
            throw CoordinatorTestError.timedOut("later row publication")
        }
    }
}

private actor ManualComparisonListingService: ComparisonListingService {
    private struct StreamState {
        let continuation: AsyncThrowingStream<ComparisonListingBatch, Error>.Continuation
        var batches: [ComparisonListingBatch]
        var next = 0
    }

    private let configuredBatches: [URL: [[ComparisonListingRecord]]]
    private let identities: [URL: String]
    private var streams: [URL: [StreamState]] = [:]
    private(set) var requests: [ComparisonListingRequest] = []

    init(batches: [URL: [[ComparisonListingRecord]]], identities: [URL: String]) {
        configuredBatches = batches
        self.identities = identities
    }

    func identity(of root: URL) throws -> FileIdentity {
        let value = identities[root, default: root.path]
        return FileIdentity(entryIdentifier: value, resolvedIdentifier: value)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.register(request, continuation: continuation) }
        }
    }

    func streamCount(root: URL) -> Int { streams[root]?.count ?? 0 }

    func releaseNext(root: URL, stream: Int = 0) {
        guard var values = streams[root], values.indices.contains(stream) else { return }
        var value = values[stream]
        guard value.batches.indices.contains(value.next) else { return }
        value.continuation.yield(value.batches[value.next])
        value.next += 1
        values[stream] = value
        streams[root] = values
    }

    func releaseAll(root: URL, stream: Int = 0) {
        guard let count = streams[root]?[safe: stream]?.batches.count else { return }
        for _ in 0 ..< count { releaseNext(root: root, stream: stream) }
    }

    func finish(root: URL, stream: Int = 0) {
        streams[root]?[safe: stream]?.continuation.finish()
    }

    func fail(root: URL, stream: Int = 0, error: any Error) {
        streams[root]?[safe: stream]?.continuation.finish(throwing: error)
    }

    private func register(
        _ request: ComparisonListingRequest,
        continuation: AsyncThrowingStream<ComparisonListingBatch, Error>.Continuation
    ) {
        requests.append(request)
        let batches = configuredBatches[request.root, default: []].map(ComparisonListingBatch.init(records:))
        streams[request.root, default: []].append(StreamState(
            continuation: continuation,
            batches: batches
        ))
    }
}

private actor ManualChecksumService: ChecksumService {
    private struct Pending {
        let request: ChecksumRequest
        let continuation: CheckedContinuation<ChecksumResult, Error>
    }

    private var pending: [Int: Pending] = [:]
    private var requests: [ChecksumRequest] = []
    private(set) var completedCount = 0

    var requestCount: Int { requests.count }
    var pendingCount: Int { pending.count }

    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        defer { completedCount += 1 }
        let index = requests.count
        requests.append(request)
        await progress(0.25)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = Pending(request: request, continuation: continuation)
        }
    }

    func succeed(request index: Int, digest: Data) {
        pending.removeValue(forKey: index)?.continuation.resume(returning: ChecksumResult(digest: digest))
    }

    func fail(request index: Int, error: any Error) {
        pending.removeValue(forKey: index)?.continuation.resume(throwing: error)
    }

    func attemptCount(for root: URL) -> Int {
        requests.count { $0.url.path.hasPrefix(root.path) }
    }

    func firstRequestIndex(for root: URL) -> Int? {
        requests.firstIndex { $0.url.path.hasPrefix(root.path) }
    }

    func request(at index: Int) -> ChecksumRequest? {
        requests[safe: index]
    }
}

private actor RecordingComparisonLogger: ComparisonLogging {
    private(set) var events: [ComparisonLogEvent] = []
    func record(_ event: ComparisonLogEvent) { events.append(event) }
}

private func entry(
    _ relative: String,
    root: String,
    identity: String,
    kind: ComparisonEntryKind = .regularFile,
    size: Int64 = 10,
    modifiedAt: Date = Date(timeIntervalSince1970: 1)
) throws -> ComparisonEntry {
    let relativePath = try path(relative)
    return ComparisonEntry(
        relativePath: relativePath,
        url: URL(filePath: root).appending(path: relative),
        kind: kind,
        fingerprint: .init(
            identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
            byteSize: kind == .regularFile ? size : nil,
            modifiedAt: modifiedAt,
            rawModifiedAt: .init(seconds: Int64(modifiedAt.timeIntervalSince1970), nanoseconds: 0)
        ),
        symbolicLinkTarget: nil,
        typeDescription: kind.rawValue
    )
}

private func path(_ value: String) throws -> ComparisonRelativePath {
    try ComparisonRelativePath(components: value.split(separator: "/").map(String.init))
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()), clock.now < deadline {
        await Task.yield()
    }
    return await condition()
}

private func valueWithinFourSeconds<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(4))
            throw CoordinatorTestError.timedOut("four-second watchdog")
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw CoordinatorTestError.timedOut("missing watchdog result")
        }
        return value
    }
}

@MainActor
private func remainsTrueForOneSecond(
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        guard await condition() else { return false }
        await Task.yield()
    }
    return await condition()
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
