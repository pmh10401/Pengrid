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
  invalidation, replacement conflict, and failed-undo behavior are covered.
  Created-output Undo identity and recursive fingerprint authority now come
  from the mutation's own result rather than a later controller lookup;
  immediate replacement and in-place edit races are rejected. A partially
  successful multi-item intent is not retryable as a whole.

- [x] **PASS — 2026-08-03 — archive progress:** Tests cover ordered exact
  preparation transitions, indeterminate native encoding, source and
  destination-parent identity checks, descriptor-anchored exclusive
  publication, pre-created identity-owned output with descriptor-bound native
  writes, identity-owned bounded parallel staging and partial-output cleanup,
  preservation of unowned replacements for recovery review, phase-aware
  labels, basename-only status copy, and a ten-hertz limit for intermediate
  preparation updates while retaining and deduplicating start and completion
  boundaries.

- [x] **PASS — 2026-08-03 — final-review regression set:** The current source
  passed 152 focused tests in seven suites covering the operation controller,
  archive service and live archive integration, transfer and mutation services,
  undo service, mutation-owned archive authority and fingerprints, throttled
  archive publication, and selection changes during Trash identity capture.
  Cross-volume move cancellation after public destination commit now requires
  recovery review and halts normal queue advancement.

- [x] **PASS — 2026-08-03 — prior full-suite baseline:** Full Xcode Swift
  Testing completed **704 tests in 55 suites with zero failures** before the
  latest final-review hardening. The release build and
  `script/build_and_run.sh --verify` also completed successfully at that
  baseline. A current full-suite rerun remains required below.

- [x] **PASS — 2026-08-03 — mechanical accessibility wiring:** Luna Max
  independently confirmed all four queue/details/recovery accessibility
  identifier connections with no omissions; the seven focused accessibility
  presentation tests passed. This does not replace the manual VoiceOver gate.

- [x] **PASS — 2026-08-03 — final-review UI mechanics:** Luna Max reran 13
  focused tests and confirmed phase-aware archive presentation, stable combined
  accessibility labels and identifiers, ten-hertz intermediate preparation
  publication, unthrottled phase boundaries, and stale Trash-selection refusal.
  No GUI-launch claim was made while LaunchServices remained unavailable.

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

- [ ] **FAIL — current full-suite completion is host-blocked:** Two serial full
  runs reached the unrelated long-lived-monitor coverage, where FSEvents could
  not start, then the AppKit panel helper reported invalid XPC connections and
  the run ended without a complete suite summary. The focused 152-test
  operation set remains green; the current macOS user session must be restored
  before this full-suite gate can be closed.

- [x] **PASS — 2026-08-03 — current release compile:** Full Xcode completed the
  production build successfully after the final-review hardening.

- [ ] **FAIL — bundle launch verification is host-blocked:**
  `script/build_and_run.sh --verify` rebuilt `dist/Pengrid.app`, but
  LaunchServices returned `kLSNoExecutableErr`. Direct inspection confirms the
  declared `BloomFileManager` executable exists, is executable, and is an arm64
  Mach-O; this matches the wider LaunchServices/XPC service failure in the
  current user session.

- [ ] **NOT RUN:** Record dated `PASS`/`FAIL` evidence for every manual item
  above against the exact release candidate. Until then, this feature remains
  suitable for the developer preview rather than a fully validated signed
  release.
