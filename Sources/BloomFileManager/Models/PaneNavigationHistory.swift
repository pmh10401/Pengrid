import Foundation

struct PaneNavigationHistory: Equatable, Sendable {
    private(set) var backward: [URL] = []
    private(set) var forward: [URL] = []
    let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    mutating func recordUserNavigation(from current: URL, to destination: URL) {
        guard Self.path(current) != Self.path(destination) else { return }
        backward = Self.appending(current, to: backward, capacity: capacity)
        forward.removeAll(keepingCapacity: true)
    }

    mutating func popBackward(from current: URL) -> URL? {
        guard let target = backward.popLast() else { return nil }
        forward = Self.appending(current, to: forward, capacity: capacity)
        return target
    }

    mutating func popForward(from current: URL) -> URL? {
        guard let target = forward.popLast() else { return nil }
        backward = Self.appending(current, to: backward, capacity: capacity)
        return target
    }

    private static func appending(
        _ url: URL,
        to original: [URL],
        capacity: Int
    ) -> [URL] {
        var stack = original
        let normalized = Self.path(url)
        if stack.last.map(Self.path) != normalized {
            stack.append(url.standardizedFileURL)
        }
        if stack.count > capacity {
            stack.removeFirst(stack.count - capacity)
        }
        return stack
    }

    private static func path(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
