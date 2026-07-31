# Pengrid

Pengrid is a dual-pane macOS file manager. The Swift package, executable, source
module, bundle identifier, and existing persistence locations retain the internal
name `BloomFileManager` for compatibility.

## Setup and verification

```bash
swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
./script/build_and_run.sh --verify
```

The development bundle is created at `dist/Pengrid.app`. Its executable remains
`dist/Pengrid.app/Contents/MacOS/BloomFileManager`.

## Download the source

Pengrid is currently available as a developer preview. Download the latest
reviewed source from the
[Pengrid repository](https://github.com/pmh10401/Pengrid) as a
[source ZIP](https://github.com/pmh10401/Pengrid/archive/refs/heads/main.zip),
or clone the repository:

```bash
git clone https://github.com/pmh10401/Pengrid.git
cd Pengrid
```

An unsigned compiled DMG is also available from the
[Pengrid 1.3 Developer Preview](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.1).
It is not Developer ID signed or notarized, so only open it when you downloaded
it directly from this repository's GitHub release page.

The current verified development target is Apple Silicon on macOS 15 or newer
with full Xcode installed.

## Build locally

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --enable-swift-testing --no-parallel --filter BloomFileManagerTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
open dist/Pengrid.app
```

Locally built or ad-hoc signed artifacts may trigger macOS trust warnings.
They are development artifacts, not the signed public release.

Google Drive and OneDrive locations are discovered through macOS File Provider.
This is macOS File Provider integration, not direct Google or Microsoft
OAuth/API integration, and Pengrid does not ask for those credentials.

## Storage Inspector

Storage Inspector is an on-demand workspace for local folders and directly
attached volumes. It publishes bounded scan batches progressively, groups only
fully verified exact duplicates, shows large and long-unmodified files, and
moves only explicitly reviewed, identity-revalidated selections to the macOS
Trash while retaining at least one copy. It does not background-index, traverse
symbolic links or packages, permanently delete files, or analyze cloud-only
content.

Generated scale, privacy, recovery, and identity-safe cleanup checks are
automated. Physical storage, real 100,000-file, disconnect/reconnect, Trash,
accessibility, and appearance checks remain unrun release gates in
`docs/verification/storage-inspector-checklist.md`.

## Navigation productivity

Each pane has an independent current-folder filename filter, Back and Forward
history, and session-only selection and scroll restoration. An open Quick Look
panel follows selection changes through the same identity and cloud
materialization safety gates used when it first opens.

The filename filter works only on the directory listing already loaded in
memory. It is not recursive or file-content search, and it does not download
cloud-only files.

## ZIP archives

Pengrid can create and extract ZIP archives from **File Operations** or a file
row's contextual menu. ZIP compression and extraction are the only archive
operations delivered in this release. Archive work is performed locally beside
the selected destination; a cloud-backed source may be downloaded first when
macOS File Provider needs to materialize it.

Archive destinations are never overwritten. Pengrid chooses an available name
before starting and exclusive publication rejects a late collision, leaving the
existing item unchanged. Password-protected archives and 7z, RAR, and tar
formats are not supported in this release.

## Release status

See `docs/release.md`, `docs/verification/version-1.1-checklist.md`,
`docs/verification/version-1.2-checklist.md`,
`docs/verification/version-1.3-archive-checklist.md`, and
`docs/verification/storage-inspector-checklist.md`. The 1.3 GitHub release is
an explicitly unsigned Developer Preview DMG: it has not been Developer ID
signed or notarized, and macOS may show a Gatekeeper warning. A signed public
release still requires the documented Developer ID, notarization, stapling,
Gatekeeper, and physical-manual gates.

Create and inspect the unsigned local app with:

```bash
./script/package_release.sh --unsigned
codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
```

The `--unsigned` mode ad-hoc signs and replaces
`dist/release/Pengrid.app` and `dist/release/Pengrid.dmg`; it does not produce
or replace `dist/release/Pengrid.zip`. The `--signed` mode produces and
publishes the app, DMG, and ZIP. Any ZIP already present after an unsigned run
may be an older signed release. SwiftPM commands and the internal
`Sources/BloomFileManager` and `Tests/BloomFileManagerTests` module paths
remain unchanged.
