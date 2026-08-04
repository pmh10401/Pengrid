# Integrated Smart Search verification record

Verification run: 2026-08-04 (Asia/Seoul), working tree candidate
`b84f179` and its integrated-smart-search ancestors. Commands used the full
Xcode developer directory because the selected Command Line Tools installation
cannot import Swift Testing.

Automated coverage is evidence for the modeled behavior only. It does not
replace the physical macOS, File Provider, keyboard, or VoiceOver checks below.

## Automated evidence

- [x] **PASS — focused pane filter:**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift test --filter PaneFilenameFilterTests
  ```

  Passed **3 tests in 1 suite** in **0.003 seconds**. Coverage confirms the
  active-listing projection keeps order and handles localized Korean substring
  matching without a recursive listing.

- [x] **PASS — focused Smart Search:**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift test --filter SmartSearch
  ```

  Passed **89 tests in 5 suites** in **1.307 seconds**. Coverage includes
  Korean initials and mixed clauses, bounded enumeration and cancellation,
  metadata bounds, saved-search persistence, metadata-only cloud search,
  identity capture/revalidation, safe Quick Look and opposite-pane actions,
  mutation handoff, progress, and accessibility state.

- [x] **PASS — focused safe-operation regressions:**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift test --filter FileOperationControllerTests
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift test --filter FileTransferTests
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift test --filter CloudOperationGateTests
  ```

  The commands exited 0: **50 tests in 1 suite** (0.060 seconds), **33 tests
  in 1 suite** (0.005 seconds), and **16 tests in 1 suite** (0.004 seconds).
  The FileTransfer run reports its intentionally cancelled cleanup-path test as
  cancelled while the suite itself passes; it is not a failure. These suites
  cover queued mutation safety, identity-aware copy/move/Trash, operation
  progress and cancellation, and cloud materialization gates.

- [x] **PASS — full serial suite and release build:**

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift test --no-parallel
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift build -c release
  ```

  The serial test run passed **803 tests in 60 suites** in **38.518 seconds**.
  The production build completed in **38.45 seconds**. The captured outputs
  contain no compiler `warning:` or `error:` lines; no new warnings were
  observed.

## Manual verification

- [ ] **NOT RUN — active-pane Command-F:** Focus each pane in turn, press
  **Command-F**, and confirm it filters only that pane's existing visible
  listing without starting a recursive listing or changing the other pane.

- [ ] **NOT RUN — Smart Search text and filters:** Press
  **Command-Shift-F**. Search local names and relative paths with `ㅍㄱ`,
  `파일`, and `ㅍㄱ report`; verify mixed clauses use AND semantics. Check file,
  folder, extension, size, and modification-date filters at both inclusive
  boundaries. Save, reopen, rename, and delete a saved search.

- [ ] **NOT RUN — Google Drive metadata-only search:** In a Google Drive File
  Provider root, search an online-only item. Confirm its provider metadata can
  appear when macOS exposes it and that Smart Search does not download the
  content.

- [ ] **NOT RUN — OneDrive metadata-only search:** Repeat the provider check
  with an online-only OneDrive item. Confirm Smart Search does not download the
  content.

- [ ] **NOT RUN — identity-safe result actions:** Search a disposable local
  item, replace it after it appears, then try Quick Look, Copy to Other Pane,
  Move to Other Pane, and Move to Trash. Each action must refuse the replacement
  with **“Item changed. Search again.”** rather than operating on the new item.

- [ ] **NOT RUN — operation-center handoff:** Submit copy, move, and Trash for
  unchanged search results. Confirm each appears in the operation center, shows
  progress, and can be cancelled according to its normal safe checkpoint rules.

- [ ] **NOT RUN — VoiceOver:** With VoiceOver enabled, verify query and filter
  controls, result-table columns and selection, progress, and errors are read
  without disclosing absolute paths.

## Release gate

Do not represent Smart Search provider behavior, keyboard interaction, or
VoiceOver behavior as physically verified until every manual item above has a
dated PASS or FAIL result against the exact release candidate. Google Drive and
OneDrive checks require real File Provider roots and online-only fixtures; they
were not available in this automated run.
