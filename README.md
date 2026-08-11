# Pengrid

[한국어](README.ko.md) · **English**

Pengrid is a free, open-source, dual-pane file manager for macOS. It combines
fast keyboard navigation with recursive search, safe queued file operations,
folder previews, archive tools, directory comparison, and storage inspection.

The Swift package, executable, source module, bundle identifier, and existing
persistence locations retain the internal name `BloomFileManager` for
compatibility.

## Download

The current build is
[Pengrid 1.3.0 Developer Preview 5](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.5).
It improves large-folder loading, pane filtering, sorting, and cancellation
while retaining Preview 4's protected-ZIP and file-manager features.

- [Download Pengrid.dmg](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.5/Pengrid.dmg)
- App version: **1.3.0 (build 7)**
- Requirements: **Apple Silicon Mac, macOS 15 or later**
- Verification: **1,223 automated tests in 80 suites**
- DMG SHA-256:
  `3db4c0bd18b7001fe93d83ea92baf7928527d393bc5310e4ba40f7e9d75148e6`

> **Developer Preview trust notice**
>
> This free DMG is ad-hoc signed. It is not Developer ID signed or notarized,
> so macOS Gatekeeper may block it. Download it only from this repository's
> GitHub release page and proceed only if you understand and accept that warning.
> Pengrid does not ask you to disable macOS security controls.

After downloading, open the DMG and copy `Pengrid.app` to `Applications`.
See the [release guide](docs/release.md) for artifact verification and local
packaging instructions.

## Highlights

### Dual-pane workspace

Browse two folders side by side with independent navigation history, sorting,
selection, and pane-local filename filtering. Copy and move workflows operate
between the active pane and the other pane.

### Smart Search, including Korean initial consonants

Press **Command-Shift-F** for recursive filename and relative-path search.
Queries support Korean initial-consonant matching, ordinary text, mixed clauses,
file/folder type, extension, size, and modified-date filters. Searches can be
saved and reopened. Result actions revalidate the captured file identity before
they mutate anything.

### Space-key previews

Press **Space** on one ordinary folder to open Pengrid's read-only, one-level
folder-contents preview. Files, packages, symbolic links, and multiple
selections continue to use system Quick Look. Cloud folder preview reads
available metadata only and does not intentionally download contents.

### Context-menu productivity (current source builds)

Right-clicking a selected row preserves the whole selection; right-clicking an
unselected row selects that row first. Commands consume that captured selection
in visible table order, not in a later pane or selection state. The context menu
keeps **Open** first, then groups **Quick Look**, **Open With**, and **Open in
Other Pane**; **Copy/Move to Other Pane**, **Show in Finder**, and **Copy Path**;
then **New Folder**, **New Folder with Selection**, favorites, **Duplicate**,
rename, existing copy/paste and archive actions, and Trash.

Quick Look keeps **Space**. Open With is available for one regular file,
package, or symbolic link; Open in Other Pane opens one directory there, or selects one
identity-matched non-directory from its captured parent. Copy/Move to Other
Pane use the other pane directory captured at invocation, so later navigation
cannot redirect the job. Show in Finder reveals captured entries without
reading bytes. **Copy Path** offers Full Path (**Option-Command-C**), Name,
Parent Path, and File URL as UTF-8 text in visible order. **Duplicate** uses
**Command-D**, extension-preserving **Keep Both** names, and no-overwrite
publication. **New Folder with Selection** accepts two or more siblings and
moves them transactionally into a validated new folder.

These actions respect text editing, current writability, File Provider
capabilities, progress, cancellation, retry, recovery, and conservative Undo.
Quick Look and Open With can request cloud materialization; path, Finder, and
other-pane navigation do not intentionally read content. Copy, Move, Duplicate,
and enclosure require a currently writable local-file-operation location.

### Preview-first batch rename (current source builds)

Select at least two rows in the active pane, then choose **File Operations >
Batch Rename…** or use the row context menu. Literal find/replace, prefix,
suffix, and stable sequence numbering update editable filename stems while
preserving ordinary extensions, package extensions, and recognized compound
archive suffixes such as `.tar.gz`. A full preview reports unchanged names,
invalid names, duplicates, and sibling collisions before any mutation starts.

Execution is a same-directory, two-phase transaction that supports swaps and
cycles. The operation center reports staging, publishing, and rollback phases;
cancellation restores original names when that can be proven safe. Retry uses
the captured immutable plan, while Undo is offered only when final identities,
fingerprints, and original-name availability still match. The preview path has
an automated 10,000-row regression ceiling of five seconds.

### Safe operation center

Copy, move, Trash, new-folder, rename, compression, extraction, and undo work
through one ordered mutation queue. Queued work can be reordered, paused at safe
checkpoints, or cancelled with cleanup. Retry and undo are offered only when
identity and fingerprint checks show that repeating or reversing an operation
will not overwrite or remove replacement data.

### Archives with visible progress

Create and extract **ZIP**, **TAR**, **TAR.GZ/TGZ**, **TAR.BZ2/TBZ/TBZ2**, and
**TAR.XZ/TXZ** archives. Multi-item preparation uses at most four bounded
workers; the native archive command remains a single operation. Pengrid reports
preparation, encoding, and finishing phases without inventing an unreliable byte
percentage.

### Password-protected ZIP

Source builds create password-protected ZIP files with **AES-256 only**. They
read AES-128, AES-192, AES-256, and ZipCrypto entries using Store or Deflate
under the current safety policy. ZIP filenames and other central-directory
metadata remain visible: encryption is not filename privacy. Passwords are
never saved or recoverable; a failed attempt asks for the password again.

Finder and Archive Utility may not open an AES ZIP. The repository has automated
fixture evidence for third-party interoperability, not a live interoperability
claim. Resource forks, ACLs, and extended attributes are not guaranteed. Unsafe
or oversized archives fail closed; cleanup uncertainty is retained for recovery
review and the queue waits for an explicit continue decision. 7z, RAR, and
password-protected TAR remain unsupported, as do Developer ID signing and
notarization for this source feature.

### Google Drive and OneDrive

Pengrid discovers Google Drive and OneDrive through macOS File Provider. It does
not implement direct Google or Microsoft OAuth. Metadata-only search and folder
preview do not intentionally materialize cloud-only file contents; copy,
archive, or other content-reading operations may ask macOS to download a source.

### Comparison, Storage Inspector, and accessibility

Directory comparison aligns both sides and supports reviewed transfers with
identity revalidation. Storage Inspector progressively finds large, old, and
exact-duplicate local files and sends only explicitly reviewed items to Trash.
Keyboard access, VoiceOver labels, Reduce Motion, and privacy-preserving status
text are built into the workspace.

Read the [detailed feature guide](docs/user-guide.md) for commands, behavior,
safety rules, and current limitations.

## Build from source

Clone the repository:

```bash
git clone https://github.com/pmh10401/Pengrid.git
cd Pengrid
```

Or download the
[main branch source ZIP](https://github.com/pmh10401/Pengrid/archive/refs/heads/main.zip).

Build and verify with full Xcode:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BloomFileManagerTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
open dist/Pengrid.app
```

The development bundle is created at `dist/Pengrid.app`. Its executable remains
`dist/Pengrid.app/Contents/MacOS/BloomFileManager`.

## Documentation

- [Detailed feature guide](docs/user-guide.md)
- [Architecture notes](docs/architecture.md)
- [Current limitations](docs/current-limitations.md)
- [Release and packaging guide](docs/release.md)
- [Developer Preview 5 release notes](docs/release-notes-v1.3.0-developer-preview.5.md)
- [Version 1.3 archive verification](docs/verification/version-1.3-archive-checklist.md)
- [Smart Search verification](docs/verification/2026-08-04-smart-search.md)
- [Folder preview verification](docs/verification/2026-08-04-folder-preview.md)
- [Batch rename verification](docs/verification/2026-08-11-batch-rename.md)
- [File context actions verification](docs/verification/2026-08-11-file-context-actions.md)
- [Storage Inspector verification](docs/verification/storage-inspector-checklist.md)

Pengrid is under active development. Candidate-specific manual checks that have
not been run remain marked `NOT RUN` in the verification documents.
