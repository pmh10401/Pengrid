import Foundation
@testable import BloomFileManager

final class InMemoryComparisonTreeMonitor: ComparisonTreeMonitor, @unchecked Sendable {
    private struct Subscriber {
        let id: UUID
        let continuation: AsyncStream<ComparisonTreeEvent>.Continuation
    }

    private let lock = NSLock()
    private var subscribers: [Subscriber] = []
    private var startsToFail = 0

    var activeStreamCount: Int {
        lock.withLock { subscribers.count }
    }

    func start(roots _: [ComparisonSide: URL]) async -> ComparisonTreeMonitorStart {
        let fails = lock.withLock {
            guard startsToFail > 0 else { return false }
            startsToFail -= 1
            return true
        }
        guard !fails else { return .failed }
        let stream = AsyncStream<ComparisonTreeEvent> { continuation in
            let id = UUID()
            lock.withLock {
                subscribers.append(.init(id: id, continuation: continuation))
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }
        }
        return .started(stream)
    }

    func send(
        _ side: ComparisonSide,
        paths: Set<ComparisonRelativePath>,
        rootChanged: Bool = false,
        requiresFullScan: Bool = false
    ) {
        let continuations = lock.withLock { subscribers.map(\.continuation) }
        let event = ComparisonTreeEvent(
            side: side,
            relativePaths: paths,
            rootChanged: rootChanged,
            requiresFullScan: requiresFullScan
        )
        continuations.forEach { $0.yield(event) }
    }

    func sendRootChanged(_ side: ComparisonSide) {
        send(side, paths: [], rootChanged: true)
    }

    func finish() {
        let continuations = lock.withLock { subscribers.map(\.continuation) }
        continuations.forEach { $0.finish() }
    }

    func failNextStart() {
        lock.withLock { startsToFail += 1 }
    }

    private func remove(id: UUID) {
        lock.withLock {
            subscribers.removeAll { $0.id == id }
        }
    }
}
