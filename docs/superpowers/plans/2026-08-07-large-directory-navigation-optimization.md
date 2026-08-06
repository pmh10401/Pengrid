# Large-Directory Navigation Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a 10,000-entry Pengrid directory show useful rows early and remain responsive while filtering, sorting, scrolling, refreshing, and cancelling, while removing duplicated work in the touched navigation path.

**Architecture:** Keep `DirectoryListingService` and `FilePaneState` as stable boundaries. Add a lazy immediate-child cursor, one-pass metadata and bounded availability building, a generation-bound pane projection snapshot, coalesced pane publication, and a pure AppKit table update planner; each optimized path retains a tested safe fallback.

**Tech Stack:** Swift 6.1, Swift Concurrency, Observation, Foundation URL metadata and File Provider integration, AppKit `NSTableView`, Swift Testing, macOS 15, Swift Package Manager.

## Global Constraints

- Prefix every `xcrun swift` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Run tests with `--disable-sandbox --no-parallel`.
- Add no external dependency and no persistent filesystem index.
- Listing, filtering, sorting, and availability enrichment never materialize online-only contents.
- Preserve `DirectoryListingService.batches(in:)`, scoped-access lifetime, `DirectoryVisibilityPolicy.baseline`, package behavior, and optional metadata fallbacks.
- Preserve file identity checks, Undo authority, recovery journals, symlink policy, archive safety, and protected ZIP behavior.
- Cancellation and generations reject stale listing, projection, availability, refresh, and monitor results.
- Existing workspace and saved-search payloads continue decoding; do not delete compatibility overloads or legacy decoders.
- Target at least 30 percent improvement in first-useful-row and filter/sort time, with no greater than 10 percent regression in complete-load time or peak memory, subject to the approved variance rule.
- Follow RED → verify failure → GREEN → verify pass → refactor → commit.
- Stage only the files named by the current task.

---

## File Structure

- `Services/ImmediateDirectoryEntryCursor.swift`: lazy, nonrecursive immediate-child cursor.
- `Services/DirectoryEntryBatchBuilder.swift`: one-pass metadata and bounded availability work.
- `Services/LiveDirectoryListingService.swift`: scoped-access, cursor consumption, cancellation, and batch publication.
- `Models/PaneItemProjection.swift`: immutable projection key/result and pure filter/sort/index builder.
- `Stores/PaneBatchBuffer.swift`: deterministic first-batch, pending-batch, and injected-delay rules.
- `Stores/FilePaneState.swift`: generations, projection acceptance, coalescing, refresh, and public pane state.
- `Views/AppKit/FileTableUpdatePlanner.swift`: pure identity-based row plan.
- `Views/AppKit/FileTableSupport.swift`: table selection, rename, drop, editing, and responder helpers.
- `Views/AppKit/FileTableView.swift`: AppKit coordinator and row-plan application.
- `Tests/BloomFileManagerTests/Support/NavigationPerformanceProbe.swift`: test-only monotonic measurements.
- `docs/verification/2026-08-07-large-directory-navigation.md`: before/after and cleanup evidence.

### Task 1: Baseline measurement harness

**Files:**
- Create: `Tests/BloomFileManagerTests/Support/NavigationPerformanceProbe.swift`
- Modify: `Tests/BloomFileManagerTests/LargeDirectoryTests.swift`
- Modify: `Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift`
- Create: `docs/verification/2026-08-07-large-directory-navigation.md`

**Interfaces:**
- Consumes: `DirectoryListingService.batches(in:)`, `PaneFilenameFilter`, `FileSort`, `ContinuousClock`.
- Produces: `ListingPerformanceSample` and `measureListing(service:directory:)`.

- [ ] **Step 1: Write the failing probe test**

```swift
@Test func listingPerformanceProbeReportsFirstBatchAndCompletion() async throws {
    let root = try TemporaryDirectory()
    defer { root.removeRecordingFailure() }
    try root.createEmptyFiles(count: 300)
    let sample = try await measureListing(
        service: LiveDirectoryListingService(batchSize: 256),
        directory: root.url
    )
    #expect(sample.itemCount == 300)
    #expect(sample.batchCount == 2)
    #expect(sample.firstBatch <= sample.complete)
}
```

- [ ] **Step 2: Run RED**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter listingPerformanceProbeReportsFirstBatchAndCompletion`

Expected: compilation fails because the sample and probe do not exist.

- [ ] **Step 3: Add the test-only probe**

```swift
import Foundation
@testable import BloomFileManager

struct ListingPerformanceSample: Sendable {
    let firstBatch: Duration
    let complete: Duration
    let batchCount: Int
    let itemCount: Int
}

func measureListing(
    service: any DirectoryListingService,
    directory: URL,
    clock: ContinuousClock = .init()
) async throws -> ListingPerformanceSample {
    let start = clock.now
    var first: Duration?
    var batches = 0
    var items = 0
    for try await batch in service.batches(in: directory) {
        if first == nil { first = start.duration(to: clock.now) }
        batches += 1
        items += batch.count
    }
    let complete = start.duration(to: clock.now)
    return .init(firstBatch: first ?? complete, complete: complete, batchCount: batches, itemCount: items)
}
```

- [ ] **Step 4: Separate 10,000-item filtering, sorting, and table-population measurements**

Build a deterministic fixture with alternating directories/files, Korean/English names, sizes, and dates. Measure five queries and every `FileSortKey` independently. Retain `.seconds(5)` only as a hang/regression ceiling for each group.

```swift
private func makeProjectionFixture(count: Int) -> [FileItem] {
    let root = URL(filePath: "/scale", directoryHint: .isDirectory)
    return (0..<count).map { index in
        let isDirectory = index.isMultiple(of: 10)
        let name = index.isMultiple(of: 2) ? "보고서-\(index)" : "report-\(index)"
        return FileItem(
            url: root.appending(path: name),
            name: name,
            isDirectory: isDirectory,
            isPackage: false,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            byteSize: isDirectory ? nil : Int64(index * 17),
            typeDescription: isDirectory ? "Folder" : "Text"
        )
    }
}
```

Add an `@MainActor` AppKit probe that constructs `FileTableView.Coordinator`, applies the first nonempty item array to an `NSTableView`, calls `layoutSubtreeIfNeeded()`, and records request-to-nonzero-`numberOfRows` plus coordinator application time. Use the same probe before and after Task 6 so `first rendered nonempty table state` is measured with one definition.

- [ ] **Step 5: Run GREEN and record baseline**

Run the focused tests, then run the real 10,000-entry test three times through `/usr/bin/time -l`. Record `sw_vers`, `system_profiler SPHardwareDataType`, raw samples, test-body timing, and maximum resident set size under `Environment` and `Baseline Samples`; do not combine process startup with first-batch time.

- [ ] **Step 6: Commit**

```bash
git add Tests/BloomFileManagerTests/Support/NavigationPerformanceProbe.swift Tests/BloomFileManagerTests/LargeDirectoryTests.swift Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift docs/verification/2026-08-07-large-directory-navigation.md
git commit -m "test: record large-directory navigation baseline"
```

### Task 2: Lazy immediate-child cursor

**Files:**
- Create: `Sources/BloomFileManager/Services/ImmediateDirectoryEntryCursor.swift`
- Modify: `Sources/BloomFileManager/Services/LiveDirectoryListingService.swift`
- Modify: `Tests/BloomFileManagerTests/DirectoryListingServiceTests.swift`

**Interfaces:**
- Produces: `ImmediateDirectoryEntryCursor.next() throws -> URL?` and `ImmediateDirectoryEntryCursorFactory.makeCursor(...)`.

- [ ] **Step 1: Write failing direct-child and non-exhaustion tests**

```swift
@Test func firstListingBatchDoesNotExhaustInjectedCursor() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    for index in 0..<300 {
        try Data().write(to: root.url.appending(path: "item-\(index)"))
    }
    let urls = (0..<300).map { root.url.appending(path: "item-\($0)") }
    let factory = CountingImmediateDirectoryEntryCursorFactory(urls: urls)
    let service = LiveDirectoryListingService(
        batchSize: 256,
        availabilityReader: ConstantAvailabilityReader(.availableLocally),
        cursorFactory: factory
    )
    var iterator = service.batches(in: URL(filePath: "/virtual")).makeAsyncIterator()
    #expect(try await iterator.next()?.count == 256)
    #expect(factory.nextCallCount == 256)
}
```

Also create a real nested fixture and assert only its direct child directory and direct file are returned, never the grandchild.

Define test support with these exact shapes in `DirectoryListingServiceTests.swift`:

```swift
private actor ConstantAvailabilityReader: CloudItemAvailabilityReading {
    let value: CloudItemAvailability
    init(_ value: CloudItemAvailability) { self.value = value }
    func availability(of url: URL) -> CloudItemAvailability { value }
}

private final class CountingImmediateDirectoryEntryCursorFactory:
    ImmediateDirectoryEntryCursorFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let urls: [URL]
    private var calls = 0
    init(urls: [URL]) { self.urls = urls }
    var nextCallCount: Int { lock.withLock { calls } }
    func makeCursor(
        in directory: URL,
        includingPropertiesForKeys keys: Set<URLResourceKey>,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> any ImmediateDirectoryEntryCursor {
        CountingImmediateDirectoryEntryCursor(urls: urls) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.calls += 1 }
        }
    }
}

private final class CountingImmediateDirectoryEntryCursor: ImmediateDirectoryEntryCursor {
    private let lock = NSLock()
    private let urls: [URL]
    private let onURL: () -> Void
    private var index = 0
    init(urls: [URL], onURL: @escaping () -> Void) {
        self.urls = urls
        self.onURL = onURL
    }
    func next() throws -> URL? {
        lock.withLock {
            guard urls.indices.contains(index) else { return nil }
            defer { index += 1; onURL() }
            return urls[index]
        }
    }
}
```

`CountingImmediateDirectoryEntryCursor` keeps a locked index, invokes the callback only when returning a URL, and returns `nil` after the array. This makes the expected count 256 rather than counting the end-of-stream probe.

- [ ] **Step 2: Run RED**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'immediateCursor|firstListingBatchDoesNotExhaustInjectedCursor'`

Expected: cursor types and injection initializer are missing.

- [ ] **Step 3: Add the cursor interfaces and live factory**

```swift
protocol ImmediateDirectoryEntryCursor: AnyObject {
    func next() throws -> URL?
}

protocol ImmediateDirectoryEntryCursorFactory: Sendable {
    func makeCursor(
        in directory: URL,
        includingPropertiesForKeys keys: Set<URLResourceKey>,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> any ImmediateDirectoryEntryCursor
}
```

`LiveImmediateDirectoryEntryCursorFactory` wraps `FileManager.default.enumerator(at:includingPropertiesForKeys:options:errorHandler:)` with `.skipsSubdirectoryDescendants`, captures enumerator errors in an `NSLock`-protected `EnumerationErrorBox`, rejects non-URL objects, and returns errors from `next()`. Add a failing-directory test and assert the captured error terminates the listing stream.

- [ ] **Step 4: Consume only one batch of cursor entries at a time**

Inject the factory with a live default. Validate `batchSize > 0`. Replace `contentsOfDirectory` with a cancellation-checked loop that collects at most `batchSize` URLs, converts and yields them, then asks the cursor for the next group. Keep scoped access alive through cursor exhaustion/cancellation.

- [ ] **Step 5: Run GREEN**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'DirectoryListingServiceTests|LargeDirectoryTests|CloudItemAvailabilityTests|CloudLocationScopedAccessTests'`

Expected: all selected tests pass; first batch observes exactly 256 cursor reads and cloud listing makes no materializer call.

- [ ] **Step 6: Commit**

```bash
git add Sources/BloomFileManager/Services/ImmediateDirectoryEntryCursor.swift Sources/BloomFileManager/Services/LiveDirectoryListingService.swift Tests/BloomFileManagerTests/DirectoryListingServiceTests.swift
git commit -m "perf: stream immediate directory entries lazily"
```

### Task 3: One-pass metadata and bounded availability

**Files:**
- Create: `Sources/BloomFileManager/Services/DirectoryEntryBatchBuilder.swift`
- Modify: `Sources/BloomFileManager/Services/LiveDirectoryListingService.swift`
- Modify: `Tests/BloomFileManagerTests/DirectoryListingServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/CloudItemAvailabilityTests.swift`

**Interfaces:**
- Produces: `DirectoryEntryMetadataReading.metadata(for:)`, `DirectoryEntryMetadata`, and `DirectoryEntryBatchBuilder.build(urls:)`.

- [ ] **Step 1: Write failing order/concurrency/cancellation tests**

```swift
@Test func batchBuilderReadsOnceBoundsConcurrencyAndPreservesOrder() async throws {
    let urls = (0..<20).map { URL(filePath: "/virtual/\($0).txt") }
    let metadata = RecordingDirectoryEntryMetadataReader()
    let availability = ConcurrencyRecordingAvailabilityReader(result: .onlineOnly)
    let builder = DirectoryEntryBatchBuilder(metadataReader: metadata, availabilityReader: availability, maximumConcurrency: 4)
    let items = try await builder.build(urls: urls)
    #expect(items.map(\.url) == urls.map(\.standardizedFileURL))
    #expect(metadata.requestCount == 20)
    #expect(await availability.maximumObservedConcurrency() <= 4)
}
```

Add a suspended-reader cancellation test and expect `CancellationError` with no partial returned array.

`RecordingDirectoryEntryMetadataReader` is an `@unchecked Sendable` final class whose request counter is protected by `NSLock`; it returns deterministic non-directory `DirectoryEntryMetadata` derived from the URL. `ConcurrencyRecordingAvailabilityReader` is an actor that increments `active`, updates `maximumActive`, yields once, decrements `active`, and returns its configured result. Expose only `maximumObservedConcurrency()` to the assertion.

- [ ] **Step 2: Run RED**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'batchBuilderReadsOnce|batchBuilderCancellation'`

Expected: builder and metadata interfaces are missing.

- [ ] **Step 3: Add metadata value and live reader**

```swift
struct DirectoryEntryMetadata: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let modifiedAt: Date?
    let byteSize: Int64?
    let typeDescription: String
    func fileItem(availability: CloudItemAvailability) -> FileItem
}

protocol DirectoryEntryMetadataReading: Sendable {
    func metadata(for url: URL) throws -> DirectoryEntryMetadata
}
```

The live reader performs one `resourceValues` call containing `.isDirectoryKey`, `.isPackageKey`, `.contentModificationDateKey`, `.fileSizeKey`, and `.localizedTypeDescriptionKey`. Preserve `"File"`, `nil` date, and `nil` size fallbacks.

- [ ] **Step 4: Implement the bounded builder**

Use `withThrowingTaskGroup(of: (Int, FileItem).self)` with at most `maximumConcurrency` submitted children. Store results into `[FileItem?]` by original index, submit one replacement after each completion, check cancellation before and after availability, and throw if any result slot is absent. Default concurrency is 8 and must be positive.

```swift
func build(urls: [URL]) async throws -> [FileItem] {
    try await withThrowingTaskGroup(of: (Int, FileItem).self) { group in
        var results = Array<FileItem?>(repeating: nil, count: urls.count)
        var nextIndex = 0
        func submit(_ index: Int) {
            let url = urls[index]
            group.addTask {
                try Task.checkCancellation()
                let metadata = try metadataReader.metadata(for: url)
                let availability = await availabilityReader.availability(of: url.standardizedFileURL)
                try Task.checkCancellation()
                return (index, metadata.fileItem(availability: availability))
            }
        }
        while nextIndex < min(maximumConcurrency, urls.count) {
            submit(nextIndex)
            nextIndex += 1
        }
        while let (index, item) = try await group.next() {
            results[index] = item
            if nextIndex < urls.count {
                submit(nextIndex)
                nextIndex += 1
            }
        }
        guard results.allSatisfy({ $0 != nil }) else { throw CancellationError() }
        return results.map { $0! }
    }
}
```

- [ ] **Step 5: Inject builder and run GREEN**

Replace the temporary serial conversion helper with `try await batchBuilder.build(urls:)` and run:

`env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'DirectoryListingServiceTests|CloudItemAvailabilityTests|CloudLocationScopedAccessTests|LargeDirectoryTests'`

- [ ] **Step 6: Commit**

```bash
git add Sources/BloomFileManager/Services/DirectoryEntryBatchBuilder.swift Sources/BloomFileManager/Services/LiveDirectoryListingService.swift Tests/BloomFileManagerTests/DirectoryListingServiceTests.swift Tests/BloomFileManagerTests/CloudItemAvailabilityTests.swift
git commit -m "perf: bound directory metadata enrichment"
```

### Task 4: Immutable pane projection

**Files:**
- Create: `Sources/BloomFileManager/Models/PaneItemProjection.swift`
- Modify: `Sources/BloomFileManager/Models/PaneFilenameFilter.swift`
- Create: `Tests/BloomFileManagerTests/PaneItemProjectionTests.swift`

**Interfaces:**
- Produces: `PaneProjectionKey`, `PaneItemProjection`, `PaneItemProjector.project(items:key:)`.

- [ ] **Step 1: Write failing projection tests**

```swift
@Test func paneProjectionFiltersSortsAndIndexes() {
    let items = makeProjectionItems([("파일관리.txt", 20), ("보고서.txt", 10), ("파일목록.txt", 30)])
    let key = PaneProjectionKey(itemsRevision: 7, normalizedQuery: "파일", sort: FileSort(key: .size, direction: .descending))
    let result = PaneItemProjector().project(items: items, key: key)
    #expect(result.items.map(\.name) == ["파일목록.txt", "파일관리.txt"])
    #expect(result.indexByURL[items[2].url] == 0)
}

private func makeProjectionItems(_ values: [(String, Int64)]) -> [FileItem] {
    let root = URL(filePath: "/projection", directoryHint: .isDirectory)
    return values.map { name, size in
        FileItem(
            url: root.appending(path: name), name: name,
            isDirectory: false, isPackage: false, modifiedAt: nil,
            byteSize: size, typeDescription: "Text"
        )
    }
}
```

Cover whitespace queries, every sort key/direction, directory-first order, URL tie-breaks, diacritics, Korean names, and deterministic handling of duplicate standardized URLs.

- [ ] **Step 2: Run RED**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter PaneItemProjectionTests`

- [ ] **Step 3: Add the projection types**

```swift
struct PaneProjectionKey: Equatable, Sendable {
    let itemsRevision: UInt64
    let normalizedQuery: String
    let sort: FileSort
}

struct PaneItemProjection: Equatable, Sendable {
    let key: PaneProjectionKey
    let items: [FileItem]
    let indexByURL: [URL: Int]
    let urlByEntryPath: [String: URL]
}

enum PaneEntryPath {
    static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
```

`PaneItemProjector` calls the existing filename filter and sort once, then builds both dictionaries with an explicit loop. If malformed injected input repeats a standardized URL or entry path, the last projected row wins deterministically; do not use `Dictionary(uniqueKeysWithValues:)`, which would terminate the process. Add `PaneFilenameFilter.normalize(_:)` returning `query.trimmingCharacters(in: .whitespacesAndNewlines)` and have both `apply(to:)` and the projection key use it.

```swift
func project(items: [FileItem], key: PaneProjectionKey) -> PaneItemProjection {
    let filtered = PaneFilenameFilter(query: key.normalizedQuery).apply(to: items)
    let projected = key.sort.apply(to: filtered)
    var indexByURL: [URL: Int] = [:]
    var urlByEntryPath: [String: URL] = [:]
    for (index, item) in projected.enumerated() {
        let url = item.url.standardizedFileURL
        indexByURL[url] = index
        urlByEntryPath[PaneEntryPath.normalize(url)] = url
    }
    return .init(key: key, items: projected, indexByURL: indexByURL, urlByEntryPath: urlByEntryPath)
}
```

- [ ] **Step 4: Run GREEN and commit**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'PaneItemProjectionTests|PaneFilenameFilterTests|FileSortTests'`

```bash
git add Sources/BloomFileManager/Models/PaneFilenameFilter.swift Sources/BloomFileManager/Models/PaneItemProjection.swift Tests/BloomFileManagerTests/PaneItemProjectionTests.swift
git commit -m "perf: add pane projection snapshots"
```

### Task 5: Generation-bound pane publication and coalescing

**Files:**
- Create: `Sources/BloomFileManager/Stores/PaneBatchBuffer.swift`
- Create: `Tests/BloomFileManagerTests/PaneBatchBufferTests.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`
- Modify: `Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift`

**Interfaces:**
- Produces: stored `visibleItems`, `visibleIndexByURL`, generation-checked projection acceptance, and `PaneBatchSleeping.sleep(for:)`.

- [ ] **Step 1: Write failing buffer and pane tests**

```swift
@Test func bufferPublishesFirstAndCoalescesLaterBatches() {
    var buffer = PaneBatchBuffer()
    #expect(buffer.receive([item("first")]) == .publish([item("first")]))
    #expect(buffer.receive([item("second")]) == .scheduleFlush)
    #expect(buffer.receive([item("third")]) == .none)
    #expect(buffer.drain().map(\.name) == ["second", "third"])
}

private func item(_ name: String) -> FileItem {
    FileItem(
        url: URL(filePath: "/buffer/\(name)"), name: name,
        isDirectory: false, isPackage: false, modifiedAt: nil,
        byteSize: 1, typeDescription: "File"
    )
}
```

Add pane tests for first batch before stream completion, flush before `navigate` returns, query/sort generation supersession, cancelled-load rejection, atomic refresh failure, and accepted-projection selection intersection.

- [ ] **Step 2: Run RED**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'PaneBatchBufferTests|FilePaneStateTests'`

- [ ] **Step 3: Add deterministic buffer policy**

```swift
enum PaneBatchReceipt: Equatable { case publish([FileItem]), scheduleFlush, none }

protocol PaneBatchSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct LivePaneBatchSleeper: PaneBatchSleeping {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

struct PaneBatchBuffer {
    private var publishedFirst = false
    private var scheduled = false
    private var pending: [FileItem] = []
    mutating func receive(_ batch: [FileItem]) -> PaneBatchReceipt
    mutating func drain() -> [FileItem]
}
```

The first nonempty batch returns `.publish`. Later items append to `pending`; only the first returns `.scheduleFlush`. `drain` returns all pending items, clears them with retained capacity, and resets the scheduled flag. Tests inject a `ControlledPaneBatchSleeper` actor that records one continuation per sleep and resumes it only when the test calls `advance()`, so no test depends on wall-clock timing.

Implement the two buffer methods exactly around this state transition:

```swift
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
```

- [ ] **Step 4: Replace computed projection with stored accepted state**

Add `itemsRevision`, `projectionGeneration`, `projectionTask`, `batchBuffer`, `batchFlushTask`, injected `any PaneBatchSleeping`, default `.milliseconds(60)` flush delay, stored `private(set) var visibleItems`, and stored `private(set) var visibleIndexByURL`. Run pure projection work in a user-initiated detached task; accept only matching directory request, item revision, and projection generation.

`updateFilterQuery` and sort changes schedule one projection. Accepted publication updates both indexes and intersects selection once. First batch is projected immediately; later batches are drained once per window. Completion flushes before `navigate` returns. Failure/cancellation/rollback discard pending work.

```swift
private func rebuildProjection(navigationGeneration: UInt64, directory: URL) async {
    let snapshot = items
    let revision = itemsRevision
    projectionGeneration &+= 1
    let generation = projectionGeneration
    let key = PaneProjectionKey(
        itemsRevision: revision,
        normalizedQuery: PaneFilenameFilter.normalize(filterQuery),
        sort: sort
    )
    let result = await Task.detached(priority: .userInitiated) {
        PaneItemProjector().project(items: snapshot, key: key)
    }.value
    guard nextRequestID == navigationGeneration,
          PaneEntryPath.normalize(currentDirectory) == PaneEntryPath.normalize(directory),
          itemsRevision == revision,
          projectionGeneration == generation else { return }
    visibleItems = result.items
    visibleIndexByURL = result.indexByURL
    selection.formIntersection(result.indexByURL.keys)
}
```

- [ ] **Step 5: Preserve snapshots and atomic refresh**

Extend `PaneSnapshot` with accepted visible items, both indexes, and item revision. Refresh stages raw items and projection privately, then atomically publishes; failure retains old raw and visible state.

- [ ] **Step 6: Run GREEN and commit**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'PaneBatchBufferTests|PaneItemProjectionTests|FilePaneStateTests|PaneNavigationHistoryTests|PaneViewStateCacheTests|WorkspacePersistenceTests|NavigationProductivityPerformanceTests'`

```bash
git add Sources/BloomFileManager/Stores/PaneBatchBuffer.swift Sources/BloomFileManager/Stores/FilePaneState.swift Tests/BloomFileManagerTests/PaneBatchBufferTests.swift Tests/BloomFileManagerTests/FilePaneStateTests.swift Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift
git commit -m "perf: cache and coalesce pane projections"
```

### Task 6: Identity-based AppKit row updates

**Files:**
- Create: `Sources/BloomFileManager/Views/AppKit/FileTableUpdatePlanner.swift`
- Create: `Tests/BloomFileManagerTests/FileTableUpdatePlannerTests.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`

**Interfaces:**
- Produces: `FileTableUpdatePlan` and `FileTableUpdatePlanner.plan(from:to:)`.

- [ ] **Step 1: Write failing planner tests**

```swift
@Test func plannerInsertsWhenOldOrderIsSubsequence() {
    #expect(FileTableUpdatePlanner().plan(from: items(["b", "d"]), to: items(["a", "b", "c", "d"])) == .insert(IndexSet([0, 2])))
}

@Test func plannerFallsBackForDuplicates() {
    #expect(FileTableUpdatePlanner().plan(from: [], to: items(["a", "a"])) == .reloadAll)
}

private func items(_ names: [String]) -> [FileItem] {
    names.map { name in
        FileItem(
            url: URL(filePath: "/table/\(name)"), name: name,
            isDirectory: false, isPackage: false, modifiedAt: nil,
            byteSize: 1, typeDescription: "File"
        )
    }
}
```

Cover equality, changed-value reload, removal, pure reorder moves, mixed insert/remove fallback, standardized URLs, and the incremental-change threshold.

- [ ] **Step 2: Run RED**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter FileTableUpdatePlannerTests`

- [ ] **Step 3: Implement plan model and pure planner**

```swift
struct FileTableRowMove: Equatable { let from: Int; let to: Int }

enum FileTableUpdatePlan: Equatable {
    case none, insert(IndexSet), remove(IndexSet), reload(IndexSet)
    case move([FileTableRowMove]), reloadAll
}

struct FileTableUpdatePlanner {
    let maximumIncrementalChanges: Int
    init(maximumIncrementalChanges: Int = 512)
    func plan(from old: [FileItem], to new: [FileItem]) -> FileTableUpdatePlan
}
```

Reject duplicate URLs. Return reload for identical identity order with changed values, insert/remove for subsequences, sequential moves for equal identity sets, and full reload for mixed or oversized changes.

Use standardized identity arrays and this decision order:

```swift
let oldIDs = old.map { $0.url.standardizedFileURL }
let newIDs = new.map { $0.url.standardizedFileURL }
guard Set(oldIDs).count == oldIDs.count,
      Set(newIDs).count == newIDs.count else { return .reloadAll }
if old == new { return .none }
if oldIDs == newIDs {
    return .reload(IndexSet(new.indices.filter { old[$0] != new[$0] }))
}
if newIDs.filter(Set(oldIDs).contains) == oldIDs {
    let inserted = IndexSet(newIDs.indices.filter { !Set(oldIDs).contains(newIDs[$0]) })
    return inserted.count <= maximumIncrementalChanges ? .insert(inserted) : .reloadAll
}
if oldIDs.filter(Set(newIDs).contains) == newIDs {
    let removed = IndexSet(oldIDs.indices.filter { !Set(newIDs).contains(oldIDs[$0]) })
    return removed.count <= maximumIncrementalChanges ? .remove(removed) : .reloadAll
}
```

For equal identity sets, create sequential moves by mutating a working ID array toward `newIDs`; return `.reloadAll` when move count exceeds the threshold or when item values also changed.

- [ ] **Step 4: Apply plans in coordinator and test AppKit calls**

Use an `UpdateRecordingTableView` to assert sorted batch insertions call `insertRows` and never `reloadData`. Apply structural changes within `beginUpdates`/`endUpdates`, restore selection through one URL-index map, preserve rename/scroll/focus, and use one full reload for ambiguous plans.

Measure 128, 256, 512, and 1,024 change thresholds with the Task 1 table probe. Record results and retain 512 only if it avoids fallback for normal 256-row batches without increasing p95 table-application time or memory beyond the approved gates; otherwise commit the measured threshold and its evidence together.

- [ ] **Step 5: Run GREEN and commit**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'FileTableUpdatePlannerTests|FileTableViewLifecycleTests|FileTableSelectionTests|DropIntentTests|WorkspaceCommandTests|AccessibilityPresentationTests'`

```bash
git add Sources/BloomFileManager/Views/AppKit/FileTableUpdatePlanner.swift Sources/BloomFileManager/Views/AppKit/FileTableView.swift Tests/BloomFileManagerTests/FileTableUpdatePlannerTests.swift Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift
git commit -m "perf: update file table incrementally"
```

### Task 7: Touched-path cleanup

**Files:**
- Create: `Sources/BloomFileManager/Views/AppKit/FileTableSupport.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Sources/BloomFileManager/Services/LiveDirectoryListingService.swift`
- Modify: `Sources/BloomFileManager/Models/PaneItemProjection.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableSelectionTests.swift`
- Modify: `Tests/BloomFileManagerTests/DropIntentTests.swift`

**Interfaces:**
- Produces: unchanged app-facing pane/listing/table APIs with replaced work removed.

- [ ] **Step 1: Record focused pre-refactor GREEN**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'FileTableSelectionTests|DropIntentTests|FileTableViewLifecycleTests|FilePaneStateTests|DirectoryListingServiceTests'`

- [ ] **Step 2: Extract table support without widening private coordinator access**

Move `FileTableSelection`, `InlineRenameSelection`, `FileTableDropRouting`, `InlineTextEditingEvent`, and `PaneActivatingTableView` verbatim into `FileTableSupport.swift`. Keep private `Column` and coordinator callbacks in `FileTableView.swift`.

- [ ] **Step 3: Delete only superseded paths**

Delete the old computed `visibleItems`, second localized-type resource read, Task 2 temporary serial builder, unconditional reload branch, and repeated visible-URL/index scans. Use `urlByEntryPath` for both rename-selection lookups and `visibleIndexByURL` for selection mapping.

Do not delete `legacyTransfer`, Smart Search legacy decoding, archive overloads, Codable keys, selectors, command handlers, task lifecycle, identity validation, or recovery code.

- [ ] **Step 4: Run post-refactor GREEN**

Run the Step 1 tests plus `PaneItemProjectionTests`, `PaneBatchBufferTests`, and `FileTableUpdatePlannerTests`. Run `swift build --disable-sandbox`. Expected: build and all selected tests pass with no duplicate declaration.

- [ ] **Step 5: Record cleanup evidence and commit**

List every removed path, replacement, and test in `Cleanup Evidence`, then commit:

```bash
git add Sources/BloomFileManager/Views/AppKit/FileTableSupport.swift Sources/BloomFileManager/Views/AppKit/FileTableView.swift Sources/BloomFileManager/Stores/FilePaneState.swift Sources/BloomFileManager/Services/LiveDirectoryListingService.swift Sources/BloomFileManager/Models/PaneItemProjection.swift Tests/BloomFileManagerTests/FilePaneStateTests.swift Tests/BloomFileManagerTests/FileTableSelectionTests.swift Tests/BloomFileManagerTests/DropIntentTests.swift docs/verification/2026-08-07-large-directory-navigation.md
git commit -m "refactor: remove duplicated navigation work"
```

### Task 8: Final verification and repository audit handoff

**Files:**
- Modify: `docs/verification/2026-08-07-large-directory-navigation.md`
- Inspect: `Sources/BloomFileManager/**/*.swift`
- Inspect: `Tests/BloomFileManagerTests/**/*.swift`

**Interfaces:**
- Produces: reviewed before/after evidence and a classified global cleanup input; this task performs no unverified global deletion.

- [ ] **Step 1: Repeat the three optimized samples**

Use exactly the Task 1 fixture and commands. Record raw first-batch, first nonempty table population, complete-load, filter/sort, table-application, longest observed main-actor application interval, and maximum-RSS samples, then median, supported p95, and percentage changes.

- [ ] **Step 2: Run focused and full gates**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'DirectoryListingServiceTests|LargeDirectoryTests|PaneItemProjectionTests|PaneBatchBufferTests|FilePaneStateTests|FileTableUpdatePlannerTests|FileTableViewLifecycleTests|CloudItemAvailabilityTests|CloudLocationScopedAccessTests|WorkspacePersistenceTests|WorkspaceCommandTests|AccessibilityPresentationTests'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift build --disable-sandbox -c release
```

- [ ] **Step 3: Perform manual UI and File Provider checks**

In both panes verify first rows during loading, scrolling, Korean/English filters, every sort, navigation cancellation, refresh, rename, selection, scroll restoration, keyboard focus, and VoiceOver. Repeat metadata-only listing/filtering in available Google Drive and OneDrive File Provider roots and verify no content download begins.

- [ ] **Step 4: Produce the global audit input**

Run line-count, declaration, reference, and legacy searches. Classify candidates as `proven-unused`, `duplicate`, `compatibility`, `safety-boundary`, `live-large-file`, or `test-support`. For every deletion candidate record declaration, all references, selector/Codable/reflection review, and tests. A separate deletion plan is written from this evidence; no regex result is deleted automatically.

- [ ] **Step 5: Decide and record acceptance**

Pass performance only at the approved 30/10 thresholds or with raw samples and a justified variance revision. Mark safety, cloud, compatibility, full suite, release build, and UI independently.

- [ ] **Step 6: Commit evidence**

```bash
git add docs/verification/2026-08-07-large-directory-navigation.md
git commit -m "docs: verify large-directory navigation optimization"
```

## Completion Gate

- First rows publish before 10,000-entry cursor exhaustion.
- `visibleItems` is a stored snapshot; repeated reads perform no filter/sort work.
- Later batches coalesce without delaying first batch or completion.
- Ordinary sorted insertions avoid full `reloadData()`.
- Selection, scroll, focus, rename, refresh rollback, monitor races, and cancellation pass.
- Listing/filtering makes zero cloud materialization calls.
- Touched-path duplication is removed with evidence.
- Full tests and release build pass.
- Verification contains raw before/after samples and classified global cleanup input.
