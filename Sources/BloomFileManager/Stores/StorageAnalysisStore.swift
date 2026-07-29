import Foundation
import Observation

@MainActor @Observable
final class StorageAnalysisStore {
    private(set) var isActive = false
    private(set) var phase: StorageAnalysisPhase = .inactive
    private(set) var currentGeneration: UInt64 = 0
    private(set) var rootURL: URL?
    private(set) var rootIdentity: FileIdentity?
    private(set) var currentAdmission: StorageScanAdmissionToken?
    private(set) var entries: [StorageEntry] = []
    private(set) var failures: [StorageRelativePath: String] = [:]
    private(set) var duplicateGroups: [StorageDuplicateGroup] = []
    private(set) var verificationStates: [
        StorageRelativePath: StorageVerificationState
    ] = [:]
    var section: StorageAnalysisSection = .overview
    var thresholds = StorageAnalysisThresholds()
    var selectedEntryIDs: Set<StorageRelativePath> = []
    var selectedDuplicateGroupID: StorageDuplicateGroupID?
    var preferredKeepFolder: StorageRelativePath?
    private(set) var pendingProtectedRoot: URL?
    private(set) var cleanupAcknowledgementRequired = false
    private(set) var hasAcknowledgedProtectedCleanup = false

    var canPerformCleanupActions: Bool {
        !cleanupAcknowledgementRequired || hasAcknowledgedProtectedCleanup
    }

    @ObservationIgnored private let scanner: any StorageScanning
    @ObservationIgnored private let duplicates: any StorageDuplicateDetecting
    @ObservationIgnored private let locationPolicy: any StorageScanLocationValidating
    @ObservationIgnored private var entryIndexByID: [StorageRelativePath: Int] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var pendingProtectedOptions: StorageScanOptions?
    @ObservationIgnored private var pendingProtectedAdmission: StorageScanAdmissionToken?
    @ObservationIgnored private var lastScanRoot: URL?
    @ObservationIgnored private var lastScanOptions: StorageScanOptions?

    init(
        scanner: any StorageScanning,
        duplicates: any StorageDuplicateDetecting,
        locationPolicy: any StorageScanLocationValidating
    ) {
        self.scanner = scanner
        self.duplicates = duplicates
        self.locationPolicy = locationPolicy
    }

    func enter() {
        guard !isActive else { return }
        isActive = true
        phase = .idle
    }

    func exit() {
        invalidateCurrentWork()
        isActive = false
        phase = .inactive
        rootURL = nil
        rootIdentity = nil
        currentAdmission = nil
        entries = []
        entryIndexByID = [:]
        failures = [:]
        duplicateGroups = []
        verificationStates = [:]
        section = .overview
        thresholds = StorageAnalysisThresholds()
        selectedEntryIDs = []
        selectedDuplicateGroupID = nil
        preferredKeepFolder = nil
        pendingProtectedRoot = nil
        pendingProtectedOptions = nil
        pendingProtectedAdmission = nil
        cleanupAcknowledgementRequired = false
        hasAcknowledgedProtectedCleanup = false
        lastScanRoot = nil
        lastScanOptions = nil
    }

    func requestScan(at root: URL, options: StorageScanOptions) async {
        let root = root.standardizedFileURL
        switch locationPolicy.decision(for: root) {
        case let .allowed(admission):
            invalidateCurrentWork()
            pendingProtectedRoot = nil
            pendingProtectedOptions = nil
            pendingProtectedAdmission = nil
            cleanupAcknowledgementRequired = false
            hasAcknowledgedProtectedCleanup = false
            await beginScan(admission: admission, options: options)
        case let .protected(_, admission):
            pendingProtectedRoot = root
            pendingProtectedOptions = options
            pendingProtectedAdmission = admission
        case .rejected:
            invalidateCurrentWork()
            pendingProtectedRoot = nil
            pendingProtectedOptions = nil
            pendingProtectedAdmission = nil
            cleanupAcknowledgementRequired = false
            hasAcknowledgedProtectedCleanup = false
            clearPublishedAnalysis()
            phase = isActive ? .paused : .inactive
        }
    }

    func cancelProtectedScanRequest() {
        pendingProtectedRoot = nil
        pendingProtectedOptions = nil
        pendingProtectedAdmission = nil
    }

    func confirmProtectedScan(options: StorageScanOptions) async {
        guard pendingProtectedRoot != nil,
              let admission = pendingProtectedAdmission else {
            return
        }
        let requestedOptions = pendingProtectedOptions ?? options
        invalidateCurrentWork()
        pendingProtectedRoot = nil
        pendingProtectedOptions = nil
        pendingProtectedAdmission = nil
        cleanupAcknowledgementRequired = true
        hasAcknowledgedProtectedCleanup = false
        await beginScan(
            admission: admission.authorizingProtectedScan(),
            options: requestedOptions
        )
    }

    func confirmProtectedCleanupAcknowledgement() {
        guard cleanupAcknowledgementRequired, isActive else { return }
        hasAcknowledgedProtectedCleanup = true
        currentAdmission = currentAdmission?.authorizingCleanup()
    }

    func revalidateCleanupAdmission(
        _ expected: StorageScanAdmissionToken
    ) async -> Bool {
        guard phase == .complete,
              currentAdmission == expected,
              expected.authorization.cleanupAuthorized
        else {
            return false
        }
        do {
            try await scanner.validateAdmission(expected)
            guard currentAdmission == expected,
                  phase == .complete,
                  locationPolicy.revalidate(expected)
            else {
                invalidateVerificationResults()
                phase = .paused
                return false
            }
            return true
        } catch {
            invalidateVerificationResults()
            phase = .paused
            return false
        }
    }

    func cancel() {
        invalidateCurrentWork()
        if isActive {
            phase = .cancelled
        }
    }

    func scanAgain() async {
        guard let root = lastScanRoot, let options = lastScanOptions else { return }
        await requestScan(at: root, options: options)
    }

    func setKeep(_ id: StorageRelativePath, in groupID: StorageDuplicateGroupID) {
        guard canPerformCleanupActions,
              phase == .complete,
              let index = duplicateGroups.firstIndex(where: { $0.id == groupID }),
              duplicateGroups[index].members.contains(where: { $0.id == id })
        else {
            return
        }

        duplicateGroups[index].keepID = id
        duplicateGroups[index].trashIDs.remove(id)
        duplicateGroups[index].recalculateReclaimableBytes()
    }

    func setTrashMarked(
        _ marked: Bool,
        id: StorageRelativePath,
        in groupID: StorageDuplicateGroupID
    ) {
        guard canPerformCleanupActions,
              phase == .complete,
              let index = duplicateGroups.firstIndex(where: { $0.id == groupID })
        else {
            return
        }

        if marked {
            guard StorageCleanupSelectionPolicy.canMarkForTrash(
                id,
                in: duplicateGroups[index]
            ) else {
                return
            }
            duplicateGroups[index].trashIDs.insert(id)
        } else {
            duplicateGroups[index].trashIDs.remove(id)
        }
        duplicateGroups[index].recalculateReclaimableBytes()
    }

    func applyCleanupResult(_ result: FileOperationResult) {
        guard phase == .complete else { return }
        let selectedTrashIDs = duplicateGroups.reduce(into: Set<StorageRelativePath>()) {
            $0.formUnion($1.trashIDs)
        }
        guard !selectedTrashIDs.isEmpty else { return }

        let successfullyTrashedURLs = Set(result.outcomes.compactMap { outcome -> URL? in
            guard case let .succeeded(source, destination) = outcome,
                  destination == nil
            else {
                return nil
            }
            return source.standardizedFileURL
        })
        guard !successfullyTrashedURLs.isEmpty else { return }

        let removedIDs = Set(entries.compactMap { entry in
            selectedTrashIDs.contains(entry.id)
                && successfullyTrashedURLs.contains(entry.url.standardizedFileURL)
                ? entry.id
                : nil
        })
        guard !removedIDs.isEmpty else { return }

        entries.removeAll { removedIDs.contains($0.id) }
        rebuildEntryIndex()
        selectedEntryIDs.subtract(removedIDs)
        for id in removedIDs {
            verificationStates.removeValue(forKey: id)
            failures.removeValue(forKey: id)
        }
        rebuildDuplicateGroups(removing: removedIDs)
    }

    var totalBytes: Int64 {
        entries.reduce(into: Int64(0)) { total, entry in
            guard let size = entry.fingerprint.byteSize, size > 0 else { return }
            total = saturatedSum(total, size)
        }
    }

    var reclaimableBytes: Int64 {
        duplicateGroups.reduce(into: Int64(0)) { total, group in
            total = saturatedSum(total, max(0, group.reclaimableBytes))
        }
    }

    var largeFiles: [StorageEntry] {
        entries.filter {
            guard $0.kind == .regularFile else { return false }
            guard let size = $0.fingerprint.byteSize else { return false }
            return size >= thresholds.largeFileBytes
        }.sorted {
            let lhsSize = $0.fingerprint.byteSize ?? 0
            let rhsSize = $1.fingerprint.byteSize ?? 0
            return lhsSize == rhsSize
                ? $0.relativePath < $1.relativePath
                : lhsSize > rhsSize
        }
    }

    var longUnmodifiedFiles: [StorageEntry] {
        let days = max(0, thresholds.longUnmodifiedDays)
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter {
            guard $0.kind == .regularFile else { return false }
            guard let modifiedAt = $0.fingerprint.modifiedAt else { return false }
            return modifiedAt <= cutoff
        }.sorted {
            let lhsDate = $0.fingerprint.modifiedAt ?? .distantFuture
            let rhsDate = $1.fingerprint.modifiedAt ?? .distantFuture
            return lhsDate == rhsDate
                ? $0.relativePath < $1.relativePath
                : lhsDate < rhsDate
        }
    }

    var entriesByCategory: [StorageFileCategory: [StorageEntry]] {
        Dictionary(grouping: entries, by: \.category)
    }

    var overviewMetrics: StorageOverviewMetrics {
        StorageOverviewMetrics(
            fileCount: entries.count(where: { $0.kind == .regularFile }),
            directoryCount: entries.count(where: { $0.kind == .directory }),
            inaccessibleCount: failures.count,
            reclaimableBytes: reclaimableBytes
        )
    }

    var fileTypeGroups: [StorageFileTypeGroup] {
        StorageFileCategory.allCases.compactMap { category in
            guard let groupedEntries = entriesByCategory[category],
                  !groupedEntries.isEmpty else {
                return nil
            }
            let bytes = groupedEntries.reduce(into: Int64(0)) { total, entry in
                guard let size = entry.fingerprint.byteSize, size > 0 else { return }
                total = saturatedSum(total, size)
            }
            return StorageFileTypeGroup(
                category: category,
                entryCount: groupedEntries.count,
                byteCount: bytes
            )
        }
    }

    private func invalidateCurrentWork() {
        currentGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
    }

    private func beginScan(
        admission: StorageScanAdmissionToken,
        options: StorageScanOptions
    ) async {
        let generation = currentGeneration
        clearPublishedAnalysis()
        let root = admission.root
        rootURL = root
        rootIdentity = admission.rootIdentity
        currentAdmission = admission
        lastScanRoot = root
        lastScanOptions = options
        phase = .scanning

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runScan(
                admission: admission,
                options: options,
                generation: generation
            )
        }
        scanTask = task
        await task.value
        if generation == currentGeneration {
            scanTask = nil
        }
    }

    private func runScan(
        admission: StorageScanAdmissionToken,
        options: StorageScanOptions,
        generation: UInt64
    ) async {
        var enteredVerification = false
        do {
            guard await validateAdmission(
                admission,
                generation: generation,
                invalidateVerification: false
            ) else {
                return
            }

            let request = StorageScanRequest(
                admission: admission,
                options: options
            )
            for try await batch in scanner.batches(for: request) {
                guard canPublish(generation) else { return }
                guard await validateAdmission(
                    admission,
                    generation: generation,
                    invalidateVerification: false
                ) else {
                    phase = .paused
                    return
                }
                publish(batch)
            }
            guard canPublish(generation) else { return }

            guard await validateAdmission(
                admission,
                generation: generation,
                invalidateVerification: false
            ) else {
                phase = .paused
                return
            }

            phase = .verifying
            enteredVerification = true
            for try await event in duplicates.events(for: entries) {
                guard canPublish(generation) else { return }
                guard await validateAdmission(
                    admission,
                    generation: generation
                ) else {
                    return
                }
                publish(event)
            }
            guard canPublish(generation) else { return }
            guard await validateAdmission(
                admission,
                generation: generation
            ) else {
                return
            }
            phase = .complete
        } catch is CancellationError {
            return
        } catch {
            guard canPublish(generation) else { return }
            if enteredVerification {
                invalidateVerificationResults()
            }
            phase = .paused
        }
    }

    private func validateAdmission(
        _ admission: StorageScanAdmissionToken,
        generation: UInt64,
        invalidateVerification: Bool = true
    ) async -> Bool {
        do {
            guard canPublish(generation) else { return false }
            guard locationPolicy.revalidate(admission) else {
                if invalidateVerification {
                    invalidateVerificationResults()
                }
                phase = .paused
                return false
            }
            try await scanner.validateAdmission(admission)
            guard canPublish(generation) else { return false }
            return true
        } catch {
            guard canPublish(generation) else { return false }
            if invalidateVerification {
                invalidateVerificationResults()
            }
            phase = .paused
            return false
        }
    }

    private func invalidateVerificationResults() {
        duplicateGroups = []
        selectedEntryIDs = []
        for entry in entries {
            verificationStates[entry.id] = .unstable
        }
    }

    private func canPublish(_ generation: UInt64) -> Bool {
        generation == currentGeneration && !Task.isCancelled
    }

    private func publish(_ batch: StorageScanBatch) {
        for record in batch.records {
            switch record {
            case let .entry(entry):
                if verificationStates[entry.id] == nil {
                    verificationStates[entry.id] = .unverified
                }
                if let index = entryIndexByID[entry.id] {
                    entries[index] = entry
                } else {
                    entryIndexByID[entry.id] = entries.count
                    entries.append(entry)
                }
            case let .failure(path, message):
                failures[path] = message
            }
        }
    }

    private func rebuildEntryIndex() {
        entryIndexByID = Dictionary(
            uniqueKeysWithValues: entries.indices.map { (entries[$0].id, $0) }
        )
    }

    private func publish(_ event: StorageDuplicateDetectionEvent) {
        switch event {
        case let .state(id, state):
            verificationStates[id] = state
        case let .group(group):
            if let index = duplicateGroups.firstIndex(where: { $0.id == group.id }) {
                duplicateGroups[index] = group
            } else {
                duplicateGroups.append(group)
            }
            if selectedDuplicateGroupID == nil {
                selectedDuplicateGroupID = group.id
            }
        case let .excluded(id, state):
            verificationStates[id] = state
        }
    }

    private func clearPublishedAnalysis() {
        rootURL = nil
        rootIdentity = nil
        currentAdmission = nil
        entries = []
        entryIndexByID = [:]
        failures = [:]
        duplicateGroups = []
        verificationStates = [:]
        selectedEntryIDs = []
        selectedDuplicateGroupID = nil
    }

    private func rebuildDuplicateGroups(removing removedIDs: Set<StorageRelativePath>) {
        duplicateGroups = duplicateGroups.compactMap { existing in
            var group = existing
            group.members.removeAll { removedIDs.contains($0.id) }
            guard group.members.count >= 2 else { return nil }

            group.trashIDs.subtract(removedIDs)
            if !group.members.contains(where: { $0.id == group.keepID }) {
                guard let keepID = StorageKeepRecommender.recommendedKeep(
                    in: group.members,
                    explicitKeep: nil,
                    preferredFolder: preferredKeepFolder
                ) else {
                    return nil
                }
                group.keepID = keepID
            }
            group.trashIDs.remove(group.keepID)
            group.recalculateReclaimableBytes()
            return group
        }
        if !duplicateGroups.contains(where: { $0.id == selectedDuplicateGroupID }) {
            selectedDuplicateGroupID = duplicateGroups.first?.id
        }
    }
}

private func saturatedSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    rhs > Int64.max - lhs ? Int64.max : lhs + rhs
}
