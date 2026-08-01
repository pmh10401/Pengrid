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
    private(set) var results: [SmartSearchResult] = []
    private(set) var state: SmartSearchStoreState = .idle
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
                includeDirectories: includeDirectories
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
                let found = try await service.search(query)
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
            includeDirectories: includeDirectories
        )
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
