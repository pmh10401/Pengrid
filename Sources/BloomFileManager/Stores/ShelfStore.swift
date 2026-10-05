import Foundation
import Observation

enum ShelfRetention: String, CaseIterable, Sendable {
    case clearOnQuit, keepBetweenLaunches
    var title: String { self == .clearOnQuit ? "Clear on Quit" : "Keep Between Launches" }
}

@MainActor @Observable
final class ShelfStore {
    static let enabledKey = "topShelf.enabled.v1"
    static let retentionKey = "topShelf.retention.v1"
    private(set) var entries: [ShelfItem] = []
    private(set) var filteredEntries: [ShelfItem] = []
    private(set) var isEnabled = false
    private(set) var retention = ShelfRetention.clearOnQuit
    var query = "" { didSet { refreshSearch() } }
    var kind: ShelfContentKind? { didSet { refreshSearch() } }
    var selectedID: UUID?
    var errorMessage: String?
    private(set) var persistenceError: String?
    private(set) var isImporting = false
    private(set) var isSearching = false
    private(set) var isRestoring = false
    private(set) var isSaving = false
    private(set) var isPreparingTermination = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistence: any ShelfPersisting
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var saveGeneration: UInt64 = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var restoreFailed = false

    init(defaults: UserDefaults = .standard, persistence: any ShelfPersisting) {
        self.defaults = defaults
        self.persistence = persistence
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        retention = ShelfRetention(rawValue: defaults.string(forKey: Self.retentionKey) ?? "") ?? .clearOnQuit
    }

    func start() async {
        guard !started else { return }
        started = true
        if isEnabled && retention == .keepBetweenLaunches {
            beginRestore()
            await restoreTask?.value
        } else {
            schedulePersistence()
            _ = await flushPersistence()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isPreparingTermination else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { clear() }
    }

    func setRetention(_ value: ShelfRetention) {
        guard !isPreparingTermination, !isRestoring else { return }
        if restoreFailed && value == .keepBetweenLaunches { return }
        restoreFailed = false
        retention = value
        defaults.set(value.rawValue, forKey: Self.retentionKey)
        schedulePersistence()
    }

    func add(_ incoming: [ShelfItem]) async {
        guard let token = beginImport() else { return }
        await completeImport(incoming, token: token)
    }

    func beginImport() -> UInt64? {
        guard isEnabled, !isImporting, !isRestoring, !restoreFailed, !isPreparingTermination else { return nil }
        isImporting = true
        errorMessage = nil
        return generation
    }

    func completeImport(_ incoming: [ShelfItem], token: UInt64) async {
        guard token == generation, isEnabled, isImporting else { return }
        let current = entries
        do {
            let validated = try await Task.detached(priority: .userInitiated) {
                try ShelfItem.validatedAddition(incoming, to: current)
            }.value
            guard token == generation, isEnabled, !isPreparingTermination else { return }
            entries = validated
            isImporting = false
            selectedID = incoming.last.flatMap { item in validated.contains(where: { $0.id == item.id }) ? item.id : nil }
            refreshSearch()
            schedulePersistence()
        } catch { failImport(error, token: token) }
    }

    func failImport(_ error: any Error, token: UInt64) {
        guard token == generation else { return }
        isImporting = false
        errorMessage = (error as? ShelfItemError)?.errorDescription ?? "Could not import the selected clipboard or drop contents."
    }

    func clear() {
        guard !isPreparingTermination else { return }
        invalidateImport()
        restoreFailed = false
        entries = []
        selectedID = nil
        query = ""
        kind = nil
        errorMessage = nil
        refreshSearch()
        schedulePersistence()
    }

    func remove(_ id: UUID) {
        guard !isPreparingTermination else { return }
        invalidateImport()
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        refreshSearch()
        schedulePersistence()
    }

    func flushPersistence() async -> Bool {
        await restoreTask?.value
        while let pending = saveTask {
            let token = saveGeneration
            await pending.value
            if token == saveGeneration { break }
        }
        return persistenceError == nil
    }

    func retryPersistence() {
        guard !isRestoring else { return }
        if restoreFailed { beginRestore() }
        else { schedulePersistence() }
    }

    func prepareForTermination() async -> Bool {
        await start()
        await restoreTask?.value
        isPreparingTermination = true
        invalidateImport()
        searchTask?.cancel()
        // Never overwrite a snapshot that could not be restored merely by quitting.
        if persistenceError == nil { schedulePersistence() }
        let succeeded = await flushPersistence()
        if !succeeded { isPreparingTermination = false }
        return succeeded
    }

    private func beginRestore() {
        isRestoring = true
        let token = generation
        let storage = persistence
        restoreTask = Task { [weak self] in
            do {
                let restored = try await storage.load()
                if let self, token == self.generation {
                    self.entries = restored
                    self.restoreFailed = false
                    self.persistenceError = nil
                    self.refreshSearch()
                }
            } catch {
                if let self, token == self.generation {
                    self.restoreFailed = true
                    self.persistenceError = "Could not restore the shelf. The saved snapshot was left unchanged. Retry to read it again."
                }
            }
            self?.isRestoring = false
            self?.restoreTask = nil
        }
    }

    private func invalidateImport() {
        generation &+= 1
        isImporting = false
    }

    private func refreshSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let token = searchGeneration
        let items = entries
        let text = query
        let filter = kind
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredEntries = items.filter { filter == nil || $0.kind == filter }
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { ShelfItem.search(items, query: text, kind: filter) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, token == self.searchGeneration else { return }
            self.filteredEntries = result
            self.isSearching = false
        }
    }

    private func schedulePersistence() {
        saveGeneration &+= 1
        let token = saveGeneration
        let previous = saveTask
        previous?.cancel()
        let items = isEnabled && retention == .keepBetweenLaunches ? entries : []
        let storage = persistence
        isSaving = true
        saveTask = Task { [weak self] in
            await previous?.value
            var failure: String?
            do {
                try Task.checkCancellation()
                if items.isEmpty { try await storage.remove() }
                else { try await storage.save(items) }
            } catch {
                failure = "Could not save or remove the local shelf snapshot. Check disk space and permissions, then retry."
            }
            guard let self, token == self.saveGeneration else { return }
            self.persistenceError = failure
            self.isSaving = false
            self.saveTask = nil
        }
    }
}
