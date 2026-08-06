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

- [x] **PASS — 2026-08-03 — phase-aware archive progress:** The full serial
  Swift Testing run passed **651 tests in 51 suites** with zero failures. The
  release build and app-bundle process verification also exited 0. Automated
  coverage verifies ordered top-level preparation counts, indeterminate native
  encoding, publication only after staged-output verification, cancellation and
  failure cleanup, format-aware VoiceOver copy, and omission of absolute parent
  paths from archive status labels.

  ```bash
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift test --disable-sandbox \
    --enable-swift-testing --no-parallel
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift build -c release --disable-sandbox
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./script/build_and_run.sh --verify
  ```

  The existing `@preconcurrency` and weak-variable compiler warnings remain;
  this change introduced no new warning category.

- [x] **PASS — 2026-08-06 — Developer Preview 3 publication:** The exact
  `v1.3.0-developer-preview.3` candidate
  `5ec4c8789bf7a101b2fbdfd3cb80ccbf062a3bc6`, version 1.3.0 (build 5),
  passed the full serial Swift Testing run with **851 tests in 66 suites**.
  Release packaging contract tests and the Apple Silicon arm64 production
  build also exited 0.

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --enable-swift-testing --no-parallel \
    --filter BloomFileManagerTests
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./script/tests/package_release_contract_tests.sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./script/package_release.sh --unsigned
  ```

  The package script produced an arm64, ad-hoc-signed app and verified DMG.
  Independent checks passed `codesign --verify --deep --strict`,
  `hdiutil verify`, read-only DMG mounting, the mounted app signature, and
  mounted `CFBundleVersion` value `5`. The final DMG SHA-256 is
  `1a0498c45ecc13ba57f2a4f8553ef1b0f760cca004cef2d46307780c6b29f0df`.

  GitHub published the asset at the
  [Developer Preview 3 release](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.3)
  with the same SHA-256 digest. A fresh download compared byte-for-byte equal
  to the verified local artifact. `spctl --assess --type execute` exited 3
  and rejected the app, which is the expected trust result for an ad-hoc-signed
  artifact without Developer ID signing or Apple notarization. It is not a
  packaging-integrity failure and the release notes identify the limitation.

- [x] **PASS — 2026-08-07 — Developer Preview 4 release candidate:** The
  packaged source commit
  `9ae22293b498fde487f1f92ff7b05a917125621e`, version 1.3.0 (build 6),
  passed the full serial Swift Testing run with **1,059 tests in 77 suites**.
  The release packaging contract suite passed, and unsigned packaging produced
  an exactly arm64, ad-hoc-signed app plus a verified DMG.

  Independent checks passed `codesign --verify --deep --strict`, `file`,
  `lipo -archs`, `hdiutil verify`, read-only DMG mounting, mounted-app signature
  verification, notice byte comparison, and mounted `CFBundleVersion` value
  `6`. The 4,566,794-byte DMG SHA-256 is
  `700f4dac87e07b76809d06b3ee5c237a7126550663a087ddc9a9547f9669c585`.

  The same app was installed at `/Applications/Pengrid.app`, where its version,
  build, signature, and arm64 executable were rechecked before a successful
  launch. The previous build 4 install was moved to the user's Trash so it
  remains recoverable. This local launch is not a fresh-download Gatekeeper or
  notarization test.

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
  format-aware cancellation label. During multi-item compression, confirm
  preparation announces the exact top-level count (for example, **Preparing
  files, 2 of 5**); native encoding announces **Encoding archive** without a
  misleading percentage; and exclusive publication announces **Finishing
  archive**. Confirm none of these announcements exposes an absolute parent
  path.

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

- [x] **PASS — 2026-08-06 — unsigned Developer Preview publication:** The
  build 5 candidate is published as the explicitly unsigned
  `v1.3.0-developer-preview.3` prerelease with its trust warning and verified
  SHA-256 digest.

- [ ] **NOT RUN — physical-manual and signed-distribution gates:** Record dated
  `PASS`/`FAIL` evidence for every manual item above against the exact
  candidate before treating all ZIP and TAR-family behavior as physically
  verified. Developer ID signing, Apple notarization, ticket stapling, and
  Gatekeeper acceptance also remain uncompleted. Neither result is implied by
  the automated unsigned publication evidence.
