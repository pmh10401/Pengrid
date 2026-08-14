# Reviewed folder synchronization verification — 2026-08-13

Status: **IMPLEMENTATION COMPLETE / AUTOMATED GATES RECORDED / MANUAL LOCAL GUI PARTIAL / COMPLETED LOCAL SYNC NOT RUN / SIGNED-IN FILE PROVIDER NOT RUN**

This record applies to the official integration worktree
`/Users/mac/Documents/Pengrid/.worktrees/safe-operation-center` on branch
`codex/safe-operation-center`. It records the integrated implementation and
final verification for Tasks 4–7 of the review-first folder synchronization
plan, including Codex follow-up `bbf6e23`.

The manual local GUI evidence below was collected on 2026-08-14 at official
HEAD `66964e7`. That commit records File Provider discovery only; it does not
change product behavior.

Implementation commits:

| Task | Commit | Message |
| --- | --- | --- |
| 4 | `30030c6` | feat: queue reviewed folder synchronization |
| 5 | `51b6b71` | feat: orchestrate reviewed folder synchronization |
| 6 | `0c1495c` | feat: present folder synchronization review |
| 7 | `f49418a` | docs: document reviewed folder synchronization |
| Follow-up | `bbf6e23` | fix: share synchronization review authority |

Tasks 1–3 were already present as `a71db40`, `4e8b2bb`, and `b698f0f`.

## Automated evidence

### Focused workflow coverage

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FolderSynchronizationIntegrationTests|FolderSynchronizationTransactionServiceTests|FileOperationControllerTests|ComparisonPresentationTests|ComparisonAccessibilityTests|WorkspaceTabPresentationTests|OperationStatusViewTests|FolderSynchronizationPreparationServiceTests|FolderSynchronizationReviewModelTests|AccessibilityPresentationTests|WorkspaceModalPresentationStateTests'
```

Result: **PASS — 239 tests in 11 suites, 0.573 seconds.**

Covered behavior includes:

- exclusive, non-retryable, non-Undoable queue admission with the same
  predicate for `canAdmitFolderSynchronization` and `synchronizeFolder`;
- rejection during termination, an active job, or a queued job without
  invoking the transaction service;
- Recovery Needed engaging the global queue gate;
- all eight `FolderSynchronizationTransactionPhase` values published as
  `.synchronizing` with bounded counts and relative-path-only detail;
- complete-row planning independent of selection and filter;
- planner-blocked and already-synchronized states never calling preparation;
- late preparation discarded after cancel or a newer direction;
- controller admission checked before consuming review authority;
- success reconciling captured roots without requiring the old generation;
- failure touching only the captured workspace and root pair;
- action-bar labels `Sync Left to Right…` / `Sync Right to Left…`;
- review-sheet counts, basenames, at most eight relative paths, destructive
  Trash wording, and no absolute root paths;
- modal exclusivity and tab teardown that dismisses the review without
  cancelling an already admitted job.

Codex follow-up coverage additionally verifies that preparation and execution
share the app-owned cloud security-scope coordinator, transition callbacks
replace MainActor polling, stale callbacks are generation-gated, and captured
workspace context is cleared before enqueue.

### Complete product suite

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --enable-swift-testing --no-parallel
```

Result: **PASS — 1645 tests in 110 suites, 81.194 seconds.**

An earlier Grok worktree run observed a cloud-scoped-access failure that also
reproduced on base `5e518f7`. The final official-worktree run above passed that
test and the complete suite; it is the primary completion evidence.

### Release configuration

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift build -c release
```

Result: **PASS — `Build complete! (44.75s)`.**

SwiftPM emitted the existing warning for 11 ProtectedZIP fixture files that are
consumed by tests but are not declared as target resources. The warning did not
fail the successful release build or full test suite.

### Development app bundle

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
```

Result: **PASS.** `dist/Pengrid.app` was built in **9.57 seconds**, ad-hoc
signed, validated on disk, and satisfied its designated requirement.

### Diff and placeholder scan

```bash
git diff --check
rg -n 'T[B]D|T[O]DO|F[I]XME|implement la[t]er' Sources Tests README.md README.ko.md docs
```

- `git diff --check`: **PASS**, exit 0.
- Placeholder scan: **no implementation markers** in `Sources`, `Tests`,
  `README.md`, or `README.ko.md`. The only matches are quoted historical audit
  commands in older plan/verification documents
  (`docs/superpowers/plans/2026-08-11-file-context-menu-productivity.md`,
  `docs/superpowers/plans/2026-08-11-readme-product-landing.md`,
  `docs/verification/2026-08-11-file-context-actions.md`).

## Independent review

| Review | Status |
| --- | --- |
| Grok 4.6 High, read-only review of `5e518f7..bbf6e23` | **SHIP** — no Critical or Important findings |
| Codex integration review and final automated gates | **PASS** |

Grok ran with OS-level write denial for the official worktree and inspected the
actual integrated branch. Its only non-blocking suggestion was to replace the
stale Grok-worktree SHAs and verification results in this document; this update
does so. Grok did not run tests because the read-only sandbox denied `.build`
writes. Codex independently ran the focused, full, release, and bundle gates
recorded above.

## Manual local GUI matrix

The 2026-08-14 run used disposable pairs under `$TMPDIR`. It dry-reviewed LTR
and RTL plans without confirming them, verified identical and planner-blocked
review states, cancelled one 201-file / 264 MB copy job and one 40-item Trash
job, checked the bound-tab close gate, and checked VoiceOver on the review
sheet. Post-terminal shell inspection found all 201 copy sources with an empty
destination, and both `keep.txt` entries plus all 40 obsolete destination files
after Trash cancellation. No screenshot, AX dump, or operation phase log was
captured, so the narrower status wording below is intentional.

| Check | Status |
| --- | --- |
| Sync Left to Right on a real local-volume pair | **NOT RUN (completed execution)** — dry ready review passed with Copy 1 / Replace 0 / Trash 1 / Skip 1 and relative names, then Cancel |
| Sync Right to Left on a real local-volume pair | **NOT RUN (completed execution)** — dry ready review passed with the reversed direction/counts and relative names, then Cancel |
| Already Synchronized review sheet | **PASS — 2026-08-14** — identical temp pair showed Already Synchronized; confirm disabled |
| Planner/preparation-blocked review sheet | **PASS — 2026-08-14 (planner-blocked symlink only)** — relative symlink path was blocked and confirm disabled; preparation-blocked was not separately run |
| Cancel during copy/staging | **PASS — 2026-08-14** — cancellation accepted during an active temp copy job; after terminal, source files 201 and destination entries 0; exact phase was not captured |
| Cancel during Trash transfer | **PASS — 2026-08-14** — cancellation accepted during the Trash phase; both keep files and all 40 obsolete files remained |
| Recovery Needed acknowledgement | NOT RUN |
| VoiceOver relative-path output | **PASS — 2026-08-14 (review sheet only)** — direction, counts, and relative names were spoken; no absolute path; operation progress was not spoken-checked |
| Tab close gating while a sync job is active | **PASS — 2026-08-14** — bound tab close was disabled during the job and re-enabled after cancellation became terminal |

## Signed-in File Provider matrix

Host discovery on 2026-08-13 found redacted Google Drive and OneDrive roots
under `~/Library/CloudStorage`. Both roots exposed a
`com.apple.file-provider-domain-id` attribute. This read-only metadata check
proves that File Provider domains are registered on this Mac; it does not prove
that Pengrid can review or execute synchronization against their contents.
No provider child was opened, previewed, hashed, compared, or materialized.

| Check | Status |
| --- | --- |
| Signed-in OneDrive review/execution | NOT RUN |
| Signed-in Google Drive review/execution | NOT RUN |
| Unavailable File Provider item reported without materialization | NOT RUN |

Automated tests prove the review and transaction do not introduce File Provider
materialization APIs. They do not replace signed-in provider execution.

## Safety properties recorded by automation

- Full comparison rows are planned; selection and `visibleRows` are not used.
- Controller admission is checked before `FolderSynchronizationReviewModel.confirm()`.
- `canAdmitFolderSynchronization` and enqueue share the same MainActor predicate.
- The job is exclusive, non-retryable, and not Undoable.
- Progress, review UI, and accessibility expose relative paths or basenames,
  never captured absolute roots.
- Success restarts the captured workspace/root pair without requiring the old
  generation.
- Failure/cancel does not overwrite another workspace or a newer root pair.
- Tab teardown dismisses the review and does not cancel an admitted job.
- Trash semantics remain the only user-data removal path; Recovery Needed still
  blocks the queue.
