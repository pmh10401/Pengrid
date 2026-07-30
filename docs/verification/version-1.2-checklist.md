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
- [x] **PASS — 2026-07-30:** A physical four-file fixture matched
  `AlphaFile.txt` from `ALPHAFILE` and `café-notes.txt` from `cafe`, confirming
  English, case-insensitive, and accent-insensitive matching in the app UI.
- [x] **PASS — 2026-07-30:** Copying composed Korean `여행` through a native
  macOS text field into the physical app filter returned only `여행계획.txt`.
- [x] **PASS — 2026-07-30:** Filtering a physical OneDrive File Provider folder
  for `docx` returned three rows while its online-only `dataless` file count
  remained 8 before and after filtering.

## Navigation and restoration

- [x] **PASS — 2026-07-30:** Back and Forward restored OneDrive and Documents
  in the right pane and Applications and Home in the left pane; each inactive
  pane kept its location during the other pane's navigation.
- [x] **PASS — 2026-07-30:** Returning to a physical 100-file folder restored
  its vertical scroll position near the end (`0.996` to `0.996`), middle
  (`0.500` to `0.501`), and top (`0` to `0`).
- [x] **PASS — 2026-07-30:** Removing the selected first-visible fixture file
  cleared the stale selection and anchor without a crash. Removing a recorded
  history destination kept the pane in its current folder and showed a
  recoverable “no such file” error.

## Quick Look

- [x] **PASS — 2026-07-30:** A physical Quick Look panel initially showed
  `café-notes.txt`; changing the live table selection to `여행계획.txt` updated
  the same panel to the new filename without reopening it.
- [x] **PASS — 2026-07-30:** Quick Look on a physical OneDrive online-only item
  materialized the selected file: its `dataless` flag cleared and the parent
  folder's online-only count changed from 8 to 7 before presentation.
- [x] **PASS — 2026-07-30:** Navigating the pane to an empty physical folder
  closed its live Quick Look session. Deleting a separately previewed fixture
  file also closed the panel immediately and cleared the table selection.
- [ ] **NOT RUN:** Physical offline-provider and superseded-materialization race
  cases do not show stale content. Their automated operation-gate regressions
  pass, but no separate physical provider race was induced.

## Accessibility and appearance

- [ ] **NOT RUN:** With VoiceOver enabled, the filter exposed its pane label and
  result count through the macOS accessibility tree, but spoken announcement
  output and restored-selection speech were not captured. VoiceOver was
  returned to its original off state.
- [x] **PASS — 2026-07-30:** After filtering the left pane with `.DS`, Escape
  restored the prior selection and Arrow Down moved the selected table row,
  confirming that keyboard focus returned to the table.
- [x] **PASS — 2026-07-30:** The physical app remained readable and operable in
  both macOS light and dark appearances; the original dark appearance was
  restored after verification.
- [ ] **NOT RUN:** Increased contrast and reduced motion remain usable. The
  macOS accessibility-settings extension repeatedly closed the UI automation
  connection before either setting could be safely toggled and restored.
