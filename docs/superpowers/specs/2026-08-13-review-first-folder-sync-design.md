# Review-First One-Way Folder Synchronization Design

Date: 2026-08-13
Status: Approved for implementation by explicit user request

## Objective

Turn an up-to-date directory comparison into an immutable, reviewable one-way
synchronization plan and execute it as one transactional exclusive operation. The MVP
has no scheduling, watching, or background synchronization.

## Planning

The user chooses Left to Right or Right to Left. Planning requires a captured
`ComparisonSession` whose phase is exactly `upToDate`. It maps the complete comparison
scope into ordered actions:

- source-only supported entry: copy to the destination;
- changed regular file of the same kind: replace destination;
- destination-only supported entry: move destination to Trash;
- identical entry: no action;
- same-kind directory containers: no direct replacement; descendants carry changes.

Top-level directory copy and directory Trash actions suppress descendant actions already
covered by the tree operation. Symbolic links, packages, special entries, type/name conflicts, errors, unstable or
checking rows, missing sides for a changed status, and unsafe ancestor layouts block the
entire plan. An empty plan is visible as Already Synchronized and cannot execute.

The pure planner can reject equal root identities and lexically equal or nested normalized
paths, but it performs no filesystem resolution. Canonical, alias-, mount-, and
symbolic-link-mediated ancestry is therefore a mandatory preparation check before a plan
may be shown as confirmable or reach mutation code.

## Prepared authority

The review plan captures both root URLs and exact identities, comparison generation,
direction, ordered relative paths, expected destination presence/absence, full
`SourceFingerprint` values for every source and every destination to be replaced or
trashed, and destination filename-policy evidence. It also captures estimated copy bytes
when available.

The review is immutable. Any comparison regeneration, monitor event, root change,
fingerprint drift, identity drift, or newly occupied planned absence invalidates it.
Confirmation performs one global preflight before the first visible mutation and a
second identity/fingerprint check at each publication boundary.

## Transaction

`FolderSynchronizationTransactionService` is the sole mutation and rollback authority:

1. Acquire scoped access, resolve no-follow canonical root ancestry, and reject equal or
   nested roots (including alias-, mount-, and symbolic-link-mediated relationships) before
   revalidating the whole plan.
2. Reserve transaction-owned staging names and stage every source copy.
3. Verify every staged payload against the captured source fingerprint.
4. Quarantine every existing replacement/deletion by exact identity.
5. Publish all staged outputs under exact parent identity.
6. Revalidate published identities and fingerprints.
7. Commit quarantined user entries to Trash.
8. Return a complete result and request comparison reconciliation.

The transaction tracks owned staging entries, created parents, quarantines, published
output identities, and committed Trash URLs. Cancellation or failure before terminal
success removes only transaction-owned data and restores pre-existing items with exact
identity/fingerprint checks. If restoration cannot be proved, outcomes are
`recoveryNeeded` and the global operation queue remains blocked for acknowledgement.
Pre-existing data is never permanently deleted.

The MVP synchronization result is not post-completion Undoable. Its safety property is
atomic in-flight rollback, not a potentially misleading inverse for a multi-replacement
mirror operation.

## Review UI

The comparison action bar offers `Sync Left to Right…` and `Sync Right to Left…` for the
complete comparison scope. These actions never depend on table selection. Planning is
admitted only from the exact current `ComparisonSession` while the comparison phase is
`upToDate`.

The same review sheet represents planner-blocked, already-synchronized, preparing,
preparation-blocked, and ready states. Planner blockers and Already Synchronized do not
invoke preparation. A ready review shows direction, root basenames, counts for
copy/replace/Trash/skip, estimated copy size, and at most eight ordered representative
relative paths. Trash actions use explicit destructive wording and are never selected
independently—the plan is all-or-nothing. Confirm is disabled for stale, blocked, empty,
or non-writable destination state.

Accessibility labels expose direction and counts without announcing full root paths.
Individual review rows intentionally expose relative paths.

## Queue admission and lifecycle

Synchronization is one exclusive `FileOperationController` job bound to the captured
`WorkspaceState` and both captured roots. Before consuming the prepared plan, the UI
checks the controller's authoritative exclusive-operation, Recovery Needed, and
termination-preparation admission gates. Only an admissible request calls
`FolderSynchronizationReviewModel.confirm()` and transfers its exact immutable authority
once. A rejected admission leaves the ready review intact.

The job is explicitly non-retryable and non-Undoable. Retrying a captured plan would
reuse stale identity/fingerprint authority; Undo requires a separate post-completion
inverse design for replacement and Trash actions. Cancellation and Recovery Needed use
the existing queue and acknowledgement behavior.

The review sheet participates in `WorkspaceModalPresentationState` exclusivity and the
workspace tab modal policy. Switching or closing a tab dismisses the review and cancels
only preparation; it never cancels an already admitted job. Because the running or
queued job is bound to its exact workspace, the existing tab close gate refuses to close
that workspace until the operation becomes terminal.

Every `FolderSynchronizationTransactionPhase` maps to a stable operation-center stage,
bounded item counts, and privacy-safe detail. After complete success, both captured
comparison roots are explicitly reconciled even when their monitor events have advanced
the comparison generation. After failure or cancellation, comparison invalidation and
restart occur only when the captured workspace and roots are still active; a newer
comparison session or another workspace is never overwritten.

## Excluded

- Bidirectional conflict resolution.
- Scheduled/background/continuous synchronization.
- Permanent deletion or mirror deletion outside Trash.
- Partial action selection in the first version.
- Post-success Undo.
- Sync of special filesystem entries.

## Verification

Pure planner tests cover every status, direction, tree coalescing, deterministic order,
and blockers. Preparation tests cover exact fingerprints, capacity, roots, and absences.
Transaction tests inject failure/cancellation at every phase and prove rollback or
Recovery Needed. Controller/UI tests prove admission before confirmation, rejected
admission preserving the ready review, late preparation rejection, modal and tab
teardown, exclusive non-retryable queueing, stale-plan rejection, every progress phase,
success reconciliation, captured-session-only failure/cancellation refresh, and no Undo
exposure. Full
suite, release build, bundle verification, and live local-volume smoke testing are final
gates; File Provider execution remains explicitly NOT RUN until signed-in verification.
