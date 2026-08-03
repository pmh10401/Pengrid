# Safe File Operation Center Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Keep core design and implementation in the root agent; delegate only mechanical checks to Luna Max. Use TDD for every behavior change.

**Goal:** Add an identity-safe, single-worker file-operation queue with bounded session history, cooperative pause/resume, cancellation, retry, and conservative undo, exposed through an accessible operation-center popover.

**Architecture:** `FileOperationController` remains the MainActor owner of UI state and becomes the single scheduler. It stores immutable prepared job closures only after source identities are captured, runs exactly one mutation job at a time, and delegates cooperative checkpoints to a small actor. Finished jobs become privacy-safe snapshots in a 100-entry session history. Undo is recipe based and fail-closed: every target identity and, for created trees, the complete no-follow fingerprint must still match before mutation.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, AppKit/Foundation file coordination, existing `FileSystemAccess` and archive services.

---

### Task 1: Job presentation models and cooperative control

**Files:**
- Create: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Create: `Sources/BloomFileManager/Services/FileOperationControl.swift`
- Create: `Tests/BloomFileManagerTests/FileOperationControlTests.swift`
- Create: `Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift`

**Interfaces:**
- `FileOperationJobKind`: copy, move, trash, create folder, rename, compress(format), extract(format), undo
- `FileOperationJobState`: queued, running, paused, succeeded, failed, cancelled
- `FileOperationJobSnapshot`: id, kind, safe title, item count, state, optional progress, retry/undo availability
- `FileOperationControl`: `pause()`, `resume()`, `cancel()`, `checkpoint()`

- [x] Write tests proving snapshots never accept or derive absolute paths, state labels are stable, preparation fractions clamp, and only terminal failed/cancelled jobs expose retry.
- [x] Write actor tests proving a paused checkpoint suspends, resume releases every waiter, cancellation releases waiters by throwing, and repeated pause/resume is idempotent.
- [x] Run `swift test` filtered to the two new suites and verify RED.
- [x] Implement the minimum models and cancellation-safe continuation handling.
- [x] Rerun focused tests, `git diff --check`, and commit `feat: model safe operation jobs`.

### Task 2: Single-worker queue, history, cancellation, pause, and retry

**Files:**
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`

**Interfaces:**
- Observable controller properties: `activeJob`, `queuedJobs`, `operationHistory`, `isPaused`
- Commands: `pauseActiveJob()`, `resumeActiveJob()`, `cancelActiveJob()`, `cancelQueuedJob(_:)`, `retryJob(_:)`
- Private `PendingFileOperation` retains the immutable identified intent, touched directories, workspace, completion callback, and operation closure.

- [x] Add gated-operation tests proving FIFO order, exactly one active closure, queued cancellation without execution, active cancellation cleanup before the next job starts, pause at checkpoint, resume, and history trimming to 100 newest entries.
- [x] Add retry tests proving the retry is a new job ID, reuses the original immutable intent, and is rejected for successful jobs.
- [x] Run the controller suite and verify the current `guard !isRunning` behavior fails the queue tests.
- [x] Replace `beginOperation` rejection with enqueue/start-next scheduling. Create one `FileOperationControl` per execution attempt and update snapshots only on MainActor.
- [x] Do not start the next job until `completeOperation` has refreshed affected panes and finished cancellation cleanup.
- [x] Run focused controller tests, `git diff --check`, and commit `feat: queue and control file operations`.

### Task 3: Capture identified intents before queued execution

**Files:**
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationService.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`

**Interfaces:**
- Queueable transfer submission captures source and destination identities immediately in an asynchronous submission task, then enqueues `IdentifiedTransferRequest` values.
- Archive and confirmed-trash jobs retain their existing identified captures.
- Queueable commands remain enabled while another mutation runs; inline rename remains disabled while a job is active.

- [x] Add a test that queues a transfer, replaces its source before execution, and expects `identityChanged` failure with no destination mutation.
- [x] Add tests proving the destination-root identity is captured before waiting and a replaced destination root fails closed.
- [x] Add command-policy tests proving copy/paste, trash, compression, extraction, and new-folder submission can enqueue while active, while rename and text-editing conflicts remain blocked.
- [x] Implement asynchronous identified transfer submission and remove all path-only transfer authority from queued closures.
- [x] Thread `FileOperationControl.checkpoint()` through materialization progress, file-item progress, and the archive phase callback. Encoding can pause only before the native process launches; it is never process-suspended.
- [x] Run transfer, command-policy, archive, and controller suites; commit `feat: capture queued file intents safely`.

### Task 4: Conservative undo recipes and Trash result capture

**Files:**
- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationService.swift`
- Modify: `Sources/BloomFileManager/Services/ArchiveOperationService.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Create: `Sources/BloomFileManager/Services/FileOperationUndoService.swift`
- Create: `Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileSystemAccessTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`

**Interfaces:**
- `trashAndReturnResultingURL(_:identifiedBy:)` returns the actual macOS Trash URL.
- `FileOperationUndoRecipe` supports identity-checked move-back, Trash restore, and fingerprint-checked removal of newly created output.
- Replacement conflict decisions explicitly make the job non-undoable.

- [x] Test live Trash URL capture with a temporary fixture and restore cleanup.
- [x] Test rename/move undo requires the same identity and an absent original path.
- [x] Test Trash undo restores only the same trashed identity and refuses an occupied original path.
- [x] Test copy/new-folder/archive/extract undo captures a full no-follow fingerprint, quarantines by identity, rechecks the fingerprint, and rolls back if either check differs.
- [x] Test replacement conflicts never expose undo and a failed undo remains in history with a safe explanation.
- [x] Implement recipes and an undo service using `quarantineForTrash`, `rollbackTrashQuarantine`, and `moveTrashQuarantineAtomically`; never recursively delete an unverified path.
- [x] Build a recipe only from successful outcomes after capturing destination identity/fingerprint. Enqueue undo as an ordinary single-worker job.
- [x] Run filesystem, mutation, archive, undo, and controller suites; commit `feat: add identity checked operation undo`.

### Task 5: Accessible operation-center interface

**Files:**
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Create: `Sources/BloomFileManager/Views/FileOperationCenterView.swift`
- Create: `Tests/BloomFileManagerTests/FileOperationCenterViewTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

**Behavior:**
- A compact bottom status control always exposes active/queued count when activity or history exists.
- Its popover has Active, Queue, and Recent sections with Pause/Resume, Cancel, Retry, and Undo actions only when valid.
- Display strings contain operation kind, basename-only title, counts, state, and phase—never absolute paths or raw provider metadata.

- [x] Add presentation tests for every state/action combination, bounded history ordering, sanitized labels, stable identifiers, keyboard focus order, VoiceOver labels, Reduce Motion, and empty state.
- [x] Add the popover and wire commands to controller methods.
- [x] Ensure progress remains determinate only where a reliable count exists and buttons have explicit accessibility labels/help.
- [x] Run view, accessibility, and controller tests; commit `feat: add file operation center interface`.

### Task 6: Documentation and full verification gate

**Files:**
- Modify: `README.md`
- Create: `docs/verification/safe-operation-center-checklist.md`

- [x] Document default-FIFO single-worker behavior and reordering, cooperative pause limitations, cancellation cleanup ordering, session-only 100-entry history, identity-safe retry, and conservative undo refusal cases.
- [x] Run the full serial Swift Testing suite with full Xcode.
- [x] Run the release build and `./script/build_and_run.sh --verify`.
- [x] Have Luna Max perform only the mechanical accessibility wiring checklist;
  actual VoiceOver speech remains a documented manual release gate.
- [x] Have Sol XHigh independently re-review the resolved safety, cancellation, identity-authority, fingerprint-authority, and progress-throttling findings.
- [ ] Rerun full verification after review fixes, record exact evidence, and run `git diff --check`.

Verification commands:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --enable-swift-testing --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release --disable-sandbox
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
git diff --check
```

Expected: zero failures, one active mutation at a time, no queued path-only authority, cancellation cleanup before dequeue, safe refusal instead of destructive undo on any mismatch, and no absolute paths in operation-center presentation or logs.
