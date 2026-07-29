import Foundation
import Observation

enum ComparisonPhase: Equatable {
    case idle
    case comparing
    case verifying
    case upToDate
    case paused
    case disconnected
}

struct ComparisonSession: Equatable, Sendable {
    let generation: UUID
    let leftRoot: URL
    let rightRoot: URL
    let leftRootIdentity: FileIdentity
    let rightRootIdentity: FileIdentity
}

private enum ComparisonCoordinatorError: Error {
    case equalRoots
}

private struct ComparisonAnnouncementSnapshot: Equatable {
    let phase: ComparisonPhase
    let rowCount: Int
}

private enum ComparisonReconciliationTarget: Hashable, Sendable {
    case root
    case subtree(ComparisonRelativePath)
}

private enum ChecksumOutcome: Sendable {
    case success(ChecksumResult, attempts: Int)
    case unstable(attempts: Int)
    case failure(String, attempts: Int)

    var attempts: Int {
        switch self {
        case let .success(_, attempts), let .unstable(attempts), let .failure(_, attempts):
            attempts
        }
    }
}

private enum ComparisonChecksumWorker {
    static func outcome(
        request: ChecksumRequest,
        checksums: any ChecksumService,
        cache: ChecksumCache,
        progress: @escaping @Sendable (Double) async -> Void
    ) async -> ChecksumOutcome {
        if let cached = await cache.value(for: request) {
            return .success(cached, attempts: 0)
        }
        for attempt in 1 ... 2 {
            do {
                let result = try await checksums.checksum(for: request, progress: progress)
                try Task.checkCancellation()
                await cache.insert(result, for: request)
                return .success(result, attempts: attempt)
            } catch is CancellationError {
                return .failure("Cancelled", attempts: attempt)
            } catch is ChecksumError {
                if attempt == 2 {
                    return .unstable(attempts: attempt)
                }
                continue
            } catch {
                return .failure(error.localizedDescription, attempts: attempt)
            }
        }
        return .unstable(attempts: 2)
    }
}

private final class WeakComparisonCoordinator: @unchecked Sendable {
    weak var value: ComparisonCoordinator?

    init(_ value: ComparisonCoordinator) {
        self.value = value
    }
}

struct ComparisonStatusOverride: Sendable {
    let leftFingerprint: ComparisonFingerprint
    let rightFingerprint: ComparisonFingerprint
    let status: ComparisonStatus
}

private struct ComparisonProjectionRequest: Sendable {
    let generation: UUID
    let revision: UInt64
    let left: [ComparisonEntry]
    let right: [ComparisonEntry]
    let errors: [ComparisonSide: [ComparisonRelativePath: String]]
    let overrides: [ComparisonRelativePath: ComparisonStatusOverride]
    let leftRoot: URL
    let rightRoot: URL
}

private struct ComparisonPresentationSnapshot: Sendable {
    let revision: UInt64
    let left: [ComparisonRelativePath: ComparisonEntry]
    let right: [ComparisonRelativePath: ComparisonEntry]
    let errors: [ComparisonSide: [ComparisonRelativePath: String]]
    let overrides: [ComparisonRelativePath: ComparisonStatusOverride]
    let leftRoot: URL
    let rightRoot: URL
}

enum ComparisonProjectionBuilder {
    private final class DifferencePrefixNode {
        var count = 0
        var children: [String: DifferencePrefixNode] = [:]
    }

    static func rows(
        left: [ComparisonEntry],
        right: [ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride] = [:],
        leftRoot: URL,
        rightRoot: URL
    ) throws -> [ComparisonRow] {
        try Task.checkCancellation()
        var matched = ComparisonMatcher.rows(left: left, right: right)
        try applyOverrides(overrides, to: &matched)
        try Task.checkCancellation()
        let overlaid = try overlayErrors(
            matched,
            errors: errors,
            leftRoot: leftRoot,
            rightRoot: rightRoot
        )
        return try applyDirectoryAggregates(overlaid)
    }

    private static func applyOverrides(
        _ overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        to rows: inout [ComparisonRow]
    ) throws {
        for index in rows.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let override = overrides[rows[index].id],
                  rows[index].left?.fingerprint == override.leftFingerprint,
                  rows[index].right?.fingerprint == override.rightFingerprint
            else { continue }
            rows[index].status = override.status
        }
    }

    private static func overlayErrors(
        _ rows: [ComparisonRow],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        leftRoot: URL,
        rightRoot: URL
    ) throws -> [ComparisonRow] {
        var values = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let paths = Set(errors.values.flatMap { $0.keys })
        for (index, path) in paths.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            var row = values[path] ?? ComparisonRow(
                relativePath: path,
                left: nil,
                right: nil,
                status: .error("Unable to compare item")
            )
            if errors[.left]?[path] != nil, row.left == nil {
                row.left = syntheticEntry(path: path, root: leftRoot, side: .left)
            }
            if errors[.right]?[path] != nil, row.right == nil {
                row.right = syntheticEntry(path: path, root: rightRoot, side: .right)
            }
            row.status = .error(
                errors[.left]?[path] ?? errors[.right]?[path] ?? "Unable to compare item"
            )
            values[path] = row
        }
        try Task.checkCancellation()
        return values.values.sorted { $0.id < $1.id }
    }

    private static func syntheticEntry(
        path: ComparisonRelativePath,
        root: URL,
        side: ComparisonSide
    ) -> ComparisonEntry {
        let url = path.components.reduce(root) { partial, component in
            partial.appending(path: component)
        }
        let identity = side == .left ? "comparison-error-left" : "comparison-error-right"
        return ComparisonEntry(
            relativePath: path,
            url: url,
            kind: .special,
            fingerprint: .init(
                identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
                byteSize: nil,
                modifiedAt: nil
            ),
            symbolicLinkTarget: nil,
            typeDescription: "Unavailable"
        )
    }

    static func applyDirectoryAggregates(
        _ rows: [ComparisonRow]
    ) throws -> [ComparisonRow] {
        let differencePrefixes = DifferencePrefixNode()
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard !isIdentical(row.status) else { continue }
            var node = differencePrefixes
            for component in row.id.parentComponents {
                if let child = node.children[component] {
                    node = child
                } else {
                    let child = DifferencePrefixNode()
                    node.children[component] = child
                    node = child
                }
                node.count += 1
            }
        }

        var projected = rows
        for index in projected.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard projected[index].left?.kind == .directory
                    || projected[index].right?.kind == .directory
            else { continue }
            var node: DifferencePrefixNode? = differencePrefixes
            for component in projected[index].id.components {
                node = node?.children[component]
                if node == nil { break }
            }
            let count = node?.count ?? 0
            projected[index].descendantDifferenceCount = count
            if count > 0, isIdentical(projected[index].status) {
                projected[index].status = .metadataChanged
            }
        }
        try Task.checkCancellation()
        return projected
    }

    static func reconcilingCurrentState(
        _ rows: [ComparisonRow],
        left: [ComparisonRelativePath: ComparisonEntry],
        right: [ComparisonRelativePath: ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) throws -> [ComparisonRow] {
        try Task.checkCancellation()
        var reconciled = rows
        var indicesByPath: [ComparisonRelativePath: Int] = [:]
        indicesByPath.reserveCapacity(rows.count)
        for index in rows.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            indicesByPath[rows[index].id] = index
        }

        for (offset, element) in overrides.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            let (path, override) = element
            guard left[path]?.fingerprint == override.leftFingerprint,
                  right[path]?.fingerprint == override.rightFingerprint,
                  let index = indicesByPath[path]
            else { continue }
            reconciled[index].status = override.status
        }

        let errorPaths = Set(errors.values.flatMap(\.keys))
        var missingRows: [ComparisonRow] = []
        missingRows.reserveCapacity(errorPaths.count)
        for (offset, path) in errorPaths.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            let message = errors[.left]?[path]
                ?? errors[.right]?[path]
                ?? "Unable to compare item"
            if let index = indicesByPath[path] {
                if errors[.left]?[path] != nil, reconciled[index].left == nil {
                    reconciled[index].left = syntheticEntry(path: path, root: leftRoot, side: .left)
                }
                if errors[.right]?[path] != nil, reconciled[index].right == nil {
                    reconciled[index].right = syntheticEntry(path: path, root: rightRoot, side: .right)
                }
                reconciled[index].status = .error(message)
                continue
            }

            var row = ComparisonRow(
                relativePath: path,
                left: left[path],
                right: right[path],
                status: .error(message)
            )
            if errors[.left]?[path] != nil, row.left == nil {
                row.left = syntheticEntry(path: path, root: leftRoot, side: .left)
            }
            if errors[.right]?[path] != nil, row.right == nil {
                row.right = syntheticEntry(path: path, root: rightRoot, side: .right)
            }
            missingRows.append(row)
        }
        guard !missingRows.isEmpty else {
            try Task.checkCancellation()
            return reconciled
        }
        try Task.checkCancellation()
        missingRows.sort { $0.id < $1.id }
        try Task.checkCancellation()
        return try mergeSorted(reconciled, missingRows)
    }

    private static func mergeSorted(
        _ existing: [ComparisonRow],
        _ missing: [ComparisonRow]
    ) throws -> [ComparisonRow] {
        var merged: [ComparisonRow] = []
        merged.reserveCapacity(existing.count + missing.count)
        var existingIndex = existing.startIndex
        var missingIndex = missing.startIndex
        var iteration = 0
        while existingIndex < existing.endIndex, missingIndex < missing.endIndex {
            if iteration.isMultiple(of: 256) { try Task.checkCancellation() }
            iteration += 1
            if existing[existingIndex].id < missing[missingIndex].id {
                merged.append(existing[existingIndex])
                existingIndex += 1
            } else {
                merged.append(missing[missingIndex])
                missingIndex += 1
            }
        }
        merged.append(contentsOf: existing[existingIndex...])
        merged.append(contentsOf: missing[missingIndex...])
        try Task.checkCancellation()
        return merged
    }

    private static func isIdentical(_ status: ComparisonStatus) -> Bool {
        status == .identical(.quick) || status == .identical(.checksum)
    }
}

protocol ComparisonProjectionBuilding: Sendable {
    func rows(
        left: [ComparisonEntry],
        right: [ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow]

    func reconciledRows(
        _ rows: [ComparisonRow],
        left: [ComparisonRelativePath: ComparisonEntry],
        right: [ComparisonRelativePath: ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow]
}

extension ComparisonProjectionBuilding {
    func reconciledRows(
        _ rows: [ComparisonRow],
        left: [ComparisonRelativePath: ComparisonEntry],
        right: [ComparisonRelativePath: ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        try ComparisonProjectionBuilder.reconcilingCurrentState(
            rows,
            left: left,
            right: right,
            errors: errors,
            overrides: overrides,
            leftRoot: leftRoot,
            rightRoot: rightRoot
        )
    }
}

struct LiveComparisonProjectionBuilder: ComparisonProjectionBuilding {
    func rows(
        left: [ComparisonEntry],
        right: [ComparisonEntry],
        errors: [ComparisonSide: [ComparisonRelativePath: String]],
        overrides: [ComparisonRelativePath: ComparisonStatusOverride],
        leftRoot: URL,
        rightRoot: URL
    ) async throws -> [ComparisonRow] {
        let worker = Task.detached(priority: .userInitiated) {
            try ComparisonProjectionBuilder.rows(
                left: left,
                right: right,
                errors: errors,
                overrides: overrides,
                leftRoot: leftRoot,
                rightRoot: rightRoot
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
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
        let worker = Task.detached(priority: .userInitiated) {
            try ComparisonProjectionBuilder.reconcilingCurrentState(
                rows,
                left: left,
                right: right,
                errors: errors,
                overrides: overrides,
                leftRoot: leftRoot,
                rightRoot: rightRoot
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

@MainActor
@Observable
final class ComparisonCoordinator {
    private let listings: any ComparisonListingService
    private let checksums: any ChecksumService
    private let cache: ChecksumCache
    private let logger: any ComparisonLogging
    private let projections: any ComparisonProjectionBuilding
    private let monitor: any ComparisonTreeMonitor
    private let announcementPoster: any ComparisonAnnouncementPosting
    private let announcementDelay: Duration

    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var rootIdentityTask: Task<Void, Never>?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var moveVolumeTask: Task<Void, Never>?
    @ObservationIgnored private var moveDispatchTask: Task<Void, Never>?
    @ObservationIgnored private var moveDispatchToken: UUID?
    @ObservationIgnored private var checksumTasks: [ComparisonRelativePath: Task<Void, Never>] = [:]
    @ObservationIgnored private var checksumTokens: [ComparisonRelativePath: UUID] = [:]
    @ObservationIgnored private var leftEntries: [ComparisonRelativePath: ComparisonEntry] = [:]
    @ObservationIgnored private var rightEntries: [ComparisonRelativePath: ComparisonEntry] = [:]
    @ObservationIgnored private var errors: [ComparisonSide: [ComparisonRelativePath: String]] = [
        .left: [:], .right: [:]
    ]
    @ObservationIgnored private var statusOverrides: [ComparisonRelativePath: ComparisonStatusOverride] = [:]
    @ObservationIgnored private var currentGeneration: UUID?
    @ObservationIgnored private var listingFinishedGeneration: UUID?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var checksumCount = 0
    @ObservationIgnored private var additionalErrorCount = 0
    @ObservationIgnored private var loggedGeneration: UUID?
    @ObservationIgnored private var projectionRevision: UInt64 = 0
    @ObservationIgnored private var activeProjectionRevision: UInt64?
    @ObservationIgnored private var pendingProjection: ComparisonProjectionRequest?
    @ObservationIgnored private var publishedProjectionRevision: UInt64 = 0
    @ObservationIgnored private var presentationRevision: UInt64 = 0
    @ObservationIgnored private var pendingReconciliations: [
        ComparisonSide: Set<ComparisonReconciliationTarget>
    ] = [:]
    @ObservationIgnored private var reconciliationRevision: UInt64 = 0
    @ObservationIgnored private var currentWorkspace: WorkspaceState?
    @ObservationIgnored private var validationToken: UUID?
    @ObservationIgnored private var activeMonitorEpoch: UUID?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAnnouncement: ComparisonAnnouncementSnapshot?
    @ObservationIgnored private var lastAnnounced: ComparisonAnnouncementSnapshot?

    private(set) var session: ComparisonSession?
    private(set) var phase: ComparisonPhase = .idle {
        didSet {
            if phase != oldValue { comparisonSummaryDidChange() }
        }
    }
    private(set) var rows: [ComparisonRow] = [] {
        didSet {
            if rows.count != oldValue.count { comparisonSummaryDidChange() }
        }
    }
    private(set) var pendingMoveConfirmation: ComparisonMoveConfirmation?
    private(set) var isMoveDispatchPending = false
    var selection: Set<ComparisonRelativePath> = []
    var filter: ComparisonFilter = .differences
    var options = ComparisonOptions()

    var isActive: Bool { session != nil }
    var actionsAreEnabled: Bool { phase == .upToDate || phase == .verifying }
    var visibleRows: [ComparisonRow] { rows.filter { filter.includes($0.status) } }
    var canVerifySelected: Bool {
        actionsAreEnabled && rows.contains {
            selection.contains($0.id)
                && $0.left?.kind == .regularFile
                && $0.right?.kind == .regularFile
                && !Self.verificationIsBlocked($0.status)
        }
    }

    init(
        listings: any ComparisonListingService,
        checksums: any ChecksumService,
        cache: ChecksumCache = ChecksumCache(),
        logger: any ComparisonLogging = LiveComparisonLogger(),
        projections: any ComparisonProjectionBuilding = LiveComparisonProjectionBuilder(),
        monitor: any ComparisonTreeMonitor = LiveComparisonTreeMonitor(),
        announcementPoster: any ComparisonAnnouncementPosting = LiveComparisonAnnouncementPoster(),
        announcementDelay: Duration = .milliseconds(500)
    ) {
        self.listings = listings
        self.checksums = checksums
        self.cache = cache
        self.logger = logger
        self.projections = projections
        self.monitor = monitor
        self.announcementPoster = announcementPoster
        self.announcementDelay = announcementDelay
    }

    func start(workspace: WorkspaceState) {
        finishMetricsIfNeeded(cancelled: true)
        stopTasksOnly()
        resetProjection()

        let generation = UUID()
        currentWorkspace = workspace
        currentGeneration = generation
        resetAnnouncements()
        phase = .comparing
        startedAt = Date()
        loggedGeneration = nil
        let cache = cache

        sessionTask = Task { [weak self, workspace] in
            guard let self else { return }
            await cache.removeAll()
            do {
                let roots = try await captureRootSession(
                    workspace: workspace,
                    generation: generation
                )
                await runCapturedSession(roots, workspace: workspace)
            } catch ComparisonCoordinatorError.equalRoots {
                guard currentGeneration == generation else { return }
                additionalErrorCount += 1
                session = nil
                phase = .paused
                finishMetricsIfNeeded(cancelled: false)
            } catch {
                guard currentGeneration == generation else { return }
                additionalErrorCount += 1
                session = nil
                phase = .disconnected
                finishMetricsIfNeeded(cancelled: false)
            }
        }
    }

    private func runCapturedSession(
        _ roots: ComparisonSession,
        workspace: WorkspaceState,
        startMonitor: Bool = true
    ) async {
        let generation = roots.generation
        guard currentGeneration == generation,
              validationToken == nil,
              phase != .paused,
              !Task.isCancelled
        else { return }
        session = roots
        if startMonitor {
            await startMonitoring(roots: roots)
            guard currentGeneration == generation,
                  validationToken == nil,
                  phase != .paused,
                  !Task.isCancelled
            else { return }
        }

        async let left: Void = consume(
            side: .left,
            root: roots.leftRoot,
            seed: workspace.left.items,
            generation: generation
        )
        async let right: Void = consume(
            side: .right,
            root: roots.rightRoot,
            seed: workspace.right.items,
            generation: generation
        )
        _ = await (left, right)

        guard currentGeneration == generation,
              validationToken == nil,
              phase != .paused,
              !Task.isCancelled
        else { return }
        listingFinishedGeneration = generation
        scheduleReconciliationIfNeeded(generation: generation)
        if phase == .paused {
            finishMetricsIfNeeded(cancelled: false)
        } else {
            updateCompletionPhase(generation: generation)
        }
    }

    func rootsDidChange(workspace: WorkspaceState) {
        start(workspace: workspace)
    }

    func stop() {
        finishMetricsIfNeeded(cancelled: true)
        currentGeneration = nil
        stopTasksOnly()
        session = nil
        currentWorkspace = nil
        phase = .idle
        resetProjection()
        Task { await cache.removeAll() }
    }

    func verifySelected() {
        guard let generation = session?.generation else { return }
        rows.filter { selection.contains($0.id) }.forEach {
            verify($0, generation: generation, forced: true)
        }
        selection.formIntersection(rows.map(\.id))
    }

    func verifyAll() {
        guard let generation = session?.generation else { return }
        rows.forEach { verify($0, generation: generation, forced: true) }
    }

    func canCopy(_ direction: ComparisonDirection) -> Bool {
        guard actionsAreEnabled else { return false }
        let selected = rows.filter { selection.contains($0.id) }
        return ComparisonActionPolicy.canCopy(
            selected,
            direction: direction,
            allRows: rows
        )
    }

    func canMove(_ direction: ComparisonDirection) -> Bool {
        guard actionsAreEnabled, !isMoveDispatchPending else { return false }
        let selected = rows.filter { selection.contains($0.id) }
        return ComparisonActionPolicy.canMove(
            selected,
            direction: direction,
            allRows: rows
        )
    }

    func moveBlockReason(_ direction: ComparisonDirection) -> String? {
        guard actionsAreEnabled else {
            return "Wait for comparison to finish before moving items."
        }
        guard !isMoveDispatchPending else {
            return "A confirmed move is being prepared."
        }
        let selected = rows.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return "Select one or more items to move." }
        if let reason = ComparisonActionPolicy.moveBlockReason(selected, direction) {
            return reason
        }
        guard ComparisonActionPolicy.canMove(
            selected,
            direction: direction,
            allRows: rows
        ) else {
            return "A destination ancestor prevents this move."
        }
        return nil
    }

    func requestMove(direction: ComparisonDirection) {
        guard canMove(direction), let session else { return }
        let requests = identifiedRequests(direction: direction, session: session)
        guard !requests.isEmpty else { return }

        moveVolumeTask?.cancel()
        let sourceRoot = direction == .leftToRight ? session.leftRoot : session.rightRoot
        let destinationRoot = direction == .leftToRight ? session.rightRoot : session.leftRoot
        let sourceRootIdentity = direction == .leftToRight
            ? session.leftRootIdentity
            : session.rightRootIdentity
        let destinationRootIdentity = direction == .leftToRight
            ? session.rightRootIdentity
            : session.leftRootIdentity
        let confirmation = ComparisonMoveConfirmation(
            direction: direction,
            requests: requests,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceRootIdentity: sourceRootIdentity,
            destinationRootIdentity: destinationRootIdentity,
            sessionGeneration: session.generation,
            representativeNames: requests.prefix(3).map { $0.source.lastPathComponent },
            crossesVolumes: nil
        )
        pendingMoveConfirmation = confirmation
        moveVolumeTask = Task { [weak self] in
            let crossesVolumes = await Self.crossesVolumes(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
            guard !Task.isCancelled,
                  let self,
                  self.pendingMoveConfirmation?.id == confirmation.id
            else { return }
            self.pendingMoveConfirmation = confirmation.updatingCrossVolumeStatus(crossesVolumes)
            self.moveVolumeTask = nil
        }
    }

    func cancelMove() {
        moveVolumeTask?.cancel()
        moveVolumeTask = nil
        pendingMoveConfirmation = nil
    }

    func confirmMove(
        operationController: FileOperationController,
        workspace: WorkspaceState
    ) {
        guard let confirmation = pendingMoveConfirmation,
              confirmationMatchesCurrentSession(confirmation),
              confirmationRequestsRemainEligible(confirmation),
              currentWorkspace === workspace,
              workspace.left.currentDirectory == confirmationRoot(
                  side: .left,
                  confirmation: confirmation
              ),
              workspace.right.currentDirectory == confirmationRoot(
                  side: .right,
                  confirmation: confirmation
              ),
              moveDispatchTask == nil
        else {
            cancelMove()
            return
        }

        moveVolumeTask?.cancel()
        moveVolumeTask = nil
        pendingMoveConfirmation = nil
        isMoveDispatchPending = true
        let token = UUID()
        moveDispatchToken = token
        let listings = listings
        moveDispatchTask = Task { [weak self, weak operationController, weak workspace] in
            do {
                async let sourceIdentity = listings.identity(of: confirmation.sourceRoot)
                async let destinationIdentity = listings.identity(of: confirmation.destinationRoot)
                let identities = try await (sourceIdentity, destinationIdentity)
                try Task.checkCancellation()
                guard let self,
                      let operationController,
                      let workspace,
                      self.moveDispatchToken == token,
                      self.confirmationMatchesCurrentSession(confirmation),
                      self.confirmationRequestsRemainEligible(confirmation),
                      self.currentWorkspace === workspace,
                      workspace.left.currentDirectory == self.confirmationRoot(
                          side: .left,
                          confirmation: confirmation
                      ),
                      workspace.right.currentDirectory == self.confirmationRoot(
                          side: .right,
                          confirmation: confirmation
                      ),
                      identities.0 == confirmation.sourceRootIdentity,
                      identities.1 == confirmation.destinationRootIdentity
                else {
                    self?.finishMoveDispatch(token: token)
                    return
                }

                self.finishMoveDispatch(token: token)
                _ = operationController.runIdentifiedTransfer(
                    confirmation.requests,
                    mode: .move,
                    workspace: workspace,
                    onCompletion: { [weak self] _ in
                        self?.reconcile(confirmation.requests)
                    }
                )
            } catch {
                self?.finishMoveDispatch(token: token)
            }
        }
    }

    @discardableResult
    func copy(
        direction: ComparisonDirection,
        operationController: FileOperationController,
        workspace: WorkspaceState
    ) -> Bool {
        guard canCopy(direction), let session else { return false }
        let requests = identifiedRequests(direction: direction, session: session)
        return operationController.runIdentifiedTransfer(
            requests,
            mode: .copy,
            workspace: workspace,
            onCompletion: { [weak self] _ in
                self?.reconcile(requests)
            }
        )
    }

    private func identifiedRequests(
        direction: ComparisonDirection,
        session: ComparisonSession
    ) -> [IdentifiedTransferRequest] {
        let destinationRoot = direction == .leftToRight
            ? session.rightRoot
            : session.leftRoot
        let destinationIdentity = direction == .leftToRight
            ? session.rightRootIdentity
            : session.leftRootIdentity
        let selected = rows.filter { selection.contains($0.id) }
        let selectedSourceDirectories = selected.compactMap { row in
            row.source(for: direction)?.kind == .directory ? row.id : nil
        }
        return selected.filter { row in
            !selectedSourceDirectories.contains { ancestor in
                row.id.isDescendant(of: ancestor)
            }
        }.compactMap { row in
            guard let source = row.source(for: direction) else { return nil }
            return IdentifiedTransferRequest(
                source: source.url,
                sourceIdentity: source.fingerprint.identity,
                destinationRoot: destinationRoot,
                destinationRootIdentity: destinationIdentity,
                relativeParentComponents: row.relativePath.parentComponents
            )
        }
    }

    private func confirmationMatchesCurrentSession(
        _ confirmation: ComparisonMoveConfirmation
    ) -> Bool {
        guard actionsAreEnabled,
              let session,
              session.generation == confirmation.sessionGeneration
        else { return false }
        switch confirmation.direction {
        case .leftToRight:
            return session.leftRoot == confirmation.sourceRoot
                && session.rightRoot == confirmation.destinationRoot
                && session.leftRootIdentity == confirmation.sourceRootIdentity
                && session.rightRootIdentity == confirmation.destinationRootIdentity
        case .rightToLeft:
            return session.rightRoot == confirmation.sourceRoot
                && session.leftRoot == confirmation.destinationRoot
                && session.rightRootIdentity == confirmation.sourceRootIdentity
                && session.leftRootIdentity == confirmation.destinationRootIdentity
        }
    }

    private func confirmationRequestsRemainEligible(
        _ confirmation: ComparisonMoveConfirmation
    ) -> Bool {
        guard !confirmation.requests.isEmpty else { return false }
        let rowsByPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var capturedRows: [ComparisonRow] = []
        capturedRows.reserveCapacity(confirmation.requests.count)
        var capturedPaths: Set<ComparisonRelativePath> = []

        for request in confirmation.requests {
            guard request.destinationRoot == confirmation.destinationRoot,
                  request.destinationRootIdentity == confirmation.destinationRootIdentity,
                  let path = try? ComparisonRelativePath(
                      components: request.relativeParentComponents + [request.source.lastPathComponent]
                  ),
                  capturedPaths.insert(path).inserted,
                  let row = rowsByPath[path],
                  let source = row.source(for: confirmation.direction),
                  source.url.standardizedFileURL == request.source.standardizedFileURL,
                  source.fingerprint.identity == request.sourceIdentity
            else { return false }
            capturedRows.append(row)
        }

        return ComparisonActionPolicy.canMove(
            capturedRows,
            direction: confirmation.direction,
            allRows: rows
        )
    }

    private func confirmationRoot(
        side: PaneID,
        confirmation: ComparisonMoveConfirmation
    ) -> URL {
        switch (side, confirmation.direction) {
        case (.left, .leftToRight), (.right, .rightToLeft):
            confirmation.sourceRoot
        case (.right, .leftToRight), (.left, .rightToLeft):
            confirmation.destinationRoot
        }
    }

    private func finishMoveDispatch(token: UUID) {
        guard moveDispatchToken == token else { return }
        moveDispatchToken = nil
        moveDispatchTask = nil
        isMoveDispatchPending = false
    }

    private static func crossesVolumes(
        sourceRoot: URL,
        destinationRoot: URL
    ) async -> Bool? {
        await Task.detached(priority: .utility) { () -> Bool? in
            do {
                let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
                let source = try sourceRoot.resourceValues(forKeys: keys).volumeIdentifier
                let destination = try destinationRoot.resourceValues(forKeys: keys).volumeIdentifier
                guard let source, let destination else { return nil }
                return try VolumeIdentifierNormalizer.normalize(source)
                    != VolumeIdentifierNormalizer.normalize(destination)
            } catch {
                return nil
            }
        }.value
    }

    private func reconcile(_ requests: [IdentifiedTransferRequest]) {
        guard let session,
              requests.allSatisfy({ request in
                  (request.destinationRoot == session.leftRoot
                      && request.destinationRootIdentity == session.leftRootIdentity)
                      || (request.destinationRoot == session.rightRoot
                          && request.destinationRootIdentity == session.rightRootIdentity)
              })
        else { return }
        let generation = session.generation
        if requests.contains(where: { $0.relativeParentComponents.isEmpty }) {
            restartCurrentRoots()
            return
        }
        let parents = Set(requests.compactMap { request in
            try? ComparisonRelativePath(components: request.relativeParentComponents)
        })
        enqueueReconciliation(side: .left, subtrees: parents, generation: generation)
        enqueueReconciliation(side: .right, subtrees: parents, generation: generation)
    }

    private func restartCurrentRoots() {
        guard let currentWorkspace else { return }
        start(workspace: currentWorkspace)
    }

    private func enqueueReconciliation(
        side: ComparisonSide,
        subtrees: Set<ComparisonRelativePath>,
        generation: UUID
    ) {
        guard currentGeneration == generation, session?.generation == generation else { return }
        invalidateMoveIntent()
        reconciliationRevision &+= 1
        let targets = Set(subtrees.map(ComparisonReconciliationTarget.subtree))
        pendingReconciliations[side, default: []].formUnion(targets)
        scheduleReconciliationIfNeeded(generation: generation)
    }

    private func startMonitoring(roots: ComparisonSession) async {
        let epoch = UUID()
        activeMonitorEpoch = epoch
        let startup = await monitor.start(roots: [
            .left: roots.leftRoot,
            .right: roots.rightRoot
        ])
        guard activeMonitorEpoch == epoch, !Task.isCancelled else {
            if case let .started(stream) = startup {
                cancelUnusedMonitorStream(stream)
            }
            return
        }
        switch startup {
        case .failed:
            monitorDidTerminate(epoch: epoch)
        case let .started(stream):
            monitorTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    self?.receiveMonitoredEvent(event, epoch: epoch)
                }
                self?.monitorDidTerminate(epoch: epoch)
            }
        }
    }

    private func cancelUnusedMonitorStream(_ stream: AsyncStream<ComparisonTreeEvent>) {
        let task = Task { for await _ in stream {} }
        task.cancel()
    }

    private func monitorDidTerminate(epoch: UUID) {
        guard activeMonitorEpoch == epoch else { return }
        activeMonitorEpoch = nil
        if let validationToken {
            invalidateRootValidation(validationToken)
            return
        }
        guard let generation = currentGeneration,
              session?.generation == generation
        else { return }
        disconnect(generation: generation)
    }

    private func receiveMonitoredEvent(_ event: ComparisonTreeEvent, epoch: UUID) {
        guard activeMonitorEpoch == epoch else { return }
        if let validationToken {
            invalidateRootValidation(validationToken)
            return
        }
        guard let generation = currentGeneration,
              session?.generation == generation
        else { return }
        receive(event, generation: generation)
    }

    private func receive(_ event: ComparisonTreeEvent, generation: UUID) {
        guard currentGeneration == generation, session?.generation == generation else { return }
        if event.rootChanged {
            recheckRootIdentity(side: event.side, generation: generation)
            return
        }
        guard event.requiresFullScan || !event.relativePaths.isEmpty else { return }
        invalidateMoveIntent()
        reconciliationRevision &+= 1
        let targets: Set<ComparisonReconciliationTarget>
        if event.requiresFullScan {
            targets = [.root]
        } else if options.includeSubfolders {
            targets = Set(event.relativePaths.map { path in
                guard !path.parentComponents.isEmpty,
                      let parent = try? ComparisonRelativePath(components: path.parentComponents)
                else { return .root }
                return .subtree(parent)
            })
        } else {
            targets = [.root]
        }
        pendingReconciliations[event.side, default: []].formUnion(targets)
        scheduleReconciliationIfNeeded(generation: generation)
    }

    private func scheduleReconciliationIfNeeded(generation: UUID) {
        guard currentGeneration == generation,
              validationToken == nil,
              phase != .paused,
              listingFinishedGeneration == generation,
              reconciliationTask == nil,
              !pendingReconciliations.isEmpty
        else { return }
        reconciliationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                await self.reconcilePendingChanges(generation: generation)
                self.finishReconciliationPass(generation: generation)
            } catch {
                self?.finishReconciliationPass(generation: generation)
            }
        }
    }

    private func finishReconciliationPass(generation: UUID) {
        guard currentGeneration == generation else { return }
        reconciliationTask = nil
        scheduleReconciliationIfNeeded(generation: generation)
    }

    private func reconcilePendingChanges(generation: UUID) async {
        guard currentGeneration == generation,
              validationToken == nil,
              phase != .paused,
              let session
        else { return }
        let pending = pendingReconciliations
        pendingReconciliations.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else { return }
        let acceptedRevision = reconciliationRevision
        phase = .comparing

        for (side, rawTargets) in pending {
            guard currentGeneration == generation, !Task.isCancelled else { return }
            let targets = normalizedTargets(rawTargets)
            invalidate(side: side, targets: targets)
            let root = side == .left ? session.leftRoot : session.rightRoot
            let requests = targets.map { target in
                ComparisonListingRequest(
                    root: root,
                    seed: nil,
                    subtree: target.subtree,
                    options: options
                )
            }
            do {
                let records = try await collectReconciliationRecords(requests)
                guard currentGeneration == generation,
                      self.session?.generation == generation,
                      validationToken == nil,
                      phase != .paused,
                      reconciliationRevision == acceptedRevision,
                      !Task.isCancelled
                else { return }
                apply(records: records, side: side)
            } catch is CancellationError {
                return
            } catch {
                await handleReconciliationFailure(side: side, generation: generation)
                return
            }
        }
        guard currentGeneration == generation,
              validationToken == nil,
              phase != .paused,
              reconciliationRevision == acceptedRevision,
              !Task.isCancelled
        else { return }
        publishRows(generation: generation)
        updateCompletionPhase(generation: generation)
    }

    private func collectReconciliationRecords(
        _ requests: [ComparisonListingRequest]
    ) async throws -> [ComparisonListingRecord] {
        let listings = listings
        let worker = Task.detached(priority: .userInitiated) {
            var records: [ComparisonListingRecord] = []
            for request in requests {
                try Task.checkCancellation()
                for try await batch in listings.batches(for: request) {
                    try Task.checkCancellation()
                    records.append(contentsOf: batch.records)
                }
            }
            return records
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func normalizedTargets(
        _ targets: Set<ComparisonReconciliationTarget>
    ) -> [ComparisonReconciliationTarget] {
        guard !targets.contains(.root) else { return [.root] }
        let paths = targets.compactMap(\.subtree).sorted {
            if $0.components.count != $1.components.count {
                return $0.components.count < $1.components.count
            }
            return $0 < $1
        }
        var kept: [ComparisonRelativePath] = []
        for path in paths where !kept.contains(where: { path.isDescendant(of: $0) }) {
            kept.append(path)
        }
        return kept.map(ComparisonReconciliationTarget.subtree)
    }

    private func invalidate(
        side: ComparisonSide,
        targets: [ComparisonReconciliationTarget]
    ) {
        let affected: (ComparisonRelativePath) -> Bool = { path in
            targets.contains { $0.containsForRelisting(path) }
        }
        if side == .left {
            leftEntries = leftEntries.filter { !affected($0.key) }
        } else {
            rightEntries = rightEntries.filter { !affected($0.key) }
        }
        errors[side] = errors[side, default: [:]].filter { !affected($0.key) }
        for path in Set(statusOverrides.keys).filter(affected) {
            statusOverrides[path] = nil
        }
        for path in Set(checksumTasks.keys).filter(affected) {
            checksumTasks.removeValue(forKey: path)?.cancel()
            checksumTokens[path] = nil
        }
        presentationRevision &+= 1
        projectionRevision &+= 1
        projectionTask?.cancel()
        projectionTask = nil
        activeProjectionRevision = nil
        pendingProjection = nil
    }

    private func apply(records: [ComparisonListingRecord], side: ComparisonSide) {
        for record in records {
            switch record {
            case let .entry(entry):
                if side == .left {
                    leftEntries[entry.relativePath] = entry
                } else {
                    rightEntries[entry.relativePath] = entry
                }
                discardOverrideIfFingerprintsChanged(at: entry.relativePath)
            case let .failure(path, message):
                errors[side, default: [:]][path] = message
            }
        }
    }

    private func recheckRootIdentity(side: ComparisonSide, generation: UUID) {
        guard rootIdentityTask == nil,
              validationToken == nil,
              let session,
              session.generation == generation,
              let workspace = currentWorkspace
        else { return }
        let root = side == .left ? session.leftRoot : session.rightRoot
        let expected = side == .left ? session.leftRootIdentity : session.rightRootIdentity
        let listings = listings
        let token = UUID()
        freezeForRootValidation(token: token)
        rootIdentityTask = Task { [weak self] in
            do {
                let current = try await listings.identity(of: root)
                guard let self, self.isValidating(token: token, generation: generation)
                else { return }
                guard current == expected else {
                    self.invalidateRootValidation(token)
                    return
                }
                let nextGeneration = UUID()
                let recaptured = try await self.captureRootSession(
                    workspace: workspace,
                    generation: nextGeneration
                )
                guard self.isValidating(token: token, generation: generation)
                else { return }
                guard recaptured.leftRoot == session.leftRoot,
                      recaptured.rightRoot == session.rightRoot,
                      recaptured.leftRootIdentity == session.leftRootIdentity,
                      recaptured.rightRootIdentity == session.rightRootIdentity
                else {
                    self.invalidateRootValidation(token)
                    return
                }

                await self.cache.removeAll()
                guard self.isValidating(token: token, generation: generation)
                else { return }

                await self.startMonitoring(roots: recaptured)
                guard self.isValidating(token: token, generation: generation)
                else { return }

                let finalCapture = try await self.captureRootSession(
                    workspace: workspace,
                    generation: nextGeneration
                )
                guard self.isValidating(token: token, generation: generation)
                else { return }
                guard finalCapture.leftRoot == session.leftRoot,
                      finalCapture.rightRoot == session.rightRoot,
                      finalCapture.leftRootIdentity == session.leftRootIdentity,
                      finalCapture.rightRootIdentity == session.rightRootIdentity
                else {
                    self.invalidateRootValidation(token)
                    return
                }

                self.finishValidatedRestart(
                    workspace: workspace,
                    roots: finalCapture,
                    replacing: generation,
                    token: token
                )
            } catch {
                guard let self, self.isValidating(token: token, generation: generation)
                else { return }
                self.invalidateRootValidation(token)
            }
        }
    }

    private func freezeForRootValidation(token: UUID) {
        validationToken = token
        phase = .paused
        invalidateMoveIntent()

        sessionTask?.cancel()
        sessionTask = nil
        activeMonitorEpoch = nil
        monitorTask?.cancel()
        monitorTask = nil

        reconciliationRevision &+= 1
        reconciliationTask?.cancel()
        reconciliationTask = nil
        pendingReconciliations.removeAll()

        presentationRevision &+= 1
        projectionRevision &+= 1
        projectionTask?.cancel()
        projectionTask = nil
        activeProjectionRevision = nil
        pendingProjection = nil

        checksumTasks.values.forEach { $0.cancel() }
        checksumTasks.removeAll()
        checksumTokens.removeAll()
        listingFinishedGeneration = nil
    }

    private func isValidating(token: UUID, generation: UUID) -> Bool {
        validationToken == token
            && currentGeneration == generation
            && session?.generation == generation
            && !Task.isCancelled
    }

    private func invalidateRootValidation(_ token: UUID) {
        guard validationToken == token, let generation = currentGeneration else { return }
        disconnect(generation: generation)
    }

    private func finishValidatedRestart(
        workspace: WorkspaceState,
        roots: ComparisonSession,
        replacing generation: UUID,
        token: UUID
    ) {
        guard isValidating(token: token, generation: generation) else { return }
        rootIdentityTask = nil
        finishMetricsIfNeeded(cancelled: true)
        resetProjection()

        currentWorkspace = workspace
        currentGeneration = roots.generation
        validationToken = nil
        session = roots
        phase = .comparing
        startedAt = Date()
        loggedGeneration = nil
        sessionTask = Task { [weak self, workspace] in
            guard let self else { return }
            await self.runCapturedSession(
                roots,
                workspace: workspace,
                startMonitor: false
            )
        }
    }

    private func handleReconciliationFailure(
        side: ComparisonSide,
        generation: UUID
    ) async {
        guard validationToken == nil,
              phase != .paused,
              let session,
              session.generation == generation
        else { return }
        let root = side == .left ? session.leftRoot : session.rightRoot
        let expected = side == .left ? session.leftRootIdentity : session.rightRootIdentity
        do {
            let current = try await listings.identity(of: root)
            guard currentGeneration == generation,
                  validationToken == nil,
                  phase != .paused
            else { return }
            if current != expected {
                disconnect(generation: generation)
            } else {
                pause(generation: generation)
            }
        } catch {
            disconnect(generation: generation)
        }
    }

    private func disconnect(generation: UUID) {
        guard currentGeneration == generation else { return }
        additionalErrorCount += 1
        finishMetricsIfNeeded(cancelled: false)
        stopTasksOnly()
        currentGeneration = nil
        phase = .disconnected
        Task { await cache.removeAll() }
    }

    private func captureRootSession(
        workspace: WorkspaceState,
        generation: UUID
    ) async throws -> ComparisonSession {
        let leftRoot = workspace.left.currentDirectory
        let rightRoot = workspace.right.currentDirectory
        async let leftIdentity = listings.identity(of: leftRoot)
        async let rightIdentity = listings.identity(of: rightRoot)
        let identities = try await (leftIdentity, rightIdentity)
        guard !identities.0.refersToSameItem(as: identities.1) else {
            throw ComparisonCoordinatorError.equalRoots
        }
        return ComparisonSession(
            generation: generation,
            leftRoot: leftRoot,
            rightRoot: rightRoot,
            leftRootIdentity: identities.0,
            rightRootIdentity: identities.1
        )
    }

    private func consume(
        side: ComparisonSide,
        root: URL,
        seed: [FileItem]?,
        subtree: ComparisonRelativePath? = nil,
        generation: UUID
    ) async {
        let request = ComparisonListingRequest(
            root: root,
            seed: seed,
            subtree: subtree,
            options: options
        )
        do {
            for try await batch in listings.batches(for: request) {
                guard currentGeneration == generation,
                      validationToken == nil,
                      phase != .paused
                else { return }
                for record in batch.records {
                    switch record {
                    case let .entry(entry):
                        if side == .left {
                            leftEntries[entry.relativePath] = entry
                        } else {
                            rightEntries[entry.relativePath] = entry
                        }
                        discardOverrideIfFingerprintsChanged(at: entry.relativePath)
                    case let .failure(path, message):
                        if errors[side]?[path] != message {
                            errors[side, default: [:]][path] = message
                            presentationRevision &+= 1
                        }
                    }
                }
                publishRows(generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard currentGeneration == generation,
                  validationToken == nil,
                  phase != .paused
            else { return }
            pause(generation: generation)
        }
    }

    private func publishRows(generation: UUID) {
        guard currentGeneration == generation,
              validationToken == nil,
              phase != .paused,
              let session,
              session.generation == generation
        else { return }
        projectionRevision &+= 1
        let request = ComparisonProjectionRequest(
            generation: generation,
            revision: projectionRevision,
            left: Array(leftEntries.values),
            right: Array(rightEntries.values),
            errors: errors,
            overrides: statusOverrides,
            leftRoot: session.leftRoot,
            rightRoot: session.rightRoot
        )
        guard activeProjectionRevision == nil else {
            pendingProjection = request
            return
        }
        startProjection(request)
    }

    private func startProjection(_ request: ComparisonProjectionRequest) {
        let projections = projections
        activeProjectionRevision = request.revision
        projectionTask = Task { [weak self] in
            do {
                let projected = try await projections.rows(
                    left: request.left,
                    right: request.right,
                    errors: request.errors,
                    overrides: request.overrides,
                    leftRoot: request.leftRoot,
                    rightRoot: request.rightRoot
                )
                while !Task.isCancelled {
                    guard let snapshot = self?.presentationSnapshot(for: request) else { return }
                    let reconciled = try await projections.reconciledRows(
                        projected,
                        left: snapshot.left,
                        right: snapshot.right,
                        errors: snapshot.errors,
                        overrides: snapshot.overrides,
                        leftRoot: snapshot.leftRoot,
                        rightRoot: snapshot.rightRoot
                    )
                    try Task.checkCancellation()
                    guard let shouldRetry = self?.receiveProjection(
                        reconciled,
                        request: request,
                        presentationRevision: snapshot.revision
                    ) else { return }
                    if !shouldRetry { return }
                }
            } catch is CancellationError {
                self?.receiveProjectionCancellation(request: request)
            } catch {
                self?.receiveProjectionFailure(request: request)
            }
        }
    }

    private func receiveProjection(
        _ projected: [ComparisonRow],
        request: ComparisonProjectionRequest,
        presentationRevision: UInt64
    ) -> Bool {
        guard currentGeneration == request.generation,
              activeProjectionRevision == request.revision,
              phase != .paused
        else { return false }
        guard self.presentationRevision == presentationRevision else {
            if pendingProjection != nil {
                projectionTask = nil
                activeProjectionRevision = nil
                startPendingProjectionIfNeeded(generation: request.generation)
                updateCompletionPhase(generation: request.generation)
                return false
            }
            return true
        }
        projectionTask = nil
        activeProjectionRevision = nil
        if request.revision > publishedProjectionRevision {
            publishedProjectionRevision = request.revision
            rows = projected
            selection.formIntersection(rows.map(\.id))
        }
        let shouldScheduleChecks = pendingProjection == nil
        startPendingProjectionIfNeeded(generation: request.generation)
        if shouldScheduleChecks {
            scheduleAmbiguousChecks(generation: request.generation)
        }
        updateCompletionPhase(generation: request.generation)
        return false
    }

    private func presentationSnapshot(
        for request: ComparisonProjectionRequest
    ) -> ComparisonPresentationSnapshot? {
        guard currentGeneration == request.generation,
              activeProjectionRevision == request.revision,
              phase != .paused
        else { return nil }
        return ComparisonPresentationSnapshot(
            revision: presentationRevision,
            left: leftEntries,
            right: rightEntries,
            errors: errors,
            overrides: statusOverrides,
            leftRoot: request.leftRoot,
            rightRoot: request.rightRoot
        )
    }

    private func receiveProjectionCancellation(request: ComparisonProjectionRequest) {
        guard currentGeneration == request.generation,
              activeProjectionRevision == request.revision,
              phase != .paused
        else { return }
        projectionTask = nil
        activeProjectionRevision = nil
        startPendingProjectionIfNeeded(generation: request.generation)
        updateCompletionPhase(generation: request.generation)
    }

    private func receiveProjectionFailure(request: ComparisonProjectionRequest) {
        guard currentGeneration == request.generation,
              activeProjectionRevision == request.revision,
              phase != .paused
        else { return }
        projectionTask = nil
        activeProjectionRevision = nil
        pendingProjection = nil
        pause(generation: request.generation)
    }

    private func startPendingProjectionIfNeeded(generation: UUID) {
        guard currentGeneration == generation,
              phase != .paused,
              let pendingProjection
        else { return }
        self.pendingProjection = nil
        startProjection(pendingProjection)
    }

    private func scheduleAmbiguousChecks(generation: UUID) {
        guard phase != .paused else { return }
        for row in rows where row.status == .checking(nil) {
            verify(row, generation: generation, forced: false)
        }
    }

    private func verify(_ row: ComparisonRow, generation: UUID, forced: Bool) {
        guard currentGeneration == generation,
              phase != .paused,
              checksumTasks[row.id] == nil,
              let left = row.left,
              let right = row.right,
              left.kind == .regularFile,
              right.kind == .regularFile,
              !Self.verificationIsBlocked(row.status),
              forced || row.status == .checking(nil)
        else { return }

        let path = row.id
        let leftRequest = ChecksumRequest(url: left.url, fingerprint: left.fingerprint)
        let rightRequest = ChecksumRequest(url: right.url, fingerprint: right.fingerprint)
        let originalStatus = row.status
        let token = UUID()
        let checksums = checksums
        let cache = cache
        let receiver = WeakComparisonCoordinator(self)

        let task = Task {
            async let leftOutcome = ComparisonChecksumWorker.outcome(
                request: leftRequest,
                checksums: checksums,
                cache: cache,
                progress: { progress in
                    await MainActor.run {
                        receiver.value?.receiveProgress(
                            progress,
                            path: path,
                            leftFingerprint: left.fingerprint,
                            rightFingerprint: right.fingerprint,
                            token: token,
                            generation: generation
                        )
                    }
                }
            )
            async let rightOutcome = ComparisonChecksumWorker.outcome(
                request: rightRequest,
                checksums: checksums,
                cache: cache,
                progress: { progress in
                    await MainActor.run {
                        receiver.value?.receiveProgress(
                            progress,
                            path: path,
                            leftFingerprint: left.fingerprint,
                            rightFingerprint: right.fingerprint,
                            token: token,
                            generation: generation
                        )
                    }
                }
            )
            let outcomes = await (leftOutcome, rightOutcome)
            await MainActor.run {
                receiver.value?.receiveChecksumResults(
                    left: outcomes.0,
                    right: outcomes.1,
                    path: path,
                    leftFingerprint: left.fingerprint,
                    rightFingerprint: right.fingerprint,
                    originalStatus: originalStatus,
                    token: token,
                    generation: generation
                )
            }
        }
        checksumTokens[path] = token
        checksumTasks[path] = task
        phase = .verifying
    }

    private func receiveProgress(
        _ progress: Double,
        path: ComparisonRelativePath,
        leftFingerprint: ComparisonFingerprint,
        rightFingerprint: ComparisonFingerprint,
        token: UUID,
        generation: UUID
    ) {
        guard currentGeneration == generation,
              phase != .paused,
              checksumTokens[path] == token,
              let index = rows.firstIndex(where: { $0.id == path }),
              rows[index].left?.fingerprint == leftFingerprint,
              rows[index].right?.fingerprint == rightFingerprint,
              !Self.verificationIsBlocked(rows[index].status)
        else { return }
        rows[index].status = .checking(progress)
    }

    private func receiveChecksumResults(
        left: ChecksumOutcome,
        right: ChecksumOutcome,
        path: ComparisonRelativePath,
        leftFingerprint: ComparisonFingerprint,
        rightFingerprint: ComparisonFingerprint,
        originalStatus: ComparisonStatus,
        token: UUID,
        generation: UUID
    ) {
        guard currentGeneration == generation,
              phase != .paused,
              checksumTokens[path] == token
        else { return }
        checksumCount += left.attempts + right.attempts
        checksumTasks[path] = nil
        checksumTokens[path] = nil
        guard let index = rows.firstIndex(where: { $0.id == path }),
              rows[index].left?.fingerprint == leftFingerprint,
              rows[index].right?.fingerprint == rightFingerprint
        else {
            scheduleAmbiguousChecks(generation: generation)
            updateCompletionPhase(generation: generation)
            return
        }

        let derivedStatus: ComparisonStatus
        switch (left, right) {
        case let (.success(leftResult, _), .success(rightResult, _)):
            var base = rows[index]
            base.status = originalStatus
            derivedStatus = ComparisonMatcher.applying(
                left: leftResult,
                right: rightResult,
                to: base
            ).status
        case (.unstable, _), (_, .unstable):
            derivedStatus = .unstable
            additionalErrorCount += 1
        case let (.failure(message, _), _), let (_, .failure(message, _)):
            derivedStatus = .error(message)
            additionalErrorCount += 1
        }
        statusOverrides[path] = ComparisonStatusOverride(
            leftFingerprint: leftFingerprint,
            rightFingerprint: rightFingerprint,
            status: derivedStatus
        )
        presentationRevision &+= 1
        guard !Self.verificationIsBlocked(rows[index].status) else {
            updateCompletionPhase(generation: generation)
            return
        }
        rows[index].status = derivedStatus
        publishRows(generation: generation)
        updateCompletionPhase(generation: generation)
    }

    private func discardOverrideIfFingerprintsChanged(at path: ComparisonRelativePath) {
        guard let override = statusOverrides[path] else { return }
        guard leftEntries[path]?.fingerprint == override.leftFingerprint,
              rightEntries[path]?.fingerprint == override.rightFingerprint
        else {
            statusOverrides[path] = nil
            presentationRevision &+= 1
            return
        }
    }

    private nonisolated static func verificationIsBlocked(_ status: ComparisonStatus) -> Bool {
        switch status {
        case .error, .unstable, .nameConflict:
            true
        default:
            false
        }
    }

    private func pause(generation: UUID) {
        guard currentGeneration == generation, phase != .paused else { return }
        additionalErrorCount += 1
        phase = .paused
        invalidateMoveIntent()
        projectionRevision &+= 1
        projectionTask?.cancel()
        projectionTask = nil
        activeProjectionRevision = nil
        pendingProjection = nil
        checksumTasks.values.forEach { $0.cancel() }
        checksumTasks.removeAll()
        checksumTokens.removeAll()
        sessionTask?.cancel()
        finishMetricsIfNeeded(cancelled: false)
    }

    private func updateCompletionPhase(generation: UUID) {
        guard currentGeneration == generation, phase != .paused else { return }
        if checksumTasks.isEmpty,
           projectionTask == nil,
           listingFinishedGeneration == generation {
            phase = .upToDate
            finishMetricsIfNeeded(cancelled: false)
        } else if !checksumTasks.isEmpty {
            phase = .verifying
        } else {
            phase = .comparing
        }
    }

    private func finishMetricsIfNeeded(cancelled: Bool) {
        guard let generation = currentGeneration, loggedGeneration != generation else { return }
        loggedGeneration = generation
        let event = ComparisonLogEvent(
            duration: max(0, Date().timeIntervalSince(startedAt)),
            discoveredCount: Set(leftEntries.keys).union(rightEntries.keys).count,
            checksumCount: checksumCount,
            errorCount: errors.values.reduce(0) { $0 + $1.count } + additionalErrorCount,
            wasCancelled: cancelled
        )
        let logger = logger
        Task { await logger.record(event) }
    }

    private func resetProjection() {
        session = nil
        rows = []
        selection = []
        leftEntries = [:]
        rightEntries = [:]
        errors = [.left: [:], .right: [:]]
        statusOverrides = [:]
        presentationRevision &+= 1
        activeProjectionRevision = nil
        pendingProjection = nil
        publishedProjectionRevision = 0
        listingFinishedGeneration = nil
        checksumCount = 0
        additionalErrorCount = 0
        pendingReconciliations = [:]
        reconciliationRevision = 0
    }

    private func stopTasksOnly() {
        sessionTask?.cancel()
        sessionTask = nil
        activeMonitorEpoch = nil
        monitorTask?.cancel()
        monitorTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        rootIdentityTask?.cancel()
        rootIdentityTask = nil
        projectionTask?.cancel()
        projectionTask = nil
        activeProjectionRevision = nil
        pendingProjection = nil
        projectionRevision &+= 1
        checksumTasks.values.forEach { $0.cancel() }
        checksumTasks.removeAll()
        checksumTokens.removeAll()
        invalidateMoveIntent()
        validationToken = nil
        announcementTask?.cancel()
        announcementTask = nil
        pendingAnnouncement = nil
    }

    private func comparisonSummaryDidChange() {
        guard currentGeneration != nil, phase != .idle else { return }
        let snapshot = ComparisonAnnouncementSnapshot(phase: phase, rowCount: rows.count)
        guard snapshot != pendingAnnouncement else { return }
        if snapshot == lastAnnounced {
            pendingAnnouncement = nil
            return
        }
        pendingAnnouncement = snapshot
        guard announcementTask == nil, let generation = currentGeneration else { return }
        let delay = announcementDelay
        announcementTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.announcementTask = nil
            guard self.currentGeneration == generation,
                  self.phase != .idle,
                  let pending = self.pendingAnnouncement,
                  pending != self.lastAnnounced
            else { return }
            self.pendingAnnouncement = nil
            self.lastAnnounced = pending
            self.announcementPoster.post(ComparisonAccessibility.summary(
                phase: pending.phase,
                count: pending.rowCount
            ))
        }
    }

    private func resetAnnouncements() {
        announcementTask?.cancel()
        announcementTask = nil
        pendingAnnouncement = nil
        lastAnnounced = nil
    }

    private func invalidateMoveIntent() {
        moveVolumeTask?.cancel()
        moveVolumeTask = nil
        moveDispatchTask?.cancel()
        moveDispatchTask = nil
        moveDispatchToken = nil
        isMoveDispatchPending = false
        pendingMoveConfirmation = nil
    }
}

private extension ComparisonReconciliationTarget {
    var subtree: ComparisonRelativePath? {
        if case let .subtree(path) = self { path } else { nil }
    }

    func containsForRelisting(_ path: ComparisonRelativePath) -> Bool {
        switch self {
        case .root:
            true
        case let .subtree(subtree):
            path.isDescendant(of: subtree)
        }
    }
}

private extension ComparisonRelativePath {
    func isDescendant(of ancestor: ComparisonRelativePath) -> Bool {
        components.count > ancestor.components.count
            && components.starts(with: ancestor.components)
    }
}
