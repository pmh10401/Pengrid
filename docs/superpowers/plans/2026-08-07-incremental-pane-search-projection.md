# Incremental Pane Search Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make 10,000-entry pane filename filtering respond within the approved interactive latency gates while preserving the exact current localized search result, sort order, selection, rename, scroll, accessibility, cloud, and cancellation semantics.

**Architecture:** Retain one sorted active-order snapshot for the current directory revision and sort. Narrow only provably safe one-scalar ASCII-alphanumeric query extensions over printable-ASCII filenames, while rescanning every localized fallback filename. Publish rows, indexes, selection, and search metadata through one aggregate assignment. Own both publication and detached worker tasks, and use an immediate visible-subset sort plus a cancellable metadata-only active-order warm-up for nonempty sort changes.

**Tech Stack:** Swift 6.1 language mode, Swift Concurrency, Observation, Foundation localized comparison, SwiftUI, AppKit `NSTableView`, Swift Testing, macOS 15, Swift Package Manager.

## Global Constraints

- Prefix every `xcrun swift` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Run tests with `--disable-sandbox --no-parallel`; use `-c release` for recorded performance samples.
- Preserve the exact oracle `FileSort.apply(to: PaneFilenameFilter.apply(to: rawItems))` for every query, sort key, direction, and malformed-input fallback.
- Keep `PaneFilenameFilter.normalize` as whitespace/newline trimming only. Do not add NFC normalization, folding, Korean initial-consonant search, or new search semantics.
- Add no external dependency, persistent filesystem index, multi-directory cache, or multi-sort cache.
- Use only already-loaded `FileItem` metadata. Filtering, active-order construction, and benchmarking must not invoke cloud materialization or start a download.
- Retain at most one current active-order snapshot, one current visible worker, and one current warm-up worker. Cancelled tails may finish no more than one 128-item chunk and must be released after draining.
- Keep `FileTableUpdatePlanner`'s production structural threshold at `0`; this feature does not enable incremental table mutations.
- Preserve `DirectoryListingService`, scoped-access lifetime, file identity checks, Undo authority, recovery journals, symlink policy, archive/protected-ZIP safety, legacy persistence decoders, and workspace/saved-search payload compatibility.
- Treat cached/query transitions at 75/100/200 ms p50/p95/max, complete load at 500/750/1000 ms, 10,000-row sort at 250/300/400 ms, and <=3,439-row sort at 80/100/150 ms as hard latency gates. The 75 ms <=3,439-row sort p50 and 50 ms ready-order targets are stretch reports. Relative matched-cell p50 is hard only at `C50 <= B50 + max(10% of B50, 5 ms)`; relative p95 is advisory only.
- Treat `>= 30%` post-first-character p95 improvement and `>= 40%` complete-trace p95 improvement as aspirational reports only.
- Follow RED → verify the expected failure → GREEN → refactor → focused verification → commit. Stage only files named by the active task.

---

## File Structure

- `Models/PaneFilenameFilter.swift`: unchanged localized predicate plus printable-ASCII and query-extension eligibility helpers.
- `Models/PaneItemProjection.swift`: request identities, active-order/search snapshots, exact projector paths, result indexes, and diagnostics.
- `Stores/ProjectionWork.swift`: explicit ownership and cancellation of detached workers and publication tasks.
- `Stores/FilePaneState.swift`: atomic accepted aggregate, generation routing, selection compatibility, visible work, and active-order warm-up.
- `Views/FilePaneView.swift`: passes accepted projection tokens to the AppKit table without changing the filter field contract.
- `Views/AppKit/FileTableView.swift`: reports completion only after the newest projection has been applied.
- `Tests/BloomFileManagerTests/Support/PaneSearchPerformanceProbe.swift`: deterministic fixture, trace driver, nearest-rank p95, and RSS sampling.
- `Tests/BloomFileManagerTests/PaneSearchBenchmarkTests.swift`: opt-in release benchmark and hard-gate assertions.
- `script/benchmark_pane_search.sh`: isolated baseline/candidate benchmark runner.
- `docs/verification/2026-08-07-incremental-pane-search.md`: raw environment, baseline, candidate, gate, fallback, and manual evidence.

### Task 1: Record the unchanged interactive baseline

**Files:**
- Create: `Tests/BloomFileManagerTests/Support/PaneSearchPerformanceProbe.swift`
- Create: `Tests/BloomFileManagerTests/PaneSearchBenchmarkTests.swift`
- Modify: `Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift`
- Create: `script/benchmark_pane_search.sh`
- Create: `docs/verification/2026-08-07-incremental-pane-search.md`
- Create: `docs/verification/2026-08-07-incremental-pane-search-baseline.json`

**Interfaces:**

```swift
enum PaneSearchTrace: String, CaseIterable, Sendable {
    case completeLoad
    case firstQuery
    case numeric
    case english
    case korean
    case reverseDeletion
    case replacement
    case rapidBurst
    case sortChange
}

struct PaneSearchTransitionSample: Codable, Sendable {
    let sampleIndex: Int
    let trace: String
    let fromQuery: String
    let toQuery: String
    let expectedCount: Int
    let sortKey: String?
    let sortDirection: String?
    let cardinality: Int
    let projectionPath: String?
    let setterToAcceptanceSeconds: Double
    let acceptanceToTableSeconds: Double
    let endToEndSeconds: Double
    let peakResidentBytes: UInt64
    let cancelledWorkerCandidateVisits: Int
}

struct PaneSearchStatistics: Codable, Sendable {
    let medianSeconds: Double
    let p95Seconds: Double
}

func paneSearchFixture(count: Int = 10_000) -> [FileItem]
func nearestRankStatistics(_ values: [Double]) -> PaneSearchStatistics
```

- [ ] **Step 1: Write the failing trace-probe tests**

Move the existing private 10,000-row fixture out of `NavigationProductivityPerformanceTests.swift` and make both suites use the one test-support function. Preserve the numeric counts `3_439`, `299`, `20`, and `1` for `"1"`, `"19"`, `"199"`, and `"1999"`.

```swift
@MainActor @Test func paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries() async throws {
    let sample = try await measurePaneSearchTrace(
        trace: .numeric,
        warmups: 0,
        samples: 1
    )
    #expect(sample.transitions.map(\.expectedCount) == [3_439, 299, 20, 1])
    #expect(sample.transitions.allSatisfy { $0.setterToAcceptanceSeconds >= 0 })
    #expect(sample.transitions.allSatisfy { $0.acceptanceToTableSeconds >= 0 })
    #expect(sample.transitions.allSatisfy { $0.endToEndSeconds >= 0 })
}
```

The probe must:

1. construct a real `FilePaneState` and `FileTableView.Coordinator`;
2. warm the table with the empty-query result;
3. record immediately before `updateFilterQuery` (the same method called by the `FilePaneView` binding);
4. observe the accepted `visibleItems` change through Observation;
5. call `Coordinator.apply(items:selection:to:)` and `layoutSubtreeIfNeeded()`;
6. record after that call returns; and
7. compare every accepted row identity and order with the current full filter/sort oracle.

- [ ] **Step 2: Run RED**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries
```

Expected: compilation fails because the trace, probe, and shared fixture do not exist.

- [ ] **Step 3: Implement the test-only probe and opt-in benchmark**

Use three unrecorded warm-ups and at least 30 recorded samples when `PENGRID_PANE_SEARCH_BENCHMARK=1`; otherwise skip the expensive benchmark test without skipping the one-sample contract test. The environment variable `PENGRID_PANE_SEARCH_SCENARIO` selects exactly one trace or one sort cell per process. Measure complete load, first query, numeric, English, Korean, reverse deletion, replacement/multi-scalar paste/whitespace normalization, a 20-query burst, and every sort key/direction/cardinality cell. Calculate complete-trace duration from the first setter dispatch to the final table apply.

```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_BENCHMARK"] == "1"))
func paneSearchReleaseBenchmark() async throws {
    let report = try await PaneSearchPerformanceProbe(
        warmupCount: 3,
        sampleCount: 30,
        scenario: try #require(ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_SCENARIO"])
    ).measureSelectedScenario()
    try report.writeJSON(to: try #require(
        ProcessInfo.processInfo.environment["PENGRID_PANE_SEARCH_REPORT"]
    ))
}
```

Sample RSS inside the isolated benchmark process with `task_info(mach_task_self_, MACH_TASK_BASIC_INFO, infoPointer, &count)`, retaining the largest observed resident size across the selected scenario. Keep `/usr/bin/time -l` around each invocation as independent corroborating evidence.

- [ ] **Step 4: Add the isolated release runner**

`script/benchmark_pane_search.sh` must validate its explicit aggregate output path, create a private `mktemp -d` staging directory, set `PENGRID_PANE_SEARCH_BENCHMARK=1`, and launch one filtered release-test process for each trace scenario plus each of the 40 `FileSortKey × SortDirection × cardinality` cells. Every process receives one `PENGRID_PANE_SEARCH_SCENARIO` and one unique `PENGRID_PANE_SEARCH_REPORT`, performs three warm-ups plus 30 recorded samples, and preserves raw stdout/stderr and `/usr/bin/time -l` maximum RSS. The script merges the scenario reports only after every child succeeds. It must not delete or overwrite an existing aggregate report unless the caller passes `--replace`.

The 40 sort cells use cardinalities `10_000`, `3_439`, `299`, `20`, and `1` for each of four keys and both directions. The complete-load, first-query, backspace, and multi-scalar-paste baseline records use the same sample structure so Task 8 can make matched comparisons instead of inventing a later measurement definition.

For the rapid-burst scenario, inject a counting projector that executes the unchanged baseline predicate/sort loop and records visits after its publication token has been superseded. Store that count in `cancelledWorkerCandidateVisits`; ordinary non-cancellation samples record zero. Task 5 replaces this baseline counter with lifecycle-probe evidence from the owned worker.

Each child invocation uses this command shape:

```bash
env PENGRID_PANE_SEARCH_BENCHMARK=1 \
  PENGRID_PANE_SEARCH_SCENARIO="$scenario" \
  PENGRID_PANE_SEARCH_REPORT="$scenario_report" \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/time -l /usr/bin/xcrun swift test -c release \
  --disable-sandbox --no-parallel --filter paneSearchReleaseBenchmark
```

Run:

```bash
script/benchmark_pane_search.sh \
  --output docs/verification/2026-08-07-incremental-pane-search-baseline.json
```

- [ ] **Step 5: Verify and record the baseline**

Record `git rev-parse HEAD`, `sw_vers`, `system_profiler SPHardwareDataType`, release configuration, all raw samples, median, nearest-rank p95, fixture counts, and isolated RSS in the verification document. Explicitly label the five-second assertions in the old suite as hang ceilings, not acceptance proof.

- [ ] **Step 6: Commit**

```bash
git add Tests/BloomFileManagerTests/Support/PaneSearchPerformanceProbe.swift \
  Tests/BloomFileManagerTests/PaneSearchBenchmarkTests.swift \
  Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift \
  script/benchmark_pane_search.sh \
  docs/verification/2026-08-07-incremental-pane-search.md \
  docs/verification/2026-08-07-incremental-pane-search-baseline.json
git commit -m "test: record pane search interaction baseline"
```

### Task 2: Add exact active-order and search primitives

**Files:**
- Modify: `Sources/BloomFileManager/Models/PaneFilenameFilter.swift`
- Modify: `Sources/BloomFileManager/Models/PaneItemProjection.swift`
- Modify: `Tests/BloomFileManagerTests/PaneFilenameFilterTests.swift`
- Modify: `Tests/BloomFileManagerTests/PaneItemProjectionTests.swift`

**Interfaces:**

```swift
struct ActiveOrderSnapshot: Equatable, Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let orderedItems: [FileItem]
    let asciiLiteralSafePositions: [Int]
    let localizedFallbackPositions: [Int]
}

struct AcceptedSearchSnapshot: Equatable, Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let normalizedQuery: String
    let matchedASCIIPositions: [Int]
    let matchedLocalizedPositions: [Int]
}
```

- [ ] **Step 1: Write failing eligibility, partition, and equivalence tests**

The corpus must include printable ASCII case/punctuation, composed and decomposed Hangul, Korean syllables and jamo, `ß`/`s`/`ss`, ligatures, circled digits, full-width text, accents, emoji, whitespace trimming, and mixed scripts. Include the known non-monotonic cases:

```swift
@Test func localizedMatchingCounterexamplesPreventGlobalCandidateNarrowing() {
    #expect(!"ß".localizedStandardContains("s"))
    #expect("ß".localizedStandardContains("ss"))
    #expect(!"⑫".localizedStandardContains("1"))
    #expect("⑫".localizedStandardContains("12"))
}

@Test func printableASCIIPartitionUsesTheExactApprovedScalarRange() {
    #expect(PaneFilenameFilter.isPrintableASCII("report-1999.txt"))
    #expect(PaneFilenameFilter.isPrintableASCII(" !~"))
    #expect(!PaneFilenameFilter.isPrintableASCII(""))
    #expect(!PaneFilenameFilter.isPrintableASCII("보고서.txt"))
    #expect(!PaneFilenameFilter.isPrintableASCII("Résumé.pdf"))
}
```

For every `FileSortKey` and both directions, assert active-order full filtering equals:

```swift
let oracle = sort.apply(to: PaneFilenameFilter(query: query).apply(to: rawItems))
#expect(projected.map { $0.url.standardizedFileURL } == oracle.map { $0.url.standardizedFileURL })
```

- [ ] **Step 2: Run RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'PaneFilenameFilterTests|PaneItemProjectionTests|FileSortTests'
```

Expected: the snapshot types, active-order builder, and eligibility functions are missing.

- [ ] **Step 3: Add exact helpers without changing the predicate**

```swift
extension PaneFilenameFilter {
    static let cancellationCheckStride = 128

    static func isPrintableASCII(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    static func isASCIIAlphanumeric(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value)
                || (0x41...0x5A).contains($0.value)
                || (0x61...0x7A).contains($0.value)
        }
    }

    static func isEligibleASCIIExtension(from oldQuery: String, to newQuery: String) -> Bool {
        let old = normalize(oldQuery)
        let new = normalize(newQuery)
        guard isASCIIAlphanumeric(old), isASCIIAlphanumeric(new),
              new.unicodeScalars.count == old.unicodeScalars.count + 1
        else { return false }
        return new.unicodeScalars.starts(with: old.unicodeScalars)
    }
}
```

`PaneFilenameFilter.apply(to:)` must continue calling `localizedStandardContains` exactly as it does before this task.

- [ ] **Step 4: Build and partition one exact active order**

Add the following synchronous primitive for this task; Task 3 replaces it with the cancellation-aware asynchronous form after its RED tests exist. Sort once with `key.sort.apply(to:)`, then append each ordered index to exactly one partition. Reject the shortcut when standardized URL or `PaneEntryPath.normalize` identities repeat; the caller will use the legacy fallback.

```swift
func buildActiveOrder(
    items: [FileItem],
    directoryKey: String,
    key: PaneProjectionKey
) -> ActiveOrderSnapshot?
```

```swift
static func hasUniqueFinalTieBreakIdentities(in items: [FileItem]) -> Bool {
    Set(items.map { $0.url.standardizedFileURL }).count == items.count
        && Set(items.map { PaneEntryPath.normalize($0.url) }).count == items.count
}
```

- [ ] **Step 5: Run GREEN and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'PaneFilenameFilterTests|PaneItemProjectionTests|FileSortTests'

git add Sources/BloomFileManager/Models/PaneFilenameFilter.swift \
  Sources/BloomFileManager/Models/PaneItemProjection.swift \
  Tests/BloomFileManagerTests/PaneFilenameFilterTests.swift \
  Tests/BloomFileManagerTests/PaneItemProjectionTests.swift
git commit -m "perf: add exact pane active-order snapshots"
```

If exact equivalence fails, stop this task with only the full-scan active-order path; do not enable candidate narrowing.

### Task 3: Implement safe candidate narrowing and cancellable projection loops

**Files:**
- Modify: `Sources/BloomFileManager/Models/PaneItemProjection.swift`
- Modify: `Tests/BloomFileManagerTests/PaneItemProjectionTests.swift`

**Interfaces:**

```swift
enum PaneProjectionPath: Equatable, Sendable {
    case fallbackFilterThenSort
    case activeOrderFullScan
    case activeOrderNarrowedASCII
    case emptyActiveOrder
    case sortedVisibleSubset
}

struct PaneProjectionDiagnostics: Equatable, Sendable {
    let path: PaneProjectionPath
    let visitedASCIIPositions: Int
    let visitedLocalizedPositions: Int
}

struct PaneItemProjection: Equatable, Sendable {
    let key: PaneProjectionKey
    let items: [FileItem]
    let indexByURL: [URL: Int]
    let urlByEntryPath: [String: URL]
    let activeOrder: ActiveOrderSnapshot?
    let search: AcceptedSearchSnapshot?
    let diagnostics: PaneProjectionDiagnostics
}

struct PaneProjectionInput: Sendable {
    let items: [FileItem]
    let directoryKey: String
    let key: PaneProjectionKey
    let activeOrder: ActiveOrderSnapshot?
    let previousSearch: AcceptedSearchSnapshot?
}

struct PaneItemProjector: Sendable {
    func projectActiveOrder(_ input: PaneProjectionInput) async throws -> PaneItemProjection
    func projectFallback(items: [FileItem], key: PaneProjectionKey) async throws -> PaneItemProjection
    func buildActiveOrder(
        items: [FileItem],
        directoryKey: String,
        key: PaneProjectionKey
    ) async throws -> ActiveOrderSnapshot?
    func projectSortedSubset(items: [FileItem], key: PaneProjectionKey) async throws -> PaneItemProjection
}
```

Retain the existing synchronous `project(items:key:)` compatibility wrapper through Task 4 so `FilePaneState` and the existing controlled double continue compiling. Task 5 migrates every caller and then removes that wrapper.

- [ ] **Step 1: Write failing narrowing and full-scan routing tests**

Assert that only a one-scalar ASCII-alphanumeric extension with matching directory/revision/sort uses `.activeOrderNarrowedASCII`. It must visit the prior ASCII matches and every localized fallback position. Backspace, empty-query change, multi-scalar paste, replacement, punctuation, Korean IME text, and directory/revision/sort mismatch must use `.activeOrderFullScan`.

Add a deterministic randomized property test using a fixed seed and at least 1,000 filename/query combinations. Compare both standardized identity sequence and full `FileItem` equality with the oracle.

- [ ] **Step 2: Run RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter PaneItemProjectionTests
```

Expected: async projector, input, diagnostics, and strategy cases do not exist.

- [ ] **Step 3: Implement the safe position algorithm**

For eligible extensions, filter `previousSearch.matchedASCIIPositions` and the complete `activeOrder.localizedFallbackPositions`. For all other nonempty queries, filter both complete partitions. Test every candidate with the unchanged localized predicate. Merge two ascending matched-position arrays without resorting:

```swift
private func mergePositions(_ left: [Int], _ right: [Int]) -> [Int] {
    var result: [Int] = []
    result.reserveCapacity(left.count + right.count)
    var leftIndex = 0
    var rightIndex = 0
    while leftIndex < left.count || rightIndex < right.count {
        if rightIndex == right.count
            || (leftIndex < left.count && left[leftIndex] < right[rightIndex]) {
            result.append(left[leftIndex])
            leftIndex += 1
        } else {
            result.append(right[rightIndex])
            rightIndex += 1
        }
    }
    return result
}
```

Call `try Task.checkCancellation()` before and after each phase and whenever `visited % 128 == 0` in filter and index-building loops. Call it immediately before and after `FileSort.apply`, because Swift's sort itself is not cooperatively cancellable.

- [ ] **Step 4: Preserve fallback and duplicate behavior**

`fallbackFilterThenSort` must keep the current order of operations: filter raw items, sort the filtered result, then build last-wins URL/path indexes. Duplicate standardized URL or normalized entry-path identities must never produce an active order or subset shortcut.

- [ ] **Step 5: Run GREEN and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'PaneItemProjectionTests|PaneFilenameFilterTests|FileSortTests'

git add Sources/BloomFileManager/Models/PaneItemProjection.swift \
  Tests/BloomFileManagerTests/PaneItemProjectionTests.swift
git commit -m "perf: narrow safe pane query extensions"
```

### Task 4: Publish the accepted pane projection atomically

**Files:**
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`
- Modify: `Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift`

**Interface:**

```swift
struct PaneProjectionToken: Equatable, Sendable {
    let navigationGeneration: UInt64
    let projectionGeneration: UInt64
}

struct AcceptedPaneProjectionState: Equatable, Sendable {
    let directoryKey: String
    let key: PaneProjectionKey?
    let token: PaneProjectionToken?
    let visibleItems: [FileItem]
    let indexByURL: [URL: Int]
    let urlByEntryPath: [String: URL]
    let selection: Set<URL>
    let activeOrder: ActiveOrderSnapshot?
    let search: AcceptedSearchSnapshot?
    let diagnostics: PaneProjectionDiagnostics

    func replacing(selection: Set<URL>) -> Self
    func replacing(activeOrder: ActiveOrderSnapshot?, search: AcceptedSearchSnapshot?) -> Self
}
```

- [ ] **Step 1: Write failing aggregate and compatibility tests**

Cover one accepted change to rows/indexes/selection; failure/cancellation/stale result retaining the entire previous aggregate; filtered-out pending rename cancellation; visible rename lookup; selection capture/restore; scroll anchor visibility; and constant-time repeated reads.

Add a source-shape regression test that asserts `acceptProjection` assigns `acceptedProjectionState` once and no longer assigns `visibleItems`, `visibleIndexByURL`, `visibleURLByEntryPath`, and `acceptedProjectionKey` independently.

- [ ] **Step 2: Run RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'FilePaneStateTests|NavigationProductivityPerformanceTests'
```

Expected: the aggregate does not exist and current observable fields are stored separately.

- [ ] **Step 3: Replace separate accepted fields with one aggregate**

Keep callers source-compatible:

```swift
private var acceptedProjectionState: AcceptedPaneProjectionState

var visibleItems: [FileItem] { acceptedProjectionState.visibleItems }
var visibleIndexByURL: [URL: Int] { acceptedProjectionState.indexByURL }
private var visibleURLByEntryPath: [String: URL] { acceptedProjectionState.urlByEntryPath }
private var acceptedProjectionKey: PaneProjectionKey? { acceptedProjectionState.key }
var acceptedProjectionToken: PaneProjectionToken? { acceptedProjectionState.token }
var acceptedProjectionDiagnostics: PaneProjectionDiagnostics { acceptedProjectionState.diagnostics }

var selection: Set<URL> {
    get { acceptedProjectionState.selection }
    set {
        acceptedProjectionState = acceptedProjectionState.replacing(selection: newValue)
        validatePendingRenameSelection()
    }
}
```

Before publishing a projection, compute the selected visible standardized identities, build the entire aggregate locally, and assign it once. Initialize the empty pane with its initial key, but replace the aggregate with `key: nil` when navigation clears the raw and visible rows; this preserves the current “no accepted projection” scheduling state. Warm-up metadata replacement must also be one aggregate assignment and preserve rows, indexes, token, selection, and diagnostics bit-for-bit. The read-only diagnostics accessor exists so correctness and performance tests can prove the route used without changing behavior.

- [ ] **Step 4: Store the aggregate in rollback snapshots**

Replace the separate projection fields in `PaneSnapshot` with `let acceptedProjectionState: AcceptedPaneProjectionState`. Update initialization, navigation clearing, `snapshot()`, `restore(_:)`, refresh staging, and failed/cancelled rollback so they never expose a mixed old/new projection.

- [ ] **Step 5: Run GREEN and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'FilePaneStateTests|PaneItemProjectionTests|NavigationProductivityPerformanceTests|PaneViewStateCacheTests'

git add Sources/BloomFileManager/Stores/FilePaneState.swift \
  Tests/BloomFileManagerTests/FilePaneStateTests.swift \
  Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift
git commit -m "refactor: publish pane projections atomically"
```

### Task 5: Own and cancel visible projection workers

**Files:**
- Create: `Sources/BloomFileManager/Stores/ProjectionWork.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`

**Interfaces:**

```swift
final class ProjectionWork: @unchecked Sendable {
    init<Value: Sendable>(worker: Task<Value, Error>)
    func installPublication(_ task: Task<Void, Never>)
    func cancel()
}

struct PaneProjectionRequest: Sendable {
    let input: PaneProjectionInput
    let token: PaneProjectionToken
}

protocol PaneItemProjecting: Sendable {
    func project(_ input: PaneProjectionInput) async throws -> PaneItemProjection
    func buildActiveOrder(
        items: [FileItem],
        directoryKey: String,
        key: PaneProjectionKey
    ) async throws -> ActiveOrderSnapshot?
    func projectSortedSubset(items: [FileItem], key: PaneProjectionKey) async throws -> PaneItemProjection
}

enum PaneProjectionLifecycleEvent: Equatable, Sendable {
    case workerStarted(PaneProjectionToken)
    case cancellationRequested(PaneProjectionToken)
    case workerFinished(PaneProjectionToken, cancelled: Bool)
    case buffersReleased(PaneProjectionToken)
}

protocol PaneProjectionLifecycleRecording: Sendable {
    func record(_ event: PaneProjectionLifecycleEvent) async
}
```

- [ ] **Step 1: Make the existing controlled projector cancellation-aware**

Change every `PaneItemProjecting` conformer and test double together to `async throws`. Replace non-cancellable suspended continuations with `withTaskCancellationHandler`; cancellation must remove and resume the matching continuation by throwing `CancellationError`.

Add failing tests proving the detached computation receives cancellation, a stale result never publishes, cancellation stops by the next 128 candidates, and a 20-query burst drains to zero active workers, cancelled tails, retained snapshots, and retained results.

```swift
@Test func replacementQueryCancelsTheOwnedDetachedWorker() async {
    let projector = CancellationRecordingPaneItemProjector()
    let pane = makeLoadedPane(projector: projector, itemCount: 10_000)
    pane.updateFilterQuery("report")
    await projector.waitUntilSuspended(request: 0)
    pane.updateFilterQuery("report-1999")
    #expect(await projector.waitForCancellation(request: 0))
    #expect(await waitForPaneCondition { pane.filterQuery == "report-1999" })
    #expect(!(await projector.didPublish(request: 0)))
}
```

- [ ] **Step 2: Run RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'rapidQueryAndSortChangesPublishOnlyTheNewestProjection|cancelledProjection|rapidTwentyQueryBurst'
```

Expected: current cancellation reaches only the publication task; the suspended worker remains live.

- [ ] **Step 3: Implement explicit two-handle ownership**

`ProjectionWork` stores a type-erased worker-cancellation closure and an `NSLock`-protected publication handle. `cancel()` snapshots both handles under the lock, releases the lock, then cancels both. `installPublication` immediately cancels a late publication if cancellation already happened.

```swift
private var projectionWork: ProjectionWork?
private var warmUpWork: ProjectionWork?
```

In `scheduleProjection`, create the detached `Task<PaneItemProjection, Error>`, create `ProjectionWork(worker:)`, create the main-actor publication task that awaits that exact worker, install it, and store the work. The publication task captures `FilePaneState` weakly. Completion clears `projectionWork` or `warmUpWork` only when its captured token and, for warm-up, warm-up generation still match; this prevents an older completion from releasing a replacement and prevents a `FilePaneState → ProjectionWork → publication task → FilePaneState` cycle. Remove the current detached-task-and-immediate-value helper. `beginProjectionGeneration`, navigation/reset/refresh cancellation, and `PaneTaskLifecycle.cancelAll()` must cancel both owned handles. The live projector uses `projectFallback(items:key:)` during this task so behavior remains exact and unchanged until Task 6 adds active-order routing.

- [ ] **Step 4: Handle cancellation as control flow**

Catch `CancellationError` without changing `errorMessage`. Clear lifecycle counters and retained buffers in `defer`. Acceptance still checks directory key, item revision, sort, navigation generation, and projection generation after the worker returns.

- [ ] **Step 5: Run GREEN and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'PaneItemProjectionTests|FilePaneStateTests'

git add Sources/BloomFileManager/Stores/ProjectionWork.swift \
  Sources/BloomFileManager/Stores/FilePaneState.swift \
  Tests/BloomFileManagerTests/FilePaneStateTests.swift
git commit -m "fix: cancel obsolete pane projection workers"
```

### Task 6: Route active orders, immediate subset sorts, and warm-ups

**Files:**
- Modify: `Sources/BloomFileManager/Models/PaneItemProjection.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Tests/BloomFileManagerTests/PaneItemProjectionTests.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`

**Additional interface:**

```swift
struct ActiveOrderWarmUpRequest: Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let navigationGeneration: UInt64
    let projectionGeneration: UInt64
    let warmUpGeneration: UInt64
    let items: [FileItem]
}
```

- [ ] **Step 1: Write failing routing and race tests**

Cover these exact cases:

- matching active order filters without sorting;
- empty query after revision/sort replacement builds and publishes the full active order;
- missing active order uses exact filter-then-sort and starts one warm-up only after acceptance;
- nonempty sort change immediately sorts only the currently accepted membership when directory/revision/query match;
- immediate subset publication clears active-order/search metadata for the new sort;
- warm-up acceptance changes metadata only and never rows, indexes, selection, or table token;
- a query arriving during warm-up cancels it, uses exact fallback, then starts one replacement warm-up;
- a query/sort/revision/navigation race cannot accept older membership or older warm-up metadata;
- duplicate standardized URL or normalized entry path uses fallback; and
- empty/broad/medium/narrow/one-result cardinalities are `10_000`, `3_439`, `299`, `20`, and `1` for every sort key and both directions.

```swift
@Test func queryDuringWarmUpFallsBackThenStartsOneReplacementWarmUp() async {
    let projector = ControlledPaneItemProjector()
    let pane = makeLoadedPane(projector: projector, itemCount: 10_000)
    pane.updateFilterQuery("19")
    await projector.waitForAcceptedProjection(query: "19")
    pane.sort = FileSort(key: .size, direction: .descending)
    await projector.waitUntilWarmUpSuspends(count: 1)

    pane.updateFilterQuery("199")

    #expect(await projector.warmUpCancellationCount == 1)
    #expect(await projector.acceptedPath(query: "199") == .fallbackFilterThenSort)
    #expect(await projector.replacementWarmUpStartCount == 1)
    #expect(pane.visibleItems == oracleItems(query: "199", sort: pane.sort))
}
```

- [ ] **Step 2: Run RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'PaneItemProjectionTests|FilePaneStateTests'
```

Expected: no active-order routing, subset path, or separate warm-up lifecycle exists.

- [ ] **Step 3: Implement the routing table**

Use the following precedence in `scheduleProjection`:

1. If normalized query is empty, build/sort the complete current raw items, publish it, and retain that exact result as active order.
2. Else if the accepted aggregate proves directory/revision/query membership is current and only sort changed, invoke `projectSortedSubset` with accepted visible items, publish immediately, clear active order/search, and start warm-up.
3. Else if a matching active order exists, invoke active-order full scan or safe narrowing.
4. Else invoke exact raw filter-then-sort fallback; after acceptance, start warm-up unless a matching active order already exists.

Never subset-sort membership from an aggregate whose directory, revision, or normalized query differs from the request.

- [ ] **Step 4: Implement generation-bound metadata-only warm-up**

Add `private var warmUpGeneration: UInt64 = 0`. Every new warm-up increments it and captures `ActiveOrderWarmUpRequest`. Acceptance compares directory key, item revision, sort, navigation generation, projection generation, and warm-up generation. It replaces only `activeOrder` and sets `search` to `nil`, preserving the accepted rows, indexes, selection, and projection token.

At most one non-cancelled visible work and one non-cancelled warm-up may exist. Query, sort, revision, refresh, and navigation changes cancel warm-up before scheduling replacement work.

- [ ] **Step 5: Run the immediate RSS precheck**

Run the Task 1 benchmark once in release mode and compare isolated peak RSS with baseline. If it is more than 10% higher, retain only current raw `items`, disable `ActiveOrderSnapshot`, warm-up, and ASCII narrowing, and use `projectFallback(items:key:)` for query changes. Preserve immediate `projectSortedSubset(items: accepted.visibleItems, key:)` for a nonempty sort change whose directory/revision/query membership is proven current, and start no warm-up afterward. Do not retain ordered-position arrays under another name. Remeasure this explicit no-cache route before proceeding.

```bash
precheck_directory="$(mktemp -d /tmp/pengrid-pane-search-rss-precheck.XXXXXX)"
script/benchmark_pane_search.sh \
  --output "$precheck_directory/report.json"
```

- [ ] **Step 6: Run GREEN and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'PaneFilenameFilterTests|PaneItemProjectionTests|FilePaneStateTests'

git add Sources/BloomFileManager/Models/PaneItemProjection.swift \
  Sources/BloomFileManager/Stores/FilePaneState.swift \
  Tests/BloomFileManagerTests/PaneItemProjectionTests.swift \
  Tests/BloomFileManagerTests/FilePaneStateTests.swift
git commit -m "perf: warm pane orders off the visible path"
```

### Task 7: Trace the newest table apply and preserve UI/cloud contracts

**Files:**
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Modify: `Tests/BloomFileManagerTests/CloudItemAvailabilityTests.swift`
- Modify: `Tests/BloomFileManagerTests/CloudLocationScopedAccessTests.swift`

**Interfaces:**

```swift
enum PaneProjectionTraceEvent: Equatable, Sendable {
    case setterEntry(query: String)
    case requestScheduled(PaneProjectionToken, PaneProjectionKey)
    case aggregateAccepted(PaneProjectionToken, PaneProjectionKey)
    case tableApplied(PaneProjectionToken)
}

@MainActor protocol PaneProjectionTraceRecording: AnyObject {
    func record(_ event: PaneProjectionTraceEvent)
}
```

Extend `FileTableView` with defaulted internal inputs so current call sites and tests remain source-compatible:

```swift
let projectionToken: PaneProjectionToken?
let onProjectionApplied: (PaneProjectionToken) -> Void

// Insert immediately after `selection` in the current initializer.
projectionToken: PaneProjectionToken? = nil,

// Insert immediately after `onSortChange` in the current initializer.
onProjectionApplied: @escaping (PaneProjectionToken) -> Void = { _ in },
```

Assign `self.projectionToken = projectionToken` beside `_selection = selection`, and assign `self.onProjectionApplied = onProjectionApplied` beside `self.onSortChange = onSortChange`. Do not reorder or change defaults for any pre-existing initializer parameter.

- [ ] **Step 1: Write failing newest-token and semantics tests**

Assert that the callback fires once only after the complete `updateNSView` sequence for a new accepted token; a stale token cannot fire after a newer one; a new token whose visible rows are unchanged still fires once; and metadata-only warm-up does not emit a second table-applied event. Retain tests for table focus, filter focus request, selection, inline rename draft/identity, and first-visible scroll anchor.

Add source/API assertions for the existing left/right filter accessibility identifiers, labels, result-count values, close labels, and filter binding. No user-visible string or identifier changes in this task.

- [ ] **Step 2: Run RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'FileTableViewLifecycleTests|AccessibilityPresentationTests|CloudItemAvailabilityTests|CloudLocationScopedAccessTests'
```

Expected: token and post-apply callback do not exist.

- [ ] **Step 3: Wire exact trace boundaries**

`updateFilterQuery` records `.setterEntry` before changing `filterQuery`. Scheduling records the assigned token. The aggregate assignment is followed immediately by `.aggregateAccepted`. `FilePaneView` passes `state.acceptedProjectionToken` and `state.recordTableApplicationCompleted(_:)` to `FileTableView`.

In `Coordinator`, remember `lastAppliedProjectionToken` and expose `notifyProjectionAppliedIfNeeded(_:)`. In `updateNSView`, call that method after `apply(sort:)`, `apply(items:selection:to:)`, `applyScrollRequest`, `reportFirstVisibleItem`, and `applyFocusRequest`. The method invokes `onProjectionApplied` when a non-nil token differs from the last applied token, including when the row update plan was `.none`.

- [ ] **Step 4: Prove metadata-only cloud behavior**

Extend the existing directory-listing/materializer test to feed `.onlineOnly` Google Drive- and OneDrive-shaped `FileItem` values through `FilePaneState` filtering and sorting. Assert the correct names/availability survive and `InMemoryCloudMaterializer.recordedCalls()` remains empty. Under a registered scoped-access root, assert filtering does not open a second access lifetime and does not request file contents.

- [ ] **Step 5: Run GREEN and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'FilePaneStateTests|FileTableViewLifecycleTests|AccessibilityPresentationTests|CloudItemAvailabilityTests|CloudLocationScopedAccessTests'

git add Sources/BloomFileManager/Stores/FilePaneState.swift \
  Sources/BloomFileManager/Views/FilePaneView.swift \
  Sources/BloomFileManager/Views/AppKit/FileTableView.swift \
  Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift \
  Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift \
  Tests/BloomFileManagerTests/CloudItemAvailabilityTests.swift \
  Tests/BloomFileManagerTests/CloudLocationScopedAccessTests.swift
git commit -m "test: trace pane search table application"
```

### Task 8: Measure the candidate, enforce hard gates, and document release readiness

**Files:**
- Modify: `Sources/BloomFileManager/Models/PaneItemProjection.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Tests/BloomFileManagerTests/BuildScriptTests.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`
- Modify: `Tests/BloomFileManagerTests/Support/PaneSearchPerformanceProbe.swift`
- Modify: `Tests/BloomFileManagerTests/PaneSearchBenchmarkTests.swift`
- Modify: `Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift`
- Modify: `Tests/BloomFileManagerTests/PaneItemProjectionTests.swift`
- Modify: `script/benchmark_pane_search.sh`
- Modify: `docs/verification/2026-08-07-incremental-pane-search.md`
- Create: `docs/verification/2026-08-07-incremental-pane-search-candidate.json`
- Create: `docs/verification/2026-08-08-incremental-pane-search-supplemental.json`
- Create: `script/evaluate_pane_search_gates.py`

- [x] **Step 1: Add hard-gate assertions to the unchanged trace harness**

The candidate report must assert the matching active order was accepted before each ready-order timing sample. Calculate per-transition and complete-trace median and nearest-rank p95. Record `cancelledWorkerCandidateVisits` from the lifecycle/worker probe for every raw trace sample and report its median/p95 per trace. Compare candidate with the committed Task 1 baseline by trace, transition, sort key, direction, and cardinality.

Policy-v3 hard failures are:

- cached/query p50/p95/max above 75/100/200 ms; complete load above 500/750/1000 ms; 10,000-row sort above 250/300/400 ms; or <=3,439-row sort above 80/100/150 ms;
- any identity/order mismatch with the full oracle;
- stale publication or cancellation beyond 128 additional candidates;
- matched-cell p50 above baseline plus `max(10% of baseline p50, 5 ms)`, or peak RSS above 110% of baseline;
- a qualifying nonempty sort change that waits for active-order warm-up instead of using `.sortedVisibleSubset`.

Relative p95 regression is an advisory and never overrides a passing absolute p95/max gate. The <=3,439-row 75 ms p50 and 50 ms ready-order objectives are stretch targets.

Report, but do not fail, post-first-character improvement below 30% or complete-trace improvement below 40%. Report every required trace and sort cell without averaging away a slower case.

- [x] **Step 2: Run the candidate benchmark in an isolated release process**

```bash
script/benchmark_pane_search.sh \
  --output docs/verification/2026-08-07-incremental-pane-search-candidate.json
```

Recorded: canonical candidate matrix has 48 scenarios and 1,920 raw samples; policy-v3 replay passes 267/267 hard gates. See `docs/verification/2026-08-07-incremental-pane-search.md` and the supplemental artifact for the retained diagnostics.

- [x] **Step 3: Run focused compatibility verification**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'PaneFilenameFilterTests|PaneItemProjectionTests|FilePaneStateTests|NavigationProductivityPerformanceTests|PaneSearchBenchmarkTests|FileTableViewLifecycleTests|AccessibilityPresentationTests|CloudItemAvailabilityTests|CloudLocationScopedAccessTests|WorkspacePersistenceTests|WorkspaceCommandTests'
```

- [x] **Step 4: Run full verification and release build**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build --disable-sandbox -c release
git diff --check
```

Record exact suite/test counts, elapsed time, warnings, skipped opt-in provider tests, release build result, and `git diff --check` in the verification document. Do not reinterpret an existing direct filter/sort 30% miss as a pass; keep it reported independently.

Recorded on 2026-08-08: the full debug test run passed 1,223 tests in 80 suites
after 83.501 seconds; the production build completed in 38.77 seconds. SwiftPM
reported only the pre-existing unhandled protected-ZIP fixture warning. `git
diff --check` passed.

- [ ] **Step 5: Perform the manual release gates**

In both panes, verify English and Korean typing, numeric narrowing, reverse deletion, multi-scalar paste, rapid cancellation, all sort keys/directions, selection, scroll restoration, inline rename retention/cancellation, table focus, filter focus, and spoken VoiceOver labels/values.

Against locally available Google Drive and OneDrive File Provider roots, repeat browsing, filtering, and sorting with online-only metadata. Observe provider status and network/download indicators; no content download may begin. If either provider is unavailable, record that manual gate as incomplete rather than inferring success from doubles.

- [x] **Step 6: Request a fresh Sol high read-only final review**

The reviewer must inspect exactness, cancellation ownership, aggregate publication, warm-up races, benchmark methodology, all hard gates, and documented manual limitations. Resolve Critical and Important findings before the final task commit.

Recorded: the final Sol read-only review returned `SHIP` with no Critical,
Important, or Minor findings after the canonical cancellation distribution,
commit manifest, and provenance wording were corrected.

- [x] **Step 7: Commit**

```bash
git add Tests/BloomFileManagerTests/Support/PaneSearchPerformanceProbe.swift \
  Sources/BloomFileManager/Models/PaneItemProjection.swift \
  Sources/BloomFileManager/Stores/FilePaneState.swift \
  Sources/BloomFileManager/Views/AppKit/FileTableView.swift \
  Sources/BloomFileManager/Views/FilePaneView.swift \
  Tests/BloomFileManagerTests/BuildScriptTests.swift \
  Tests/BloomFileManagerTests/FilePaneStateTests.swift \
  Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift \
  Tests/BloomFileManagerTests/PaneSearchBenchmarkTests.swift \
  Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift \
  Tests/BloomFileManagerTests/PaneItemProjectionTests.swift \
  script/benchmark_pane_search.sh \
  script/evaluate_pane_search_gates.py \
  docs/verification/2026-08-07-incremental-pane-search.md \
  docs/verification/2026-08-07-incremental-pane-search-candidate.json \
  docs/verification/2026-08-08-incremental-pane-search-supplemental.json \
  docs/superpowers/plans/2026-08-07-incremental-pane-search-projection.md
git commit -m "perf: verify incremental pane search projection"
```

## Stop/Go Rules

1. If the printable-ASCII partition or position merge differs from the oracle, ship no narrowing; retain the exact full-active-order scan.
2. If active-order retention exceeds the 10% RSS gate, remove that cache and remeasure cooperative cancellation plus exact filtering.
3. If a hard latency, sort, load, cancellation, exactness, or memory gate fails, do not mark the feature release-ready.
4. If only the aspirational 30%/40% improvements miss while every hard gate passes, report the miss and inspect worker CPU/table publication before proposing debounce.
5. If automated tests pass but VoiceOver or live Google Drive/OneDrive checks remain incomplete, record the feature as implemented but not release-validated.
