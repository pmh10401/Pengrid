import Foundation

struct PaneDirectoryViewState: Equatable, Sendable {
    let selection: Set<URL>
    let scrollAnchor: URL?
}

struct PaneScrollRequest: Equatable, Sendable {
    let id: UUID
    let anchor: URL
}

struct PaneViewStateCache: Sendable {
    private var values: [String: PaneDirectoryViewState] = [:]
    private var recency: [String] = []
    let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    mutating func store(_ value: PaneDirectoryViewState, for directory: URL) {
        let key = Self.key(directory)
        values[key] = value
        touch(key)
        while recency.count > capacity {
            values.removeValue(forKey: recency.removeFirst())
        }
    }

    mutating func value(for directory: URL) -> PaneDirectoryViewState? {
        let key = Self.key(directory)
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    private mutating func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}
