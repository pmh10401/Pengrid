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
[Pengrid 1.3.0 Developer Preview 4](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.4).
It is the first published Pengrid DMG that includes password-protected ZIP
creation and extraction.

- [Download Pengrid.dmg](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.4/Pengrid.dmg)
- App version: **1.3.0 (build 6)**
- Requirements: **Apple Silicon Mac, macOS 15 or later**
- Verification: **1,059 automated tests in 77 suites**
- DMG SHA-256:
  `700f4dac87e07b76809d06b3ee5c237a7126550663a087ddc9a9547f9669c585`

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
- [Release and packaging guide](docs/release.md)
- [Developer Preview 4 release notes](docs/release-notes-v1.3.0-developer-preview.4.md)
- [Version 1.3 archive verification](docs/verification/version-1.3-archive-checklist.md)
- [Smart Search verification](docs/verification/2026-08-04-smart-search.md)
- [Folder preview verification](docs/verification/2026-08-04-folder-preview.md)
- [Storage Inspector verification](docs/verification/storage-inspector-checklist.md)

Pengrid is under active development. Candidate-specific manual checks that have
not been run remain marked `NOT RUN` in the verification documents.
