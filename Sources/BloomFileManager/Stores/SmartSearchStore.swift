import Foundation
import Observation

protocol SmartSearchPersisting: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

enum SmartSearchSort: String, CaseIterable, Codable, Equatable, Sendable {
    case score
    case name
    case modifiedAt
    case size
}

enum SmartSearchPresentationState: Equatable, Sendable {
    case idle
    case searching
    case results
    case cancelled
    case failed
}

struct SmartSearchProgressRelay: Sendable {
    let stream: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation

    init() {
        let pair = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ count: Int) {
        continuation.yield(count)
    }

    func finish() {
        continuation.finish()
    }
}

extension SmartSearchMetadataFilter {
    static let unrestricted = try! Self(
        kind: .all,
        extensionText: "",
        minimumBytes: nil,
        maximumBytes: nil,
        modifiedAfter: nil,
        modifiedBefore: nil
    )
}

@MainActor @Observable
final class SmartSearchStore {
    private(set) var isPresented = false
    private(set) var phase: SmartSearchPresentationState = .idle
    private(set) var results: [SmartSearchResult] = []
    private(set) var examinedEntryCount = 0
    private(set) var progressMessage: String?
    private(set) var errorMessage: String?
    private(set) var savedSearches: [SmartSearchRecord]

    var queryText = ""
    var roots: [URL] = []
    var includeHidden = false
    var includePackages = false
    var includeDirectories = true {
        didSet {
            guard metadata.kind != (includeDirectories ? .all : .files) else { return }
            metadata = copyMetadata(kind: includeDirectories ? .all : .files)
        }
    }
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
    var metadata: SmartSearchMetadataFilter = .unrestricted
    var sort: SmartSearchSort = .score {
        didSet {
            results = sorted(results)
        }
    }

    var canSaveCurrentSearch: Bool {
        currentQuery() != nil
    }

    private let service: any SmartSearching
    private let persistence: any SmartSearchPersisting
    private var searchTask: Task<Void, Never>?
    private var progressConsumerTask: Task<Void, Never>?
    private var generation = 0

    init(service: any SmartSearching, persistence: any SmartSearchPersisting) {
        self.service = service
        self.persistence = persistence
        if let data = persistence.load(), let records = try? JSONDecoder().decode([SmartSearchRecord].self, from: data) {
            savedSearches = records
        } else {
            savedSearches = []
        }
    }

    convenience init(service: any SmartSearching, persistence: WorkspacePersistence) {
        self.init(service: service, persistence: persistence.smartSearchPersistence)
    }

    func present(initialRoot: URL) {
        cancelActiveSearch()
        roots = [initialRoot.standardizedFileURL]
        isPresented = true
        results = []
        resetTransientState(to: .idle)
    }

    func dismiss() {
        cancel()
        isPresented = false
    }

    func submit() {
        cancelActiveSearch()
        results = []
        resetTransientState(to: .idle)

        let query: SmartSearchQuery
        do {
            query = try makeQuery()
        } catch SmartSearchValidationError.queryTooComplex {
            phase = .failed
            errorMessage = "Search is too long. Use fewer terms."
            return
        } catch SmartSearchValidationError.noSearchableTerms {
            phase = .failed
            errorMessage = "Search needs a filename, path, or Korean initials."
            return
        } catch SmartSearchValidationError.emptyText {
            return
        } catch {
            phase = .failed
            errorMessage = "Search failed."
            return
        }

        generation += 1
        let searchGeneration = generation
        phase = .searching
        progressMessage = "Searching files…"
        let relay = SmartSearchProgressRelay()
        let progressConsumer = Task { @MainActor [weak self] in
            for await count in relay.stream {
                guard !Task.isCancelled else { return }
                self?.publishProgress(count, for: searchGeneration)
            }
        }
        progressConsumerTask = progressConsumer
        let service = service
        searchTask = Task { [weak self] in
            do {
                let found = try await service.search(query, progress: relay.yield)
                relay.finish()
                await progressConsumer.value
                guard !Task.isCancelled,
                      let self,
                      searchGeneration == self.generation
                else { return }
                self.results = self.sorted(found)
                self.phase = .results
                self.progressMessage = nil
                self.progressConsumerTask = nil
                self.searchTask = nil
            } catch is CancellationError {
                relay.finish()
                progressConsumer.cancel()
                await progressConsumer.value
                guard let self, searchGeneration == self.generation else { return }
                self.phase = .cancelled
                self.progressMessage = nil
                self.progressConsumerTask = nil
                self.searchTask = nil
            } catch {
                relay.finish()
                progressConsumer.cancel()
                await progressConsumer.value
                guard !Task.isCancelled,
                      let self,
                      searchGeneration == self.generation
                else { return }
                self.phase = .failed
                self.progressMessage = nil
                self.errorMessage = "Search failed."
                self.progressConsumerTask = nil
                self.searchTask = nil
            }
        }
    }

    func cancel() {
        cancelActiveSearch()
        phase = .cancelled
        progressMessage = nil
    }

    func addRoots(_ urls: [URL]) {
        var paths = Set(roots.map(\.standardizedFileURL.path))
        for url in urls where url.isFileURL && url.path.hasPrefix("/") {
            let standardized = url.standardizedFileURL
            if paths.insert(standardized.path).inserted {
                roots.append(standardized)
            }
        }
    }

    func removeRoot(_ url: URL) {
        let path = url.standardizedFileURL.path
        roots.removeAll { $0.standardizedFileURL.path == path }
    }

    func openSavedSearch(_ record: SmartSearchRecord) {
        cancelActiveSearch()
        queryText = record.query.text
        roots = record.query.roots
        includeHidden = record.query.includeHidden
        includePackages = record.query.includePackages
        maximumResults = record.query.maximumResults
        includeDirectories = record.query.includeDirectories
        metadata = record.query.metadata
        isPresented = true
        submit()
    }

    @discardableResult
    func saveCurrentSearch(named displayName: String) -> SmartSearchRecord? {
        guard let query = currentQuery() else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let record = SmartSearchRecord(displayName: name, query: query)
        savedSearches.append(record)
        persistSavedSearches()
        return record
    }

    @discardableResult
    func renameSavedSearch(id: UUID, to displayName: String) -> Bool {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }) else { return false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        savedSearches[index].displayName = name
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

    private func makeQuery() throws -> SmartSearchQuery {
        try SmartSearchQuery(
            text: queryText,
            roots: roots,
            includeHidden: includeHidden,
            includePackages: includePackages,
            includeDirectories: includeDirectories,
            maximumResults: maximumResults,
            metadata: metadata
        )
    }

    private func currentQuery() -> SmartSearchQuery? {
        try? makeQuery()
    }

    private func resetTransientState(to phase: SmartSearchPresentationState) {
        self.phase = phase
        examinedEntryCount = 0
        progressMessage = nil
        errorMessage = nil
    }

    private func publishProgress(_ count: Int, for searchGeneration: Int) {
        guard searchGeneration == generation,
              phase == .searching,
              count >= examinedEntryCount
        else { return }
        examinedEntryCount = count
        progressMessage = count == 1 ? "Examined 1 entry…" : "Examined \(count) entries…"
    }

    private func cancelActiveSearch() {
        generation += 1
        progressConsumerTask?.cancel()
        progressConsumerTask = nil
        searchTask?.cancel()
        searchTask = nil
    }

    private func persistSavedSearches() {
        guard let data = try? JSONEncoder().encode(savedSearches) else { return }
        persistence.save(data)
    }

    private func copyMetadata(kind: SmartSearchItemKind) -> SmartSearchMetadataFilter {
        try! SmartSearchMetadataFilter(
            kind: kind,
            extensionText: metadata.extensions.sorted().joined(separator: ","),
            minimumBytes: metadata.minimumBytes,
            maximumBytes: metadata.maximumBytes,
            modifiedAfter: metadata.modifiedAfter,
            modifiedBefore: metadata.modifiedBefore
        )
    }

    private func sorted(_ values: [SmartSearchResult]) -> [SmartSearchResult] {
        values.sorted { lhs, rhs in
            switch sort {
            case .score:
                if lhs.score != rhs.score { return lhs.score > rhs.score }
            case .name:
                let comparison = lhs.item.name.localizedStandardCompare(rhs.item.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .modifiedAt:
                if lhs.item.modifiedAt != rhs.item.modifiedAt {
                    return (lhs.item.modifiedAt ?? .distantPast) > (rhs.item.modifiedAt ?? .distantPast)
                }
            case .size:
                if lhs.item.byteSize != rhs.item.byteSize {
                    return (lhs.item.byteSize ?? -1) > (rhs.item.byteSize ?? -1)
                }
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }
}
