# Task 2 report — cancellable folder preview listing and atomic state

## Scope

- Added `FolderPreviewListing` and `LiveFolderPreviewListing` as the sole
  cancellable facade over `FileSystemAccess.snapshotFolder`.
- Added `@MainActor @Observable FolderPreviewModel` with generation-guarded
  progress, complete-snapshot-only row publication, and an owned work lifetime.

## Safety decisions

- The live facade requires the returned snapshot request to equal the complete
  captured request (pane, standardized URL, exact identity, and kind); a
  mismatch is surfaced as `FileSystemAccessError.identityMismatch`.
- The model repeats that exact request check before publishing. Identity
  mismatch becomes `.folderChanged`; every other non-cancellation filesystem or
  provider failure becomes `.unavailable`. Cancellation has no result/error
  publication.
- Replacement and close/reset increment a generation, cancel prior work, and
  clear request, rows, progress, and phase. A newest-only progress stream
  returns updates to the main actor, so large listings do not create one task
  per examined item and can update only the live loading generation.
- `FolderPreviewWorkLifetime` owns the task under a lock, while the task holds
  the model weakly. Its deinitializer cancels even a listing that ignores
  cancellation, so the model cannot be retained by outstanding preview work.

## Tests

All invoked with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- `xcrun swift test --filter FolderPreviewListingTests` — 2 passed.
- `xcrun swift test --filter FolderPreviewModelTests` — 7 passed.
- `xcrun swift test --filter FileSystemAccessTests` — 17 passed.
- `xcrun swift test --filter DirectoryListingServiceTests` — 2 passed.
- `git diff --check` — passed.

The test suite emitted only pre-existing AppKit `@preconcurrency` warnings in
unrelated test fixtures.

## Fix round 1 — review evidence hardening

- Replaced every unbounded `Task.yield()` polling loop in the model test file
  with a one-second bounded wait helper. A timeout records the awaited state in
  the test failure instead of leaving the test process stalled.
- Separated the late-success case from stale error/progress coverage: a
  cancelled first listing can now return a complete old snapshot after its
  replacement has started, and the test proves it leaves the new generation
  loading with no rows until the second snapshot completes.
- Strengthened model deinitialization coverage with a deliberately
  noncooperative continuation. The test first verifies an initial relay update,
  releases the model, observes cancellation delivered to the held listing task,
  sends a post-cancellation progress value into the now-finished relay path,
  permits the held task to exit, and verifies the model remains released. This
  exercises the single `FolderPreviewWorkLifetime.cancel()` path that finishes
  the relay and cancels the progress consumer alongside the listing task.

Fix-round verification (same Xcode developer directory):

- `FolderPreviewListingTests` — 2 passed.
- `FolderPreviewModelTests` — 8 passed.
- `FileSystemAccessTests` — 17 passed.
- `DirectoryListingServiceTests` — 2 passed.
- `git diff --check` — passed.
