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
- changed regular file, symbolic link, or package of the same kind: replace destination;
- destination-only supported entry: move destination to Trash;
- identical entry: no action;
- same-kind directory containers: no direct replacement; descendants carry changes.

Top-level directory copy and directory Trash actions suppress descendant actions already
covered by the tree operation. Special entries, type/name conflicts, errors, unstable or
checking rows, missing sides for a changed status, and unsafe ancestor layouts block the
entire plan. An empty plan is visible as Already Synchronized and cannot execute.

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

1. Acquire scoped access and revalidate roots and the whole plan.
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

The review sheet shows direction, root basenames, counts for copy/replace/Trash/skip,
estimated copy size, and an ordered path list. Trash actions use explicit destructive
wording and are never preselected independently—the plan is all-or-nothing. Confirm is
disabled for stale, blocked, empty, or non-writable destination state.

Accessibility labels expose direction and counts without announcing full root paths.
Individual review rows intentionally expose relative paths.

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
Recovery Needed. Controller/UI tests prove no mutation before confirmation, exclusive
queueing, stale-plan rejection, progress, reconciliation, and no Undo exposure. Full
suite, release build, bundle verification, and live local-volume smoke testing are final
gates; File Provider execution remains explicitly NOT RUN until signed-in verification.
