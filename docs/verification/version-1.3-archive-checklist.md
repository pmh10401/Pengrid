# Pengrid version 1.3 ZIP archive verification checklist

Verification record opened: 2026-07-31 (Asia/Seoul)

Use only `PASS`, `FAIL`, or `NOT RUN` for each item. Automated local-process
coverage does not replace the physical macOS, File Provider, keyboard, or
VoiceOver checks below.

## Automated evidence

- [x] **PASS — 2026-07-31:** The exact 1.3.0 (build 4) Developer Preview
  candidate passed the full serial Swift Testing suite (**625 tests in 50
  suites**) and the live `ditto` integration coverage. The unsigned package
  script produced an arm64, ad-hoc-signed Pengrid.app and a verified DMG;
  `codesign --verify --deep --strict` and `hdiutil verify` passed. The DMG
  SHA-256 is
  `690ea180e7d313d424c965d08fd959b00ebd3ba2b7370dd175c9f61bed9d3548`.

  The focused live-`ditto` command is:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --enable-swift-testing --no-parallel \
    --filter ArchiveOperationIntegrationTests
  ```

  The suite creates temporary local files, round-trips spaced and multi-item
  selections with macOS `ditto`, verifies a selected symbolic link remains a
  link, and verifies malformed-ZIP failure cleanup.

## Manual verification

- [ ] **NOT RUN — keyboard and menu discovery:** In an active file pane, select
  a regular file or folder. Open the menu-bar path **File Operations > Compress
  to ZIP**, then repeat with the selected row's contextual menu path
  **Control-click row > Compress to ZIP**. With Full Keyboard Access enabled, use the
  menu bar and arrow keys to reach the same File Operations command; confirm it
  can be invoked without a pointing device. Select a ZIP and repeat both paths
  for **Extract ZIP**.

- [ ] **NOT RUN — non-ZIP extraction disabled:** Select only a local `.txt`
  file. Confirm **File Operations > Extract ZIP** and **Control-click row >
  Extract ZIP** are disabled. Select a directory and a mixed ZIP/non-ZIP
  selection and confirm extraction remains disabled in both locations.

- [ ] **NOT RUN — collision behavior:** In one local test folder, create
  `Notes.txt`, then create `Notes.txt.zip` before selecting `Notes.txt` and
  choosing **File Operations > Compress to ZIP**. Confirm the existing archive
  remains unchanged and the new archive is named `Notes.txt 2.zip`. Extract a
  ZIP whose proposed destination directory already exists and confirm the
  existing directory remains unchanged while Pengrid uses the next available
  name (for example, `Notes 2`).

- [ ] **NOT RUN — cancellation cleanup:** In a local test folder, select a
  sufficiently large folder, choose **File Operations > Compress to ZIP**, and
  activate the status row's **Cancel** control while it is running. Confirm no
  final ZIP appears. In Terminal, change to the selected destination's parent,
  then run `find "$PWD" -maxdepth 1 -name '.bloom-staging-*'`; it must print no
  paths. Repeat during extraction of a sufficiently large local ZIP;
  confirm no partial extraction directory and no staging path remain.

- [ ] **NOT RUN — VoiceOver labels:** Enable VoiceOver, start compression and
  extraction of a large local fixture, then move VoiceOver focus to the archive
  status row and Cancel button. Confirm the labels announce **Compressing ZIP
  archive** or **Extracting ZIP archive**, the current item, and respectively
  **Cancel ZIP compression** or **Cancel ZIP extraction**.

- [ ] **NOT RUN — local ZIP round trip:** In a local test folder, create a
  directory named `Kept Parent` containing `Report with spaces.txt` with known
  text. Select `Kept Parent` and use **File Operations > Compress to ZIP**.
  Select the resulting ZIP and use **File Operations > Extract ZIP**. Open the
  new extraction directory and verify `Kept Parent/Report with spaces.txt`
  exists with the original content.

- [ ] **NOT RUN — selected package:** Create or copy a disposable macOS package
  such as `Archive Fixture.app`, with a known file under its `Contents`
  directory. Select only the package and choose **File Operations > Compress to
  ZIP**, then extract the resulting ZIP. Confirm the extracted
  `Archive Fixture.app` remains a package and its known nested file has the
  original content.

- [ ] **NOT RUN — selected symbolic-link policy:** In Terminal, create a target
  file and a relative symbolic link to it, then select only the symbolic link in
  Pengrid and choose **File Operations > Compress to ZIP**. Extract the ZIP into
  its dedicated destination. Run `test -L "Selected Link"` and
  `readlink "Selected Link"` inside the extraction directory; confirm the
  selected item is still a link with the original link text. Confirm the target
  file's bytes were not silently substituted into the archive. Pengrid's 1.3
  policy is to preserve a selected link itself, never follow its target.

- [ ] **NOT RUN — case-sensitive volume:** On a disposable case-sensitive APFS
  volume, create `Case.txt` and `case.txt` with different known contents.
  Multi-select both files, compress them, and extract the ZIP. Confirm both
  distinct names and contents survive. Repeat a keep-both collision on that
  volume and confirm Pengrid never replaces either pre-existing path.

- [ ] **NOT RUN — cloud-provider materialization:** In a Google Drive or
  OneDrive File Provider folder shown by Pengrid, choose an online-only local
  item that has not yet been downloaded. Use **File Operations > Compress to
  ZIP** and confirm macOS materializes the source before the local ZIP appears
  beside it. Then extract that ZIP through **File Operations > Extract ZIP**;
  confirm the extracted local destination has the expected content. Restore or
  remove only the created test artifacts.

## Release gate

- [ ] **NOT RUN:** Record dated `PASS`/`FAIL` evidence for every manual item
  above against the exact candidate commit before treating ZIP operations as a
  release-ready capability.
