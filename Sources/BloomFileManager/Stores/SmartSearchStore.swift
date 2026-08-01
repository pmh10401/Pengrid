import Foundation
import Observation

enum SmartSearchStoreState: Equatable {
    case idle
    case searching
    case results
    case cancelled
    case failed
}

@MainActor @Observable
final class SmartSearchStore {
    var isPresented = false
    var queryText = ""
    var roots: [URL] = []
    var includeHidden = false
    var includePackages = false
    var includeDirectories = true
    var maximumResults = SmartSearchQuery.defaultMaximumResults {
        didSet {
            let clamped = min(
                max(maximumResults, SmartSearchQuery.maximumResultRange.lowerBound),
                SmartSearchQuery.maximumResultRange.upperBound
            )
            if clamped != maximumResults {
                maximumResults = clamped
            }
        }
    }
    private(set) var results: [SmartSearchResult] = []
    private(set) var state: SmartSearchStoreState = .idle
    private(set) var examinedEntryCount = 0
    private(set) var progressMessage: String?
    private(set) var errorMessage: String?
    private(set) var savedSearches: [SmartSearchRecord]

    private let service: any SmartSearching
    private let persistence: WorkspacePersistence
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    init(service: any SmartSearching, persistence: WorkspacePersistence) {
        self.service = service
        self.persistence = persistence
        savedSearches = persistence.loadSavedSearches()
    }

    func present(for root: URL) {
        cancelSearchTask()
        roots = [root.standardizedFileURL]
        isPresented = true
        results = []
        examinedEntryCount = 0
        progressMessage = nil
        errorMessage = nil
        state = .idle
    }

    func dismiss() {
        cancelSearch()
        isPresented = false
    }

    func search() {
        cancelSearchTask()
        results = []
        examinedEntryCount = 0
        progressMessage = nil
        errorMessage = nil
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .idle
            return
        }

        let query: SmartSearchQuery
        do {
            query = try SmartSearchQuery(
                text: queryText,
                roots: roots,
                includeHidden: includeHidden,
                includePackages: includePackages,
                includeDirectories: includeDirectories,
                maximumResults: maximumResults
            )
        } catch {
            state = .failed
            errorMessage = "Search failed."
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        state = .searching
        progressMessage = "Searching files…"
        let service = service
        searchTask = Task { [weak self] in
            do {
                let found = try await service.search(query, progress: { [weak self] count in
                    Task { @MainActor [weak self] in
                        self?.publishProgress(count, generation: generation)
                    }
                })
                guard !Task.isCancelled,
                      let self,
                      generation == self.searchGeneration
                else { return }
                self.results = found
                self.state = .results
                self.progressMessage = nil
                self.searchTask = nil
            } catch is CancellationError {
                guard let self, generation == self.searchGeneration else { return }
                self.state = .cancelled
                self.progressMessage = nil
                self.searchTask = nil
            } catch {
                guard !Task.isCancelled,
                      let self,
                      generation == self.searchGeneration
                else { return }
                self.state = .failed
                self.progressMessage = nil
                self.errorMessage = "Search failed."
                self.searchTask = nil
            }
        }
    }

    func cancelSearch() {
        cancelSearchTask()
        state = .cancelled
        progressMessage = nil
    }

    func addRoots(_ urls: [URL]) {
        var seen = Set(roots.map { $0.standardizedFileURL.path })
        for url in urls where url.isFileURL && url.path.hasPrefix("/") {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                roots.append(standardized)
            }
        }
    }

    func removeRoot(_ url: URL) {
        let path = url.standardizedFileURL.path
        roots.removeAll { $0.standardizedFileURL.path == path }
    }

    func openSavedSearch(_ record: SmartSearchRecord) {
        cancelSearchTask()
        queryText = record.query.text
        roots = record.query.roots
        includeHidden = record.query.includeHidden
        includePackages = record.query.includePackages
        includeDirectories = record.query.includeDirectories
        maximumResults = record.query.maximumResults
        isPresented = true
        search()
    }

    @discardableResult
    func saveCurrentSearch(named displayName: String) -> SmartSearchRecord? {
        guard let query = currentQuery(),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let record = SmartSearchRecord(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            query: query
        )
        savedSearches.append(record)
        persistSavedSearches()
        return record
    }

    @discardableResult
    func renameSavedSearch(id: UUID, to displayName: String) -> Bool {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }) else { return false }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        savedSearches[index].displayName = trimmedName
        persistSavedSearches()
        return true
    }

    @discardableResult
    func deleteSavedSearch(id: UUID) -> Bool {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }) else { return false }
        savedSearches.remove(at: index)
        persistSavedSearches()
        return true
    }

    private func currentQuery() -> SmartSearchQuery? {
        try? SmartSearchQuery(
            text: queryText,
            roots: roots,
            includeHidden: includeHidden,
            includePackages: includePackages,
            includeDirectories: includeDirectories,
            maximumResults: maximumResults
        )
    }

    private func publishProgress(_ count: Int, generation: Int) {
        guard generation == searchGeneration,
              state == .searching,
              count >= examinedEntryCount
        else { return }
        examinedEntryCount = count
        progressMessage = count == 1
            ? "Examined 1 entry…"
            : "Examined \(count) entries…"
    }

    private func cancelSearchTask() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
    }

    private func persistSavedSearches() {
        persistence.saveSavedSearches(savedSearches)
    }
}
