import Foundation
import Testing
@testable import BloomFileManager

struct PaneNavigationHistoryTests {
    @Test func userNavigationDropsAdjacentDuplicatesAndClearsForward() {
        var history = PaneNavigationHistory(capacity: 3)
        let a = URL(filePath: "/a")
        let b = URL(filePath: "/b")
        history.recordUserNavigation(from: a, to: b)
        history.recordUserNavigation(from: URL(filePath: "/a/"), to: b)
        #expect(history.backward == [a])
        #expect(history.forward.isEmpty)
    }

    @Test func stacksKeepOnlyTheNewestCapacityEntries() {
        var history = PaneNavigationHistory(capacity: 3)
        let urls = (0...4).map { URL(filePath: "/\($0)") }
        for index in 1..<urls.count {
            history.recordUserNavigation(from: urls[index - 1], to: urls[index])
        }
        #expect(history.backward == Array(urls[1...3]))
    }

    @Test func backwardAndForwardTransitionsAreSymmetric() {
        var history = PaneNavigationHistory(capacity: 100)
        let a = URL(filePath: "/a")
        let b = URL(filePath: "/b")
        let c = URL(filePath: "/c")
        history.recordUserNavigation(from: a, to: b)
        history.recordUserNavigation(from: b, to: c)
        #expect(history.popBackward(from: c) == b)
        #expect(history.backward == [a])
        #expect(history.forward == [c])
        #expect(history.popForward(from: b) == c)
        #expect(history.backward == [a, b])
        #expect(history.forward.isEmpty)
    }
}
