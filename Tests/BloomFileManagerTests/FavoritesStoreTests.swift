import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FavoritesStoreTests {
    @Test func favoritesPersistOrderAndDoNotDuplicateExactURLs() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let bookmarking = InMemoryFavoriteBookmarking()
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        let a = URL(filePath: "/folders/A")
        let b = URL(filePath: "/folders/B")

        try store.add(a)
        try store.add(b)
        try store.add(a)
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(store.records.map(\.displayName) == ["B", "A"])
        let restored = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        #expect(restored.records.map(\.displayName) == ["B", "A"])
    }

    @Test func exactResolvedDuplicateRefreshesAndPersistsStaleBookmark() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let alias = URL(filePath: "/folders/Alias")
        let target = URL(filePath: "/folders/Target")
        let bookmarking = InMemoryFavoriteBookmarking(resolvedPaths: [alias.path: target.path])
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)

        try store.add(alias)
        bookmarking.setStalePaths([alias.path])
        try store.add(target)

        #expect(store.records.count == 1)
        #expect(store.records[0].lastKnownPath == target.path)
        #expect(bookmarking.bookmarkCreationPaths.filter { $0 == target.path }.count >= 1)
        let restored = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        #expect(restored.records.count == 1)
        #expect(restored.resolution(for: restored.records[0]) == .available(target))
    }

    @Test func resolvingStaleBookmarkRefreshesItsPersistedRecord() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let oldLocation = URL(filePath: "/folders/Old")
        let newLocation = URL(filePath: "/folders/New")
        let bookmarking = InMemoryFavoriteBookmarking(
            resolvedPaths: [oldLocation.path: newLocation.path]
        )
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        try store.add(oldLocation)
        bookmarking.setStalePaths([oldLocation.path])
        let record = try #require(store.records.first)

        #expect(store.resolution(for: record) == .available(newLocation))

        #expect(store.records[0].lastKnownPath == newLocation.path)
        #expect(bookmarking.bookmarkCreationPaths.contains(newLocation.path))
        bookmarking.setStalePaths([])
        let restored = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        #expect(restored.resolution(for: restored.records[0]) == .available(newLocation))
    }

    @Test func staleBookmarkRecreationFailureIsUnavailableWithoutPartialPublish() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let oldLocation = URL(filePath: "/folders/Old")
        let newLocation = URL(filePath: "/folders/New")
        let bookmarking = InMemoryFavoriteBookmarking(
            resolvedPaths: [oldLocation.path: newLocation.path]
        )
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        try store.add(oldLocation)
        let recordsBeforeRefresh = store.records
        let storageBeforeRefresh = try Data(contentsOf: storage)
        bookmarking.setStalePaths([oldLocation.path])
        bookmarking.setBookmarkCreationFailurePaths([newLocation.path])

        let resolution = store.resolution(for: recordsBeforeRefresh[0])

        #expect(resolution == .unavailable(lastKnownPath: newLocation.path))
        #expect(store.records == recordsBeforeRefresh)
        #expect(try Data(contentsOf: storage) == storageBeforeRefresh)
    }

    @Test func staleBookmarkSaveFailureIsUnavailableWithoutPartialPublish() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporaryDirectory.url.path
            )
            temporaryDirectory.remove()
        }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let oldLocation = URL(filePath: "/folders/Old")
        let newLocation = URL(filePath: "/folders/New")
        let bookmarking = InMemoryFavoriteBookmarking(
            resolvedPaths: [oldLocation.path: newLocation.path]
        )
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        try store.add(oldLocation)
        let recordsBeforeRefresh = store.records
        let storageBeforeRefresh = try Data(contentsOf: storage)
        bookmarking.setStalePaths([oldLocation.path])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: temporaryDirectory.url.path
        )

        let resolution = store.resolution(for: recordsBeforeRefresh[0])

        #expect(resolution == .unavailable(lastKnownPath: newLocation.path))
        #expect(store.records == recordsBeforeRefresh)
        #expect(try Data(contentsOf: storage) == storageBeforeRefresh)
    }

    @Test func differentFoldersWithTheSameDisplayNameAreAllowed() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let store = FavoritesStore(
            storageURL: temporaryDirectory.url.appending(path: "favorites.json"),
            bookmarking: InMemoryFavoriteBookmarking()
        )

        try store.add(URL(filePath: "/one/Common"))
        try store.add(URL(filePath: "/two/Common"))

        #expect(store.records.map(\.displayName) == ["Common", "Common"])
        #expect(store.records.map(\.lastKnownPath) == ["/one/Common", "/two/Common"])
    }

    @Test func unresolvedFavoriteRemainsVisibleWithWarningAfterRestore() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let bookmarking = InMemoryFavoriteBookmarking(unavailablePaths: ["/folders/A"])
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)

        try store.add(URL(filePath: "/folders/A"))

        #expect(store.resolution(for: store.records[0]) == .unavailable(lastKnownPath: "/folders/A"))
        let restored = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        #expect(restored.records.count == 1)
        #expect(restored.resolution(for: restored.records[0]) == .unavailable(lastKnownPath: "/folders/A"))
    }

    @Test func malformedStorageFallsBackToEmptyAndCanBeReplaced() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        try Data("not-json".utf8).write(to: storage)
        let bookmarking = InMemoryFavoriteBookmarking()
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)

        #expect(store.records.isEmpty)
        try store.add(URL(filePath: "/folders/A"))

        let restored = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        #expect(restored.records.map(\.lastKnownPath) == ["/folders/A"])
    }

    @Test func saveCreatesMissingDirectoriesAndLeavesDecodableStorage() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url
            .appending(path: "deep", directoryHint: .isDirectory)
            .appending(path: "support", directoryHint: .isDirectory)
            .appending(path: "favorites.json")
        let store = FavoritesStore(storageURL: storage, bookmarking: InMemoryFavoriteBookmarking())

        try store.add(URL(filePath: "/folders/A"))

        #expect(FileManager.default.fileExists(atPath: storage.path))
        let persisted = try JSONDecoder().decode([FavoriteRecord].self, from: Data(contentsOf: storage))
        #expect(persisted.map(\.lastKnownPath) == ["/folders/A"])
        let siblingNames = try FileManager.default.contentsOfDirectory(
            at: storage.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(siblingNames == ["favorites.json"])
    }

    @Test func failedSaveDoesNotPublishAnUnpersistedFavorite() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let blockingFile = temporaryDirectory.url.appending(path: "not-a-directory")
        try Data().write(to: blockingFile)
        let storage = blockingFile.appending(path: "favorites.json")
        let store = FavoritesStore(storageURL: storage, bookmarking: InMemoryFavoriteBookmarking())

        #expect(throws: (any Error).self) {
            try store.add(URL(filePath: "/folders/A"))
        }
        #expect(store.records.isEmpty)
    }

    @Test func removingFavoriteDoesNotTouchReferencedFolderOrContents() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let folder = temporaryDirectory.url.appending(path: "Favorite", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let marker = folder.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)
        let store = FavoritesStore(
            storageURL: temporaryDirectory.url.appending(path: "favorites.json"),
            bookmarking: InMemoryFavoriteBookmarking()
        )
        try store.add(folder)
        let id = try #require(store.records.first?.id)

        store.remove(id: id)

        #expect(store.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test func invalidMovesLeaveOrderAndStorageUnchanged() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let bookmarking = InMemoryFavoriteBookmarking()
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        try store.add(URL(filePath: "/folders/A"))
        try store.add(URL(filePath: "/folders/B"))
        try store.add(URL(filePath: "/folders/C"))

        store.move(fromOffsets: IndexSet(integer: 8), toOffset: 0)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 9)
        store.move(fromOffsets: [], toOffset: 0)

        #expect(store.records.map(\.displayName) == ["A", "B", "C"])
        let restored = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        #expect(restored.records.map(\.displayName) == ["A", "B", "C"])
    }

    @Test func validMultipleMovePersistsExpectedOrder() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let bookmarking = InMemoryFavoriteBookmarking()
        let store = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        for name in ["A", "B", "C", "D"] {
            try store.add(URL(filePath: "/folders/\(name)"))
        }

        store.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)

        #expect(store.records.map(\.displayName) == ["B", "D", "A", "C"])
        let restored = FavoritesStore(storageURL: storage, bookmarking: bookmarking)
        #expect(restored.records.map(\.displayName) == ["B", "D", "A", "C"])
    }

    @Test func removeSaveFailureRetainsPublishedAndPersistedRecords() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporaryDirectory.url.path
            )
            temporaryDirectory.remove()
        }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let store = FavoritesStore(
            storageURL: storage,
            bookmarking: InMemoryFavoriteBookmarking()
        )
        try store.add(URL(filePath: "/folders/A"))
        let recordsBeforeRemove = store.records
        let storageBeforeRemove = try Data(contentsOf: storage)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: temporaryDirectory.url.path
        )

        store.remove(id: recordsBeforeRemove[0].id)

        #expect(store.records == recordsBeforeRemove)
        #expect(try Data(contentsOf: storage) == storageBeforeRemove)
    }

    @Test func moveSaveFailureRetainsPublishedAndPersistedOrder() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporaryDirectory.url.path
            )
            temporaryDirectory.remove()
        }
        let storage = temporaryDirectory.url.appending(path: "favorites.json")
        let store = FavoritesStore(
            storageURL: storage,
            bookmarking: InMemoryFavoriteBookmarking()
        )
        try store.add(URL(filePath: "/folders/A"))
        try store.add(URL(filePath: "/folders/B"))
        let recordsBeforeMove = store.records
        let storageBeforeMove = try Data(contentsOf: storage)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: temporaryDirectory.url.path
        )

        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(store.records == recordsBeforeMove)
        #expect(try Data(contentsOf: storage) == storageBeforeMove)
    }
}
