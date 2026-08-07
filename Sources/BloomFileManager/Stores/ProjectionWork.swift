import Foundation

final class ProjectionWork: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelWorker: @Sendable () -> Void
    private var publication: Task<Void, Never>?
    private var cancelled = false

    init<Value: Sendable>(worker: Task<Value, Error>) {
        cancelWorker = { worker.cancel() }
    }

    func installPublication(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if cancelled {
                return true
            }
            publication = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let handles = lock.withLock { () -> (@Sendable () -> Void, Task<Void, Never>?)? in
            guard !cancelled else { return nil }
            cancelled = true
            defer { self.publication = nil }
            return (cancelWorker, self.publication)
        }
        handles?.0()
        handles?.1?.cancel()
    }
}
