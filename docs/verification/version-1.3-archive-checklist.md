# Pengrid version 1.3 ZIP archive verification checklist

Verification record opened: 2026-07-31 (Asia/Seoul)

Use only `PASS`, `FAIL`, or `NOT RUN` for each item. Automated local-process
coverage does not replace the physical macOS, File Provider, keyboard, or
VoiceOver checks below.

## Automated evidence

- [ ] **NOT RUN:** Run the focused live-`ditto` integration suite from the
  candidate worktree:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --enable-swift-testing --no-parallel \
    --filter ArchiveOperationIntegrationTests
  ```

  The suite creates temporary local files, round-trips a spaced filename with
  macOS `ditto`, and verifies malformed-ZIP failure cleanup.

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
