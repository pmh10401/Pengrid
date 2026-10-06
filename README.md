<p align="center">
  <img src="Assets/Pengrid/AppIcon-1024.png" width="112" alt="Pengrid penguin app icon">
</p>

<h1 align="center">Pengrid</h1>

<p align="center">
  <strong>Your files, side by side. Your ideas, one hover away.</strong><br>
  A free native macOS file manager with a movable notch shelf.<br><br>
  <a href="https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0"><strong>Download for Mac</strong></a>
  · <a href="README.ko.md">한국어</a>
  · <a href="docs/user-guide.md">Feature guide</a>
</p>

![Pengrid dual-pane workspace with sample project files](docs/images/workspace.png)

*Real Pengrid views with sample data. Screenshots do not contain personal files or cloud accounts.*

## Download

[**Pengrid 1.3.0 — download the DMG**](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0/Pengrid.dmg)

**Apple Silicon · macOS 15+ · version 1.3.0, build 14 · free · stable GitHub release**

Open the DMG and drag `Pengrid.app` to `Applications`. Verify your download with
[SHA256SUMS.txt](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0/SHA256SUMS.txt):

```bash
shasum -a 256 -c SHA256SUMS.txt
```

> This release is ad-hoc signed, not Developer ID signed or
> Apple-notarized. Gatekeeper may block it. Obtain the app from this repository's
> release page; Pengrid does not ask you to disable macOS security controls.

[Release notes](docs/release-notes-v1.3.0.md) ·
[Packaging and verification](docs/release.md)

## A shelf that belongs at the edge

Keep a file reference, a useful note, or an image close to your next task.
Enable **Settings > Top Shelf > Enable Top Shelf**, then drag an item in or
choose **Import Clipboard**. Clipboard import is always manual.

![Pengrid dark-glass horizontal notch shelf with image, text and file cards](docs/images/notch-shelf.png)

The shelf can disappear inside a supported MacBook's camera notch. Hover to
reveal it; leave to fold it after a short grace period. Click to keep it open.
Drag the six-dot grip along the display border: it flows around corners,
settles on the chosen edge, and opens inward. Release near the camera notch
to dock there again; **Escape** cancels a move.

<table>
  <tr>
    <td align="center" width="46%">
      <img src="docs/images/side-shelf.png" width="300" alt="Vertical shelf docked to the right screen edge">
    </td>
    <td align="center" width="54%">
      <img src="docs/images/shelf-settings.png" width="460" alt="Korean shelf settings with Liquid Glass, edge and retention options">
    </td>
  </tr>
  <tr>
    <td>Left and right: upright, vertically scrolling cards.</td>
    <td>Choose Liquid Glass, Dark Glass, or Solid Black.</td>
  </tr>
</table>

- **Search with Korean initials:** filter filenames, notes and image names.
  Category capsules show the actual counts for All, Files, Text and Images.
- **Keep your place:** query, category and selection survive edge changes.
  Search and clipboard controls stay fixed while cards scroll.
- **Use the keyboard:** select cards with **← / →** horizontally or **↑ / ↓**
  vertically, then **⌘C** to copy. Arrows in the search field edit text.
- **See ongoing work:** the shelf shows active file-operation progress, queued
  jobs and recovery/failure states when attention is needed.
- **Choose retention:** **Clear on Quit** is the default; **Keep Between
  Launches** saves an unencrypted local snapshot. Removing a shelf entry
  preserves the original file.

Liquid Glass requires **macOS 26+**. On older macOS versions or with Reduce
Transparency enabled, the shelf uses solid black. Reduce Motion disables
the movement animations. Menu-bar commands, file context menus, shelf controls
and shelf settings support Korean and English; some dialogs and error messages
remain English.

The shelf accepts up to **50 items**, **256 KiB per text item**, **16 MiB / 40
megapixels per static PNG/TIFF image**, and **64 MiB total encoded payload**.
File entries are references. There is no automatic clipboard sampling, OCR,
cloud shelf sync or global hotkey. [Full shelf behavior](docs/user-guide.md#top-shelf)

## A file manager first

| Workflow | What Pengrid provides |
| --- | --- |
| **Two panes, several workspaces** | Independent history, filters and sorting. Tabs, named profiles, session layouts and reopening closed tabs. |
| **Find files** | Recursive name/path search, Korean initials, type/extension/size/date filters, saved searches and optional already-indexed Spotlight content search. |
| **Preview in place** | **Space** opens a folder's immediate contents or system Quick Look. **⌘I** opens read-only Get Info. |
| **Act from a context menu** | Open With, Open in Other Pane, Copy Path, Duplicate, New Folder with Selection, rename and batch rename. |
| **Follow file operations** | Ordered copy/move/Trash/archive jobs, progress, safe cancellation, and conservative Undo/Redo where supported. |
| **Create and extract archives** | ZIP, TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2 and TAR.XZ/TXZ. Create AES-256 ZIP; read supported AES and ZipCrypto ZIP entries. |
| **Review before synchronizing** | Directory comparison, checksum verification and review-first one-way folder synchronization. |
| **Understand storage** | Storage Inspector with scoped scans and reviewed duplicate cleanup. |
| **Use your cloud folders** | Discover the installed Google Drive and OneDrive macOS File Provider roots. |

Optional transferred-content verification compares regular-file data with
SHA-256 in staging before eligible copies, duplicates, cross-volume moves and
reviewed synchronization results are published. It is off by default.
[Details and verification scope](docs/user-guide.md#optional-transferred-content-verification)

Cloud content and write availability remain controlled by macOS and the
installed provider. Content-reading actions may download online-only files;
metadata search avoids intentional downloads. Pengrid does not implement
direct Google or Microsoft OAuth. 7z, RAR and password-protected TAR are not
supported. [Current limitations](docs/current-limitations.md)

## Essential shortcuts

| Shortcut | Action |
| --- | --- |
| **Space** | Folder preview / system Quick Look |
| **⌘F** / **⇧⌘F** | Pane filter / Smart Search |
| **⌘P** | Quick Go command and location palette |
| **⌘I** | Get Info |
| **⌘T** / **⌘W** / **⇧⌘T** | New / close / reopen workspace tab |
| **⌃Tab** / **⌃⇧Tab** | Next / previous workspace tab |
| **⌘D** / **⌥⌘C** | Duplicate / copy full paths |
| **⌥⌘N** | Create an empty file and start rename |
| **⌥⌘A** / **⌥⌘I** / **⌥⌘E** | Select visible / invert / same extension |
| **⌥⌘S** | Select by one filename wildcard pattern |
| **⌘?** | Bilingual offline Help |

File-action shortcuts respect the active pane, text-editing focus and current
selection. [Detailed command behavior](docs/user-guide.md)

## Build from source

The app uses **Swift 6, SwiftUI and AppKit**, with a C core for encrypted ZIP.
Install full **Xcode 26 or later** with the macOS 26 SDK to compile the current
glass APIs; the built app still supports macOS 15.

```bash
git clone https://github.com/pmh10401/Pengrid.git
cd Pengrid
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BloomFileManagerTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
open dist/Pengrid.app
```

The package, executable, module and compatibility-sensitive persistence identity
retain the internal name `BloomFileManager`.

## Documentation and contributions

- [Detailed feature guide](docs/user-guide.md) · [한국어 기능 안내](docs/user-guide.ko.md)
- [Version 1.3.0 release notes](docs/release-notes-v1.3.0.md)
- [Release guide](docs/release.md) · [Architecture](docs/architecture.md)
- [Limitations](docs/current-limitations.md) · [Version 1.3.0 verification](docs/verification/v1.3.0-release-check.md)
- [Screenshot provenance](docs/images/README.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

The feature candidate passed **2,055 automated tests in 131 suites**.
Automated coverage does not replace the physical cloud-provider, accessibility
or volume checks recorded separately in the verification documents.

The shelf interaction references [PenguinNotch](https://github.com/pmh10401/PenguinNotch)
and the card-gallery layout references [Supaste](https://www.supaste.com/).
Pengrid is an independent app. Third-party attribution is included in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Reproducible [issue reports](https://github.com/pmh10401/Pengrid/issues) and
focused pull requests are welcome.
