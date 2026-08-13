<p align="center">
  <img src="Assets/Pengrid/AppIcon-1024.png" width="160" alt="Pengrid app icon">
</p>

<h1 align="center">Pengrid</h1>

<p align="center">
  <strong>A fast, keyboard-friendly dual-pane file manager for macOS.</strong><br>
  <a href="README.ko.md">한국어</a> · <strong>English</strong>
</p>

Pengrid combines two-pane navigation, recursive search, previews, queued file
operations, archive tools, directory comparison, and storage inspection in one
free, open-source macOS app.

## Download

The current release is
[Pengrid 1.3.0 Developer Preview 6](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.6).

- [Download Pengrid.dmg](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.6/Pengrid.dmg)
- Version: **1.3.0 (build 8)**
- Requirements: **Apple Silicon Mac, macOS 15 or later**
- Verification: **1,407 automated tests in 92 suites**
- DMG SHA-256:
  `ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32`

Open the DMG, then copy `Pengrid.app` to `Applications`.

> **Developer Preview trust notice**
>
> This free DMG is ad-hoc signed. It is not Developer ID signed or notarized,
> so macOS Gatekeeper may block it. Download it only from this repository's
> GitHub release page and proceed only if you understand and accept the warning.
> Pengrid does not ask you to disable macOS security controls.

See the [release guide](docs/release.md) for artifact verification and local
packaging instructions.

## Why Pengrid

- **Work in context:** browse two independent panes and transfer files between
  the captured source and destination instead of opening many Finder windows.
- **Stay on the keyboard:** search, filter, preview, duplicate, copy paths, and
  manage common file actions with focused desktop shortcuts.
- **Prefer recoverable operations:** queued mutations revalidate file identity,
  report progress, clean up cancellation, and offer Retry or Undo only when the
  captured state still makes them safe.

## What You Can Do

### Navigate and manage two panes

Each pane keeps its own history, selection, sorting, and filename filter. Copy,
move, Open in Other Pane, and reviewed comparison transfers use the pane and
destination captured when the command starts.

### Keep several workspaces ready

Use workspace tabs to keep independent dual-pane folder pairs open. **Command-T**
opens a tab from the active tab's persisted layout, **Command-W** closes the active
tab when it has no active or queued file work, and **Control-Tab** / **Control-Shift-Tab**
move between tabs. Tab titles show both pane folder names, never their full paths.

Save a named workspace profile from the tab bar, then open it from the Profiles menu
to create a new tab without changing the existing one. The session restores tab
folders, sort orders, split position, active pane, and profiles; selections, filters,
history, previews, searches, and operation state are intentionally not restored.

### Find files quickly

Smart Search scans filenames and relative paths recursively. It supports
ordinary text, Korean initial-consonant matching, mixed queries, type,
extension, size, and modified-date filters. Searches can be saved and reopened.
The optional **Search indexed file contents** filter is off by default: it uses
only already-indexed Spotlight content, never downloads cloud-only files, and
reports when content coverage is unavailable or skipped for an initial-consonant
query.

### Preview and act without losing context

Press **Space** to preview one folder's immediate contents or open system Quick
Look for files, packages, symbolic links, and multiple selections. The context
menu includes Open, Open With, Open in Other Pane, Show in Finder, Copy Path,
Duplicate, New Folder with Selection, rename, archives, and Trash.

Preview 6 captures the visible selection before dispatch, so later navigation
or selection changes cannot silently redirect an action. Read the
[release notes](docs/release-notes-v1.3.0-developer-preview.6.md) for the exact
selection and capability rules.

Press **Command-I**, or choose **Get Info** from a row's context menu, to open a
nonmodal read-only inspector for the captured selection. It reports metadata for
one item or a multiple-selection summary; directory sizes are entry sizes, not
recursive totals. SHA-256 is calculated only after choosing the explicit button
for one eligible regular file, which may require macOS to download a cloud-only
file.

### Run safer file operations

Copy, move, Trash, rename, new-folder, archive, and Undo jobs share an ordered
operation center. Jobs expose progress and safe cancellation points; exclusive
transactions such as batch rename and New Folder with Selection use staged
publication and conservative rollback checks.

### Create and extract archives

Pengrid creates and extracts **ZIP**, **TAR**, **TAR.GZ/TGZ**,
**TAR.BZ2/TBZ/TBZ2**, and **TAR.XZ/TXZ**. Progress distinguishes preparation,
encoding, and finishing phases. Source builds also create AES-256
password-protected ZIP files and read supported AES and ZipCrypto entries.

### Work with cloud locations and accessibility tools

Google Drive and OneDrive appear through macOS File Provider. Metadata-only
search and folder preview avoid intentional content downloads; byte-reading
operations may ask macOS to materialize an online-only item. Pengrid also
includes directory comparison, Storage Inspector, keyboard navigation,
VoiceOver labels, Reduce Motion support, and privacy-preserving status text.

## Essential Shortcuts

| Shortcut | Action |
| --- | --- |
| **Space** | Folder preview or system Quick Look |
| **Command-F** | Filter the active pane |
| **Command-Shift-F** | Smart Search from the active pane |
| **Command-I** | Get Info for the captured selection |
| **Command-T** | New workspace tab |
| **Command-W** | Close active workspace tab when safe |
| **Control-Tab** | Next workspace tab |
| **Control-Shift-Tab** | Previous workspace tab |
| **Command-D** | Duplicate the captured selection |
| **Option-Command-C** | Copy full paths in visible order |

Batch Rename and the remaining context actions are available from the File
Operations menu or a row's context menu.

## Cloud and Safety Boundaries

- Pengrid discovers cloud roots through macOS File Provider. It does not
  implement direct Google or Microsoft OAuth.
- Availability, write capability, and materialization remain controlled by the
  installed provider and macOS.
- Password-protected ZIP encryption does not hide filenames or other central
  directory metadata. Passwords are never saved or recoverable.
- 7z, RAR, password-protected TAR, Developer ID signing, and notarization are
  not included in this Developer Preview.
- Manual checks that have not been run remain explicitly marked `NOT RUN` in
  the verification documents.

For detailed behavior, safety rules, and limitations, read the
[feature guide](docs/user-guide.md) and
[current limitations](docs/current-limitations.md).

## Build from Source

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

The development app is created at `dist/Pengrid.app`. The Swift package,
executable, source module, bundle identifier, and existing persistence paths
retain the internal name `BloomFileManager` for compatibility.

## Documentation

- [Detailed feature guide](docs/user-guide.md)
- [Developer Preview 6 release notes](docs/release-notes-v1.3.0-developer-preview.6.md)
- [Release and packaging guide](docs/release.md)
- [Architecture notes](docs/architecture.md)
- [Current limitations](docs/current-limitations.md)
- [Verification records](docs/verification/)

Pengrid is under active development. Contributions and reproducible issue
reports are welcome.
