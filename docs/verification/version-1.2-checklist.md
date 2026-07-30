# Pengrid version 1.2 verification checklist

Verification record opened: 2026-07-30 (Asia/Seoul)

`PASS`, `FAIL`, and `NOT RUN` are the only status values used below. Automated
fixtures do not count as physical macOS, File Provider, Quick Look, VoiceOver,
keyboard-focus, or appearance evidence.

## Automated evidence

- [x] **PASS — 2026-07-30:** The exact serial full Swift test suite passed 588
  tests in 45 suites with zero failures in 35.825 seconds.
- [x] **PASS — 2026-07-30:** `./script/build_and_run.sh --verify` exited zero
  from the same worktree state and confirmed the launched `BloomFileManager`
  process. The staged development executable is a Mach-O arm64 binary and its
  `Info.plist` passes `plutil -lint`.
- [x] **PASS — 2026-07-30:** The 10,000-item filter regression test passed in
  0.088 seconds across five queries. The five-second value is a CI regression
  ceiling, not a user-operation latency promise.
- [x] **PASS — 2026-07-30 (durable timing-flake note):** One transient
  comparison-coordinator assertion failed, passed in focused isolation, and
  the following complete serial rerun passed. The release gate remains PASS;
  no flake fix is claimed.

## Filter and keyboard

- [ ] **NOT RUN:** Command-F opens the active pane's filter and does not affect
  the other pane.
- [ ] **NOT RUN:** Escape restores the prior selection when that item still
  exists.
- [ ] **NOT RUN:** Korean, English, case, and accent matching behave as
  documented.
- [ ] **NOT RUN:** Filtering a File Provider listing causes no download request.

## Navigation and restoration

- [ ] **NOT RUN:** Back and Forward remain independent in both panes.
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
- [ ] **NOT RUN:** Keyboard focus returns to the table after Escape.
- [ ] **NOT RUN:** Light, dark, increased contrast, and reduced motion remain
  usable.
