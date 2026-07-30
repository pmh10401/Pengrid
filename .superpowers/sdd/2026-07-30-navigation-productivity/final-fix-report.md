# Pengrid 1.2 final-fix report

Date: 2026-07-30 (Asia/Seoul)
Branch: `feature/pengrid-1.2-navigation`
Fix base: `e53d23fc97f966a57a4462e636e259221c0eb0ef`

## Final-fix wave

This wave closes every finding in `final-review-findings.md` while preserving
the earlier review-fix commits as separate history:

- `cb94449` — `fix: preserve pane scroll anchor on rollback`
- `ffa7855` — `fix: ignore cancelled Quick Look selection updates`
- `e53d23f` — `test: verify Pengrid navigation productivity`

No push, publication, tag, DMG replacement, signing, notarization, or
destructive cleanup was performed.

## TDD evidence

All semantic RED and GREEN runs used the full Xcode toolchain:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --filter '<test>'
```

An initial attempt through the active Command Line Tools toolchain stopped
before test execution with `no such module 'Testing'`. That environment error
was not counted as a semantic RED; all evidence below came from the full Xcode
toolchain.

### 1. Invalid Back and Forward destinations

Tests:

- `failedBackNavigationDropsOnlyTheAttemptedDestination`
- `failedForwardNavigationDropsOnlyTheAttemptedDestination`
- `cancelledBackNavigationRestoresCompletePriorHistory`
- `supersededForwardNavigationRestoresCompletePriorHistory`

RED: failed Back restored `[home, stale]`, so the retry remained in Documents
and did not create the expected Forward entry. Failed Forward reproduced the
symmetric stale-destination retry.
GREEN: a navigation intent is recorded before loading; history transitions
commit only on success, failure discards only the attempted source-stack
destination, and cancellation or supersession restores the complete committed
snapshot.

Files:

- `Sources/BloomFileManager/Models/PaneNavigationHistory.swift`
- `Sources/BloomFileManager/Stores/FilePaneState.swift`
- `Tests/BloomFileManagerTests/FilePaneStateTests.swift`

### 2. Escape priority from the result table and other pane controls

Tests:

- `escapeFromFocusedFilterResultTableDismissesFilterFirst`
- `escapeFromPathEditorDismissesFilterBeforeCancellingPathEditing`

RED 1: the result-table regression did not compile because `FileTableView` had
no `onCancel` route.
GREEN 1: an actual unmodified Escape key event on the focused AppKit table
dismisses filtering, restores the captured selection, and does not invoke a
broader cancellation.

Independent re-review then found that a focused path editor could still cancel
path editing while leaving filtering open. RED 2 did not compile because the
shared `PaneEscapeRouting` behavior was absent. GREEN 2 verifies the first
Escape dismisses filtering without path cancellation and the next Escape
performs the broader path cancellation. The filter field, path field, AppKit
table, and pane-level SwiftUI handler now share that priority.

Files:

- `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- `Sources/BloomFileManager/Views/FilePaneView.swift`
- `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`
- `Tests/BloomFileManagerTests/FileTableSelectionTests.swift`

### 3. Exact scroll-anchor restoration

Tests:

- `scrollRestorationPinsTopAnchorToFirstVisibleRow`
- `scrollRestorationPinsMiddleAnchorToFirstVisibleRow`
- `scrollRestorationClampsEndAnchorToDocumentBottom`

RED: restoring the middle anchor made row 11 first-visible instead of row 15
because `scrollRowToVisible` only exposed the row.
GREEN: the coordinator positions the clip-view origin from the anchor row
rectangle and lets AppKit constrain the requested bounds at the top and
document end. All three AppKit behavior cases pass.

Files:

- `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`

### 4. Inactive-pane filter focus

Test: `focusingPresentedFilterActivatesInactivePaneBeforeEditingSession`

RED: the behavior test did not compile because no filter-focus route existed.
GREEN: focus activates the pane before starting its filter editing session;
focus loss only ends that session.

Files:

- `Sources/BloomFileManager/Views/FilePaneView.swift`
- `Tests/BloomFileManagerTests/FileTableSelectionTests.swift`

### 5. Stale initial Quick Look

Tests:

- `selectionChangeInvalidatesPendingInitialQuickLookPreparation`
- `quickLookCommandRejectsSelectionChangedDuringIdentityPreflight`
- `cancelledEmptyUpdateCannotCloseOrSupersedeNewerPreview`

RED 1: selection A completed suspended materialization and was presented after
selection changed; recorder history was `[[first]]` instead of empty.
GREEN 1: every active-pane selection generation invalidates pending controller
preparation before the closed-panel early return. A cancellation guard remains
ahead of invalidation so a cancelled stale observer cannot supersede a newer
preview.

Independent re-review found an earlier window while command identity preflight
was suspended. RED 2 did not compile because the pane-and-URL command-selection
route was absent. GREEN 2 uses a deterministic suspended identity lookup:
changing from pane/selection A to B before preflight releases prevents both
materialization and presentation of A. The current pane and URLs are
revalidated immediately before `prepareAndPresent`.

An intermediate focused run exposed an ordering regression in
`cancelledEmptyUpdateCannotCloseOrSupersedeNewerPreview`; moving the
already-cancelled guard before generation mutation restored the intended
ordering, and the amended focused and full suites pass.

Files:

- `Sources/BloomFileManager/Support/QuickLookController.swift`
- `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- `Sources/BloomFileManager/Views/WorkspaceView.swift`
- `Tests/BloomFileManagerTests/CloudOperationGateTests.swift`
- `Tests/BloomFileManagerTests/Support/RecordingFileSystem.swift`

### 6. Pane-specific VoiceOver filter labels

Test: `paneFilterAccessibilityIsStableAndReportsResults`

RED: presentation helpers did not expose pane-specific `fieldLabel` and
`closeLabel` values.
GREEN: left and right filter fields and close buttons derive stable spoken
labels from `PaneID`. No source-string or source-grep assertion was added.

Files:

- `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- `Sources/BloomFileManager/Views/FilePaneView.swift`
- `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

### 7. Trailing directory separators in the view-state cache

Test: `cacheTreatsTrailingDirectorySeparatorsAsTheSameLocation`

RED: storing `file:///folder/` and reading `file:///folder` returned `nil`.
GREEN: cache keys remove trailing separators while preserving the root path,
matching `FilePaneState` and navigation-history normalization.

Files:

- `Sources/BloomFileManager/Models/PaneViewStateCache.swift`
- `Tests/BloomFileManagerTests/PaneViewStateCacheTests.swift`

## Final verification

Focused amended suites:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'FilePaneStateTests|PaneNavigationHistoryTests|FileTableSelectionTests|FileTableViewLifecycleTests|CloudOperationGateTests|AccessibilityPresentationTests|PaneViewStateCacheTests'
```

Result: **PASS**, 70 tests in 5 suites, 0 failures, 0.143 seconds.

Exact serial full suite:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
```

Result: **PASS**, 588 tests in 45 suites, 0 failures, 34.919 seconds.

Build/run verification:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
```

Result: **PASS**, exit 0; debug build completed successfully.

Diff hygiene:

```sh
git diff --check
```

Result: **PASS**, exit 0 with no output.

The public checklist now includes the required durable note: one transient
comparison-coordinator assertion failed, passed in focused isolation, and the
following complete serial rerun passed. The release gate remains PASS and no
flake fix is claimed. Every physical/manual checklist row remains `NOT RUN`.

## Self-review

- New regressions exercise behavior and use continuations, actor state, actual
  AppKit events, or observable model output; no new sleep-based race or
  production-source text assertion was added.
- Failed history transitions, cancellation, supersession, persistence, cache
  bounds, Quick Look generation ordering, and table teardown remain covered by
  the serial suite.
- AppKit callbacks are cleared during dismantle.
- Quick Look revalidation occurs after identity preflight and before
  materialization, while controller generation checks cover the materialization
  window.
- Manual keyboard focus, VoiceOver, physical File Provider, Quick Look,
  appearance, and large-folder interaction checks were not performed and
  remain explicitly open.
- Existing warnings remain in test code for ineffective `@preconcurrency`
  annotations and weak-variable mutability. No warning was introduced by this
  wave.

## Concerns

- Physical/manual gates are still `NOT RUN`; automated evidence must not be
  treated as physical UI, VoiceOver, File Provider, or appearance validation.
- The documented comparison-coordinator timing flake was not reproduced in the
  final serial run and was not claimed fixed.
- Signing, notarization, Gatekeeper, release assets, publication, and remote
  delivery remain outside this wave.
