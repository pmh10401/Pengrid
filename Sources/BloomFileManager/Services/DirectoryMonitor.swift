import Darwin
import Dispatch
import Foundation

protocol DirectoryMonitor: Sendable {
    func events(for directory: URL) -> AsyncStream<Void>
}

struct LiveDirectoryMonitor: DirectoryMonitor, Sendable {
    private let debounceNanoseconds: UInt64
    private let onFileDescriptorClosed: @Sendable (Int32) -> Void
    private let accessCoordinator: CloudLocationScopedAccessCoordinator

    init(
        debounceNanoseconds: UInt64 = 200_000_000,
        onFileDescriptorClosed: @escaping @Sendable (Int32) -> Void = { _ in },
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.onFileDescriptorClosed = onFileDescriptorClosed
        self.accessCoordinator = accessCoordinator
    }

    func events(for directory: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let accessLease: CloudLocationScopedAccessLease?
            do {
                accessLease = try accessCoordinator.acquireAccess(for: directory)
            } catch {
                continuation.finish()
                return
            }
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else {
                accessLease?.finish()
                continuation.finish()
                return
            }

            let queue = DispatchQueue(
                label: "com.minho.BloomFileManager.directory-monitor.\(UUID().uuidString)"
            )
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: queue
            )
            let closer = FileDescriptorCloser(
                descriptor: descriptor,
                onClose: onFileDescriptorClosed
            )
            let debouncer = DirectoryEventDebouncer(
                queue: queue,
                debounceNanoseconds: debounceNanoseconds,
                continuation: continuation
            )

            source.setEventHandler {
                debouncer.receive(source.data)
            }
            source.setCancelHandler {
                debouncer.cancelPendingEvent()
                closer.closeOnce()
                accessLease?.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }
}

private final class DirectoryEventDebouncer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let debounceNanoseconds: UInt64
    private let continuation: AsyncStream<Void>.Continuation
    private var pendingEvent: DispatchWorkItem?
    private var shouldFinishAfterEvent = false

    init(
        queue: DispatchQueue,
        debounceNanoseconds: UInt64,
        continuation: AsyncStream<Void>.Continuation
    ) {
        self.queue = queue
        self.debounceNanoseconds = debounceNanoseconds
        self.continuation = continuation
    }

    func receive(_ events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            shouldFinishAfterEvent = true
        }

        pendingEvent?.cancel()
        let event = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingEvent = nil
            continuation.yield()
            if shouldFinishAfterEvent {
                continuation.finish()
            }
        }
        pendingEvent = event
        let delay = Int(min(debounceNanoseconds, UInt64(Int.max)))
        queue.asyncAfter(deadline: .now() + .nanoseconds(delay), execute: event)
    }

    func cancelPendingEvent() {
        pendingEvent?.cancel()
        pendingEvent = nil
    }
}

private final class FileDescriptorCloser: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private let onClose: @Sendable (Int32) -> Void
    private var isClosed = false

    init(descriptor: Int32, onClose: @escaping @Sendable (Int32) -> Void) {
        self.descriptor = descriptor
        self.onClose = onClose
    }

    func closeOnce() {
        let shouldClose = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        close(descriptor)
        onClose(descriptor)
    }
}
