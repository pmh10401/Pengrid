import Foundation

enum PaneBatchReceipt: Equatable {
    case publish([FileItem])
    case scheduleFlush
    case none
}

protocol PaneBatchSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct LivePaneBatchSleeper: PaneBatchSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct PaneBatchBuffer {
    private var publishedFirst = false
    private var scheduled = false
    private var pending: [FileItem] = []

    mutating func receive(_ batch: [FileItem]) -> PaneBatchReceipt {
        guard !batch.isEmpty else { return .none }
        if !publishedFirst {
            publishedFirst = true
            return .publish(batch)
        }
        pending.append(contentsOf: batch)
        guard !scheduled else { return .none }
        scheduled = true
        return .scheduleFlush
    }

    mutating func drain() -> [FileItem] {
        let result = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        return result
    }
}
