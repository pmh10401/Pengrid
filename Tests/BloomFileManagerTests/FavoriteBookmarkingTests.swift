import Foundation
import Testing
@testable import BloomFileManager

struct FavoriteBookmarkingTests {
    @Test func liveBookmarkResolvesDirectoryAfterRename() throws {
        let temporaryDirectory = try TemporaryDirectory()
        defer { temporaryDirectory.remove() }
        let original = temporaryDirectory.url.appending(path: "Original", directoryHint: .isDirectory)
        let renamed = temporaryDirectory.url.appending(path: "Renamed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let bookmarking = LiveFavoriteBookmarking()
        let bookmarkData = try bookmarking.createBookmark(for: original)

        try FileManager.default.moveItem(at: original, to: renamed)
        let resolved = try bookmarking.resolve(bookmarkData)

        #expect(
            resolved.url.resolvingSymlinksInPath().standardizedFileURL
                == renamed.resolvingSymlinksInPath().standardizedFileURL
        )
        #expect(FileManager.default.fileExists(atPath: resolved.url.path))
    }
}
