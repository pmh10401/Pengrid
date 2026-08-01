# Smart Search verification checklist

Verification record opened: 2026-08-01 (Asia/Seoul)

Use only `PASS`, `FAIL`, or `NOT RUN` for each item. Automated local-fixture
coverage does not replace the physical macOS, File Provider, keyboard, and
VoiceOver checks below.

## Automated evidence

- [x] **PASS — serial Swift Testing (2026-08-01):** The final-fix candidate
  completed 687 tests in 55 suites with zero failures:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
  ```

  The suite must cover recursive filename/path matching; ranking and the
  500-result default cap; invalid and duplicate roots; default exclusion and
  explicit inclusion of hidden items and packages; exclusion of symbolic-link
  entries and descendants;
  optional folder results; cancellation; unreadable-entry tolerance; saved
  search persistence; and cloud-only availability without materialization.

- [x] **PASS — release and static contracts (2026-08-01):** The package release
  contract script reported `PASS`, the arm64 release build completed, and both
  working-tree and branch diff checks reported no whitespace errors:

  ```bash
  ./script/tests/package_release_contract_tests.sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build -c release --arch arm64
  git diff main...HEAD --check
  ```

## Manual verification

- [ ] **NOT RUN — command and scope:** In an active pane, use **Edit > Search
  Files…** and **Command-Shift-F**. Confirm Smart Search opens with keyboard
  focus in its query field and names the active pane's current directory as
  its only initial root. Change the active pane and repeat; confirm the root
  changes accordingly. Confirm Command-F remains the pane-local filename
  filter rather than opening Smart Search.

- [ ] **NOT RUN — local recursive filenames and folders:** In a disposable
  local root, create matching files and folders at multiple depths, including
  names with spaces and diacritics. Confirm Smart Search finds matching names
  and relative paths recursively, ranks exact filename matches ahead of
  path-only matches, and does not report file-content-only matches.

- [ ] **NOT RUN — result bound and cancellation:** With the default cap, create
  more than 500 matching local entries. Confirm the displayed result list
  contains no more than 500 ranked results. Change the cap and confirm it
  remains within 1...2,000. Start a sufficiently large search, select
  **Cancel**, and confirm the search changes to cancelled without navigating
  or modifying any searched item.

- [ ] **NOT RUN — inclusion and traversal boundaries:** In a disposable local
  root, create a hidden directory, a package, and a symbolic link to a
  directory outside the root. Confirm hidden and package descendants are
  absent by default and appear only after enabling their respective options.
  Confirm the symbolic-link entry itself and its target descendants never
  appear, even when the inclusion options are enabled. Confirm the **Include
  folders** option
  controls folder results.

- [ ] **NOT RUN — unreadable entries:** Include an entry the current user
  cannot read alongside an accessible matching file. Confirm the accessible
  match remains searchable and the search does not fail solely because of the
  unreadable entry. Restore permissions or remove the disposable fixture.

- [ ] **NOT RUN — saved searches:** Save a query with a distinct name, quit and
  reopen Pengrid, then select it from **Places > Smart Searches**. Confirm its
  text, explicit roots, inclusion options, and a non-default result cap are
  restored and it runs again. Delete the saved search and confirm it is removed
  after relaunch.

- [ ] **NOT RUN — cloud-only behavior:** In a Google Drive or OneDrive File
  Provider folder shown by Pengrid, select an online-only item that has not
  been downloaded and search from that folder. Confirm a matching result can
  report its cloud-only availability, and observe that searching itself does
  not download or materialize the item. Smart Search must not perform remote
  provider search or request Google or Microsoft credentials.

- [ ] **NOT RUN — accessibility:** With VoiceOver and Full Keyboard Access
  enabled, open Smart Search with Command-Shift-F, enter a query, change every
  inclusion option, run and cancel a search, open a result, save a search, and
  remove it from the Places rail. Confirm controls, root summary, availability,
  progress, results, and saved-search actions have understandable labels.

## Release gate

- [ ] **NOT RUN:** Record dated `PASS` or `FAIL` evidence for every automated
  and manual item above against the exact candidate commit before describing
  Smart Search as release-ready. Smart Search remains a local filename/path
  feature: do not describe it as content search, remote search, or an automatic
  cloud-download feature.
