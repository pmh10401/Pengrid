# Task 6 report: Smart Search workspace integration

## Delivered

- Preserved the pane-local `Command-F` filter and added `Command-Shift-F` Smart Search.
- Wired a live `SmartSearchStore`, identity-safe router, search sheet, roots, filters,
  sortable privacy-safe result columns, saved-search controls, progress/errors, and Task 5 actions.
- Added stable Smart Search accessibility identifiers, deterministic initial query focus,
  explicit labels/hints, and VoiceOver-safe search state announcements.
- Copy, move, and Trash revalidate first, then dismiss the sheet immediately before the
  identified operation-center handoff. This keeps identity-mismatch errors visible in the sheet.

## TDD evidence

1. RED: `xcrun swift test --filter SmartSearchPresentationTests && xcrun swift test --filter WorkspaceCommandTests`
   initially failed because `WorkspaceSearchCommandActions` and Smart Search accessibility
   identifiers did not exist.
2. RED: the new presentation test failed because direct date filters and VoiceOver
   announcement wiring were absent.
3. RED: the presentation test failed while mutations dismissed before identity revalidation.
4. GREEN: each corresponding focused test passed after the minimal implementation.

All `xcrun` invocations used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Final verification

- `xcrun swift test --filter SmartSearchPresentationTests` — 1 passed
- `xcrun swift test --filter WorkspaceCommand` — 18 passed
- `xcrun swift test --filter AccessibilityPresentationTests` — 8 passed
- `xcrun swift test --filter SmartSearchActionRouterTests` — 10 passed
- `xcrun swift test --filter SmartSearchStoreTests` — 17 passed
- `git diff --check` — clean

## Judgment call

`WorkspaceCommands.smartSearch` is optional to preserve unrelated direct-initializer callers
and tests. The application always injects the live store, and the Smart Search command stays
disabled when no store is supplied.

## Review fix round 1

- Queue mutations now dismiss only after the identified controller accepts the operation; a
  rejected queue keeps the sheet and its state open with a safe error.
- The action router receives the app's shared scoped-access coordinator and holds registered
  manual-cloud leases while revalidating every action identity. A denied lease fails closed.
- Saved searches now support open, save, rename, and delete. Opening immediately reloads every
  visible filter draft before a user can submit a replacement query.
- Supported sort headers set `SmartSearchStore.sort` and render its deterministic ordering;
  non-persisted location/type/availability columns remain display-only.
- Actions capture result selection, source pane, target pane, and destination URL before their
  asynchronous task begins. The router has an explicit captured-target-pane route.
- Smart Search announcements are injectable; search progress and cancellation are announced.

### Round 1 verification

- RED: presentation/action-router tests failed for absent coordinator injection and capture/CRUD
  requirements, then passed after implementation.
- `SmartSearchPresentationTests` — 1 passed
- `WorkspaceCommand` — 18 passed
- `AccessibilityPresentationTests` — 8 passed
- `SmartSearchActionRouterTests` — 12 passed
- `SmartSearchStoreTests` — 17 passed
- `CloudLocationScopedAccessTests` — 17 passed
