# Pengrid version 1.2 verification checklist

Verification record opened: 2026-07-30 (Asia/Seoul)

`PASS`, `FAIL`, and `NOT RUN` are the only status values used below. Automated
fixtures do not count as physical macOS, File Provider, Quick Look, VoiceOver,
keyboard-focus, or appearance evidence.

## Automated evidence

- [x] **PASS — 2026-07-30:** The exact serial full Swift test suite passed 589
  tests in 45 suites with zero failures in 36.663 seconds.
- [x] **PASS — 2026-07-30:** `./script/build_and_run.sh --verify` exited zero
  from the same worktree state and confirmed the launched `BloomFileManager`
  process. The staged development executable is a Mach-O arm64 binary and its
  `Info.plist` passes `plutil -lint`.
- [x] **PASS — 2026-07-30:** The 10,000-item filter regression test passed in
  0.088 seconds across five queries. The five-second value is a CI regression
  ceiling, not a user-operation latency promise.
- [x] **PASS — 2026-07-30 (timing regression stabilized):** The comparison
  test now waits for the new fingerprint before completing stale checksum
  requests and accepts legitimate progress on the replacement verification.
  Twenty focused repetitions and the following complete serial run passed.

## Filter and keyboard

- [x] **PASS — 2026-07-30:** Command-F opened only the active pane's filter in
  both left- and right-pane manual UI checks. Activating the right pane first
  produced the pane-specific `rightPane.filter` control.
- [x] **PASS — 2026-07-30:** Escape closed the populated left-pane filter and
  restored the previously selected `Chrome Apps.localized` row.
- [ ] **NOT RUN:** Korean, English, case, and accent matching behave as
  documented.
- [ ] **NOT RUN:** Filtering a File Provider listing causes no download request.

## Navigation and restoration

- [x] **PASS — 2026-07-30:** Back and Forward restored OneDrive and Documents
  in the right pane and Applications and Home in the left pane; each inactive
  pane kept its location during the other pane's navigation.
- [ ] **NOT RUN:** Returning near the top, middle, and end of a large folder
  restores position.
- [ ] **NOT RUN:** Deleted selections, anchors, and history destinations recover
  without a crash.

## Quick Look

- [ ] **NOT RUN:** An open panel follows local-file selection.
- [ ] **NOT RUN:** An online-only item uses the existing materialization gate.
- [ ] **NOT RUN:** Empty, deleted, offline, and superseded selections do not
  show stale content.

## Accessibility and appearance

- [ ] **NOT RUN:** VoiceOver announces filter labels, result count, and restored
  selection.
- [x] **PASS — 2026-07-30:** After filtering the left pane with `.DS`, Escape
  restored the prior selection and Arrow Down moved the selected table row,
  confirming that keyboard focus returned to the table.
- [ ] **NOT RUN:** Light, dark, increased contrast, and reduced motion remain
  usable.
