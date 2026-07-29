import CoreServices
import Dispatch
import Foundation

struct ComparisonTreeEvent: Sendable {
    let side: ComparisonSide
    let relativePaths: Set<ComparisonRelativePath>
    let rootChanged: Bool
    let requiresFullScan: Bool

    init(
        side: ComparisonSide,
        relativePaths: Set<ComparisonRelativePath>,
        rootChanged: Bool,
        requiresFullScan: Bool = false
    ) {
        self.side = side
        self.relativePaths = relativePaths
        self.rootChanged = rootChanged
        self.requiresFullScan = requiresFullScan
    }
}

enum ComparisonTreeMonitorStart: Sendable {
    case started(AsyncStream<ComparisonTreeEvent>)
    case failed
}

protocol ComparisonTreeMonitor: Sendable {
    func start(roots: [ComparisonSide: URL]) async -> ComparisonTreeMonitorStart
}

struct LiveComparisonTreeMonitor: ComparisonTreeMonitor, Sendable {
    let latency: CFTimeInterval
    private let onOwnerStopped: @Sendable () -> Void
    private let accessCoordinator: CloudLocationScopedAccessCoordinator

    init(
        latency: CFTimeInterval = 0.2,
        onOwnerStopped: @escaping @Sendable () -> Void = {},
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.latency = max(0, latency)
        self.onOwnerStopped = onOwnerStopped
        self.accessCoordinator = accessCoordinator
    }

    func start(roots: [ComparisonSide: URL]) async -> ComparisonTreeMonitorStart {
        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: Array(roots.values))
        } catch {
            return .failed
        }
        let channel = ComparisonTreeEventChannel.make()
        let owner = FSEventOwner(
            roots: roots,
            latency: latency,
            continuation: channel.continuation,
            onStopped: onOwnerStopped,
            accessLeases: accessLeases
        )
        channel.continuation.onTermination = { _ in owner.stop() }
        guard owner.start() else { return .failed }
        return .started(channel.stream)
    }
}

struct ComparisonTreeEventChannel {
    let stream: AsyncStream<ComparisonTreeEvent>
    let continuation: AsyncStream<ComparisonTreeEvent>.Continuation

    static func make() -> ComparisonTreeEventChannel {
        let channel = AsyncStream<ComparisonTreeEvent>.makeStream(bufferingPolicy: .unbounded)
        return ComparisonTreeEventChannel(
            stream: channel.stream,
            continuation: channel.continuation
        )
    }
}

private struct ComparisonWatchRoot {
    let side: ComparisonSide
    let canonicalPath: String

    init(side: ComparisonSide, url: URL) {
        self.side = side
        canonicalPath = canonicalMonitorLocation(url).path
    }

    func contains(_ path: String) -> Bool {
        if canonicalPath == "/" { return path.hasPrefix("/") }
        return path == canonicalPath || path.hasPrefix(canonicalPath + "/")
    }

    func relativePath(for path: String) -> ComparisonRelativePath? {
        guard path != canonicalPath else { return nil }
        let relative: Substring
        if canonicalPath == "/" {
            relative = path.dropFirst()
        } else {
            relative = path.dropFirst(canonicalPath.count + 1)
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return try? ComparisonRelativePath(components: components)
    }
}

final class ComparisonTreeEventMapper {
    private let roots: [ComparisonWatchRoot]
    private var lastEventID: FSEventStreamEventId?

    init(roots: [ComparisonSide: URL]) {
        self.roots = roots.map(ComparisonWatchRoot.init(side:url:)).sorted {
            $0.canonicalPath.count > $1.canonicalPath.count
        }
    }

    var watchPaths: [String] { roots.map(\.canonicalPath) }

    func events(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        eventIDs: [FSEventStreamEventId]
    ) -> [ComparisonTreeEvent] {
        var relativePaths: [ComparisonSide: Set<ComparisonRelativePath>] = [:]
        var rootChanges: Set<ComparisonSide> = []
        var fullScans: Set<ComparisonSide> = []
        let count = min(paths.count, flags.count, eventIDs.count)

        for index in 0 ..< count {
            let canonicalPath = canonicalMonitorLocation(URL(filePath: paths[index])).path
            let root = roots.first { $0.contains(canonicalPath) }
            let eventFlags = flags[index]
            let eventID = eventIDs[index]
            let historyIsInvalid = lastEventID.map { eventID <= $0 } ?? false
            lastEventID = eventID
            let requiresRecovery = historyIsInvalid || Self.hasLossFlag(eventFlags)
            if requiresRecovery {
                if canonicalPath == "/" {
                    fullScans.formUnion(roots.map(\.side))
                } else if let root {
                    fullScans.insert(root.side)
                } else {
                    fullScans.formUnion(roots.map(\.side))
                }
            }
            guard let root else { continue }
            let changedRoot = canonicalPath == root.canonicalPath && (
                eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                    || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
                    || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
            )
            if changedRoot {
                rootChanges.insert(root.side)
            } else if !requiresRecovery, let path = root.relativePath(for: canonicalPath) {
                relativePaths[root.side, default: []].insert(path)
            }
        }

        let sides = Set(relativePaths.keys).union(rootChanges).union(fullScans)
        return sides.sorted(by: Self.sideOrder).map { side in
            ComparisonTreeEvent(
                side: side,
                relativePaths: fullScans.contains(side) ? [] : relativePaths[side, default: []],
                rootChanged: rootChanges.contains(side),
                requiresFullScan: fullScans.contains(side)
            )
        }
    }

    private static func hasLossFlag(_ flags: FSEventStreamEventFlags) -> Bool {
        let lossFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
        )
        return flags & lossFlags != 0
    }

    private static func sideOrder(_ lhs: ComparisonSide, _ rhs: ComparisonSide) -> Bool {
        lhs == .left && rhs == .right
    }
}

private final class FSEventOwner: @unchecked Sendable {
    private let mapper: ComparisonTreeEventMapper
    private let latency: CFTimeInterval
    private let continuation: AsyncStream<ComparisonTreeEvent>.Continuation
    private let onStopped: @Sendable () -> Void
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    private var stream: FSEventStreamRef?
    private var retainedContext: UnsafeMutableRawPointer?
    private var pendingPaths: [ComparisonSide: Set<ComparisonRelativePath>] = [:]
    private var rootChanges: Set<ComparisonSide> = []
    private var fullScans: Set<ComparisonSide> = []
    private var pendingFlush: DispatchWorkItem?
    private var hasStarted = false
    private var hasStopped = false
    private var accessLeases: [CloudLocationScopedAccessLease]

    init(
        roots: [ComparisonSide: URL],
        latency: CFTimeInterval,
        continuation: AsyncStream<ComparisonTreeEvent>.Continuation,
        onStopped: @escaping @Sendable () -> Void,
        accessLeases: [CloudLocationScopedAccessLease]
    ) {
        mapper = ComparisonTreeEventMapper(roots: roots)
        self.latency = latency
        self.continuation = continuation
        self.onStopped = onStopped
        self.accessLeases = accessLeases
        queue = DispatchQueue(
            label: "com.minho.BloomFileManager.comparison-tree-monitor.\(UUID().uuidString)"
        )
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        accessLeases.forEach { $0.finish() }
    }

    func start() -> Bool {
        var succeeded = false
        executeSynchronously {
            guard !hasStarted, !hasStopped, !mapper.watchPaths.isEmpty else {
                if mapper.watchPaths.isEmpty { stopOnQueue() }
                return
            }
            hasStarted = true

            let retained = Unmanaged.passRetained(self)
            let contextPointer = retained.toOpaque()
            retainedContext = contextPointer
            var context = FSEventStreamContext(
                version: 0,
                info: contextPointer,
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let paths = mapper.watchPaths as CFArray
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                comparisonTreeEventCallback,
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                releaseRetainedContextOnce()
                stopOnQueue()
                return
            }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                stopOnQueue()
                return
            }
            succeeded = true
        }
        return succeeded
    }

    func stop() {
        executeSynchronously { stopOnQueue() }
    }

    func receive(
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>,
        count: Int
    ) {
        precondition(DispatchQueue.getSpecific(key: queueKey) != nil)
        guard !hasStopped else { return }

        let mapped = mapper.events(
            paths: paths,
            flags: Array(UnsafeBufferPointer(start: flags, count: count)),
            eventIDs: Array(UnsafeBufferPointer(start: eventIDs, count: count))
        )
        for event in mapped {
            pendingPaths[event.side, default: []].formUnion(event.relativePaths)
            if event.rootChanged { rootChanges.insert(event.side) }
            if event.requiresFullScan { fullScans.insert(event.side) }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard pendingFlush == nil,
              !pendingPaths.isEmpty || !rootChanges.isEmpty || !fullScans.isEmpty
        else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + latency, execute: work)
    }

    private func flush() {
        precondition(DispatchQueue.getSpecific(key: queueKey) != nil)
        guard !hasStopped else { return }
        pendingFlush = nil
        let sides = Set(pendingPaths.keys).union(rootChanges).union(fullScans)
        let paths = pendingPaths
        let changed = rootChanges
        let scans = fullScans
        pendingPaths.removeAll(keepingCapacity: true)
        rootChanges.removeAll(keepingCapacity: true)
        fullScans.removeAll(keepingCapacity: true)
        for side in sides {
            continuation.yield(.init(
                side: side,
                relativePaths: scans.contains(side) ? [] : paths[side, default: []],
                rootChanged: changed.contains(side),
                requiresFullScan: scans.contains(side)
            ))
        }
    }

    private func stopOnQueue() {
        guard !hasStopped else { return }
        hasStopped = true
        pendingFlush?.cancel()
        pendingFlush = nil
        pendingPaths.removeAll()
        rootChanges.removeAll()
        fullScans.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        accessLeases.forEach { $0.finish() }
        accessLeases.removeAll()
        releaseRetainedContextOnce()
        continuation.finish()
        onStopped()
    }

    private func releaseRetainedContextOnce() {
        guard let retainedContext else { return }
        self.retainedContext = nil
        Unmanaged<FSEventOwner>.fromOpaque(retainedContext).release()
    }

    private func executeSynchronously(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }
}

private let comparisonTreeEventCallback: FSEventStreamCallback = {
    _, context, count, paths, flags, eventIDs in
    guard let context else { return }
    let owner = Unmanaged<FSEventOwner>.fromOpaque(context).takeUnretainedValue()
    let values = unsafeBitCast(paths, to: NSArray.self)
    guard let stringPaths = values as? [String] else { return }
    owner.receive(paths: stringPaths, flags: flags, eventIDs: eventIDs, count: count)
}

private func canonicalMonitorLocation(_ url: URL) -> URL {
    let standardized = url.standardizedFileURL
    let parent = standardized.deletingLastPathComponent()
        .resolvingSymlinksInPath()
        .standardizedFileURL
    return parent.appendingPathComponent(
        standardized.lastPathComponent,
        isDirectory: standardized.hasDirectoryPath
    ).standardizedFileURL
}
