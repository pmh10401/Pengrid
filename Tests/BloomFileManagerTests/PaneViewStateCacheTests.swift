import Foundation
import Testing
@testable import BloomFileManager

struct PaneViewStateCacheTests {
    @Test func cacheReturnsStoredSelectionAndAnchor() {
        var cache = PaneViewStateCache(capacity: 2)
        let directory = URL(filePath: "/folder")
        let state = PaneDirectoryViewState(
            selection: [URL(filePath: "/folder/a")],
            scrollAnchor: URL(filePath: "/folder/m")
        )

        cache.store(state, for: directory)

        #expect(cache.value(for: directory) == state)
    }

    @Test func cacheEvictsTheLeastRecentlyUsedDirectory() {
        var cache = PaneViewStateCache(capacity: 2)
        let a = URL(filePath: "/a")
        let b = URL(filePath: "/b")
        let c = URL(filePath: "/c")
        cache.store(.init(selection: [], scrollAnchor: nil), for: a)
        cache.store(.init(selection: [], scrollAnchor: nil), for: b)

        _ = cache.value(for: a)
        cache.store(.init(selection: [], scrollAnchor: nil), for: c)

        #expect(cache.value(for: a) != nil)
        #expect(cache.value(for: b) == nil)
        #expect(cache.value(for: c) != nil)
    }

    @Test func cacheTreatsTrailingDirectorySeparatorsAsTheSameLocation() {
        var cache = PaneViewStateCache(capacity: 2)
        let folder = URL(string: "file:///folder")!
        let folderWithSeparator = URL(string: "file:///folder/")!
        let state = PaneDirectoryViewState(
            selection: [URL(filePath: "/folder/report.txt")],
            scrollAnchor: URL(filePath: "/folder/summary.txt")
        )

        cache.store(state, for: folderWithSeparator)

        #expect(cache.value(for: folder) == state)
    }
}
