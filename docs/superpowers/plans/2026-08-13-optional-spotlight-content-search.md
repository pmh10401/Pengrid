# Optional Spotlight Content Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Smart Search mode that merges Spotlight-indexed file-content hits with the existing recursive name/path results without reading or materializing file contents.

**Architecture:** Preserve `LocalSmartSearchService` as the default backend. Add a cancellable `NSMetadataQuery` adapter and an identity-validating Spotlight result service, then compose both backends only when a persisted query flag is enabled and the query contains literal terms only. Surface explicit coverage state through the existing store and sheet.

**Tech Stack:** Swift 6.1, Foundation `NSMetadataQuery`, Observation, SwiftUI, Swift Testing, macOS 15, existing `SmartSearching`, `FileSystemAccess`, `CloudItemAvailabilityReading`, and scoped-access APIs.

## Global Constraints

- Prefix Swift verification commands with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun`.
- The default query behavior remains the existing recursive filename, relative-path, metadata, and Korean-initial search.
- Indexed-content search is explicit, persisted with saved searches, and defaults to `false` when decoding older records.
- Spotlight code must not call `CloudMaterializing`, `NSFileCoordinator`, `FileHandle`, `Data(contentsOf:)`, `String(contentsOf:)`, or another file-byte read API.
- `NSMetadataQuery.searchScopes` is never empty; every returned URL is standardized, root-contained, metadata-filtered, and exact-identity checked before publication.
- Korean-initial or mixed initial queries do not query indexed contents and publish a visible skipped-coverage state.
- Spotlight failure or five-second timeout returns ordinary local results plus an unavailable-coverage state; explicit task cancellation still throws `CancellationError`.
- The initial gather is static: stop after the first finished-gathering notification and do not subscribe to live updates.
- Preserve all existing Smart Search result caps, candidate caps, cancellation generations, sorting, saved-search compatibility, and result-action authority.
- Follow RED → observed expected failure → minimal GREEN → focused pass for every production behavior.

---

### Task 1: Query option and coverage contract

**Files:**
- Modify: `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Modify: `Sources/BloomFileManager/Services/SmartSearchService.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchServiceTests.swift`

**Interfaces:**
- Consumes: existing `SmartSearchQuery`, `SmartSearchQueryPlan`, and `SmartSearching.search(_:progress:)`.
- Produces: `SmartSearchCoverage`, `SmartSearchQuery.searchIndexedContents`, and a backward-compatible coverage-reporting search overload.

- [ ] **Step 1: Add failing model and service-contract tests**

Add literal expectations that prove a new query round-trips the opt-in flag, a legacy JSON payload decodes it as `false`, and a conformer that implements only the original search requirement receives the default names/path coverage:

```swift
@Test func indexedContentPreferenceRoundTripsAndLegacyDefaultsOff() throws {
    let optedIn = try SmartSearchQuery(
        text: "invoice",
        roots: [URL(filePath: "/tmp")],
        searchIndexedContents: true
    )
    let decoded = try JSONDecoder().decode(
        SmartSearchQuery.self,
        from: JSONEncoder().encode(optedIn)
    )
    #expect(decoded.searchIndexedContents)

    let legacy = #"{"text":"invoice","roots":["file:\/\/\/tmp"],"includeHidden":false,"includePackages":false,"includeDirectories":true,"maximumResults":500}"#.data(using: .utf8)!
    #expect(try JSONDecoder().decode(SmartSearchQuery.self, from: legacy).searchIndexedContents == false)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'SmartSearchModelTests|SmartSearchServiceTests'
```

Expected: compilation fails because `searchIndexedContents`, `SmartSearchCoverage`, and the coverage overload do not exist.

- [ ] **Step 3: Implement the minimal backward-compatible contract**

Add these shapes and preserve the original protocol requirement so existing test doubles remain valid:

```swift
enum SmartSearchCoverage: Equatable, Sendable {
    case namesAndPathsOnly
    case indexedContentsIncluded
    case indexedContentsUnavailable
    case indexedContentsSkippedForInitialQuery
}

protocol SmartSearching: Sendable {
    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult]

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void,
        coverage: @escaping @Sendable (SmartSearchCoverage) -> Void
    ) async throws -> [SmartSearchResult]
}
```

The protocol extension's coverage overload publishes `.namesAndPathsOnly` and delegates to the original requirement. Add `searchIndexedContents: Bool` to `SmartSearchQuery`, default it to `false`, include it in `CodingKeys`, and use `decodeIfPresent(Bool.self) ?? false`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2 and require zero failures.

- [ ] **Step 5: Commit the contract task**

```bash
git add Sources/BloomFileManager/Models/SmartSearchModels.swift Sources/BloomFileManager/Services/SmartSearchService.swift Tests/BloomFileManagerTests/SmartSearchModelTests.swift Tests/BloomFileManagerTests/SmartSearchServiceTests.swift
git commit -m "feat: add indexed search query contract"
```

### Task 2: Cancellable Spotlight query and composed backend

**Files:**
- Create: `Sources/BloomFileManager/Services/SpotlightMetadataQueryRunner.swift`
- Create: `Sources/BloomFileManager/Services/SpotlightSmartSearchService.swift`
- Create: `Sources/BloomFileManager/Services/ContentAwareSmartSearchService.swift`
- Create: `Tests/BloomFileManagerTests/SpotlightMetadataQueryRunnerTests.swift`
- Create: `Tests/BloomFileManagerTests/SpotlightSmartSearchServiceTests.swift`
- Create: `Tests/BloomFileManagerTests/ContentAwareSmartSearchServiceTests.swift`

**Interfaces:**
- Consumes: `SmartSearchQuery`, `SmartSearchResult`, `SmartSearchRanker`, `FileSystemAccess`, `CloudItemAvailabilityReading`, and `CloudLocationScopedAccessCoordinator`.
- Produces: `SpotlightMetadataQueryRunning`, `LiveSpotlightMetadataQueryRunner`, `SpotlightContentSearching`, `LiveSpotlightSmartSearchService`, and `ContentAwareSmartSearchService`.

- [ ] **Step 1: Add failing pure predicate and query-lifecycle tests**

Test the production predicate by evaluating it against hand-authored metadata dictionaries, not by comparing source text:

```swift
@Test func contentPredicateRequiresEveryLiteralToken() throws {
    let predicate = try #require(SpotlightContentPredicate.make(tokens: ["annual", "report"]))
    #expect(predicate.evaluate(with: [NSMetadataItemTextContentKey: "Annual REPORT for 2026"]))
    #expect(!predicate.evaluate(with: [NSMetadataItemTextContentKey: "annual notes"]))
}
```

Use an injected query-session double to verify that a finished gather snapshots only result URLs, stops once, and removes observers; cancellation must stop and throw `CancellationError` even when no finish notification arrives.

- [ ] **Step 2: Run runner tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter SpotlightMetadataQueryRunnerTests
```

Expected: compilation fails because the predicate builder and runner do not exist.

- [ ] **Step 3: Implement the query adapter**

Expose the narrow production boundary:

```swift
protocol SpotlightMetadataQueryRunning: Sendable {
    func matchingURLs(tokens: [String], roots: [URL]) async throws -> [URL]
}

enum SpotlightMetadataQueryError: Error, Equatable, Sendable {
    case unavailable
    case startRejected
}
```

`LiveSpotlightMetadataQueryRunner` is main-actor isolated. A per-call session owns the `NSMetadataQuery`, notification tokens, and one checked continuation. Set its operation queue, AND predicate, and nonempty root scopes before `startQuery()`. On finish, call `disableUpdates()`, read `NSMetadataItemURLKey` values through indexed results, then stop, remove observers, and resume once. Its cancellation handler schedules the same single cleanup path on the main actor and resumes with `CancellationError`.

- [ ] **Step 4: Add failing Spotlight hydration and composition tests**

Cover these observable cases with deterministic injected runners and real temporary files:

```swift
@Test func contentResultsOutsideRootsAndChangedIdentitiesAreDiscarded() async throws
@Test func optedOutQueryUsesOnlyLocalBackend() async throws
@Test func literalOptInMergesDeduplicatesAndRanksLocalAndIndexedResults() async throws
@Test func initialQuerySkipsSpotlightAndPublishesSkippedCoverage() async throws
@Test func spotlightFailureReturnsLocalResultsAndUnavailableCoverage() async throws
@Test func timeoutCancelsSpotlightAndReturnsLocalResults() async throws
@Test func callerCancellationCancelsBothBackendsAndThrows() async throws
```

- [ ] **Step 5: Run composition tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'SpotlightSmartSearchServiceTests|ContentAwareSmartSearchServiceTests'
```

Expected: compilation fails because the live Spotlight service and content-aware composer do not exist.

- [ ] **Step 6: Implement hydration, fallback, timeout, and merge**

Use these boundaries:

```swift
protocol SpotlightContentSearching: Sendable {
    func searchIndexedContents(_ query: SmartSearchQuery) async throws -> [SmartSearchResult]
}

struct ContentAwareSmartSearchService: SmartSearching {
    init(
        local: any SmartSearching,
        spotlight: any SpotlightContentSearching,
        timeout: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    )
}
```

The live Spotlight service acquires scoped access for validated roots, requests URLs from the runner, enforces root containment and hidden/package/symbolic-link boundaries, applies `SmartSearchMetadataFilter`, captures exact identity before and after metadata reads, and caps hydration at `candidateBudget`. It never reads file bytes.

The composer always preserves local progress. It calls Spotlight only for an opted-in literal-only plan, races it against the injected five-second sleep, deduplicates standardized paths, applies `SmartSearchRanker.ranked`, and publishes the exact coverage state. Catch ordinary Spotlight errors for fallback but rethrow `CancellationError` from the caller.

- [ ] **Step 7: Run all new service tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'SpotlightMetadataQueryRunnerTests|SpotlightSmartSearchServiceTests|ContentAwareSmartSearchServiceTests|SmartSearchServiceTests'
```

Require zero failures, then run `git diff --check`.

- [ ] **Step 8: Commit the backend task**

```bash
git add Sources/BloomFileManager/Services/SpotlightMetadataQueryRunner.swift Sources/BloomFileManager/Services/SpotlightSmartSearchService.swift Sources/BloomFileManager/Services/ContentAwareSmartSearchService.swift Tests/BloomFileManagerTests/SpotlightMetadataQueryRunnerTests.swift Tests/BloomFileManagerTests/SpotlightSmartSearchServiceTests.swift Tests/BloomFileManagerTests/ContentAwareSmartSearchServiceTests.swift
git commit -m "feat: add optional Spotlight content search"
```

### Task 3: Store, sheet, app composition, accessibility, and documentation

**Files:**
- Modify: `Sources/BloomFileManager/Stores/SmartSearchStore.swift`
- Modify: `Sources/BloomFileManager/Views/SmartSearchView.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Create: `Sources/BloomFileManager/Support/SpotlightSearchAccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchStoreTests.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`
- Modify: `docs/current-limitations.md`
- Modify: `docs/current-limitations.ko.md`

**Interfaces:**
- Consumes: `ContentAwareSmartSearchService`, `SmartSearchCoverage`, and the query flag from Tasks 1–2.
- Produces: persisted store state, coverage presentation, opt-in controls, and live app composition.

- [ ] **Step 1: Add failing store and presentation tests**

Prove that the store sends the opt-in flag, accepts generation-bound coverage callbacks, ignores stale callbacks, restores the flag from saved searches, and presents these privacy-safe strings:

```swift
"Indexed contents included"
"Spotlight unavailable; searched names and paths only"
"Indexed contents skipped for Korean-initial search"
```

Verify the toggle has a stable accessibility identifier and its hint states that only already-indexed contents are searched without downloading cloud-only files.

- [ ] **Step 2: Run focused UI/store tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'SmartSearchStoreTests|SmartSearchPresentationTests|AccessibilityPresentationTests'
```

Expected: compilation or assertions fail for missing store state, toggle, and identifiers.

- [ ] **Step 3: Wire store, view, and app composition**

Add `searchIndexedContents`, `coverage`, and a derived coverage message to `SmartSearchStore`. Pass the query flag from `makeQuery()`, restore it from a saved record, and call the coverage-reporting service overload with the same generation guard used for results and progress.

Place this control in the filter surface and keep the existing query field and shortcuts unchanged:

```swift
Toggle(
    "Search indexed file contents",
    isOn: Binding(
        get: { store.searchIndexedContents },
        set: { store.searchIndexedContents = $0 }
    )
)
.accessibilityIdentifier(AccessibilityIdentifiers.smartSearchIndexedContents)
.accessibilityHint("Searches contents already indexed by Spotlight without downloading cloud-only files")
```

Render the coverage message beside progress/error state with a stable accessibility value.

Compose the app service as:

```swift
let localSearch = LocalSmartSearchService(
    fileSystem: cloudDependencies.fileSystem,
    scopedAccessCoordinator: cloudDependencies.accessCoordinator
)
let spotlightSearch = LiveSpotlightSmartSearchService(
    runner: LiveSpotlightMetadataQueryRunner(),
    fileSystem: cloudDependencies.fileSystem,
    availabilityReader: LiveCloudItemAvailabilityService(),
    scopedAccessCoordinator: cloudDependencies.accessCoordinator
)
let searchService = ContentAwareSmartSearchService(
    local: localSearch,
    spotlight: spotlightSearch
)
```

- [ ] **Step 4: Update English and Korean documentation**

Document that the option searches only Spotlight-indexed content, may be incomplete for File Provider or excluded locations, never forces cloud download, provides no snippets, and falls back visibly to names/paths. Correct the stale Preview 5 wording in both limitations documents while editing them.

- [ ] **Step 5: Run focused and full verification**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'SmartSearchModelTests|SmartSearchServiceTests|SpotlightMetadataQueryRunnerTests|SpotlightSmartSearchServiceTests|ContentAwareSmartSearchServiceTests|SmartSearchStoreTests|SmartSearchPresentationTests|AccessibilityPresentationTests'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel
rg -n 'CloudMaterializing|materialize\(|NSFileCoordinator|FileHandle|Data\(contentsOf:|String\(contentsOf:' Sources/BloomFileManager/Services/SpotlightMetadataQueryRunner.swift Sources/BloomFileManager/Services/SpotlightSmartSearchService.swift Sources/BloomFileManager/Services/ContentAwareSmartSearchService.swift
git diff --check
```

The search audit must return no matches and both test commands must exit zero.

- [ ] **Step 6: Commit integration**

```bash
git add Sources/BloomFileManager/Stores/SmartSearchStore.swift Sources/BloomFileManager/Views/SmartSearchView.swift Sources/BloomFileManager/App/BloomFileManagerApp.swift Sources/BloomFileManager/Support/SpotlightSearchAccessibilityIdentifiers.swift Tests/BloomFileManagerTests/SmartSearchStoreTests.swift Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md docs/current-limitations.md docs/current-limitations.ko.md
git commit -m "feat: expose indexed content search"
```
