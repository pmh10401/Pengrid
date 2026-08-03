# Safe file operation center verification checklist

Verification record opened: 2026-08-03 (Asia/Seoul)

Use only `PASS`, `FAIL`, or `NOT RUN` for manual checks. Automated coverage and
the accessibility tree do not replace physical-volume, File Provider, keyboard,
or VoiceOver checks against a release candidate.

## Automated evidence

- [x] **PASS — 2026-08-03 — queue and presentation:** Automated tests cover
  default-FIFO single-worker execution, queued reordering and cancellation,
  exactly-once cancellation callbacks, acknowledged cooperative pause/resume,
  cleanup-before-dequeue, recovery blocking, exclusive non-retryable cleanup
  and Undo, 100-entry session history, safe details, stable accessibility
  identifiers, and omission of absolute paths from operation-center
  presentation.

- [x] **PASS — 2026-08-03 — captured authority and conservative undo:** Tests
  replace queued transfer and Trash sources plus transfer and archive
  destination roots and confirm mutations fail closed. Move, rename, Trash
  restore, created-output quarantine, recursive no-follow fingerprint
  verification, exclusive collision refusal, cancellation rollback, ancestor
  invalidation, replacement conflict, and failed-undo behavior are covered. A
  partially successful multi-item intent is not retryable as a whole.

- [x] **PASS — 2026-08-03 — archive progress:** Tests cover ordered exact
  preparation transitions, indeterminate native encoding, source and
  destination-parent identity checks, descriptor-anchored exclusive
  publication, identity-owned bounded parallel staging, cancellation cleanup,
  preservation of unowned partial output for recovery review, phase-aware
  labels, and basename-only status copy.

- [x] **PASS — 2026-08-03 — full automated suite:** Full Xcode Swift Testing
  completed **700 tests in 55 suites with zero failures** after the independent
  review fixes. A release build and `script/build_and_run.sh --verify` had also
  completed successfully at the pre-review baseline; both are rerun at the
  final gate below.

## App smoke evidence

- [x] **PASS — 2026-08-03 — local new-folder history:** In the built Pengrid
  app, a disposable local folder was opened and **File > New Folder** completed.
  The status row reported one success. The operation-center button announced
  zero active, zero queued, and one recent operation. Its popover showed
  **Recent**, **Create Folder**, **Completed**, the basename **New Folder**, and
  an **Undo Create Folder** action with the help text “Undo only if the files
  are still unchanged.” The popover had no visible clipping or overlap. Undo
  was intentionally not activated. The disposable fixture was removed after
  the check.

- [x] **PASS — 2026-08-03 — accessibility tree:** The operation-center control,
  recent-history section, job row, and Undo action were discoverable with
  stable identifiers and explicit descriptions/help. No absolute path appeared
  in the operation row or action label. Actual VoiceOver speech was not tested
  in this smoke pass.

## Manual release-candidate verification

- [ ] **NOT RUN — keyboard and VoiceOver:** With Full Keyboard Access and
  VoiceOver enabled, queue at least two disposable local operations. Reach the
  operation center without a pointing device, traverse Active, Queue, and
  Recent in visual order, and invoke Pause/Resume and queued Cancel. Confirm
  focus is visible, each state and action is spoken once, and no absolute path
  or provider metadata is announced.

- [ ] **NOT RUN — active cancellation cleanup:** Copy or compress a large local
  fixture, cancel during a cooperative phase, and confirm either all owned
  temporary output is cleaned before the next queued job begins, or unverified
  residue is preserved without deletion and the queue stops for recovery
  review. Confirm no partial public destination appears.

- [ ] **NOT RUN — pause limitation:** Pause during multi-item preparation and
  confirm progress stops at the next item boundary. Pause again after native
  archive encoding begins and confirm the UI explains the paused request without
  suspending the already-running native process.

- [ ] **NOT RUN — conservative undo refusal:** Complete a disposable copy,
  modify its output, and invoke Undo; confirm Pengrid refuses without removing
  the modified copy. Repeat for an occupied move/rename/Trash restore location.

- [ ] **NOT RUN — File Provider identity:** Queue disposable Google Drive and
  OneDrive operations behind a long local job, then replace or move the queued
  source from the provider before execution. Confirm the queued job fails closed
  and does not operate on the replacement. Restore or remove only test data.

- [ ] **NOT RUN — physical-volume interruption:** Queue operations to a
  disposable external volume, disconnect it between capture and execution, and
  confirm failure/cancellation does not mutate another subsequently mounted
  volume or leave a misleading retry/undo action.

## Release gate

- [ ] **NOT RUN:** Record dated `PASS`/`FAIL` evidence for every manual item
  above against the exact release candidate. Until then, this feature remains
  suitable for the developer preview rather than a fully validated signed
  release.
