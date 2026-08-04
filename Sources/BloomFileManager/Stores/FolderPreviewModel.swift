import Foundation
import Observation

private struct FolderPreviewProgressRelay: Sendable {
    let stream: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation

    init() {
        let pair = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ count: Int) {
        continuation.yield(count)
    }

    func finish() {
        continuation.finish()
    }
}

private final class FolderPreviewWorkLifetime: @unchecked Sendable {
    private struct Work {
        let relay: FolderPreviewProgressRelay
        let progressConsumerTask: Task<Void, Never>
        let listingTask: Task<Void, Never>
    }

    private let lock = NSLock()
    private var work: Work?

    func replace(
        relay: FolderPreviewProgressRelay,
        progressConsumerTask: Task<Void, Never>,
        listingTask: Task<Void, Never>
    ) {
        cancel(replace(with: Work(
            relay: relay,
            progressConsumerTask: progressConsumerTask,
            listingTask: listingTask
        )))
    }

    func cancel() {
        cancel(replace(with: nil))
    }

    deinit {
        cancel()
    }

    private func replace(with newWork: Work?) -> Work? {
        lock.lock()
        defer { lock.unlock() }
        let previous = work
        work = newWork
        return previous
    }

    private func cancel(_ work: Work?) {
        work?.relay.finish()
        work?.progressConsumerTask.cancel()
        work?.listingTask.cancel()
    }
}

@MainActor @Observable
final class FolderPreviewModel {
    private(set) var request: FolderPreviewRequest?
    private(set) var entries: [FolderPreviewEntry] = []
    private(set) var examinedCount = 0
    private(set) var phase: FolderPreviewPhase = .idle

    var statusText: String {
        switch phase {
        case .idle:
            ""
        case .loading:
            "Loading \(examinedCount) items…"
        case .loaded:
            "\(entries.count) items"
        case .failed(.folderChanged):
            "Folder changed. Close the preview and try again."
        case .failed(.unavailable):
            "Folder contents are unavailable without downloading."
        }
    }

    private let listing: any FolderPreviewListing
    private let workLifetime = FolderPreviewWorkLifetime()
    private var generation = 0

    init(listing: any FolderPreviewListing = LiveFolderPreviewListing()) {
        self.listing = listing
    }

    func load(_ request: FolderPreviewRequest) {
        generation &+= 1
        let loadGeneration = generation
        workLifetime.cancel()
        self.request = request
        entries = []
        examinedCount = 0
        phase = .loading

        let relay = FolderPreviewProgressRelay()
        let progressConsumerTask = Task { @MainActor [weak self] in
            for await count in relay.stream {
                guard !Task.isCancelled else { return }
                self?.publishProgress(count, for: loadGeneration)
            }
        }
        let listing = listing
        let listingTask = Task { [weak self, listing] in
            do {
                let snapshot = try await listing.snapshot(request, progress: relay.yield)
                relay.finish()
                guard !Task.isCancelled else { return }
                self?.publish(snapshot, for: request, generation: loadGeneration)
            } catch is CancellationError {
                relay.finish()
                guard !Task.isCancelled else { return }
                self?.finishCancellation(for: loadGeneration)
            } catch {
                relay.finish()
                guard !Task.isCancelled else { return }
                self?.publish(error: error, for: request, generation: loadGeneration)
            }
        }
        workLifetime.replace(
            relay: relay,
            progressConsumerTask: progressConsumerTask,
            listingTask: listingTask
        )
    }

    func cancel() {
        generation &+= 1
        workLifetime.cancel()
        request = nil
        entries = []
        examinedCount = 0
        phase = .idle
    }

    private func publishProgress(_ count: Int, for loadGeneration: Int) {
        guard loadGeneration == generation,
              phase == .loading,
              count >= examinedCount
        else { return }
        examinedCount = count
    }

    private func publish(
        _ snapshot: FolderPreviewSnapshot,
        for expectedRequest: FolderPreviewRequest,
        generation loadGeneration: Int
    ) {
        guard loadGeneration == generation,
              request == expectedRequest,
              snapshot.request == expectedRequest
        else {
            if loadGeneration == generation, request == expectedRequest {
                entries = []
                phase = .failed(.folderChanged)
                workLifetime.cancel()
            }
            return
        }
        entries = snapshot.entries
        phase = .loaded
        workLifetime.cancel()
    }

    private func publish(
        error: any Error,
        for expectedRequest: FolderPreviewRequest,
        generation loadGeneration: Int
    ) {
        guard loadGeneration == generation, request == expectedRequest else { return }
        entries = []
        if let error = error as? FileSystemAccessError,
           case .identityMismatch = error {
            phase = .failed(.folderChanged)
        } else {
            phase = .failed(.unavailable)
        }
        workLifetime.cancel()
    }

    private func finishCancellation(for loadGeneration: Int) {
        guard loadGeneration == generation else { return }
        request = nil
        entries = []
        examinedCount = 0
        phase = .idle
        workLifetime.cancel()
    }
}
