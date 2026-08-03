# Pengrid Safe Operation Center and Archive Progress Design

**Date:** 2026-08-03

## Objective

Add a session-scoped operation center that serializes file mutations, exposes
queued and recent work, supports safe cancellation, cooperative pause/resume,
retry, and identity-gated undo. Replace the archive spinner with honest staged
progress that never invents a percentage the native archive tools cannot
prove.

## Existing Baseline

Pengrid 1.3 already has one `FileOperationController` shared by the workspace,
identity-aware transfer and rename paths, cloud materialization, conflict
resolution, cancellation, staged archive publication, and a compact bottom
status bar. `beginOperation` currently rejects every second operation while one
is active. Archive progress currently identifies the format and item but is
indeterminate after cloud preparation.

## Product Principles

- Only one job may mutate the file system at a time.
- A queued intent must retain the identities captured from the user's original
  selection. Waiting must never turn a path into authority to mutate a later
  replacement at the same path.
- A retry reuses the original intent and identities. If an item changed, the
  retry fails closed and asks the user to refresh and select again.
- Pause is cooperative. Pengrid pauses before the next item or before launching
  a native archive process. It does not send `SIGSTOP` to `ditto`, `tar`, or a
  File Provider operation.
- Cancel remains available while running. A cancelled job follows the existing
  cleanup and recovery rules before the next job begins.
- Undo is offered only after all required identities and fingerprints have been
  captured. If validation fails, no mutation is attempted.
- Undo of a created item moves it to the macOS Trash; it never permanently
  deletes it.
- Operation history is session-only, bounded, and never written to logs or
  preferences with absolute paths.
- Visible progress and VoiceOver use basenames only. Duplicate basenames may be
  disambiguated only by already validated relative paths.

## Scope

The first delivery covers ordinary copy, move, rename, new folder, Trash,
compression, and extraction jobs. Storage Inspector cleanup remains an
exclusive reviewed operation and is shown in the active status, but it is not
queueable, retryable, or undoable through the ordinary operation center.
Comparison transfers use the same queue because they already provide captured
identities and safe relative paths.

The operation center provides:

- one active job and a FIFO pending queue;
- move-up and move-down controls for pending jobs;
- cancellation of active or pending jobs;
- cooperative pause after the current item and resume;
- retry for failed, partially failed, and cancelled jobs;
- a bounded list of the 100 most recent terminal jobs;
- eligible undo for the newest still-valid completed job;
- a compact bottom status plus an accessible popover containing active,
  pending, and recent sections.

## Non-goals

- Running two mutation jobs concurrently.
- Pausing a native archive process after it has started.
- Resuming a cancelled archive process from partial bytes.
- Persisting queued jobs or history across app launches.
- Automatic retry, background execution after app termination, scheduling, or
  notification delivery.
- Undoing conflict replacement. A job containing `Replace` is recorded as not
  undoable because restoring the replaced destination would require retaining
  private backup data.
- Treating an estimated compression ratio or growing output size as progress.

## Job Model

`FileOperationJob` is an observable presentation snapshot with:

- `id: UUID`
- `kind: FileOperationJobKind`
- `title` and privacy-safe `displayName`
- `itemCount`
- `state: FileOperationJobState`
- `progress: OperationProgressSnapshot?`
- `submittedAt`, optional `startedAt`, optional `finishedAt`
- optional terminal `FileOperationResult`
- `canRetry`, `canUndo`, and an optional user-facing reason when unavailable

The executable closure and the retry/undo recipes are held in a private
`QueuedOperation` runtime object. They are never encoded. Presentation structs
are value types and do not expose URLs.

States are:

- `queued`
- `preparing`
- `running`
- `waitingForConflict`
- `pauseRequested`
- `paused`
- `cancelling`
- `succeeded`
- `partiallyFailed`
- `failed`
- `cancelled`
- `undoing`
- `undone`
- `undoUnavailable`

Only terminal jobs enter history. A retry creates a new job linked to the old
job's ID; it does not rewrite history.

## Queue and Execution Control

`FileOperationController` owns a private FIFO of `QueuedOperation`, the active
runtime job, and a single worker task. Submission appends a job and starts the
worker if idle. Completion fully refreshes touched visible panes before the
next job starts so the next job sees current state.

`OperationExecutionControl` is an actor shared by one active job. Services call
`checkpoint()` before each top-level item, after conflict resolution, before
archive staging workers claim a new item, and immediately before a native
archive command launches. `checkpoint()` suspends while paused and throws on
cancellation. A pause requested during a single long copy or native archive
command becomes `pauseRequested`; it becomes `paused` at the next checkpoint.
The UI explains this as “Pauses after the current item.”

Pending cancellation marks the job cancelled without executing its closure.
Active cancellation cancels the worker child task and resolves a waiting
conflict as `.cancel`. The worker waits for existing cleanup to finish before
advancing.

## Safe Intent Capture

Queue submission captures identities before the job can wait:

- rename and confirmed Trash already carry `IdentifiedFileRequest` values;
- comparison transfer already carries `IdentifiedTransferRequest` values;
- paste and drag/drop asynchronously capture each source identity plus the
  destination root identity before enqueueing;
- compression and extraction capture each source identity plus the destination
  parent identity before enqueueing;
- new folder captures its destination parent identity.

If selection or destination changes while asynchronous capture is running, the
submission is discarded. Raw URL controller entry points remain only as
compatibility wrappers for tests and immediately submitted work; production UI
routes use identified intents.

## Retry

Retry is available for jobs with failed or cancelled outcomes. It builds a new
runtime job from the original immutable identified intent and performs the same
identity checks as the first run. Conflict “apply to all” decisions are not
reused. Archive destinations are replanned using the original desired basename
and current occupied names, preserving the existing keep-both rule.

Successful outcomes from a partial job are not executed again. The retry recipe
contains only failed, skipped-at-error, and cancelled inputs. A skipped item
caused by an explicit `Skip` conflict decision is not retried automatically.

## Undo

Undo recipes are captured only for successful outcomes and are invalidated by
any later Pengrid mutation that overlaps their source or destination paths.
Before undo, every recipe is preflighted; if any member is invalid, none begin.

- **Rename:** require the renamed destination identity to match, require the
  original path to be absent, then move by identity back to the original path.
- **Move:** require every destination identity to match and every original path
  to be absent. Move in reverse completion order using identity-aware exclusive
  moves.
- **Trash:** ordinary Trash operations return the actual resulting Trash URL
  and identity. Require that Trash identity to match and the original path to
  be absent, then move back exclusively. If macOS does not return a resulting
  URL, that outcome is not undoable.
- **Copy, new folder, compression, extraction:** capture a full no-follow
  fingerprint after successful publication. Undo first moves the item into an
  identity-bound private quarantine, compares the quarantined fingerprint with
  the completion fingerprint, and only then moves it to the macOS Trash. A
  mismatch is rolled back to the original location and undo becomes
  unavailable.
- **Replacement conflicts:** not undoable in this delivery.

Undo itself is represented as an exclusive active operation but is not
retryable. A partially completed undo is reported as recovery needed and stops
the queue until its cleanup result is visible.

## Archive Progress

`ArchiveOperationProgress` becomes phase-aware:

1. `preparingSources(completedItems, totalItems, currentDisplayName)` reports
   completion of top-level aggregate staging copies. Parallel workers update a
   single actor-backed counter, so counts are monotonic and bounded.
2. `encoding(currentDisplayName)` is an indeterminate native-command phase.
   A 2026-08-03 macOS diagnostic showed that `ditto -V` omits directories,
   emits two status lines for ordinary files and symbolic links, adds separate
   AppleDouble entries, and splits a newline-containing name across physical
   lines. `tar -v` was regular in the same fixture, but Pengrid uses one honest
   progress contract across ZIP and TAR-family formats.
3. `publishing(currentDisplayName)` covers staged-output verification and the
   exclusive move to the final destination.

The native command runner accepts an `ArchiveCommandProgressHandler`, but does
not enable or parse verbose command output. Pengrid shows the exact top-level
source-preparation bar followed by an indeterminate “Encoding archive” phase.
Completion is emitted only after process exit status 0 and output publication.
This gives meaningful progress without claiming a false percentage.

Progress updates are throttled to at most ten visible publications per second,
except phase changes and terminal completion, which publish immediately.

## UI and Accessibility

The compact `OperationStatusView` remains at the bottom of the workspace. It
shows the active job, a determinate bar when progress is determinate, an
indeterminate indicator otherwise, pending count, and an “Operations” button.

The operation-center popover contains:

- Active: title, phase, item/count progress, pause/resume when supported, cancel.
- Pending: ordered rows with Move Up, Move Down, and Cancel.
- Recent: summary, Details, Retry when eligible, and Undo when eligible.

Buttons use text labels in addition to symbols. Each row is one VoiceOver
element with kind, state, progress, and availability reason. Progress
announcements occur on phase change and each 10% boundary, not every native
output line. Focus moves to the next sensible control when a pending row is
removed, and opening/closing the popover does not steal file-table focus.

## Integration Boundaries

- `FileOperationController` remains the workspace source of truth and scheduler.
- `FileOperationService` remains the owner of file mutations and receives an
  optional execution-control checkpoint.
- `ArchiveOperationService` remains the owner of staging publication and
  forwards phase-aware progress.
- `ArchiveCommandRunning` owns native-process progress and cancellation only.
- `FileSystemAccess` owns identity-anchored quarantine, fingerprint comparison,
  Trash-result capture, and exclusive restoration.
- `WorkspaceCommandPolicy` permits queueable mutations while another ordinary
  job runs, but continues to block them during text editing, Storage Inspector
  cleanup, comparison state transitions that require exclusivity, and undo.

## Failure and Recovery

- A failure in one job never starts a second job before cleanup and pane refresh
  complete.
- Queue processing continues after ordinary failure or cancellation.
- `recoveryNeeded` pauses automatic queue advancement until the user explicitly
  chooses Continue; this prevents hiding a retained staging payload behind later
  work.
- App termination cancels the active task. Pending jobs and session history are
  discarded.
- Absolute paths remain available only inside runtime recipes and existing
  filesystem calls; presentation, accessibility, and logs receive sanitized
  names or validated relative paths.

## Test Strategy

- Model tests for every state transition, terminal summary, retry eligibility,
  bounded history, queue reordering, and invalid transition rejection.
- Scheduler tests for FIFO execution, one active mutation, pending cancellation,
  pause checkpoints, conflict wait, cleanup-before-next-job, and recovery halt.
- Identity tests for replacement while queued, retry after replacement, and
  destination-root replacement.
- Undo tests for each recipe, collisions, changed fingerprints, quarantine
  rollback, partial recovery, and replacement-conflict exclusion.
- Archive runner tests for monotonic preparation counts, parallel completion
  ordering, phase transitions, cancellation, stderr limits, and newline names.
- Integration round trips for ZIP, TAR, TAR.GZ, TAR.BZ2, and TAR.XZ with progress
  and unchanged archive contents.
- UI presentation and accessibility tests for determinate/indeterminate phases,
  controls, availability explanations, focus, and announcement throttling.
- Full `swift test --disable-sandbox --no-parallel`, release build, app-bundle
  verification, and manual VoiceOver/appearance checks.

## Delivery Slices

1. Phase-aware archive progress from runner through the existing status bar.
2. Operation job model, serial scheduler, bounded session history, cancel,
   cooperative pause/resume, and retry.
3. Operation-center popover, queue reorder controls, command-policy routing, and
   accessibility.
4. Identity-gated undo recipes and quarantine-backed safe removal.
5. Full regression, performance, release documentation, and manual UI gates.

Each slice must keep all previous tests green and be independently reviewable.
