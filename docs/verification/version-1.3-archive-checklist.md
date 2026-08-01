# Pengrid version 1.3 multi-format archive verification checklist

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
  selections with macOS `ditto`, verifies selected symbolic links remain
  links for ZIP and every TAR-family format, and verifies malformed-ZIP
  cleanup. It also exercises renamed TAR aliases (**TGZ**, **TBZ**, **TBZ2**,
  and **TXZ**) and rejects a hostile TAR fixture containing both `..` traversal
  and a symlink escape without publishing a destination or writing outside it.
  Current multi-format automated evidence must additionally cover **ZIP**,
  **TAR**, **TAR.GZ** and **TGZ**, **TAR.BZ2**, **TBZ**, and **TBZ2**, and
  **TAR.XZ** and **TXZ**. The TAR aliases are extraction inputs; newly
  compressed TAR-family archives use canonical `.tar`, `.tar.gz`, `.tar.bz2`,
  and `.tar.xz` names.

- [x] **PASS — 2026-08-01 — final candidate
  `multi-format-archive-verified`:** The required serial suite, release
  packaging contract checks, and Apple Silicon production build completed for
  the final multi-format archive candidate:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
  ./script/tests/package_release_contract_tests.sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build -c release --arch arm64
  ```

  Each command exited 0. The serial suite covered `BloomFileManagerTests`; the
  release contract script passed; and SwiftPM reported `Build complete!` for
  the arm64 release build. The stable verification marker
  `multi-format-archive-verified` points to this final verified HEAD; it is
  created only after these commands are rerun against that exact HEAD.

## Manual verification

- [ ] **NOT RUN — keyboard and menu discovery:** In an active file pane, select
  a regular file or folder. Open the menu-bar path **File Operations > Compress
  to** and confirm its ZIP, TAR, TAR.GZ, TAR.BZ2, and TAR.XZ choices, then
  repeat from **Control-click row > Compress to**. With Full Keyboard Access
  enabled, use the menu bar and arrow keys to reach each command; confirm it
  can be invoked without a pointing device. Select one archive for every
  recognized suffix—`.zip`, `.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz`,
  `.tbz2`, `.tar.xz`, and `.txz`—and confirm both menu paths expose its
  format-aware **Extract** command.

- [ ] **NOT RUN — unsupported extraction disabled:** Select only a local `.txt`
  file. Confirm the format-aware **Extract** commands in File Operations and
  the contextual menu are disabled. Select a directory and a mixed
  supported-archive/non-archive selection and confirm extraction remains
  disabled in both locations. Confirm RAR, 7z, and password-protected archives
  remain unsupported.

- [ ] **NOT RUN — collision behavior:** In one local test folder, create
  `Notes.txt`, then pre-create the proposed ZIP and each canonical TAR-family
  destination before selecting `Notes.txt` and compressing in every format.
  Confirm existing archives remain unchanged and each new archive receives the
  next available name (for example, `Notes.txt 2.tar.gz`). Extract an archive
  whose proposed destination directory already exists and confirm the existing
  directory remains unchanged while Pengrid uses the next available name (for
  example, `Notes 2`).

- [ ] **NOT RUN — cancellation and bounded-staging cleanup:** In a local test
  folder, select enough separate large sources to exercise multi-source staging,
  choose every compression format in turn, and activate the status row's
  **Cancel** control while staging or archiving is running. Confirm no final
  archive appears. The staging phase may copy sources in parallel, but must use
  no more than four workers and no more than the available processor or source
  count; the native archive command is not parallelized. In Terminal, change to
  the selected destination's parent, then run `find "$PWD" -maxdepth 1 -name
  '.archive-source-*'`; it must print no paths. Repeat during extraction of a
  sufficiently large local archive in every canonical format; confirm no partial
  extraction directory or staging path remains.

- [ ] **NOT RUN — VoiceOver labels:** Enable VoiceOver, start compression and
  extraction of a large local fixture in every canonical format, then move
  VoiceOver focus to the archive status row and Cancel button. Confirm labels
  announce the selected format (for example, **Compressing TAR.GZ archive** or
  **Extracting TAR.XZ archive**), the current item, and the matching
  format-aware cancellation label.

- [ ] **NOT RUN — local round trip:** In a local test folder, create a
  directory named `Kept Parent` containing `Report with spaces.txt` with known
  text. Select `Kept Parent`, create ZIP, TAR, TAR.GZ, TAR.BZ2, and TAR.XZ
  archives, and extract each canonical archive. Also extract copies renamed to
  `.tgz`, `.tbz`, `.tbz2`, and `.txz`. Open every new extraction directory and
  verify `Kept Parent/Report with spaces.txt` exists with the original content.

- [ ] **NOT RUN — selected package:** Create or copy a disposable macOS package
  such as `Archive Fixture.app`, with a known file under its `Contents`
  directory. Select only the package and create/extract each canonical archive.
  Confirm every extracted `Archive Fixture.app` remains a package and its known
  nested file has the original content.

- [ ] **NOT RUN — selected symbolic-link policy:** In Terminal, create a target
  file and a relative symbolic link to it, then select only the symbolic link in
  Pengrid and create/extract each canonical archive into its dedicated
  destination. Run `test -L "Selected Link"` and `readlink "Selected Link"`
  inside every extraction directory; confirm the selected item is still a link
  with the original link text. Confirm the target file's bytes were not silently
  substituted into an archive. Pengrid's 1.3 policy is to preserve a selected
  link itself, never follow its target.

- [ ] **NOT RUN — case-sensitive volume:** On a disposable case-sensitive APFS
  volume, create `Case.txt` and `case.txt` with different known contents.
  Multi-select both files, create/extract each canonical archive, and confirm
  both distinct names and contents survive. Repeat a keep-both collision on
  that volume and confirm Pengrid never replaces either pre-existing path.

- [ ] **NOT RUN — cloud-provider materialization:** In a Google Drive or
  OneDrive File Provider folder shown by Pengrid, choose an online-only local
  item that has not yet been downloaded. Create every canonical archive and
  confirm macOS materializes the source before each local archive appears
  beside it. Extract each archive through its format-aware **Extract** command;
  confirm the extracted local destination has the expected content. Restore or
  remove only the created test artifacts.

## Release gate

- [ ] **NOT RUN:** Record dated `PASS`/`FAIL` evidence for every manual item
  above against the exact candidate commit before treating ZIP or TAR-family
  archive operations as release-ready capabilities. The release remains an
  explicitly unsigned Developer Preview until the separate Developer ID,
  notarization, stapling, and Gatekeeper gates are passed.
