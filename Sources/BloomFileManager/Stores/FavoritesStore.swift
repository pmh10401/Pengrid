import Foundation
import Observation

@MainActor @Observable
final class FavoritesStore {
    private(set) var records: [FavoriteRecord]

    private let storageURL: URL
    private let bookmarking: any FavoriteBookmarking

    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "favorites.json")
    }

    init(
        storageURL: URL = FavoritesStore.defaultStorageURL,
        bookmarking: any FavoriteBookmarking = LiveFavoriteBookmarking()
    ) {
        self.storageURL = storageURL
        self.bookmarking = bookmarking
        records = Self.load(from: storageURL)
    }

    func add(_ url: URL) throws {
        let requestedURL = url.standardizedFileURL
        let requestedBookmark = try bookmarking.createBookmark(for: requestedURL)
        let requestedResolution = try? bookmarking.resolve(requestedBookmark)
        let resolvedRequestedURL = (requestedResolution?.url ?? requestedURL).standardizedFileURL

        var updatedRecords = records
        var didRefreshBookmark = false
        var isDuplicate = false

        for index in updatedRecords.indices {
            let resolved: ResolvedBookmark
            do {
                resolved = try bookmarking.resolve(updatedRecords[index].bookmarkData)
            } catch {
                let lastKnownURL = URL(filePath: updatedRecords[index].lastKnownPath).standardizedFileURL
                if lastKnownURL == requestedURL {
                    isDuplicate = true
                }
                continue
            }
            let resolvedURL = resolved.url.standardizedFileURL
            if resolvedURL == resolvedRequestedURL {
                isDuplicate = true
            }
            if resolved.isStale {
                updatedRecords[index].bookmarkData = try bookmarking.createBookmark(for: resolvedURL)
                updatedRecords[index].displayName = Self.displayName(for: resolvedURL)
                updatedRecords[index].lastKnownPath = resolvedURL.path
                didRefreshBookmark = true
            }
        }

        if isDuplicate {
            if didRefreshBookmark {
                try persist(updatedRecords)
                records = updatedRecords
            }
            return
        }

        var storedBookmark = requestedBookmark
        var storedURL = requestedURL
        if let requestedResolution {
            storedURL = requestedResolution.url.standardizedFileURL
            if requestedResolution.isStale {
                storedBookmark = try bookmarking.createBookmark(for: storedURL)
            }
        }
        updatedRecords.append(
            FavoriteRecord(
                id: UUID(),
                displayName: Self.displayName(for: storedURL),
                bookmarkData: storedBookmark,
                lastKnownPath: storedURL.path
            )
        )
        try persist(updatedRecords)
        records = updatedRecords
    }

    func remove(id: UUID) {
        let updatedRecords = records.filter { $0.id != id }
        guard updatedRecords != records else { return }
        guard (try? persist(updatedRecords)) != nil else { return }
        records = updatedRecords
    }

    func containsExactURL(_ url: URL) -> Bool {
        let requestedURL = resolvedURL(for: url) ?? url.standardizedFileURL
        return records.contains { record in
            if let resolved = try? bookmarking.resolve(record.bookmarkData) {
                return resolved.url.standardizedFileURL == requestedURL
            }
            return URL(filePath: record.lastKnownPath).standardizedFileURL == requestedURL
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
              source.allSatisfy(records.indices.contains),
              (0...records.count).contains(destination)
        else { return }

        let movedRecords = source.map { records[$0] }
        var updatedRecords = records.enumerated()
            .filter { !source.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = destination - removedBeforeDestination
        guard updatedRecords.indices.contains(insertionIndex) || insertionIndex == updatedRecords.endIndex else {
            return
        }
        updatedRecords.insert(contentsOf: movedRecords, at: insertionIndex)
        guard updatedRecords != records else { return }
        guard (try? persist(updatedRecords)) != nil else { return }
        records = updatedRecords
    }

    func resolution(for record: FavoriteRecord) -> FavoriteResolution {
        do {
            let resolved = try bookmarking.resolve(record.bookmarkData)
            let resolvedURL = resolved.url.standardizedFileURL
            if resolved.isStale {
                guard let index = records.firstIndex(where: { $0.id == record.id }) else {
                    return .unavailable(lastKnownPath: record.lastKnownPath)
                }
                let refreshedBookmark = try bookmarking.createBookmark(for: resolvedURL)
                var updatedRecords = records
                updatedRecords[index].bookmarkData = refreshedBookmark
                updatedRecords[index].displayName = Self.displayName(for: resolvedURL)
                updatedRecords[index].lastKnownPath = resolvedURL.path
                try persist(updatedRecords)
                records = updatedRecords
            }
            return .available(resolvedURL)
        } catch {
            return .unavailable(lastKnownPath: record.lastKnownPath)
        }
    }

    private static func load(from storageURL: URL) -> [FavoriteRecord] {
        guard let data = try? Data(contentsOf: storageURL),
              let records = try? JSONDecoder().decode([FavoriteRecord].self, from: data)
        else { return [] }
        return records
    }

    private func resolvedURL(for url: URL) -> URL? {
        guard let bookmark = try? bookmarking.createBookmark(for: url.standardizedFileURL),
              let resolution = try? bookmarking.resolve(bookmark)
        else { return nil }
        return resolution.url.standardizedFileURL
    }

    private func persist(_ records: [FavoriteRecord]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: storageURL, options: .atomic)
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
