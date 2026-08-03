# Smart Search verification checklist

Verification record opened: 2026-08-03 (Asia/Seoul)

Use only `PASS`, `FAIL`, or `NOT RUN` for each item. Automated local-fixture
coverage does not replace the physical macOS, File Provider, keyboard, and
VoiceOver checks below.

## Automated evidence

- [x] **PASS — focused Swift Testing (2026-08-03):** The Korean-initial-search
  candidate completed 55 tests in five independently selected suites with zero
  failures: analyzer 12, ranking/model 18, service 16, Store 8, and presentation
  guidance 1.

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --no-parallel --filter SmartSearchTextAnalyzerTests
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --no-parallel --filter SmartSearchModelTests
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --no-parallel --filter SmartSearchServiceTests
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --no-parallel --filter SmartSearchStoreTests
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --no-parallel \
      --filter searchGuidanceExplainsAutomaticKoreanInitialMatching
  ```

  These suites cover compatibility-jamo and modern-choseong equivalence;
  NFC/NFD filenames; all 19 modern initials; mixed literal-and-initial AND
  queries; deterministic evidence-based ranking; linear analysis work;
  recursive filename/path matching; cancellation; saved-search state; and
  cloud-only availability without materialization. A ranking mutation that
  reversed evidence order made
  `weakestInitialClauseWinsBeforeOneExcellentClause` fail, and the test passed
  again after restoring the production comparator.

- [ ] **FAIL — full serial Swift Testing (2026-08-03):** The unfiltered run is
  not a release gate on this host. It recorded failures outside Smart Search
  before an AppKit `NSOpenPanel` XPC helper ended the run. Narrow reproduction
  confirmed `CloudItemAvailabilityTests.directoryListingDoesNotCallTheMaterializer`
  fails because LaunchServices returns `kLSDataUnavailableErr (-10813)` for a
  temporary file's optional kind string; the checksum timestamp fixture also
  remains empty. These host failures are recorded separately and must not be
  described as passing.

- [x] **PASS — release and static contracts (2026-08-03):** The package release
  contract script reported `PASS`, the arm64 release build completed, and both
  working-tree and branch diff checks reported no whitespace errors:

  ```bash
  ./script/tests/package_release_contract_tests.sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build -c release --arch arm64
  git diff --check
  git diff origin/feature/smart-search...HEAD --check
  ```

## Local UI smoke evidence

- [x] **PASS — Korean-initial UI smoke (2026-08-03):** A disposable local
  fixture was opened in both panes, Smart Search was launched with
  Command-Shift-F, and Return submitted each query. `ㅎㄱ` returned the Korean
  filename matches; modern choseong `ᄒᄀ` returned the same rows; `ㄱㄷ`
  returned `구글 드라이브` and its matching descendant without returning the
  unrelated `ㄱㅅㄷ` path; and `ㅎㄱ report` returned only `한국 report.pdf`.

- [x] **PASS — presentation smoke (2026-08-03):** The query placeholder,
  idle Korean example, result count, Korean filenames, relative paths, and
  availability remained readable in dark appearance at wide and narrow window
  sizes and in an isolated light-appearance build. Accessibility inspection
  exposed the stable `smartSearch.query` identifier and the Korean-initial
  help text. The separate VoiceOver, Full Keyboard Access, and live Korean-IME
  checks remain `NOT RUN` below.

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

- [x] **PASS — Korean initial matching through Computer Use (2026-08-03):** A
  disposable local root contained `한국 보고서.pdf`, `한글 노트.txt`,
  `구글 드라이브/계획.txt`, `개인 사진 다운로드/메모.txt`, the explicit
  jamo folder `ㄱㅅㄷ`, and literal English report files. `ㅎㄱ` and modern
  choseong `ᄒᄀ` returned the same three Korean rows. `ㄱㄷ` returned only the
  `구글 드라이브` directory and its path match, excluding `개인 사진
  다운로드`. `ㄱㅅㄷ` ranked the explicit jamo name before derived run-head
  matches. `ㅎㄱ report`, submitted with Return, returned only `한국
  report.pdf`.

- [ ] **NOT RUN — physical Korean IME composition:** Repeat the compatibility-
  jamo queries using the user's installed Korean input source and confirm IME
  composition and Return submission behave identically.

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

- [x] **PASS — accessibility tree and dark layout through Computer Use
  (2026-08-03):** The query field exposed the Korean-initial accessibility hint,
  prompt, value, and stable identifier. The disposable result rows exposed
  filename, relative path, and availability. The dark appearance screenshot at
  the current window size showed the mixed query, controls, one-result heading,
  result row, and saved-search controls without overlap or essential clipping.

- [ ] **NOT RUN — physical accessibility matrix:** With VoiceOver and Full
  Keyboard Access enabled, open Smart Search with Command-Shift-F, enter a
  query, change every
  inclusion option, run and cancel a search, open a result, save a search, and
  remove it from the Places rail. Confirm controls, root summary, availability,
  progress, results, and saved-search actions have understandable labels.
  Confirm the query field announces the Korean-initial hint exactly once. In
  both light and dark appearances, resize the window through narrow and wide
  layouts and confirm the prompt, idle guidance, and result rows remain
  readable without truncating the essential query guidance.

## Release gate

- [ ] **NOT RUN:** Record dated `PASS` or `FAIL` evidence for every automated
  and manual item above against the exact candidate commit before describing
  Smart Search as release-ready. Smart Search remains a local filename/path
  feature: do not describe it as content search, remote search, or an automatic
  cloud-download feature.
