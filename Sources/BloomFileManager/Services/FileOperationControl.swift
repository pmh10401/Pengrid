import Foundation

actor FileOperationControl {
    private enum State {
        case running
        case paused
        case cancelled
    }

    private var state: State = .running
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    var isPaused: Bool { state == .paused }
    var waitingCount: Int { waiters.count }

    func pause() {
        guard state != .cancelled else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        state = .running
        let continuations = waiters.values
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func cancel() {
        guard state != .cancelled else { return }
        state = .cancelled
        let continuations = waiters.values
        waiters.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    func checkpoint() async throws {
        try Task.checkCancellation()
        switch state {
        case .running:
            return
        case .cancelled:
            throw CancellationError()
        case .paused:
            break
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledWaiterIDs.remove(waiterID) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    switch state {
                    case .running:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .paused:
                        waiters[waiterID] = continuation
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledWaiterIDs.insert(id)
        }
    }
}
