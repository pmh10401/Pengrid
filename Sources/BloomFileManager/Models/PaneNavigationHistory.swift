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
        guard let target = backward.last else { return nil }
        commitBackwardNavigation(from: current, to: target)
        return target
    }

    mutating func popForward(from current: URL) -> URL? {
        guard let target = forward.last else { return nil }
        commitForwardNavigation(from: current, to: target)
        return target
    }

    mutating func commitBackwardNavigation(from current: URL, to destination: URL) {
        guard backward.last.map(Self.path) == Self.path(destination) else { return }
        backward.removeLast()
        forward = Self.appending(current, to: forward, capacity: capacity)
    }

    mutating func commitForwardNavigation(from current: URL, to destination: URL) {
        guard forward.last.map(Self.path) == Self.path(destination) else { return }
        forward.removeLast()
        backward = Self.appending(current, to: backward, capacity: capacity)
    }

    mutating func discardBackwardDestination(_ destination: URL) {
        guard backward.last.map(Self.path) == Self.path(destination) else { return }
        backward.removeLast()
    }

    mutating func discardForwardDestination(_ destination: URL) {
        guard forward.last.map(Self.path) == Self.path(destination) else { return }
        forward.removeLast()
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
