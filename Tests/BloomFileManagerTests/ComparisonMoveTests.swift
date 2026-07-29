import Foundation
import Testing
@testable import BloomFileManager

@Suite("ComparisonMoveTests")
struct ComparisonMoveTests {
    @Test func onlyOneSidedRowsPermitMoveInTheChosenDirection() throws {
        let leftOnly = try Self.row(path: "left.txt", status: .leftOnly, left: true, right: false)
        let rightOnly = try Self.row(path: "right.txt", status: .rightOnly, left: false, right: true)
        let changed = try Self.row(path: "changed.txt", status: .contentChanged, left: true, right: true)

        #expect(ComparisonActionPolicy.canMove(
            [leftOnly], direction: .leftToRight, allRows: [leftOnly, rightOnly, changed]
        ))
        #expect(!ComparisonActionPolicy.canMove(
            [rightOnly], direction: .leftToRight, allRows: [leftOnly, rightOnly, changed]
        ))
        #expect(!ComparisonActionPolicy.canMove(
            [changed], direction: .leftToRight, allRows: [leftOnly, rightOnly, changed]
        ))
        #expect(ComparisonActionPolicy.canMove(
            [rightOnly], direction: .rightToLeft, allRows: [leftOnly, rightOnly, changed]
        ))
    }

    @MainActor @Test func requestNeverStartsOperationBeforeConfirmation() async throws {
        let fixture = try await MoveFixture.make(relativePath: "report.txt")
        defer { fixture.stop() }

        #expect(fixture.coordinator.canMove(.leftToRight))
        fixture.coordinator.requestMove(direction: .leftToRight)

        let confirmation = try #require(fixture.coordinator.pendingMoveConfirmation)
        #expect(confirmation.requests.count == 1)
        #expect(confirmation.sourceRoot == fixture.leftRoot)
        #expect(confirmation.destinationRoot == fixture.rightRoot)
        #expect(!fixture.operations.isRunning)
        #expect(await fixture.fileSystem.events.isEmpty)
    }

    @MainActor @Test func cancellingConfirmationNeverStartsOperation() async throws {
        let fixture = try await MoveFixture.make(relativePath: "report.txt")
        defer { fixture.stop() }

        fixture.coordinator.requestMove(direction: .leftToRight)
        fixture.coordinator.cancelMove()
        await Task.yield()

        #expect(fixture.coordinator.pendingMoveConfirmation == nil)
        #expect(!fixture.operations.isRunning)
        #expect(await fixture.fileSystem.events.isEmpty)
    }

    @MainActor @Test func confirmationKeepsAnImmutableRequestSnapshot() async throws {
        let fixture = try await MoveFixture.make(relativePath: "A/report.txt")
        defer { fixture.stop() }

        fixture.coordinator.requestMove(direction: .leftToRight)
        let captured = try #require(fixture.coordinator.pendingMoveConfirmation)
        fixture.coordinator.selection = []

        #expect(fixture.coordinator.pendingMoveConfirmation?.requests == captured.requests)
        #expect(captured.requests.first?.relativeParentComponents == ["A"])
        #expect(captured.sessionGeneration == fixture.coordinator.session?.generation)
    }

    @MainActor @Test func restartingComparisonInvalidatesPendingConfirmation() async throws {
        let fixture = try await MoveFixture.make(relativePath: "report.txt")
        defer { fixture.stop() }

        fixture.coordinator.requestMove(direction: .leftToRight)
        #expect(fixture.coordinator.pendingMoveConfirmation != nil)
        fixture.coordinator.start(workspace: fixture.workspace)

        #expect(fixture.coordinator.pendingMoveConfirmation == nil)
        #expect(!fixture.coordinator.isMoveDispatchPending)
        #expect(!fixture.operations.isRunning)
    }

    @MainActor @Test func rootValidationImmediatelyInvalidatesPendingConfirmation() async throws {
        let fixture = try await MoveFixture.make(relativePath: "report.txt")
        defer { fixture.stop() }

        fixture.coordinator.requestMove(direction: .leftToRight)
        #expect(fixture.coordinator.pendingMoveConfirmation != nil)
        fixture.monitor.sendRootChanged(.left)

        #expect(await fixture.waitUntil {
            fixture.coordinator.pendingMoveConfirmation == nil
        })
        #expect(!fixture.operations.isRunning)
        #expect(await fixture.fileSystem.events.isEmpty)
    }

    @MainActor @Test func reconciliationInvalidatesMoveWhenRowIsNoLongerOneSided() async throws {
        let fixture = try await MoveFixture.make(relativePath: "report.txt")
        defer { fixture.stop() }
        let path = try #require(fixture.coordinator.selection.first)
        let left = try #require(fixture.coordinator.rows.first { $0.id == path }?.left)
        let destination = fixture.rightRoot.appending(path: "report.txt")
        let destinationIdentity = FileIdentity(
            entryIdentifier: "destination:report.txt",
            resolvedIdentifier: "destination:report.txt"
        )
        let right = ComparisonEntry(
            relativePath: path,
            url: destination,
            kind: .regularFile,
            fingerprint: .init(
                identity: destinationIdentity,
                byteSize: left.fingerprint.byteSize,
                modifiedAt: left.fingerprint.modifiedAt,
                rawModifiedAt: left.fingerprint.rawModifiedAt
            ),
            symbolicLinkTarget: nil,
            typeDescription: "File"
        )

        fixture.coordinator.requestMove(direction: .leftToRight)
        #expect(fixture.coordinator.pendingMoveConfirmation != nil)
        await fixture.listings.setEntries([right], for: fixture.rightRoot)
        await fixture.fileSystem.replaceIdentity(at: destination, with: destinationIdentity)
        fixture.monitor.send(.right, paths: [path])

        #expect(await fixture.waitUntil {
            fixture.coordinator.rows.first { $0.id == path }?.right != nil
        })
        #expect(fixture.coordinator.pendingMoveConfirmation == nil)
        #expect(!fixture.coordinator.isMoveDispatchPending)

        fixture.coordinator.confirmMove(
            operationController: fixture.operations,
            workspace: fixture.workspace
        )
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!fixture.operations.isRunning)
        #expect(fixture.operations.lastResult == nil)
    }

    @MainActor @Test func monitorEventCancelsConfirmedMoveBeforeRootRecheckFinishes() async throws {
        let fixture = try await MoveFixture.make(relativePath: "report.txt")
        defer {
            Task { await fixture.listings.resumeIdentity(of: fixture.leftRoot) }
            fixture.stop()
        }
        let path = try #require(fixture.coordinator.selection.first)
        await fixture.listings.stallIdentity(of: fixture.leftRoot)
        fixture.coordinator.requestMove(direction: .leftToRight)
        fixture.coordinator.confirmMove(
            operationController: fixture.operations,
            workspace: fixture.workspace
        )
        #expect(await fixture.waitUntil { fixture.coordinator.isMoveDispatchPending })
        #expect(await fixture.waitUntilAsync {
            await fixture.listings.isIdentityWaiting(for: fixture.leftRoot)
        })

        fixture.monitor.send(.right, paths: [path])
        #expect(await fixture.waitUntil { !fixture.coordinator.isMoveDispatchPending })
        await fixture.listings.resumeIdentity(of: fixture.leftRoot)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!fixture.operations.isRunning)
        #expect(fixture.operations.lastResult == nil)
        #expect(await fixture.fileSystem.events.isEmpty)
    }

    @MainActor @Test func confirmedCrossVolumeMovePreservesRelativeParents() async throws {
        let fixture = try await MoveFixture.make(relativePath: "A/B/report.txt")
        defer { fixture.stop() }

        fixture.coordinator.requestMove(direction: .leftToRight)
        fixture.coordinator.confirmMove(
            operationController: fixture.operations,
            workspace: fixture.workspace
        )

        #expect(await fixture.waitUntil { !fixture.operations.isRunning })
        #expect(await fixture.waitUntil { fixture.operations.lastResult != nil })
        #expect(fixture.operations.lastResult?.hasFailures == false)
        let destination = fixture.rightRoot.appending(path: "A/B/report.txt")
        let sourceParent = fixture.leftRoot.appending(path: "A/B", directoryHint: .isDirectory)
        #expect(await fixture.fileSystem.existingURLs.contains(destination))
        #expect(!(await fixture.fileSystem.existingURLs.contains(fixture.source)))
        #expect(await fixture.fileSystem.existingURLs.contains(sourceParent))
        #expect(await fixture.fileSystem.events.contains(
            "prepareHierarchy:\(fixture.rightRoot.path)/A/B"
        ))
    }

    @MainActor @Test func staleRootIdentityCannotDispatchConfirmedMove() async throws {
        let fixture = try await MoveFixture.make(relativePath: "report.txt")
        defer { fixture.stop() }

        fixture.coordinator.requestMove(direction: .leftToRight)
        await fixture.listings.replaceIdentity(
            of: fixture.rightRoot,
            with: FileIdentity(entryIdentifier: "replacement", resolvedIdentifier: "replacement")
        )
        fixture.coordinator.confirmMove(
            operationController: fixture.operations,
            workspace: fixture.workspace
        )
        #expect(await fixture.waitUntil { !fixture.coordinator.isMoveDispatchPending })

        #expect(!fixture.operations.isRunning)
        #expect(fixture.operations.lastResult == nil)
        #expect(await fixture.fileSystem.events.isEmpty)
    }

    @Test func movePresentationRequiresFourExplicitActionsAndAMandatorySheet() throws {
        let actionBar = try source(named: "Views/Comparison/ComparisonActionBar.swift")
        #expect(actionBar.contains("Button(\"Copy Left to Right\")"))
        #expect(actionBar.contains("Button(\"Move Left to Right…\")"))
        #expect(actionBar.contains("Button(\"Copy Right to Left\")"))
        #expect(actionBar.contains("Button(\"Move Right to Left…\")"))
        #expect(actionBar.contains(".accessibilityHint(moveHelp"))

        let workspace = try source(named: "Views/Comparison/ComparisonWorkspaceView.swift")
        #expect(workspace.contains(".sheet(item: moveConfirmationBinding)"))
        #expect(workspace.contains("confirmation.sourceRoot"))
        #expect(workspace.contains("confirmation.destinationRoot"))
        #expect(workspace.contains("verifies the copy before removing each source item"))
        #expect(workspace.contains("Button(\"Cancel\", role: .cancel"))
        #expect(workspace.contains("confirmation.representativeNames.enumerated()"))
        #expect(workspace.contains("id: \\.offset"))
        #expect(!workspace.contains("ForEach(confirmation.representativeNames, id: \\.self)"))

        let commands = try source(named: "Support/WorkspaceCommands.swift")
        #expect(commands.contains("Button(\"Move Left to Right…\")"))
        #expect(commands.contains("Button(\"Move Right to Left…\")"))
        #expect(commands.contains("comparison?.requestMove(direction:"))
        #expect(!commands.contains("confirmMove"))
    }

    private static func row(
        path string: String,
        status: ComparisonStatus,
        left: Bool,
        right: Bool
    ) throws -> ComparisonRow {
        let path = try ComparisonRelativePath(components: [string])
        func entry(_ side: String) -> ComparisonEntry {
            let token = "\(side):\(string)"
            return ComparisonEntry(
                relativePath: path,
                url: URL(filePath: "/\(side)/\(string)"),
                kind: .regularFile,
                fingerprint: .init(
                    identity: .init(entryIdentifier: token, resolvedIdentifier: token),
                    byteSize: 1,
                    modifiedAt: Date(timeIntervalSince1970: 1)
                ),
                symbolicLinkTarget: nil,
                typeDescription: "File"
            )
        }
        return ComparisonRow(
            relativePath: path,
            left: left ? entry("left") : nil,
            right: right ? entry("right") : nil,
            status: status
        )
    }

    private func source(named relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appending(path: "Sources/BloomFileManager", directoryHint: .isDirectory)
                .appending(path: relativePath),
            encoding: .utf8
        )
    }
}

private actor MutableMoveListingService: ComparisonListingService {
    private var batchesByRoot: [URL: [ComparisonListingBatch]]
    private var identities: [URL: FileIdentity]
    private var stalledIdentityRoots: Set<URL> = []
    private var identityContinuations: [URL: [CheckedContinuation<Void, Never>]] = [:]

    init(
        batchesByRoot: [URL: [ComparisonListingBatch]],
        identities: [URL: FileIdentity]
    ) {
        self.batchesByRoot = batchesByRoot
        self.identities = identities
    }

    func identity(of root: URL) async throws -> FileIdentity {
        if stalledIdentityRoots.contains(root) {
            await withCheckedContinuation { continuation in
                identityContinuations[root, default: []].append(continuation)
            }
        }
        guard let identity = identities[root] else { throw CocoaError(.fileNoSuchFile) }
        return identity
    }

    func replaceIdentity(of root: URL, with identity: FileIdentity) {
        identities[root] = identity
    }

    func stallIdentity(of root: URL) {
        stalledIdentityRoots.insert(root)
    }

    func isIdentityWaiting(for root: URL) -> Bool {
        identityContinuations[root]?.isEmpty == false
    }

    func resumeIdentity(of root: URL) {
        stalledIdentityRoots.remove(root)
        let continuations = identityContinuations.removeValue(forKey: root) ?? []
        continuations.forEach { $0.resume() }
    }

    func setEntries(_ entries: [ComparisonEntry], for root: URL) {
        batchesByRoot[root] = entries.isEmpty
            ? []
            : [.init(records: entries.map(ComparisonListingRecord.entry))]
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for batch in await self.configuredBatches(for: request.root) {
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }
    }

    private func configuredBatches(for root: URL) -> [ComparisonListingBatch] {
        batchesByRoot[root, default: []]
    }
}

@MainActor
private final class MoveFixture {
    let leftRoot = URL(filePath: "/move-left", directoryHint: .isDirectory)
    let rightRoot = URL(filePath: "/move-right", directoryHint: .isDirectory)
    let workspace: WorkspaceState
    let coordinator: ComparisonCoordinator
    let operations: FileOperationController
    let fileSystem: RecordingFileSystem
    let listings: MutableMoveListingService
    let monitor: InMemoryComparisonTreeMonitor
    let source: URL

    private init(
        workspace: WorkspaceState,
        coordinator: ComparisonCoordinator,
        operations: FileOperationController,
        fileSystem: RecordingFileSystem,
        listings: MutableMoveListingService,
        monitor: InMemoryComparisonTreeMonitor,
        source: URL
    ) {
        self.workspace = workspace
        self.coordinator = coordinator
        self.operations = operations
        self.fileSystem = fileSystem
        self.listings = listings
        self.monitor = monitor
        self.source = source
    }

    static func make(relativePath string: String) async throws -> MoveFixture {
        let leftRoot = URL(filePath: "/move-left", directoryHint: .isDirectory)
        let rightRoot = URL(filePath: "/move-right", directoryHint: .isDirectory)
        let components = string.split(separator: "/").map(String.init)
        let path = try ComparisonRelativePath(components: components)
        let source = components.reduce(leftRoot) { $0.appending(path: $1) }
        let sourceIdentity = FileIdentity(
            entryIdentifier: "source:\(string)",
            resolvedIdentifier: "source:\(string)"
        )
        let leftIdentity = FileIdentity(entryIdentifier: "left-root", resolvedIdentifier: "left-root")
        let rightIdentity = FileIdentity(entryIdentifier: "right-root", resolvedIdentifier: "right-root")
        let entry = ComparisonEntry(
            relativePath: path,
            url: source,
            kind: .regularFile,
            fingerprint: .init(
                identity: sourceIdentity,
                byteSize: 6,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "File"
        )
        let listings = MutableMoveListingService(
            batchesByRoot: [
                leftRoot: [.init(records: [.entry(entry)])],
                rightRoot: []
            ],
            identities: [leftRoot: leftIdentity, rightRoot: rightIdentity]
        )
        let workspace = WorkspaceState(
            leftURL: leftRoot,
            rightURL: rightRoot,
            listingService: StubDirectoryListingService(values: [:])
        )
        let monitor = InMemoryComparisonTreeMonitor()
        let coordinator = ComparisonCoordinator(
            listings: listings,
            checksums: InMemoryChecksumService(probe: ChecksumConcurrencyProbe()),
            monitor: monitor
        )
        let sourceParents = (1 ..< components.count).map { count in
            components.prefix(count).reduce(leftRoot) { $0.appending(path: $1, directoryHint: .isDirectory) }
        }
        let fileSystem = RecordingFileSystem(
            existingURLs: Set([leftRoot, rightRoot, source] + sourceParents),
            volumeIdentifiers: [source: "source-volume"],
            byteSizes: [source: 6],
            availableCapacities: [rightRoot: 1_000_000],
            identities: [leftRoot: leftIdentity, rightRoot: rightIdentity, source: sourceIdentity]
        )
        let operations = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let fixture = MoveFixture(
            workspace: workspace,
            coordinator: coordinator,
            operations: operations,
            fileSystem: fileSystem,
            listings: listings,
            monitor: monitor,
            source: source
        )
        coordinator.options.includeSubfolders = true
        coordinator.start(workspace: workspace)
        #expect(await fixture.waitUntil {
            coordinator.phase == .upToDate && coordinator.rows.contains { $0.id == path }
        })
        coordinator.selection = [path]
        return fixture
    }

    func stop() {
        coordinator.stop()
        operations.cancel()
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func waitUntilAsync(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0 ..< 300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
