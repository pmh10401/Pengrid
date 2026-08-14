# Command-Z File Operation Undo and Redo Design

Date: 2026-08-13
Status: Approved for implementation by explicit user request

## Objective

Expose Pengrid's existing identity-safe file-operation reversal through the standard
Edit-menu Command-Z and Command-Shift-Z commands, and add one-session Redo without
weakening preflight, rollback, or operation-queue authority.

## Command routing

During path, filename, filter, search, or other text editing, Command-Z and
Command-Shift-Z are sent to the active responder's `UndoManager`; Pengrid file operations
do not consume them. Outside text editing, the commands target the latest valid file
operation reversal and are enabled only when the operation queue is idle and not blocked
by recovery.

Menu titles name the action, for example `Undo Rename` and `Redo Move`. Existing
per-history Undo buttons remain. The operation center exposes Redo only for the latest
successfully undone action.

## Reversal model

A direction-neutral `FileOperationReversalRecipe` replaces one-way controller assumptions.
Every move entry captures current URL, exact identity, full `SourceFingerprint`, and
destination URL. Created-output reversal captures identity and full fingerprint. Batch
rename and selection-folder recipes retain their transaction plans.

Executing a recipe returns `FileOperationReversalExecution` containing the ordinary
`FileOperationResult` and an optional freshly captured inverse recipe. The inverse exists
only after every outcome succeeds and a complete exact postflight validates the new
state. Failed, skipped, cancelled, or recovery-needed execution never creates an inverse.

## Inverse rules

- Move/rename/Trash reversal moves entries back and produces the swapped move recipe
  using fresh identity and fingerprint at the restored location.
- Copy/duplicate/create/compress/extract reversal moves created outputs to Trash and
  produces a move recipe from actual Trash URLs back to the original published URLs.
- Batch Rename reverse execution returns a fresh plan representing the opposite
  direction after exact identity/fingerprint validation.
- Selection-folder reverse returns a fresh forward recipe only after its transaction
  service validates the restored sources; forward Redo returns a fresh undo plan.
- Replacement operations remain non-Undoable because the controller deliberately marks
  them as destructive replacement today.

Move recipes validate full fingerprints before and after relocation, not identity alone.
Rollback moves are detached from cancellation and require exact identity/fingerprint
matches.

## Controller stacks and invalidation

The controller keeps an ordered process-local Undo stack and a single linear Redo stack,
both tied to operation/history IDs and workspace runtime IDs.

- A normal successful mutation pushes an Undo entry and clears the Redo branch.
- Undo/Redo entries are consumed only after their exclusive operation is successfully
  enqueued.
- Successful Undo pushes its fresh inverse to Redo; successful Redo pushes its fresh
  inverse to Undo.
- Failure/cancellation leaves no opposite entry; Recovery Needed blocks the queue.
- Starting a normal mutation invalidates every overlapping Undo and Redo entry using
  existing directory-key overlap rules and clears Redo even when non-overlapping.
- External changes may remain unobserved, but execution always fails closed during
  preflight.
- Closing a workspace tab invalidates entries tied to that tab.
- Nothing is persisted across launches.

## Job and history presentation

Undo and Redo are explicit job kinds with progress and accessibility labels. Reversal
jobs are exclusive, non-retryable, and never recursively show an Undo button on their
own history row. The original history row's eligibility updates as the recipe moves
between stacks.

## Excluded

- Persistent/cross-launch Undo journals.
- Undo of conflict replacements or synchronization transactions.
- Arbitrary branching history after a new forward operation.
- Reversing external filesystem changes not initiated by Pengrid.

## Verification

Service tests cover fresh inverse recipes for move, Trash, created output, batch rename,
and selection folders; fingerprint drift, occupied paths, cancellation, rollback, and
recovery failure. Controller tests cover LIFO order, enqueue failure, Undo→Redo→Undo,
forward branch clearing, overlap invalidation, workspace binding, recovery gating, and
history presentation. Command tests cover exact shortcuts, dynamic titles, responder
routing, and idle gating. The full suite, release build, bundle verification, and manual
Finder/VoiceOver checks remain final gates.
