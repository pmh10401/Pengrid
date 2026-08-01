# Local Smart Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` for this plan. Dispatch a fresh implementer for each task, run a task-scoped review after each task, and run a whole-branch review before integration.

**Goal:** Add a local, recursive, cancellable Smart Search with deterministic BM25-style filename/path ranking, saved searches, and an accessible macOS search panel.

**Architecture:** A pure query/result/ranking model feeds `LocalSmartSearchService`, which enumerates explicit local roots and reports `FileItem` metadata. `SmartSearchStore` owns cancellable UI state and saved-search CRUD. `WorkspacePersistence` stores saved searches under a separate versioned key. `WorkspaceView`, `PlacesRailView`, and `WorkspaceCommands` expose the feature without changing the existing pane-local Command-F filter.

**Tech Stack:** Swift 6.1, macOS 15, SwiftUI, AppKit, Swift Testing, Foundation `FileManager` and `UserDefaults`; no new package dependencies.

## Global Constraints

- Preserve the existing dual-pane behavior and keep `Command-F` mapped to the pane-local filename filter; Smart Search uses Command-Shift-F.
- Search is local and metadata-only. Do not add network calls, remote embeddings, document-content reads, Spotlight requirements, or automatic cloud materialization.
- Search roots are explicit, absolute local file URLs. Standardize and deduplicate them; never broaden a root to its parent or a volume.
- Traversal defaults are safe: skip hidden entries, package descendants, and symbolic-link descendants. A matching symlink may be returned as a row but must never be traversed.
- Query text is trimmed; empty queries do not start a search. `maximumResults` is clamped to `1...2_000` and defaults to `500`.
- Every traversal loop and result publication checks cancellation. Starting a new store search cancels the previous generation and stale results must not overwrite the current query.
- Rank filename matches above path-only matches with deterministic BM25-style scoring. Equal scores sort by standardized path using localized numeric comparison.
- Cloud availability is displayed from `CloudItemAvailabilityReading`; search must never call `CloudMaterializing`.
- Persist saved searches under a separate versioned UserDefaults key (`smartSearches.v1`) so existing `WorkspaceSnapshot` decoding remains backward-compatible. Malformed data restores an empty list.
- All new user-facing controls and result rows have explicit accessibility labels and stable identifiers. Do not expose full sensitive paths in error/log strings when a display name or relative path is sufficient.
- Use Swift Testing and temporary-directory fixtures. Each implementation task must add a focused failing test before production code and commit one coherent change.
- Do not modify the original workspace at `/Users/mac/Documents/파일관리자 만들기`; all work happens in the `smart-search` worktree.

---

## Task 1: Query, result, and ranking models

**Files:**
- Add `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Add `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`

### Step 1: Write the failing tests

Add Swift Testing coverage for:

- trimming query text and clamping result limits;
- rejecting empty text and invalid/non-file roots through the model validation API;
- localized case/diacritic-insensitive tokenization, including a Korean token;
- filename token matches scoring above path-only matches;
- exact and prefix filename bonuses;
- deterministic path ordering for equal scores; and
- `SmartSearchRecord` Codable round trips with URLs and dates.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter SmartSearchModelTests
```

Expected: FAIL because the model does not exist yet.

### Step 2: Implement the minimum model

Define `SmartSearchQuery`, `SmartSearchResult`, `SmartSearchRecord`, a
`SmartSearchValidationError`, and an internal/public deterministic ranker. Use
Foundation tokenization and `URL.standardizedFileURL`. Keep value types
`Codable`, `Equatable`, and `Sendable` where applicable. Expose only the
validation and ranking operations needed by the service/store.

### Step 3: Verify and commit

Re-run the focused tests and then commit:

```text
feat: add smart search query and ranking models
```

The implementer report must be at `.superpowers/sdd/2026-08-01-smart-search/task-1-report.md`.

---

## Task 2: Local recursive search service

**Files:**
- Add `Sources/BloomFileManager/Services/SmartSearchService.swift`
- Add `Tests/BloomFileManagerTests/SmartSearchServiceTests.swift`
- Reuse `CloudItemAvailabilityReading` and `CloudLocationScopedAccessCoordinator` without changing their contracts.

### Step 1: Write the failing tests

Use `TemporaryDirectory` fixtures and a fake availability reader. Cover:

- recursive matching across nested directories;
- multiple explicit roots with duplicate-root de-duplication;
- filename ranking preference and result-cap enforcement;
- hidden-file, package-descendant, and symlink-descendant defaults plus opt-in behavior;
- directory-result toggling;
- cloud availability copied to the result without materialization;
- invalid/non-directory roots throwing a stable error;
- unreadable descendants being skipped while other matches remain; and
- cancellation of a large traversal returning `CancellationError` promptly.

Run the focused suite and observe the expected compile/test failure before implementation.

### Step 2: Implement the service

Define:

```swift
protocol SmartSearching: Sendable {
    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult]
}
```

Implement `LocalSmartSearchService` with injectable `FileManager`, availability
reader, and a small traversal hook for deterministic tests. Standardize and
validate roots, enumerate metadata only, skip unsafe descendants, check
`Task.checkCancellation()`, rank candidates with Task 1, and return the top
clamped limit. Do not invoke any cloud materializer.

### Step 3: Verify and commit

Run `SmartSearchServiceTests` and commit:

```text
feat: add cancellable local smart search service
```

The implementer report must be at `.superpowers/sdd/2026-08-01-smart-search/task-2-report.md`.

---

## Task 3: Store, saved-search persistence, and command routing

**Files:**
- Add `Sources/BloomFileManager/Stores/SmartSearchStore.swift`
- Update `Sources/BloomFileManager/Stores/WorkspacePersistence.swift`
- Update `Sources/BloomFileManager/Stores/WorkspaceState.swift`
- Update `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Update `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Add `Tests/BloomFileManagerTests/SmartSearchStoreTests.swift`
- Extend `Tests/BloomFileManagerTests/WorkspacePersistenceTests.swift` and `WorkspaceCommandTests.swift`

### Step 1: Write the failing tests

Cover:

- a new store search cancels/replaces an older generation and stale results are ignored;
- empty query does not call the service;
- progress, cancellation, and error state transitions;
- save/rename/delete saved-search CRUD with stable ordering;
- separate-key persistence, malformed-data fallback, and relaunch round trip;
- Command-Shift-F opens the store using the active pane directory; and
- existing Command-F filter routing remains unchanged.

Run the focused tests and observe failure before implementation.

### Step 2: Implement the store and routing

Make `SmartSearchStore` `@MainActor @Observable`, inject `SmartSearching` and
`WorkspacePersistence`, and guard each search task with a monotonically
increasing generation. Add `WorkspacePersistence.loadSavedSearches()` and
`saveSavedSearches(_:)` using `smartSearches.v1`. Initialize the store in
`WorkspaceState`/`BloomFileManagerApp`, expose it as a focused scene value, and
add a `Search Files…` command with Command-Shift-F. Keep command actions pure
enough to test and do not alter the existing filter command.

### Step 3: Verify and commit

Run the focused suites and commit:

```text
feat: connect smart search state persistence and commands
```

The implementer report must be at `.superpowers/sdd/2026-08-01-smart-search/task-3-report.md`.

---

## Task 4: Search panel, sidebar saved searches, and accessibility

**Files:**
- Add `Sources/BloomFileManager/Views/SmartSearchView.swift`
- Update `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Update `Sources/BloomFileManager/Views/PlacesRailView.swift`
- Update `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Add `Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift`

### Step 1: Write the failing tests

Add pure presentation tests for:

- result accessibility labels with relative paths and availability;
- saved-search row labels and delete affordance text;
- the empty/loading/error/complete presentation states; and
- opening a result navigates the active pane to a directory or containing folder without materialization.

Run the focused suite and observe failure before implementation.

### Step 2: Implement the UI

Build an overlay panel with a focused search field, root summary, hidden/package/
directory toggles, progress/cancel state, capped result list, save action, and
an explicit close action. Add Smart Searches to the sidebar with context-menu
delete and activation. Wire result activation to the active pane and retain
cloud availability labels. Provide stable identifiers in
`AccessibilityIdentifiers` and keep VoiceOver strings concise.

### Step 3: Verify and commit

Run the focused presentation tests and a release compile, then commit:

```text
feat: add accessible smart search workspace UI
```

The implementer report must be at `.superpowers/sdd/2026-08-01-smart-search/task-4-report.md`.

---

## Task 5: Documentation and whole-feature verification

**Files:**
- Update `README.md` with Smart Search usage and safety behavior.
- Add `docs/verification/smart-search-checklist.md`.
- Update `docs/release.md` with the next unreleased feature note.
- Add or update tests only when a verification gap is discovered.

### Step 1: Document the feature

Describe the Command-Shift-F shortcut, explicit roots, saved searches, result
limit, cloud-only behavior, and traversal safety. Do not claim content search,
remote search, or automatic downloads.

### Step 2: Run all gates

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
./script/tests/package_release_contract_tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --arch arm64
git diff main...HEAD --check
```

Record test counts and any pre-existing warnings in the implementer report.

### Step 3: Commit

```text
docs: document local smart search
```

The implementer report must be at `.superpowers/sdd/2026-08-01-smart-search/task-5-report.md`.

---

## Final review and integration

After all task reviews are clean, dispatch the broad whole-branch code review
using the most capable available reviewer. Resolve every finding with one
targeted fix round and a scoped re-review. Re-run the full gates above, then use
`superpowers:finishing-a-development-branch` to present the integration menu.
